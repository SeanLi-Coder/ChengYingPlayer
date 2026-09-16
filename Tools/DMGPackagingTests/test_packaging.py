"""Use synthetic native applications to test packaging; never publish these fixtures."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "package_dmg", PROJECT_ROOT / "other/package_dmg.py"
)
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


def command(*arguments, capture=False):
    return subprocess.run(
        arguments, check=True, stdout=subprocess.PIPE if capture else None
    ).stdout


class PackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="chengying packaging tests ")
        cls.root = Path(cls.temporary.name).resolve()
        cls.native = cls.root / "fixture"
        cls.intel = cls.root / "intel-fixture"
        source = PROJECT_ROOT / "Tools/DMGPackagingTests/fixture.c"
        command("xcrun", "clang", "-arch", "arm64", str(source), "-o", str(cls.native))
        command("xcrun", "clang", "-arch", "x86_64", str(source), "-o", str(cls.intel))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="case-", dir=self.root))
        self.application = self.work / "ChengYing.app"
        for relative in PACKAGER.REQUIRED_EXECUTABLES:
            path = self.application / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.native, path)
            command("codesign", "--force", "--sign", "-", str(path))
        resources = self.application / "Contents/Resources"
        resources.mkdir(parents=True)
        (resources / "fixture.txt").write_text(
            "Synthetic packaging fixture, not a release.\n"
        )
        (resources / "fixture-alias.txt").symlink_to("fixture.txt")
        legal = resources / "Legal"
        legal.mkdir()
        for name in PACKAGER.REQUIRED_NOTICES:
            (legal / name).write_text(
                "Synthetic notice fixture; never distribute this test app.\n"
            )
        self.write_info(self.application, "ChengYing", PACKAGER.BUNDLE_ID)
        nested = self.application / "Contents/Helpers/DownloadCenter.app"
        self.write_info(
            nested,
            "chengying-download-center-helper",
            PACKAGER.BUNDLE_ID + ".FixtureHelper",
        )
        command("codesign", "--force", "--sign", "-", str(nested))
        self.sign()

    def tearDown(self):
        shutil.rmtree(self.work)

    def write_info(self, application, executable, identifier):
        (application / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": executable,
                    "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "0.0.0-fixture",
                }
            )
        )

    def sign(self):
        command("codesign", "--force", "--sign", "-", str(self.application))

    def test_01_real_readonly_dmg_and_source_preservation(self):
        original = PACKAGER.snapshot(self.application)
        output = self.work / "Synthetic Fixture Apple Silicon.dmg"
        command(
            "bash",
            str(PROJECT_ROOT / "other/package_dmg.sh"),
            str(self.application),
            str(output),
        )
        self.assertEqual(PACKAGER.snapshot(self.application), original)
        self.assertEqual(
            output.with_suffix(".dmg.sha256").read_text(),
            f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name}\n",
        )
        self.assertFalse(list(self.work.glob(".chengying-dmg-*")))
        mount = self.work / "private mount"
        mount.mkdir()
        try:
            command(
                "hdiutil",
                "attach",
                "-readonly",
                "-nobrowse",
                "-noautoopen",
                "-mountpoint",
                str(mount),
                str(output),
            )
            with self.assertRaises(OSError):
                (mount / "must-not-write.txt").write_text("Read-only check")
            self.assertEqual(os.readlink(mount / "Applications"), "/Applications")
            self.assertIn(
                "Synthetic ARM64",
                command(
                    str(mount / "ChengYing.app/Contents/MacOS/ChengYing"), capture=True
                ).decode(),
            )
            self.assertEqual(PACKAGER.snapshot(mount / "ChengYing.app"), original)
        finally:
            command("hdiutil", "detach", str(mount))
        with self.assertRaisesRegex(ValueError, "overwrite"):
            PACKAGER.package(self.application, output)

    def test_02_existing_checksum_is_not_overwritten(self):
        output = self.work / "existing.dmg"
        checksum = output.with_suffix(".dmg.sha256")
        checksum.write_text("User-owned checksum")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            PACKAGER.package(self.application, output)
        self.assertEqual(checksum.read_text(), "User-owned checksum")
        self.assertFalse(output.exists())

    def test_03_rejects_output_inside_input(self):
        with self.assertRaisesRegex(ValueError, "inside"):
            PACKAGER.package(self.application, self.application / "nested.dmg")

    def test_04_rejects_wrong_identifier(self):
        self.write_info(self.application, "ChengYing", "invalid.fixture.identifier")
        with self.assertRaisesRegex(ValueError, "identifier"):
            PACKAGER.validate_application(self.application)

    def test_05_rejects_missing_helper(self):
        (self.application / "Contents/MacOS/ffmpeg").unlink()
        with self.assertRaisesRegex(ValueError, "Missing executable"):
            PACKAGER.validate_application(self.application)

    def test_06_rejects_missing_notice(self):
        (
            self.application / "Contents/Resources/Legal/ChengYingPlayer-GPLv3.txt"
        ).unlink()
        with self.assertRaisesRegex(ValueError, "Missing legal notice"):
            PACKAGER.validate_application(self.application)

    def test_07_rejects_non_arm64_macho(self):
        shutil.copy2(self.intel, self.application / "Contents/MacOS/ffprobe")
        with self.assertRaisesRegex(ValueError, "ARM64"):
            PACKAGER.validate_application(self.application)

    def test_08_rejects_external_runtime_dependency(self):
        executable = self.application / "Contents/MacOS/ChengYing"
        command(
            "install_name_tool",
            "-change",
            "/usr/lib/libSystem.B.dylib",
            "/opt/homebrew/lib/libSystem.B.dylib",
            str(executable),
        )
        self.sign()
        with self.assertRaisesRegex(ValueError, "Absolute non-system dependency"):
            PACKAGER.validate_application(self.application)

    def test_09_rejects_escaped_symlink(self):
        (self.application / "Contents/Resources/escaped").symlink_to(
            "../../../../fixture"
        )
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            PACKAGER.validate_application(self.application)

    def test_10_rejects_signature_tampering(self):
        (self.application / "Contents/Resources/fixture.txt").write_text(
            "Tampered after signing"
        )
        with self.assertRaises(subprocess.CalledProcessError):
            PACKAGER.validate_application(self.application)

    def test_11_rejects_external_rpath(self):
        executable = self.application / "Contents/MacOS/ChengYing"
        command("install_name_tool", "-add_rpath", "/opt/homebrew/lib", str(executable))
        self.sign()
        with self.assertRaisesRegex(
            ValueError, "Absolute non-system runtime search path"
        ):
            PACKAGER.validate_application(self.application)

    def test_12_rejects_unresolved_rpath_dependency(self):
        executable = self.application / "Contents/MacOS/ChengYing"
        command(
            "install_name_tool",
            "-change",
            "/usr/lib/libSystem.B.dylib",
            "@rpath/missing.dylib",
            str(executable),
        )
        self.sign()
        with self.assertRaisesRegex(ValueError, "Unresolved or external dependency"):
            PACKAGER.validate_application(self.application)

    def test_13_accepts_bundled_rpath_dependencies(self):
        frameworks = self.application / "Contents/Frameworks"
        frameworks.mkdir()
        library = frameworks / "libFixture.dylib"
        source = PROJECT_ROOT / "Tools/DMGPackagingTests/fixture.c"
        command(
            "xcrun",
            "clang",
            "-arch",
            "arm64",
            "-dynamiclib",
            "-DDMG_LIBRARY",
            str(source),
            "-install_name",
            "@rpath/libFixture.dylib",
            "-o",
            str(library),
        )
        command("codesign", "--force", "--sign", "-", str(library))
        executable = self.application / "Contents/MacOS/ChengYing"
        command(
            "xcrun",
            "clang",
            "-arch",
            "arm64",
            "-DDMG_LINK_FIXTURE",
            str(source),
            "-L",
            str(frameworks),
            "-lFixture",
            "-Wl,-rpath,@executable_path/../Frameworks",
            "-o",
            str(executable),
        )
        self.sign()
        PACKAGER.validate_application(self.application)
        self.assertIn(
            "Synthetic ARM64", command(str(executable), capture=True).decode()
        )

    def test_14_accepts_arm64_slice_in_universal_macho(self):
        universal = self.work / "universal"
        command(
            "xcrun",
            "lipo",
            "-create",
            str(self.native),
            str(self.intel),
            "-output",
            str(universal),
        )
        destination = self.application / "Contents/MacOS/ffprobe"
        shutil.copy2(universal, destination)
        command("codesign", "--force", "--sign", "-", str(destination))
        self.sign()
        PACKAGER.validate_application(self.application)

    def test_15_rejects_dangling_output_symlink(self):
        output = self.work / "symlink.dmg"
        output.symlink_to("not-created")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            PACKAGER.package(self.application, output)
        self.assertTrue(output.is_symlink())


if __name__ == "__main__":
    unittest.main(verbosity=2)
