from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER_ROOT = Path(__file__).resolve().parents[1]
VENDOR_ROOT = HELPER_ROOT / "vendor" / "rednote"
MANIFEST_PATH = HELPER_ROOT / "upstream-manifest.json"
SPEC = importlib.util.spec_from_file_location(
    "downloader_verify_vendor", HELPER_ROOT / "verify_vendor.py"
)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class VendorIntegrityTests(unittest.TestCase):
    def test_complete_vendor_matches_manifest(self):
        self.assertEqual(VERIFIER.verify_vendor(), [])

    def test_only_approved_files_have_documented_patches(self):
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.assertEqual(len(manifest["files"]), 69)
        self.assertEqual(
            {
                entry["path"]
                for entry in manifest["files"]
                if entry["upstream_sha256"] != entry["vendored_sha256"]
            },
            {"app/main.py", "tests/test_stop.py"},
        )

    def test_modified_missing_and_unlisted_files_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="chengying-vendor-integrity-") as name:
            root = Path(name) / "vendor"
            shutil.copytree(VENDOR_ROOT, root)
            (root / "app" / "errors.py").write_text("# Modified.\n", encoding="utf-8")
            (root / "LICENSE").unlink()
            (root / "unexpected.py").write_text("# Unexpected.\n", encoding="utf-8")
            errors = VERIFIER.verify_vendor(root)
            self.assertIn("Vendored file hash mismatch: app/errors.py", errors)
            self.assertIn("Missing or unreadable vendored file: LICENSE", errors)
            self.assertIn("Untracked vendored file: unexpected.py", errors)

    def test_symlink_cannot_redirect_an_expected_source_file(self):
        with tempfile.TemporaryDirectory(prefix="chengying-vendor-symlink-") as name:
            root = Path(name) / "vendor"
            shutil.copytree(VENDOR_ROOT, root)
            source = root / "LICENSE"
            source.unlink()
            source.symlink_to(VENDOR_ROOT / "LICENSE")
            self.assertIn(
                "Symlinks are not allowed in vendored source: LICENSE",
                VERIFIER.verify_vendor(root),
            )

    def test_runtime_cache_files_do_not_change_source_integrity(self):
        with tempfile.TemporaryDirectory(prefix="chengying-vendor-cache-") as name:
            root = Path(name) / "vendor"
            shutil.copytree(VENDOR_ROOT, root)
            cache = root / "app" / "__pycache__"
            cache.mkdir(exist_ok=True)
            (cache / "main.cpython-311.pyc").write_bytes(b"test cache")
            self.assertEqual(VERIFIER.verify_vendor(root), [])


class WritablePathIsolationTests(unittest.TestCase):
    def _run_import(self, *, override_paths: bool):
        with tempfile.TemporaryDirectory(prefix="chengying-downloader-paths-") as name:
            root = Path(name)
            engine = root / "engine"
            shutil.copytree(VENDOR_ROOT, engine)
            state = root / "external" / "Application Support" / "Downloader"
            downloads = root / "external" / "Downloaded Media"
            env = os.environ.copy()
            for key in (
                "CHENGYING_DOWNLOAD_DATA_DIR",
                "CHENGYING_DOWNLOAD_DEFAULT_DIR",
                "PYTHONPATH",
            ):
                env.pop(key, None)
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            if override_paths:
                env["CHENGYING_DOWNLOAD_DATA_DIR"] = str(state)
                env["CHENGYING_DOWNLOAD_DEFAULT_DIR"] = str(downloads)
            else:
                state = engine / "data"
                downloads = engine / "downloads"
            script = """
import json
from app import main
try:
    main._save_config(main.config)
    print(json.dumps({
        'project': str(main.PROJECT_ROOT),
        'static': str(main.STATIC_DIR),
        'data': str(main.DATA_DIR),
        'config': str(main.CONFIG_PATH),
        'default_download': str(main.DEFAULT_DOWNLOAD_DIR),
        'download': str(main.config.download_dir),
        'store': str(main.manager.store.state_dir),
    }))
finally:
    main.manager.shutdown(wait=True, cancel_running=True)
"""
            result = subprocess.run(
                [sys.executable, "-c", script],
                cwd=engine,
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=True,
            )
            paths = json.loads(result.stdout)
            self.assertEqual(paths["project"], str(engine.resolve()))
            self.assertEqual(paths["static"], str((engine / "app" / "static").resolve()))
            self.assertEqual(paths["data"], str(state.resolve()))
            self.assertEqual(paths["config"], str((state / "config.json").resolve()))
            self.assertEqual(paths["store"], str((state / "state").resolve()))
            self.assertEqual(paths["default_download"], str(downloads.resolve()))
            self.assertEqual(paths["download"], str(downloads.resolve()))
            self.assertTrue((state / "config.json").is_file())
            self.assertTrue((state / "state").is_dir())
            self.assertTrue(downloads.is_dir())
            if override_paths:
                self.assertFalse((engine / "data").exists())
                self.assertFalse((engine / "downloads").exists())

    def test_native_app_writes_only_to_explicit_user_paths(self):
        self._run_import(override_paths=True)

    def test_unset_environment_preserves_upstream_defaults(self):
        self._run_import(override_paths=False)


if __name__ == "__main__":
    unittest.main()
