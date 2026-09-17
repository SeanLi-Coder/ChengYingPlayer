"""Exercise the real distribution verifier with explicit archive and native-tool boundaries."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "distribution", ROOT / "other/verify_playback_distribution.py"
)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="chengying distribution proof "
        )
        self.dependencies = Path(self.temporary.name)
        self.record = self.dependencies / "playback-build-record"
        self.record.mkdir()
        self.cache = self.dependencies / "sources"
        self.cache.mkdir()
        self.sources = {}
        self.patch_records, original_hashes, _ = VERIFY.locked_patches()
        self.original_patch_sources = {
            name: f"Synthetic original source: {name}\n".encode()
            for name in original_hashes
        }
        self.modified_patch_sources = {
            name: f"Synthetic modified source: {name}\n".encode()
            for name in original_hashes
        }
        self.patch_before = {
            name: hashlib.sha256(data).hexdigest()
            for name, data in self.original_patch_sources.items()
        }
        self.patch_after = {
            name: hashlib.sha256(data).hexdigest()
            for name, data in self.modified_patch_sources.items()
        }
        for name, data in self.modified_patch_sources.items():
            destination = self.record / "patched-sources" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        self.record.joinpath("patches").mkdir()
        for value in self.patch_records.values():
            filename = value[2]
            self.record.joinpath("patches", filename).write_bytes(
                ROOT.joinpath("other/patches", filename).read_bytes()
            )
        self.record.joinpath("patches.tsv").write_text(
            "".join("\t".join(value) + "\n" for value in self.patch_records.values())
        )
        for label, hashes in (
            ("before", self.patch_before),
            ("after", self.patch_after),
        ):
            self.record.joinpath(f"patch-{label}-sha256.txt").write_text(
                "".join(f"{digest}  {name}\n" for name, digest in hashes.items())
            )
        # These tiny local archives are deliberately synthetic source-lock boundaries.
        # Production always obtains the real pinned records from repository-owned scripts.
        for (
            component,
            version,
            filename,
            url,
            _digest,
        ) in VERIFY.locked_sources().values():
            archive = self.cache / filename
            root = f"{component}-{version}"
            notices = {
                "LICENCE"
                if component == "libunibreak"
                else "LICENSE": f"Synthetic {component} license.\n".encode(),
                "embedded/COPYING.fixture": b"Synthetic embedded notice.\n",
                "Copyright": b"Synthetic copyright attribution.\n",
                "AUTHORS": b"Synthetic author attribution.\n",
                "NOTICE": b"Synthetic distribution notice.\n",
            }
            with tarfile.open(archive, "w:gz") as output:
                for name, contents in notices.items():
                    entry = tarfile.TarInfo(f"{root}/{name}")
                    entry.size = len(contents)
                    output.addfile(entry, io.BytesIO(contents))
                    destination = self.record / "licenses" / root / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(contents)
                for name, contents in self.original_patch_sources.items():
                    if name.split("/")[0] != root:
                        continue
                    entry = tarfile.TarInfo(name)
                    entry.size = len(contents)
                    output.addfile(entry, io.BytesIO(contents))
            self.sources[component] = (
                component,
                version,
                filename,
                url,
                VERIFY.digest_file(archive),
            )
        self.write_sources()
        self.record.joinpath("toolchain.txt").write_text(
            "Architecture: arm64\nDeployment target: 12.0\nApple clang version 17.0.0\nSDK: 26.5\nmacOS: 26.5\ncmake version 4.0.0\n1.10.0\n1.13.0\n"
        )
        flags = {
            "CONFIG_GPL": 1,
            "CONFIG_VERSION3": 1,
            "CONFIG_NONFREE": 0,
            "CONFIG_LIBDAV1D": 1,
            "CONFIG_LIBASS": 1,
            "CONFIG_LIBZIMG": 1,
            "CONFIG_VIDEOTOOLBOX": 1,
            "CONFIG_SECURETRANSPORT": 1,
            "CONFIG_AUDIOTOOLBOX": 1,
        }
        self.record.joinpath("config.h").write_text(
            "\n".join(f"#define {key} {value}" for key, value in flags.items()) + "\n"
        )
        self.record.joinpath("config_components.h").write_text(
            "#define CONFIG_H264_DECODER 1\n"
        )
        self.record.joinpath("ffmpeg-config.mak").write_text(
            "FFMPEG_CONFIGURATION=--disable-autodetect --enable-shared --disable-static --enable-libdav1d --enable-videotoolbox --enable-gpl --enable-version3\n"
        )
        self.record.joinpath("mpv-config.h").write_text("#define HAVE_GL_COCOA 1\n")
        self.write_options(
            "mpv-buildoptions.json",
            {
                "auto_features": "disabled",
                "prefer_static": False,
                "libmpv": True,
                "cplayer": False,
                "gpl": True,
                "lua": "disabled",
                "cocoa": "enabled",
                "gl-cocoa": "enabled",
                "gl": "enabled",
                "plain-gl": "enabled",
                "swift-build": "enabled",
                "videotoolbox-gl": "enabled",
                "coreaudio": "enabled",
                "lcms2": "enabled",
                "zimg": "enabled",
                "uchardet": "enabled",
                "libavdevice": "enabled",
            },
        )
        self.write_options(
            "libplacebo-buildoptions.json",
            {
                "auto_features": "disabled",
                "default_library": "static",
                "demos": False,
                "tests": False,
                "lcms": "enabled",
                "dovi": "enabled",
            },
        )
        libraries = self.dependencies / "lib"
        libraries.mkdir()
        library_checksums = []
        for name in sorted(VERIFY.LIBRARIES):
            binary = libraries / name
            binary.write_bytes(f"Synthetic native boundary for {name}".encode())
            library_checksums.append(f"{VERIFY.digest_file(binary)}  ./{name}\n")
        self.record.joinpath("library-sha256.txt").write_text(
            "".join(library_checksums)
        )
        header_checksums = []
        for directory in sorted(VERIFY.SDK_DIRECTORIES):
            header = self.dependencies / "include" / directory / "fixture.h"
            header.parent.mkdir(parents=True)
            header.write_text("// Synthetic SDK header.\n")
            header_checksums.append(
                f"{VERIFY.digest_file(header)}  ./{directory}/fixture.h\n"
            )
        self.record.joinpath("headers-sha256.txt").write_text("".join(header_checksums))
        self.command_calls = []

    def tearDown(self):
        self.temporary.cleanup()

    def write_sources(self):
        self.record.joinpath("sources.tsv").write_text(
            "".join("\t".join(value) + "\n" for value in self.sources.values())
        )

    def write_options(self, filename, values):
        self.record.joinpath(filename).write_text(
            json.dumps(
                [{"name": name, "value": value} for name, value in values.items()]
            )
        )

    def native_boundary(self, arguments):
        self.command_calls.append(arguments)
        name = Path(arguments[-1]).name
        if arguments[0] == "lipo":
            return "arm64\n"
        if arguments[:2] == ["otool", "-L"]:
            return (
                f"{arguments[-1]}:\n\t@rpath/{name} (compatibility version 1.0.0, current version 1.0.0)\n"
                "\t@rpath/libavutil.59.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
                "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
            )
        if arguments[:2] == ["otool", "-l"]:
            return "Load command 0\n          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)\n"
        if arguments[:3] == ["codesign", "--verify", "--strict"]:
            return ""
        raise AssertionError(f"Unexpected native command: {arguments}")

    def verify(self, runner=None):
        VERIFY.verify_distribution(
            self.dependencies,
            sources=self.sources,
            source_cache=self.cache,
            runner=runner or self.native_boundary,
            patch_spec=(self.patch_records, self.patch_before, self.patch_after),
        )

    def test_missing_patch_manifest_is_rejected(self):
        self.record.joinpath("patches.tsv").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or linked build-record"):
            self.verify()

    def test_reordered_patches_are_rejected(self):
        path = self.record / "patches.tsv"
        path.write_text("\n".join(reversed(path.read_text().splitlines())) + "\n")
        with self.assertRaisesRegex(ValueError, "application order"):
            self.verify()

    def test_modified_patch_is_rejected(self):
        next(self.record.joinpath("patches").glob("*.patch")).write_text(
            "Tampered patch\n"
        )
        with self.assertRaisesRegex(
            ValueError, "patch files are missing, extra, or modified"
        ):
            self.verify()

    def test_missing_patch_is_rejected(self):
        next(self.record.joinpath("patches").glob("*.patch")).unlink()
        with self.assertRaisesRegex(
            ValueError, "patch files are missing, extra, or modified"
        ):
            self.verify()

    def test_stale_patch_is_rejected(self):
        self.record.joinpath("patches/obsolete.patch").write_text("Stale patch\n")
        with self.assertRaisesRegex(
            ValueError, "patch files are missing, extra, or modified"
        ):
            self.verify()

    def test_linked_patch_is_rejected(self):
        path = next(self.record.joinpath("patches").glob("*.patch"))
        data = path.read_bytes()
        path.unlink()
        target = self.dependencies / "external.patch"
        target.write_bytes(data)
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "Linked patch entry"):
            self.verify()

    def test_modified_patched_source_is_rejected(self):
        path = self.record / "patched-sources" / next(iter(self.patch_after))
        path.write_text("Unpatched implementation\n")
        with self.assertRaisesRegex(ValueError, "patched source files"):
            self.verify()

    def test_forged_patched_source_hash_is_rejected(self):
        path = self.record / "patch-after-sha256.txt"
        path.write_text(
            path.read_text().replace(next(iter(self.patch_after.values())), "0" * 64)
        )
        with self.assertRaisesRegex(ValueError, "patched-source checksums"):
            self.verify()

    def test_original_patch_source_is_verified_against_archive(self):
        name = next(iter(self.patch_before))
        self.patch_before[name] = "0" * 64
        self.record.joinpath("patch-before-sha256.txt").write_text(
            "".join(f"{digest}  {name}\n" for name, digest in self.patch_before.items())
        )
        with self.assertRaisesRegex(ValueError, "patch original source checksums"):
            self.verify()

    def test_checked_in_patch_bytes_match_the_locks(self):
        patches, before, after = VERIFY.locked_patches()
        self.assertEqual(set(before), set(after))
        self.assertEqual(len(patches), 2)
        for value in patches.values():
            self.assertEqual(
                VERIFY.digest_file(ROOT / "other/patches" / value[2]), value[4]
            )

    def test_valid_distribution_and_unrelated_old_libraries(self):
        self.dependencies.joinpath("lib/unused-old-library.dylib").write_bytes(
            b"Unrelated previous library"
        )
        self.verify()
        self.assertEqual(len(self.command_calls), 9 * 4)
        self.assertFalse(
            any(
                "unused-old" in argument
                for call in self.command_calls
                for argument in call
            )
        )

    def test_modified_library_is_rejected(self):
        self.dependencies.joinpath("lib/libmpv.2.dylib").write_bytes(
            b"Old library substituted"
        )
        with self.assertRaisesRegex(ValueError, "library checksum mismatch"):
            self.verify()

    def test_wrong_source_version_is_rejected(self):
        path = self.record / "sources.tsv"
        path.write_text(path.read_text().replace("7.1.5", "7.0.1"))
        with self.assertRaisesRegex(ValueError, "locked sources"):
            self.verify()

    def test_missing_source_is_rejected(self):
        path = self.record / "sources.tsv"
        path.write_text("\n".join(path.read_text().splitlines()[1:]) + "\n")
        with self.assertRaisesRegex(ValueError, "locked sources"):
            self.verify()

    def test_duplicate_source_is_rejected(self):
        path = self.record / "sources.tsv"
        path.write_text(path.read_text() + path.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "Duplicate source"):
            self.verify()

    def test_sdk_header_tampering_is_rejected(self):
        self.dependencies.joinpath("include/mpv/fixture.h").write_text(
            "// Wrong SDK.\n"
        )
        with self.assertRaisesRegex(ValueError, "SDK checksum mismatch"):
            self.verify()

    def test_missing_sdk_version_is_rejected(self):
        path = self.record / "toolchain.txt"
        path.write_text(path.read_text().replace("SDK: 26.5", "26.5"))
        with self.assertRaisesRegex(ValueError, "SDK version"):
            self.verify()

    def test_untracked_sdk_header_is_rejected(self):
        self.dependencies.joinpath("include/mpv/old.h").write_text("// Old SDK.\n")
        with self.assertRaisesRegex(ValueError, "SDK files differ"):
            self.verify()

    def test_nonfree_configuration_is_rejected(self):
        path = self.record / "config.h"
        path.write_text(
            path.read_text().replace("CONFIG_NONFREE 0", "CONFIG_NONFREE 1")
        )
        with self.assertRaisesRegex(ValueError, "CONFIG_NONFREE"):
            self.verify()

    def test_automatic_dependency_detection_is_rejected(self):
        path = self.record / "mpv-buildoptions.json"
        path.write_text(path.read_text().replace('"disabled"', '"auto"', 1))
        with self.assertRaisesRegex(ValueError, "auto_features"):
            self.verify()

    def test_corrupt_source_archive_is_rejected(self):
        filename = next(iter(self.sources.values()))[2]
        self.cache.joinpath(filename).write_bytes(b"Wrong source archive")
        with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
            self.verify()

    def test_missing_british_spelling_license_is_rejected(self):
        path = next(self.record.joinpath("licenses").rglob("LICENCE"))
        path.unlink()
        with self.assertRaisesRegex(ValueError, "licenses differ"):
            self.verify()

    def test_modified_embedded_license_is_rejected(self):
        path = next(self.record.joinpath("licenses").rglob("COPYING.fixture"))
        path.write_text("Wrong version embedded license")
        with self.assertRaisesRegex(ValueError, "licenses differ"):
            self.verify()

    def test_missing_copyright_attribution_is_rejected(self):
        path = next(self.record.joinpath("licenses").rglob("Copyright"))
        path.unlink()
        with self.assertRaisesRegex(ValueError, "licenses differ"):
            self.verify()

    def test_extra_old_source_license_is_rejected(self):
        self.record.joinpath("licenses/old-version-LICENSE").write_text(
            "Old extra notice"
        )
        with self.assertRaisesRegex(ValueError, "licenses differ"):
            self.verify()

    def test_external_dependency_is_rejected(self):
        def boundary(arguments):
            value = self.native_boundary(arguments)
            return value.replace(
                "/usr/lib/libSystem.B.dylib", "/opt/homebrew/lib/libExternal.dylib"
            )

        with self.assertRaisesRegex(ValueError, "External or untracked"):
            self.verify(boundary)

    def test_untracked_rpath_dependency_is_rejected(self):
        def boundary(arguments):
            value = self.native_boundary(arguments)
            return value.replace(
                "/usr/lib/libSystem.B.dylib", "@rpath/unused-old-library.dylib"
            )

        with self.assertRaisesRegex(ValueError, "External or untracked"):
            self.verify(boundary)

    def test_external_runtime_search_path_is_rejected(self):
        def boundary(arguments):
            return self.native_boundary(arguments).replace(
                "/usr/lib/swift", "/Users/build-machine/lib"
            )

        with self.assertRaisesRegex(ValueError, "runtime search path"):
            self.verify(boundary)

    def test_old_universal_prebuilt_is_rejected(self):
        def boundary(arguments):
            return (
                "x86_64 arm64\n"
                if arguments[0] == "lipo"
                else self.native_boundary(arguments)
            )

        with self.assertRaisesRegex(ValueError, "ARM64-only"):
            self.verify(boundary)

    def test_broken_signature_is_rejected(self):
        def boundary(arguments):
            if arguments[0] == "codesign":
                raise subprocess.CalledProcessError(1, arguments)
            return self.native_boundary(arguments)

        with self.assertRaises(subprocess.CalledProcessError):
            self.verify(boundary)

    def test_checksum_path_traversal_is_rejected(self):
        path = self.record / "library-sha256.txt"
        path.write_text(
            path.read_text().replace("./libmpv.2.dylib", "../libmpv.2.dylib")
        )
        with self.assertRaisesRegex(ValueError, "Unsafe checksum path"):
            self.verify()

    def test_record_content_is_not_executed(self):
        marker = self.dependencies / "must-not-exist"
        self.record.joinpath("sources.tsv").write_text(f"$(touch {marker})\n")
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
