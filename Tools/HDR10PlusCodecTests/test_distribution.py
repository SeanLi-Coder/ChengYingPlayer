"""Reject altered or incomplete FFmpeg HDR10+ source and patch records."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import verify_media_distribution as distribution


class MediaPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="chengying-media-patch-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.sources = distribution.source_locks()
        cls.spec = distribution.patch_locks()
        cls.cache = ROOT / "deps/sources"
        archive = cls.cache / cls.sources["ffmpeg"][2]
        cls.source = cls.root / "source"
        with tarfile.open(archive) as contents:
            for name, expected in cls.spec[1].items():
                destination = cls.source / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(contents.extractfile(name).read())
                if distribution.digest_file(destination) != expected:
                    raise AssertionError("Original FFmpeg source checksum mismatch")
        cls.original = cls.root / "original-record"
        subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; apply_media_patches "$2" "$3"',
                "media-patch-test",
                str(ROOT / "other/media_patches.sh"),
                str(cls.source),
                str(cls.original),
            ],
            check=True,
            capture_output=True,
        )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.temporary.cleanup)
        self.record = Path(self.temporary.name) / "record"
        shutil.copytree(self.original, self.record)

    def validate(self):
        distribution.validate_patches(
            self.record, self.cache, self.sources, patch_spec=self.spec
        )

    def test_verified_patch_applies_without_fuzz_and_matches_original_archive(self):
        self.validate()

    def test_modified_patch_is_rejected(self):
        patch = next((self.record / "patches").iterdir())
        patch.write_bytes(patch.read_bytes() + b"\nChanged\n")
        with self.assertRaises(ValueError):
            self.validate()

    def test_missing_patch_is_rejected(self):
        next((self.record / "patches").iterdir()).unlink()
        with self.assertRaises(ValueError):
            self.validate()

    def test_extra_patch_is_rejected(self):
        (self.record / "patches/extra.patch").write_text("Unexpected patch\n")
        with self.assertRaises(ValueError):
            self.validate()

    def test_changed_source_is_rejected(self):
        source = self.record / "patched-sources" / next(iter(self.spec[2]))
        source.write_bytes(source.read_bytes() + b"\n/* Changed */\n")
        with self.assertRaises(ValueError):
            self.validate()

    def test_linked_source_is_rejected(self):
        name = next(iter(self.spec[2]))
        source = self.record / "patched-sources" / name
        source.unlink()
        source.symlink_to(self.original / "patched-sources" / name)
        with self.assertRaises(ValueError):
            self.validate()

    def test_modified_manifest_is_rejected(self):
        manifest = self.record / "patches.tsv"
        manifest.write_text(
            manifest.read_text().replace("ffmpeg-9.0.1\t", "ffmpeg-9.0.2\t")
        )
        with self.assertRaises(ValueError):
            self.validate()

    def test_modified_original_hash_is_rejected(self):
        manifest = self.record / "patch-before-sha256.txt"
        manifest.write_text(
            manifest.read_text().replace(next(iter(self.spec[1].values())), "0" * 64)
        )
        with self.assertRaises(ValueError):
            self.validate()


if __name__ == "__main__":
    unittest.main()
