import hashlib
import io
import json
import os
import selectors
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from downloads import AssetError, Cancelled
from helper import Supervisor, load_manifest
from runtime import Runtime, run_process


def fixture_manifest():
    def artifact(identifier, path, url):
        return {"id": identifier, "path": path, "url": url, "size": 1, "sha256": hashlib.sha256(b"x").hexdigest()}
    revision = "a" * 40
    return {
        "schema_version": 1,
        "runtime": {"id": "test-runtime", "python_executable": "python/bin/python3",
                    "archive": artifact("python", "downloads/python.tar.gz", "https://example.com/python.tar.gz"),
                    "wheels": [artifact("wheel", "wheels/test.whl", "https://example.com/test.whl")],
                    "requirements": ["test==1.0 --hash=sha256:" + "a" * 64]},
        "models": [{"id": name, "name": name, "directory": f"models/{name}", "revision": revision,
                    "repository": "test/model", "artifacts": [artifact(name, f"models/{name}/weights", f"https://huggingface.co/test/model/resolve/{revision}/weights")]}
                   for name in ("asr", "aligner", "translator")],
    }


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-helper-test-")
        self.root = Path(self.temporary.name).resolve()
        self.events = []
        self.supervisor = Supervisor(fixture_manifest(), "manifest-hash", self.root, self.root, "/ffmpeg", "/ffprobe", self.events.append)

    def tearDown(self):
        self.supervisor.close()
        self.temporary.cleanup()

    def test_status_does_not_claim_unverified_models_are_ready(self):
        for artifact in self.supervisor.artifacts:
            destination = self.supervisor.store.path(artifact)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"x")
        self.supervisor.request({"id": "status", "command": "status"})
        event = self.events[-1]
        self.assertEqual(event["type"], "status")
        self.assertEqual(event["downloaded_bytes"], event["total_bytes"])
        self.assertFalse(any(model["ready"] for model in event["models"]))
        self.assertFalse(event["runtime_ready"])

    def test_prepare_start_mutually_exclusive_but_status_and_cancel_work(self):
        entered = threading.Event()

        def pending(*args):
            entered.set()
            while not self.supervisor._cancel.wait(0.01):
                pass
            raise Cancelled("Cancelled")

        with patch.object(self.supervisor.store, "ensure", side_effect=pending):
            self.supervisor.request({"id": "prepare", "command": "prepare"})
            self.assertTrue(entered.wait(3))
            self.supervisor.request({"id": "status", "command": "status"})
            self.assertEqual(self.events[-1]["type"], "status")
            self.assertEqual(self.events[-1]["active_id"], "prepare")
            self.supervisor.request({"id": "start", "command": "start", "input_path": "/video"})
            self.assertEqual(self.events[-1]["type"], "failed")
            self.supervisor.request({"id": "cancel", "command": "cancel", "target_id": "prepare"})
            self.supervisor._thread.join(3)
        self.assertTrue(any(event.get("type") == "cancelled" and event.get("id") == "prepare" for event in self.events))
        self.assertIsNone(self.supervisor.status()["active_id"])

    def test_unknown_cancel_target_does_not_cancel_current_operation(self):
        self.supervisor.request({"id": "cancel", "command": "cancel", "target_id": "missing"})
        self.assertEqual(self.events[-1]["type"], "failed")
        self.assertFalse(self.supervisor._cancel.is_set())

    def test_manifest_requires_pinned_revision_and_rejects_duplicate_paths(self):
        path = self.root / "assets.json"
        valid = fixture_manifest()
        path.write_text(json.dumps(valid))
        manifest, fingerprint = load_manifest(path)
        self.assertEqual(len(fingerprint), 64)
        self.assertEqual(manifest["schema_version"], 1)
        valid["models"][0]["revision"] = "main"
        path.write_text(json.dumps(valid))
        with self.assertRaisesRegex(AssetError, "fixed repository commit"):
            load_manifest(path)

    def test_worker_subprocess_is_terminated_on_cancel(self):
        cancel = threading.Event()
        started = threading.Event()
        process_ids = []
        caught = []

        def output(line):
            process_ids.append(int(line))
            started.set()

        def run():
            try:
                run_process([sys.executable, "-u", "-c", "import os,time; print(os.getpid()); time.sleep(60)"], cancel, output)
            except Cancelled:
                caught.append(True)

        thread = threading.Thread(target=run)
        thread.start()
        self.assertTrue(started.wait(3))
        cancel.set()
        thread.join(8)
        self.assertFalse(thread.is_alive())
        self.assertEqual(caught, [True])
        with self.assertRaises(ProcessLookupError):
            os.kill(process_ids[0], 0)

    def test_terminal_event_is_emitted_after_active_state_is_cleared(self):
        video = self.root / "video.mp4"
        video.write_bytes(b"not-a-video")
        self.supervisor.request({"id": "job", "command": "start", "input_path": str(video)})
        self.supervisor._thread.join(3)
        self.assertEqual(self.events[-1]["type"], "failed")
        self.assertIsNone(self.events[-1]["active_id"])
        self.assertIsNone(self.supervisor.status()["active_id"])

    def test_worker_receives_verified_local_models_and_offline_environment(self):
        video = self.root / "video.mp4"
        video.write_bytes(b"video")
        for _, artifacts in self.supervisor.models:
            for artifact in artifacts:
                path = self.supervisor.store.path(artifact)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"x")
        captured = []

        def worker(command, cancel, output, *, env, on_stderr):
            payload = json.loads(Path(command[-1]).read_text())
            captured.append(payload)
            self.assertEqual(command[-2], "--request-json")
            self.assertEqual(env["HF_HUB_OFFLINE"], "1")
            self.assertEqual(env["TRANSFORMERS_OFFLINE"], "1")
            self.assertEqual(payload["models"]["asr"], str(self.root / "models/asr"))
            on_stderr('{"type":"failed","error":"This is a diagnostic, not a protocol event."}')
            output(json.dumps({"type": "completed", "outputs": {"srt": "/output.srt"}, "partial": True, "warnings": ["Burn skipped."]}))
            return 0

        with patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.runtime, "python", return_value=Path(sys.executable)), patch("helper.run_process", side_effect=worker):
            self.supervisor.request({"id": "job", "command": "start", "input_path": str(video), "burn_subtitles": True})
            self.supervisor._thread.join(3)
        self.assertEqual(len(captured), 1)
        terminal = self.events[-1]
        self.assertEqual(terminal["type"], "completed")
        self.assertEqual(terminal["warnings"], ["Burn skipped."])
        self.assertTrue(terminal["partial"])
        self.assertEqual(list((self.root / "requests").iterdir()), [])

    def test_missing_model_does_not_start_worker_or_download(self):
        video = self.root / "video.mp4"
        video.write_bytes(b"video")
        with patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.store, "ensure") as download, patch("helper.run_process") as worker:
            self.supervisor.request({"id": "job", "command": "start", "input_path": str(video)})
            self.supervisor._thread.join(3)
        self.assertEqual(self.events[-1]["type"], "failed")
        download.assert_not_called()
        worker.assert_not_called()

    def test_shutdown_waits_for_cancelled_operation(self):
        entered = threading.Event()

        def pending(*args):
            entered.set()
            self.supervisor._cancel.wait(3)
            raise Cancelled("Cancelled")

        with patch.object(self.supervisor.store, "ensure", side_effect=pending):
            self.supervisor.request({"id": "prepare", "command": "prepare"})
            self.assertTrue(entered.wait(3))
            self.supervisor.request({"id": "shutdown", "command": "shutdown"})
        self.assertFalse(self.supervisor._thread.is_alive())
        self.assertEqual(self.events[-1]["id"], "shutdown")
        self.assertEqual(self.events[-1]["type"], "completed")
        self.assertTrue(any(event.get("type") == "cancelled" for event in self.events))

    def test_cancel_kills_grandchildren_even_when_they_ignore_sigterm(self):
        cancel = threading.Event()
        started = threading.Event()
        identifiers = []
        caught = []
        child = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print(os.getpid(),flush=True); time.sleep(60)"
        parent = f"import os,subprocess,sys,time; p=subprocess.Popen([sys.executable,'-u','-c',{child!r}],stdout=subprocess.PIPE,text=True); print(p.stdout.readline().strip(),flush=True); time.sleep(60)"

        def output(line):
            identifiers.append(int(line))
            started.set()

        def run():
            try:
                run_process([sys.executable, "-u", "-c", parent], cancel, output)
            except Cancelled:
                caught.append(True)

        thread = threading.Thread(target=run)
        thread.start()
        self.assertTrue(started.wait(3))
        cancel.set()
        thread.join(8)
        self.assertFalse(thread.is_alive())
        self.assertEqual(caught, [True])
        # A killed orphan can briefly remain a zombie until init reaps it.
        state = subprocess.run(["ps", "-p", str(identifiers[0]), "-o", "stat="], capture_output=True, text=True, timeout=3, check=False).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), state)

    def test_sigterm_to_supervisor_cleans_up_running_worker(self):
        helper_root = str(Path(__file__).resolve().parents[1])
        program = f"""import sys
sys.path.insert(0, {helper_root!r})
from helper import Supervisor, main
from runtime import run_process
def fake_start(self, request, emit, progress):
    run_process([sys.executable, '-u', '-c', 'import os,time; print(os.getpid()); time.sleep(60)'], self._cancel, lambda line: emit({{'type':'progress','stage':'test','pid':int(line)}}))
Supervisor._start = fake_start
raise SystemExit(main())
"""
        process = subprocess.Popen([sys.executable, "-u", "-c", program, "--ffmpeg", "/ffmpeg", "--ffprobe", "/ffprobe", "--data-dir", str(self.root), "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        worker_pid = None
        try:
            process.stdin.write(b'{"id":"job","command":"start"}\n')
            process.stdin.flush()
            buffer = b""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and worker_pid is None:
                for key, _ in selector.select(timeout=0.2):
                    buffer += os.read(key.fileobj.fileno(), 65536)
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        event = json.loads(line)
                        worker_pid = event.get("pid", worker_pid)
            self.assertIsNotNone(worker_pid)
            process.terminate()
            process.communicate(timeout=8)
            self.assertEqual(process.returncode, 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(worker_pid, 0)
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)

    def test_worker_stderr_cannot_forge_protocol_events(self):
        output, diagnostics = [], []
        program = "import sys; print('{\"type\":\"progress\"}'); print('{\"type\":\"completed\"}', file=sys.stderr)"
        result = run_process([sys.executable, "-u", "-c", program], threading.Event(), output.append, on_stderr=diagnostics.append)
        self.assertEqual(result, 0)
        self.assertEqual(output, ['{"type":"progress"}'])
        self.assertEqual(diagnostics, ['{"type":"completed"}'])


class RuntimeInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-offline-install-test-")
        self.root = Path(self.temporary.name).resolve()
        self.manifest = fixture_manifest()
        archive = self.root / self.manifest["runtime"]["archive"]["path"]
        archive.parent.mkdir(parents=True)
        with tarfile.open(archive, "w:gz") as target:
            entry = tarfile.TarInfo("python/bin/python3")
            entry.size = 6
            entry.mode = 0o755
            target.addfile(entry, io.BytesIO(b"python"))
        self.runtime = Runtime(self.root, self.manifest, "test-fingerprint")

    def tearDown(self):
        self.temporary.cleanup()

    def test_installer_is_offline_hash_required_and_atomically_published(self):
        calls = []

        def execute(command, cancel, log, *, env):
            calls.append(command)
            self.assertFalse(self.runtime.directory.exists())
            self.assertEqual(env["PIP_NO_INDEX"], "1")
            return 0

        with patch("runtime.run_process", side_effect=execute):
            self.runtime.ensure(threading.Event(), lambda event: None)
        self.assertTrue(self.runtime.ready())
        self.assertEqual(len(calls), 3)
        for argument in ("--no-index", "--no-deps", "--require-hashes", "--only-binary=:all:"):
            self.assertIn(argument, calls[1])
        self.assertEqual(list((self.root / "runtime").glob(".installing-*")), [])
        self.runtime.python().write_bytes(b"modified")
        self.assertFalse(self.runtime.ready())

    def test_broken_imports_do_not_publish_ready_runtime(self):
        with patch("runtime.run_process", side_effect=[0, 0, 1]), self.assertRaisesRegex(AssetError, "Offline runtime validation failed"):
            self.runtime.ensure(threading.Event(), lambda event: None)
        self.assertFalse(self.runtime.ready())
        self.assertFalse(self.runtime.directory.exists())

    def test_failed_pip_does_not_publish_ready_runtime(self):
        with patch("runtime.run_process", side_effect=[0, 1]), self.assertRaisesRegex(AssetError, "Offline runtime installation failed"):
            self.runtime.ensure(threading.Event(), lambda event: None)
        self.assertFalse(self.runtime.ready())
        self.assertFalse(self.runtime.directory.exists())
        self.assertEqual(list((self.root / "runtime").glob(".installing-*")), [])

    def test_runtime_rejects_unhashed_or_index_injected_requirements(self):
        for requirement in ("test>=1", "test==1 --index-url=https://example.com", "--extra-index-url=https://example.com"):
            with self.subTest(requirement=requirement):
                self.manifest["runtime"]["requirements"] = [requirement]
                with self.assertRaisesRegex(AssetError, "exact versions"):
                    Runtime(self.root, self.manifest, "fingerprint")


if __name__ == "__main__":
    unittest.main()
