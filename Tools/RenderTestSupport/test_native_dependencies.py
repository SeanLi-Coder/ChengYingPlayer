"""Check isolated native-test dependency selection and identity fences."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("native_dependencies.sh").resolve()
LIBRARIES = (
    "libavcodec.61.dylib", "libavformat.61.dylib", "libavutil.59.dylib",
    "libswresample.5.dylib", "libswscale.8.dylib",
)


class NativeDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-dependency-boundary.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.make_deps(self.root / "deps", b"original")

    def make_deps(self, path, data):
        (path / "include/libavcodec").mkdir(parents=True)
        (path / "include/libavcodec/avcodec.h").write_bytes(data)
        (path / "lib").mkdir()
        for name in LIBRARIES:
            (path / "lib" / name).write_bytes(data + name.encode())

    def run_helper(self, function="prepare_native_test_dependencies", override=None):
        env = dict(os.environ)
        env.pop("NATIVE_PLAYBACK_DEPS", None)
        if override is not None:
            env["NATIVE_PLAYBACK_DEPS"] = str(override)
        return subprocess.run(
            ["/bin/bash", "-c", 'set -euo pipefail; repo_root="$1"; test_dir="$2"; source "$3"; "$4"',
             "native-dependency-test", str(self.root), str(self.artifacts), str(HELPER), function],
            env=env, capture_output=True, text=True, timeout=10)

    def test_default_and_unchanged_validation(self):
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.artifacts / "dependency-root.txt").read_text().strip(),
                         str((self.root / "deps").resolve()))
        self.assertEqual(self.run_helper("validate_native_test_dependencies").returncode, 0)

    def test_explicit_candidate_does_not_replace_default(self):
        candidate = self.root / "isolated candidate"
        self.make_deps(candidate, b"candidate")
        original = (self.root / "deps/lib" / LIBRARIES[0]).read_bytes()
        self.assertEqual(self.run_helper(override=candidate).returncode, 0)
        self.assertEqual((self.artifacts / "dependency-root.txt").read_text().strip(),
                         str(candidate.resolve()))
        self.assertEqual((self.root / "deps/lib" / LIBRARIES[0]).read_bytes(), original)
        self.assertEqual(self.run_helper("validate_native_test_dependencies").returncode, 0)

    def test_header_mutation_fails_validation(self):
        self.assertEqual(self.run_helper().returncode, 0)
        (self.root / "deps/include/libavcodec/avcodec.h").write_bytes(b"changed")
        self.assertEqual(self.run_helper("validate_native_test_dependencies").returncode, 1)
        self.assertIn("avcodec.h: FAILED", (self.artifacts / "dependency-validation.log").read_text())

    def test_linked_library_mutation_fails_validation(self):
        self.assertEqual(self.run_helper().returncode, 0)
        (self.root / "deps/lib" / LIBRARIES[0]).write_bytes(b"changed")
        self.assertEqual(self.run_helper("validate_native_test_dependencies").returncode, 1)
        self.assertIn("libavcodec.61.dylib: FAILED", (self.artifacts / "dependency-validation.log").read_text())

    def test_missing_candidate_does_not_fall_back(self):
        result = self.run_helper(override=self.root / "missing")
        self.assertEqual(result.returncode, 2)
        self.assertIn("dependency directory is incomplete", result.stderr)
        self.assertFalse((self.artifacts / "dependency-sha256.txt").exists())

    def test_missing_library_is_rejected(self):
        (self.root / "deps/lib" / LIBRARIES[-1]).unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Missing native test library", result.stderr)


if __name__ == "__main__":
    unittest.main()
