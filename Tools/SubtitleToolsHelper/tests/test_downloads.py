import hashlib
import io
import os
import sys
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from downloads import Artifact, ArtifactStore, AssetError, Cancelled, certificate_file
from runtime import extract_runtime, operation_lock

DATA = bytes(range(256)) * 2048


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.ranges.append(self.headers.get("Range"))
        data = self.server.data
        offset = int(self.headers.get("Range", "bytes=0-")[6:-1])
        behavior = self.server.behavior
        if behavior == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://example.com/model")
            self.end_headers()
            return
        if behavior == "416":
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{len(data)}")
            self.end_headers()
            return
        partial = offset > 0 and behavior != "ignore"
        self.send_response(206 if partial else 200)
        if partial:
            begin = offset + (1 if behavior == "bad_range" else 0)
            self.send_header("Content-Range", f"bytes {begin}-{len(data) - 1}/{len(data)}")
        else:
            offset = 0
        self.send_header("Content-Length", str(len(data) - offset))
        self.end_headers()
        body = data[offset:]
        if behavior == "disconnect":
            body = body[:len(body) // 2]
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-download-test-")
        self.root = Path(self.temporary.name).resolve()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.data = DATA
        self.server.behavior = "normal"
        self.server.ranges = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.artifact = Artifact("weights", "models/weights.bin", f"http://127.0.0.1:{self.server.server_port}/weights", len(DATA), hashlib.sha256(DATA).hexdigest())
        self.store = ArtifactStore(self.root, allow_local_http=True, reserve_bytes=0)
        self.cancel = threading.Event()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def part(self, data):
        path = self.store.path(self.artifact, partial=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_resumes_with_range_and_verifies(self):
        self.part(DATA[:12345])
        events = []
        result = self.store.ensure(self.artifact, self.cancel, lambda *args: events.append(args))
        self.assertEqual(result.read_bytes(), DATA)
        self.assertEqual(self.server.ranges, ["bytes=12345-"])
        self.assertTrue(self.store.ready(self.artifact))
        self.assertFalse(self.store.path(self.artifact, partial=True).exists())
        self.assertEqual({item[1] for item in events}, {"download", "verify"})

    def test_server_ignoring_range_restarts_without_concatenating(self):
        self.part(b"wrong-prefix")
        self.server.behavior = "ignore"
        self.assertEqual(self.store.ensure(self.artifact, self.cancel).read_bytes(), DATA)

    def test_disconnect_retains_and_new_store_resumes(self):
        self.server.behavior = "disconnect"
        with self.assertRaises(AssetError):
            self.store.ensure(self.artifact, self.cancel)
        part = self.store.path(self.artifact, partial=True)
        retained = part.stat().st_size
        self.assertGreater(retained, 0)
        self.assertFalse(self.store.ready(self.artifact))
        self.server.behavior = "normal"
        restarted = ArtifactStore(self.root, allow_local_http=True, reserve_bytes=0)
        self.assertEqual(restarted.ensure(self.artifact, self.cancel).read_bytes(), DATA)
        self.assertEqual(self.server.ranges[-1], f"bytes={retained}-")

    def test_bad_206_does_not_append(self):
        part = self.part(DATA[:500])
        self.server.behavior = "bad_range"
        with self.assertRaisesRegex(AssetError, "range"):
            self.store.ensure(self.artifact, self.cancel)
        self.assertEqual(part.read_bytes(), DATA[:500])

    def test_checksum_failure_never_publishes(self):
        self.server.data = b"z" * len(DATA)
        with self.assertRaisesRegex(AssetError, "SHA-256"):
            self.store.ensure(self.artifact, self.cancel)
        self.assertFalse(self.store.ready(self.artifact))
        self.assertFalse(self.store.path(self.artifact).exists())
        self.assertFalse(self.store.path(self.artifact, partial=True).exists())

    def test_complete_part_is_verified_without_another_request(self):
        self.server.behavior = "416"
        self.part(DATA)
        self.assertEqual(self.store.ensure(self.artifact, self.cancel).read_bytes(), DATA)
        self.assertEqual(self.server.ranges, [])

    def test_416_with_incomplete_part_fails_without_publishing(self):
        self.server.behavior = "416"
        part = self.part(DATA[:500])
        with self.assertRaisesRegex(AssetError, "416"):
            self.store.ensure(self.artifact, self.cancel)
        self.assertEqual(part.read_bytes(), DATA[:500])
        self.assertFalse(self.store.path(self.artifact).exists())

    def test_cancel_retains_prefix(self):
        def progress(artifact, stage, count, rate):
            if stage == "download":
                self.cancel.set()
        with self.assertRaises(Cancelled):
            self.store.ensure(self.artifact, self.cancel, progress)
        self.assertGreater(self.store.path(self.artifact, partial=True).stat().st_size, 0)
        self.assertFalse(self.store.ready(self.artifact))
        self.cancel.clear()
        self.assertEqual(self.store.ensure(self.artifact, self.cancel).read_bytes(), DATA)

    def test_changed_ready_file_is_rejected(self):
        destination = self.store.ensure(self.artifact, self.cancel)
        destination.write_bytes(b"x" * len(DATA))
        self.assertFalse(self.store.ready(self.artifact))
        self.assertEqual(self.store.ensure(self.artifact, self.cancel).read_bytes(), DATA)
        self.assertTrue(destination.with_name(destination.name + ".invalid").exists())

    def test_symlinks_and_traversal_are_rejected(self):
        with self.assertRaises(AssetError):
            Artifact.from_dict({"id": "x", "path": "../x", "url": "https://example.com/x", "size": 1, "sha256": "0" * 64})
        (self.root / "models").symlink_to(self.root)
        with self.assertRaises(AssetError):
            self.store.ensure(self.artifact, self.cancel)

    def test_partial_symlink_is_rejected(self):
        path = self.part(b"existing")
        path.unlink()
        path.symlink_to(self.root / "outside")
        with self.assertRaises(AssetError):
            self.store.ensure(self.artifact, self.cancel)
        self.assertFalse((self.root / "outside").exists())

    def test_http_is_disabled_in_production(self):
        production = ArtifactStore(self.root)
        with self.assertRaisesRegex(AssetError, "HTTPS"):
            production.ensure(self.artifact, self.cancel)

    def test_redirect_to_nonlocal_http_is_rejected(self):
        self.server.behavior = "redirect"
        with self.assertRaisesRegex(AssetError, "HTTPS"):
            self.store.ensure(self.artifact, self.cancel)

    def test_disk_space_failure_preserves_existing_prefix(self):
        partial = self.part(DATA[:500])
        with patch("downloads.shutil.disk_usage") as usage:
            usage.return_value.free = 0
            with self.assertRaisesRegex(AssetError, "disk space"):
                self.store.ensure(self.artifact, self.cancel)
        self.assertEqual(partial.read_bytes(), DATA[:500])
        self.assertEqual(self.server.ranges, [])


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-runtime-test-")
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, entries):
        archive = self.root / "runtime.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            for name, content, link in entries:
                info = tarfile.TarInfo(name)
                if link is not None:
                    info.type = tarfile.SYMTYPE
                    info.linkname = link
                    target.addfile(info)
                else:
                    info.size = len(content)
                    target.addfile(info, io.BytesIO(content))
        return archive

    def test_safe_internal_symlink_is_supported(self):
        archive = self.archive([("python/bin/python3.13", b"python", None), ("python/bin/python3", b"", "python3.13")])
        target = self.root / "target"
        target.mkdir()
        extract_runtime(archive, target, threading.Event(), lambda *_: None)
        self.assertEqual((target / "python/bin/python3").read_bytes(), b"python")

    def test_path_traversal_and_escaping_links_are_rejected(self):
        for name, content, link in [("../escape", b"x", None), ("python/bin/python3", b"", "../../../escape")]:
            with self.subTest(name=name, link=link):
                archive = self.archive([(name, content, link)])
                target = self.root / "target"
                target.mkdir(exist_ok=True)
                with self.assertRaises(AssetError):
                    extract_runtime(archive, target, threading.Event(), lambda *_: None)
                self.assertFalse((self.root / "escape").exists())

    def test_process_lock_excludes_another_operation(self):
        with operation_lock(self.root), self.assertRaisesRegex(AssetError, "Another subtitle operation"), operation_lock(self.root):
            self.fail("A second operation acquired the lock")


class CertificateTests(unittest.TestCase):
    def test_macos_system_ca_precedes_compiled_python_defaults(self):
        with patch.dict(os.environ, {}, clear=True), patch("downloads.sys.platform", "darwin"), patch.object(Path, "is_file", lambda path: str(path) == "/etc/ssl/cert.pem"):
            self.assertEqual(certificate_file(), "/etc/ssl/cert.pem")

    def test_explicit_ca_precedes_system_ca(self):
        with patch.dict(os.environ, {"SSL_CERT_FILE": "/custom/ca.pem"}):
            self.assertEqual(certificate_file(), "/custom/ca.pem")


if __name__ == "__main__":
    unittest.main()
