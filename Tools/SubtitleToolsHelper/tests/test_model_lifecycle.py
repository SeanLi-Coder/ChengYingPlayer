"""Model lifecycle regressions using tiny local fixtures, never real weights."""

import copy
import hashlib
import json
import sys
import tempfile
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from downloads import Cancelled
from helper import Supervisor
from runtime import operation_lock
from test_helper import fixture_manifest


class ModelLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-model-lifecycle-")
        self.root = Path(self.temporary.name).resolve()
        self.manifest = fixture_manifest()
        self.events = []
        self.supervisors = []
        self.supervisor = self.make_supervisor()

    def tearDown(self):
        for supervisor in self.supervisors:
            supervisor.close()
        self.temporary.cleanup()

    def make_supervisor(self, manifest=None, fingerprint="fixture-manifest"):
        supervisor = Supervisor(manifest or self.manifest, fingerprint, self.root,
                                self.root, "/ffmpeg", "/ffprobe", self.events.append)
        self.supervisors.append(supervisor)
        return supervisor

    def write(self, relative, value=b"x"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
        return path

    def populate(self, *, runtime_marker=True):
        for artifact in self.supervisor.artifacts:
            self.write(artifact.path)
        executable = self.write("runtime/test-runtime/python/bin/python3", b"python")
        if runtime_marker:
            marker = {"validation_version": 1,
                      "manifest_sha256": self.supervisor.runtime.fingerprint,
                      "python_sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
            self.write("runtime/test-runtime/.ready.json", json.dumps(marker).encode())

    def run_request(self, command, *, supervisor=None, **arguments):
        supervisor = supervisor or self.supervisor
        identifier = f"{command}-{len(self.events)}"
        supervisor.request({"id": identifier, "command": command, **arguments})
        if supervisor._thread is not None:
            supervisor._thread.join(5)
            self.assertFalse(supervisor._thread.is_alive(), "Lifecycle operation did not finish")
        terminals = [event for event in self.events if event.get("id") == identifier
                     and event.get("type") in {"completed", "failed", "cancelled"}]
        self.assertEqual(len(terminals), 1)
        return terminals[0]

    def model(self, identifier, supervisor=None):
        return next(model for model in (supervisor or self.supervisor).status()["models"]
                    if model["id"] == identifier)

    @contextmanager
    def offline_only(self):
        with patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("Network is forbidden")) as network, \
             patch.object(self.supervisor.store, "ensure", side_effect=AssertionError("Download is forbidden")) as download, \
             patch("runtime.run_process", side_effect=AssertionError("Runtime installation is forbidden")) as install:
            yield
            network.assert_not_called()
            download.assert_not_called()
            install.assert_not_called()

    def test_restart_recognizes_complete_models_without_network_or_reinstallation(self):
        self.populate()
        for artifact in self.supervisor.artifacts:
            self.assertTrue(self.supervisor.store.verify(artifact, threading.Event()))
        restarted = self.make_supervisor(fingerprint="upgraded-whole-manifest")
        self.assertFalse(any(model["ready"] for model in restarted.status()["models"]))
        with self.offline_only():
            terminal = self.run_request("verify", supervisor=restarted)
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertTrue(all(model["ready"] for model in restarted.status()["models"]))
        self.assertTrue(restarted.status()["runtime_ready"])

    def test_verification_reports_missing_model_without_fetching_it(self):
        self.populate()
        (self.root / "models/aligner/weights").unlink()
        with self.offline_only():
            self.run_request("verify")
        self.assertFalse(self.model("aligner")["ready"])
        self.assertEqual(self.model("aligner")["downloaded_bytes"], 0)
        self.assertTrue(self.model("asr")["ready"])
        self.assertFalse((self.root / "models/aligner/weights").exists())

    def test_verification_rejects_same_size_corruption_without_replacing_it(self):
        self.populate()
        corrupt = self.write("models/asr/weights", b"z")
        with self.offline_only():
            self.run_request("verify")
        self.assertFalse(self.model("asr")["ready"])
        self.assertTrue(self.model("asr")["needs_repair"])
        self.assertEqual(corrupt.read_bytes(), b"z")
        self.assertTrue(self.model("translator")["ready"])
        self.assertFalse(self.model("translator")["needs_repair"])

    def test_invalid_model_markers_clear_after_replacing_and_verifying_valid_files(self):
        self.populate()
        for contents in (b"z", b"too-long", b""):
            with self.subTest(contents=contents):
                path = self.write("models/asr/weights", contents)
                with self.offline_only():
                    self.run_request("verify")
                self.assertFalse(self.model("asr")["ready"])
                self.assertTrue(self.model("asr")["needs_repair"])
                self.assertTrue(self.model("translator")["ready"])
                self.assertFalse(self.model("translator")["needs_repair"])
                path.write_bytes(b"x")
                self.assertFalse(self.model("asr")["ready"])
                self.assertFalse(self.model("asr")["needs_repair"])
                with self.offline_only():
                    self.run_request("verify")
                self.assertTrue(self.model("asr")["ready"])
                self.assertFalse(self.model("asr")["needs_repair"])

    def test_deleting_invalid_model_clears_repair_state_without_affecting_other_models(self):
        self.populate()
        self.write("models/asr/weights", b"z")
        self.write("models/asr/weights.invalid", b"old-invalid")
        self.write("models/aligner/weights", b"also-bad")
        with self.offline_only():
            self.run_request("verify")
        self.assertTrue(self.model("asr")["needs_repair"])
        self.assertTrue(self.model("aligner")["needs_repair"])
        with self.offline_only():
            terminal = self.run_request("delete_model", model_id="asr")
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertFalse(self.model("asr")["ready"])
        self.assertFalse(self.model("asr")["needs_repair"])
        self.assertEqual(self.model("asr")["stored_bytes"], 0)
        self.assertNotIn("models/asr/weights", self.supervisor.store._invalid)
        self.assertTrue(self.model("aligner")["needs_repair"])
        self.assertEqual((self.root / "models/aligner/weights").read_bytes(), b"also-bad")
        self.assertTrue(self.model("translator")["ready"])
        self.assertFalse(self.model("translator")["needs_repair"])
        self.assertTrue(self.supervisor.runtime.ready())

    def test_verification_does_not_publish_partial_download_as_ready(self):
        self.populate()
        (self.root / "models/asr/weights").unlink()
        partial = self.write("models/asr/weights.part")
        with self.offline_only():
            self.run_request("verify")
        self.assertFalse(self.model("asr")["ready"])
        self.assertFalse(self.model("asr")["needs_repair"])
        self.assertEqual(partial.read_bytes(), b"x")

    def test_changed_model_lock_does_not_accept_old_verified_bytes(self):
        self.populate()
        self.run_request("verify")
        changed = copy.deepcopy(self.manifest)
        changed["models"][0]["artifacts"][0]["sha256"] = hashlib.sha256(b"y").hexdigest()
        restarted = self.make_supervisor(changed, "upgraded-model-lock")
        with self.offline_only():
            self.run_request("verify", supervisor=restarted)
        self.assertFalse(self.model("asr", restarted)["ready"])
        self.assertTrue(self.model("translator", restarted)["ready"])
        self.assertEqual((self.root / "models/asr/weights").read_bytes(), b"x")

    def test_installed_runtime_survives_missing_archive_and_wheel_cache(self):
        self.populate()
        (self.root / "downloads/python.tar.gz").unlink()
        (self.root / "wheels/test.whl").unlink()
        with self.offline_only():
            terminal = self.run_request("verify")
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertTrue(self.supervisor.status()["runtime_ready"])
        self.assertTrue(all(model["ready"] for model in self.supervisor.status()["models"]))
        self.assertFalse((self.root / "downloads/python.tar.gz").exists())

    def test_known_legacy_runtime_marker_migrates_locally(self):
        self.populate()
        marker = self.root / "runtime/test-runtime/.ready.json"
        payload = json.loads(marker.read_text())
        payload["manifest_sha256"] = "old-whole-manifest"
        marker.write_text(json.dumps(payload))
        manifest = copy.deepcopy(self.manifest)
        manifest["legacy_runtime_manifests"] = {"old-whole-manifest": self.supervisor.runtime.fingerprint}
        restarted = self.make_supervisor(manifest, "new-whole-manifest")
        with self.offline_only():
            terminal = self.run_request("verify", supervisor=restarted)
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertTrue(restarted.runtime.ready())
        self.assertEqual(json.loads(marker.read_text())["manifest_sha256"], restarted.runtime.fingerprint)

    def test_unknown_legacy_marker_does_not_trigger_install_or_become_ready(self):
        self.populate()
        marker = self.root / "runtime/test-runtime/.ready.json"
        payload = json.loads(marker.read_text())
        payload["manifest_sha256"] = "unrecognized-runtime"
        marker.write_text(json.dumps(payload))
        with self.offline_only():
            self.run_request("verify")
        self.assertFalse(self.supervisor.runtime.ready())
        self.assertEqual(json.loads(marker.read_text())["manifest_sha256"], "unrecognized-runtime")

    def test_prepare_does_not_fetch_runtime_cache_when_runtime_is_installed(self):
        self.populate()
        (self.root / "downloads/python.tar.gz").unlink()
        (self.root / "wheels/test.whl").unlink()
        with patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("Network is forbidden")) as network, \
             patch.object(self.supervisor.store, "ensure", wraps=self.supervisor.store.ensure) as ensure, \
             patch("runtime.run_process", side_effect=AssertionError("Installation is forbidden")) as install:
            terminal = self.run_request("prepare")
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertEqual([call.args[0].id for call in ensure.call_args_list], ["asr", "aligner", "translator"])
        network.assert_not_called()
        install.assert_not_called()
        self.assertFalse((self.root / "downloads/python.tar.gz").exists())
        self.assertTrue(self.supervisor.runtime.ready())

    def test_prepare_migrates_legacy_runtime_before_install_space_is_reserved(self):
        self.populate()
        marker = self.root / "runtime/test-runtime/.ready.json"
        payload = json.loads(marker.read_text())
        payload["manifest_sha256"] = "fixture-manifest"
        marker.write_text(json.dumps(payload))
        with patch("helper.ensure_space") as space, \
             patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("Network is forbidden")) as network, \
             patch("runtime.run_process", side_effect=AssertionError("Installation is forbidden")) as install:
            terminal = self.run_request("prepare")
        self.assertEqual(terminal["type"], "completed", terminal)
        space.assert_called_once_with(self.root, 0)
        network.assert_not_called()
        install.assert_not_called()
        self.assertTrue(self.supervisor.runtime.ready())

    def test_delete_removes_only_selected_manifest_files_and_sidecars(self):
        self.populate()
        self.run_request("verify")
        partial = self.write("models/asr/weights.part", b"partial")
        invalid = self.write("models/asr/weights.invalid", b"bad")
        protected = [self.write("models/asr/user-notes.txt", b"notes"),
                     self.write("summaries/result/report.md", b"report"),
                     self.write("downloads/private-notes.txt", b"private")]
        protected += [self.root / "models/aligner/weights", self.root / "models/translator/weights",
                      self.root / "runtime/test-runtime/.ready.json", self.root / "downloads/python.tar.gz",
                      self.root / "wheels/test.whl"]
        snapshots = {path: path.read_bytes() for path in protected}
        with self.offline_only():
            terminal = self.run_request("delete_model", model_id="asr")
        self.assertEqual(terminal["type"], "completed", terminal)
        self.assertFalse((self.root / "models/asr/weights").exists())
        self.assertFalse(partial.exists())
        self.assertFalse(invalid.exists())
        self.assertFalse(self.model("asr")["ready"])
        self.assertEqual(self.model("asr")["downloaded_bytes"], 0)
        self.assertTrue(self.model("aligner")["ready"])
        self.assertTrue(self.supervisor.runtime.ready())
        for path, contents in snapshots.items():
            self.assertEqual(path.read_bytes(), contents, str(path))

    def test_delete_already_missing_model_is_safe_and_repeatable(self):
        for _ in range(2):
            terminal = self.run_request("delete_model", model_id="asr")
            self.assertEqual(terminal["type"], "completed", terminal)
        self.assertEqual(self.model("asr")["downloaded_bytes"], 0)

    def test_delete_rejects_unknown_or_path_like_identifiers(self):
        self.populate()
        for identifier in (None, "", "runtime", "../asr", "/models/asr", ["asr"], {"id": "asr"}):
            with self.subTest(identifier=identifier):
                terminal = self.run_request("delete_model", model_id=identifier)
                self.assertEqual(terminal["type"], "failed", terminal)
                self.assertEqual((self.root / "models/asr/weights").read_bytes(), b"x")

    def test_delete_rejects_sidecar_symlinks_before_removing_valid_files(self):
        self.populate()
        protected = self.write("protected.txt", b"keep")
        link = self.root / "models/asr/weights.part"
        link.symlink_to(protected)
        terminal = self.run_request("delete_model", model_id="asr")
        self.assertEqual(terminal["type"], "failed", terminal)
        self.assertEqual(protected.read_bytes(), b"keep")
        self.assertTrue(link.is_symlink())
        self.assertEqual((self.root / "models/asr/weights").read_bytes(), b"x")

    def test_delete_never_recurses_into_directory_at_an_artifact_path(self):
        protected = self.write("models/asr/weights/child", b"keep")
        terminal = self.run_request("delete_model", model_id="asr")
        self.assertEqual(terminal["type"], "failed", terminal)
        self.assertEqual(protected.read_bytes(), b"keep")

    def test_delete_obeys_cross_process_operation_lock(self):
        self.populate()
        with operation_lock(self.root):
            terminal = self.run_request("delete_model", model_id="asr")
        self.assertEqual(terminal["type"], "failed", terminal)
        self.assertEqual((self.root / "models/asr/weights").read_bytes(), b"x")

    def test_verification_can_cancel_and_delete_is_rejected_while_busy(self):
        self.populate()
        entered = threading.Event()

        def pending(*args, **kwargs):
            entered.set()
            self.supervisor._cancel.wait(5)
            raise Cancelled("Cancelled locally")

        with patch.object(self.supervisor.store, "verify", side_effect=pending):
            self.supervisor.request({"id": "checking", "command": "verify"})
            self.assertTrue(entered.wait(3))
            self.supervisor.request({"id": "deleting", "command": "delete_model", "model_id": "asr"})
            self.assertEqual(self.events[-1]["type"], "failed")
            self.supervisor.request({"id": "cancel-check", "command": "cancel", "target_id": "checking"})
            self.supervisor._thread.join(5)
        self.assertFalse(self.supervisor._thread.is_alive())
        self.assertTrue(any(event.get("id") == "checking" and event["type"] == "cancelled" for event in self.events))
        self.assertIsNone(self.supervisor.status()["active_id"])
        self.assertEqual((self.root / "models/asr/weights").read_bytes(), b"x")

    def test_delete_rejects_cancel_and_finishes_its_bounded_operation(self):
        self.populate()
        entered, release = threading.Event(), threading.Event()

        @contextmanager
        def pending_lock(root):
            entered.set()
            self.assertTrue(release.wait(5))
            yield

        with patch("helper.operation_lock", pending_lock):
            try:
                self.supervisor.request({"id": "deleting", "command": "delete_model", "model_id": "asr"})
                self.assertTrue(entered.wait(3))
                self.supervisor.request({"id": "cancel-delete", "command": "cancel", "target_id": "deleting"})
                self.assertEqual(self.events[-1]["type"], "failed")
                self.assertFalse(self.supervisor._cancel.is_set())
            finally:
                release.set()
                if self.supervisor._thread is not None:
                    self.supervisor._thread.join(5)
        self.assertFalse(self.supervisor._thread.is_alive())
        self.assertTrue(any(event.get("id") == "deleting" and event["type"] == "completed" for event in self.events))
        self.assertFalse((self.root / "models/asr/weights").exists())


if __name__ == "__main__":
    unittest.main()
