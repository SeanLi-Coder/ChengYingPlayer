"""Reject altered or incomplete FFmpeg HDR10+ source and patch records."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import verify_media_distribution as distribution


class MediaRecordPathTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="chengying-record-paths-")
        self.addCleanup(self.workspace.cleanup)
        self.record = Path(self.workspace.name)

    def write_records(self, configuration, make_configuration):
        (self.record / "config.h").write_text(configuration)
        (self.record / "config.mak").write_text(make_configuration)

    def test_ci_raw_lexical_and_physical_paths_are_all_normalized(self):
        raw = "/var/folders/36/ci-runner/T//chengying-media-runtime.fixture"
        lexical = "/var/folders/36/ci-runner/T/chengying-media-runtime.fixture"
        physical = "/private/var/folders/36/ci-runner/T/chengying-media-runtime.fixture"
        configuration = (
            f'#define FFMPEG_CONFIGURATION "--prefix={raw}/ffmpeg-install"\n'
        )
        make_configuration = (
            f"prefix={raw}/ffmpeg-install\n"
            f"CFLAGS=-I{lexical}/x265-install/include -I{physical}/subtitle-install/include\n"
            "LDFLAGS=-framework VideoToolbox\n"
        )
        # The old two-replacement sanitizer misses pkg-config's lexical spelling.
        old_result = make_configuration.replace(raw, "<BUILD_ROOT>").replace(
            physical, "<BUILD_ROOT>"
        )
        with self.assertRaises(ValueError):
            distribution.validate_record_paths(
                configuration.replace(raw, "<BUILD_ROOT>"), old_result
            )
        self.write_records(configuration, make_configuration)
        with mock.patch.object(distribution.os.path, "realpath", return_value=physical):
            distribution.normalize_build_records(self.record, raw)
        self.assertEqual(
            (self.record / "config.mak").read_text(),
            "prefix=<BUILD_ROOT>/ffmpeg-install\n"
            "CFLAGS=-I<BUILD_ROOT>/x265-install/include -I<BUILD_ROOT>/subtitle-install/include\n"
            "LDFLAGS=-framework VideoToolbox\n",
        )

    def test_actual_symlink_and_repeated_separator_paths(self):
        physical_parent = self.record / "physical"
        physical_parent.mkdir()
        alias_parent = self.record / "logical"
        alias_parent.symlink_to(physical_parent, target_is_directory=True)
        physical = physical_parent / "chengying-media-runtime.fixture"
        physical.mkdir()
        physical = physical.resolve()
        raw = f"{alias_parent}//chengying-media-runtime.fixture"
        lexical = str(alias_parent / physical.name)
        self.write_records(
            f'ROOT="{raw}/ffmpeg-install"\n',
            f"CFLAGS=-I{lexical}/include -I{physical}/include\n",
        )
        distribution.normalize_build_records(self.record, raw)
        self.assertEqual(
            (self.record / "config.h").read_text(),
            'ROOT="<BUILD_ROOT>/ffmpeg-install"\n',
        )
        self.assertEqual(
            (self.record / "config.mak").read_text(),
            "CFLAGS=-I<BUILD_ROOT>/include -I<BUILD_ROOT>/include\n",
        )

    def test_runner_work_root_is_normalized_without_erasing_tool_flags(self):
        root = "/Users/runner/work/_temp/chengying-media-runtime.fixture"
        self.write_records(
            f'ROOT="{root}/ffmpeg-install"\n',
            f"CFLAGS=-I{root}/include -O3 -arch arm64\n",
        )
        distribution.normalize_build_records(self.record, root)
        self.assertEqual(
            (self.record / "config.mak").read_text(),
            "CFLAGS=-I<BUILD_ROOT>/include -O3 -arch arm64\n",
        )

    def test_unrelated_private_path_is_rejected_without_changing_records(self):
        root = "/tmp/chengying-media-runtime.fixture"
        for unrelated in (
            "/Users/private-user/sdk",
            "/tmp/other-build/include",
            "/private/var/other-build/include",
            root + "-other/include",
            "/opt/unrelated" + root + "/include",
            "/opt/unrelated-I" + root + "/include",
        ):
            with self.subTest(path=unrelated):
                configuration = f'ROOT="{root}/ffmpeg-install"\n'
                make_configuration = f"CFLAGS=-I{root}/include -I{unrelated}\n"
                self.write_records(configuration, make_configuration)
                with self.assertRaises(ValueError):
                    distribution.normalize_build_records(self.record, root)
                self.assertEqual((self.record / "config.h").read_text(), configuration)
                self.assertEqual(
                    (self.record / "config.mak").read_text(), make_configuration
                )

    def test_existing_normalized_records_are_idempotent(self):
        self.write_records(
            'ROOT="<BUILD_ROOT>/ffmpeg-install"\n', "CFLAGS=-I<BUILD_ROOT>/include\n"
        )
        distribution.normalize_build_records(
            self.record, "/tmp/chengying-media-runtime.fixture"
        )
        self.assertEqual(
            (self.record / "config.mak").read_text(), "CFLAGS=-I<BUILD_ROOT>/include\n"
        )

    def test_normalization_command_accepts_exact_build_inputs(self):
        root = "/tmp/chengying-media-runtime.fixture"
        self.write_records(
            f'ROOT="{root}/ffmpeg-install"\n', f"prefix={root}/ffmpeg-install\n"
        )
        subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "other/verify_media_distribution.py"),
                "--normalize-record",
                str(self.record),
                "--build-root",
                root,
            ],
            check=True,
            capture_output=True,
        )
        self.assertEqual(
            (self.record / "config.mak").read_text(),
            "prefix=<BUILD_ROOT>/ffmpeg-install\n",
        )


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
