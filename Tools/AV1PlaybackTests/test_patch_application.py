"""Apply the actual locked backport to verified original FFmpeg source files."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "other/patches"
ADDED = "ffmpeg-7.1.5/libavcodec/videotoolbox_av1.c"
ARCHIVE_SHA256 = "de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"


def hashes(name):
    return {path: digest for digest, path in
            (line.split() for line in (PATCHES / name).read_text().splitlines())}


class PatchApplicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before = hashes("playback-ffmpeg-before-sha256.txt")
        cls.after = hashes("playback-ffmpeg-after-sha256.txt")
        cache = Path(os.environ.get("SOURCE_CACHE_DIR", ROOT / "deps/sources"))
        archive = cache / "ffmpeg-7.1.5.tar.xz"
        if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
            raise RuntimeError("FFmpeg original archive checksum mismatch")
        cls.original = {}
        with tarfile.open(archive) as source:
            if ADDED in source.getnames():
                raise RuntimeError("New AV1 source must be absent from original FFmpeg")
            for name, digest in cls.before.items():
                member = source.getmember(name)
                if not member.isfile():
                    raise RuntimeError("Original patch input must be a regular file")
                with source.extractfile(member) as stream:
                    content = stream.read()
                if hashlib.sha256(content).hexdigest() != digest:
                    raise RuntimeError("Original FFmpeg source checksum mismatch")
                cls.original[name] = content

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-av1-patch-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / "source"
        self.record = self.work / "record"
        for name, content in self.original.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

    def apply(self, script=ROOT / "other/playback_ffmpeg_patches.sh"):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; apply_playback_ffmpeg_patches "$2" "$3"',
             "apply-av1-test", str(script), str(self.source), str(self.record)],
            capture_output=True, text=True, timeout=30)

    def assert_originals_untouched(self):
        for name, content in self.original.items():
            self.assertEqual((self.source / name).read_bytes(), content)

    def test_exact_patch_and_record(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = self.record / "ffmpeg-av1-backport"
        for name, digest in self.after.items():
            self.assertEqual(hashlib.sha256((self.source / name).read_bytes()).hexdigest(), digest)
            self.assertEqual((record / "patched-sources" / name).read_bytes(),
                             (self.source / name).read_bytes())
        self.assertEqual((record / "patch-added-files.txt").read_text(), ADDED + "\n")

    def test_preexisting_empty_file_is_rejected(self):
        added = self.source / ADDED
        added.write_bytes(b"")
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(added.read_bytes(), b"")
        self.assert_originals_untouched()

    def test_preexisting_dangling_link_is_rejected(self):
        added = self.source / ADDED
        missing = self.work / "must-not-be-created"
        added.symlink_to(missing)
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertTrue(added.is_symlink())
        self.assertFalse(missing.exists())
        self.assert_originals_untouched()

    def test_preexisting_regular_link_does_not_modify_target(self):
        outside = self.work / "unrelated-file"
        outside.write_bytes(b"Unrelated original content\n")
        (self.source / ADDED).symlink_to(outside)
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_bytes(), b"Unrelated original content\n")
        self.assert_originals_untouched()

    def test_unexpected_added_file_marker_is_rejected_before_patch(self):
        # Copy the implementation solely to replace its adjacent trust-boundary
        # fixture; never mutate the repository's locks during a test.
        isolated = self.work / "implementation"
        isolated.mkdir()
        shutil.copy2(ROOT / "other/playback_ffmpeg_patches.sh", isolated)
        shutil.copytree(PATCHES, isolated / "patches")
        marker = isolated / "patches/playback-ffmpeg-added-files.txt"
        for text in ("", ADDED + "\n\n", ADDED + "\nffmpeg-7.1.5/unexpected.c\n"):
            with self.subTest(marker=text):
                marker.write_text(text)
                result = self.apply(isolated / "playback_ffmpeg_patches.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unexpected FFmpeg added-source lock", result.stderr)
                self.assertFalse((self.source / ADDED).exists())
                self.assert_originals_untouched()


if __name__ == "__main__":
    unittest.main()
