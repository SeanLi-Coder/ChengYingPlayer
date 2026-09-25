"""Round-trip real signed stable DMGs and Sparkle deltas using disposable keys."""

from __future__ import annotations

import copy
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import build_delta_update as builder
import download_previous_release as previous
import generate_update_feed as producer
import verify_appcast as policy


class DeltaBuilder(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="chengying-delta-builder-")
        cls.directory = Path(cls.temporary.name)
        cls.sparkle = Path(os.environ["SPARKLE_TEST_ROOT"]).resolve()
        producer.validate_sparkle(cls.sparkle)
        key_tool = cls.directory / "fixture-key"
        subprocess.run(
            [
                "xcrun",
                "swiftc",
                str(Path(__file__).with_name("FixtureKey.swift")),
                "-o",
                str(key_tool),
            ],
            check=True,
        )
        subprocess.run([str(key_tool), str(cls.directory)], check=True)
        cls.key = (cls.directory / "test-seed").read_text()
        public = (cls.directory / "test-public").read_text()
        cls.info = {
            "CFBundleIdentifier": policy.BUNDLE_ID,
            "CFBundleName": "ChengYing",
            "CFBundleExecutable": "ChengYing",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "100",
            "CFBundleShortVersionString": "99.0.0",
            "LSMinimumSystemVersion": "12.0",
            "SUFeedURL": policy.FEED_URL,
            "SUPublicEDKey": public,
            "SUEnableAutomaticChecks": True,
            "SUAllowsAutomaticUpdates": True,
            "SUAutomaticallyUpdate": False,
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
        }
        cls.old_app = cls.directory / "old/ChengYing.app"
        executable = cls.old_app / "Contents/MacOS/ChengYing"
        executable.parent.mkdir(parents=True)
        subprocess.run(
            [
                "xcrun",
                "clang",
                "-arch",
                "arm64",
                "-mmacosx-version-min=12.0",
                str(Path(__file__).with_name("FixtureApp.c")),
                "-o",
                str(executable),
            ],
            check=True,
        )
        executable.chmod(0o755)
        frameworks = cls.old_app / "Contents/Frameworks"
        frameworks.mkdir()
        framework = (
            cls.sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        )
        if not framework.exists():
            framework = cls.sparkle / "Sparkle.framework"
        subprocess.run(
            ["ditto", str(framework), str(frameworks / "Sparkle.framework")], check=True
        )
        resources = cls.old_app / "Contents/Resources"
        resources.mkdir()
        # Stable incompressible resources make savings deterministic without a
        # production application, personal files, keys or network downloads.
        (resources / "unchanged.bin").write_bytes(os.urandom(256 * 1024))
        cls.write_info_and_sign(cls.old_app, cls.info)
        cls.old_tag = "v99.0.0"
        cls.old_directory = cls.directory / "old-release"
        cls.old_directory.mkdir()
        cls.old_archive = cls.make_archive(cls.old_app, cls.old_directory, cls.old_tag)
        with patch.dict(os.environ, {"SPARKLE_ED25519_PRIVATE_KEY": cls.key}):
            producer.generate(
                cls.old_app,
                cls.old_archive,
                cls.old_directory / "appcast.xml",
                cls.old_tag,
                cls.sparkle,
            )
        checksum = cls.old_archive.with_suffix(".dmg.sha256")
        checksum.write_text(
            f"{previous.digest(cls.old_archive)}  {cls.old_archive.name}\n"
        )
        cls.release = {
            "tag_name": cls.old_tag,
            "draft": False,
            "prerelease": False,
            "published_at": "2026-09-26T00:00:00Z",
            "html_url": f"{policy.RELEASES}/tag/{cls.old_tag}",
            "assets": [],
        }
        for path in (cls.old_archive, checksum, cls.old_directory / "appcast.xml"):
            cls.release["assets"].append(
                {
                    "name": path.name,
                    "state": "uploaded",
                    "size": path.stat().st_size,
                    "digest": f"sha256:{previous.digest(path)}",
                    "browser_download_url": f"{policy.RELEASES}/download/{cls.old_tag}/{path.name}",
                }
            )
        (cls.old_directory / "release.json").write_text(json.dumps(cls.release))
        cls.new_app = cls.directory / "new/ChengYing.app"
        cls.new_app.parent.mkdir()
        subprocess.run(["ditto", str(cls.old_app), str(cls.new_app)], check=True)
        cls.new_info = dict(
            cls.info, CFBundleVersion="101", CFBundleShortVersionString="99.0.1"
        )
        (cls.new_app / "Contents/Resources/new-resource.txt").write_text(
            "Updated resource fixture.\n"
        )
        cls.write_info_and_sign(cls.new_app, cls.new_info)
        cls.tag = "v99.0.1"
        cls.output = cls.directory / "new-release"
        cls.output.mkdir()
        cls.archive = cls.make_archive(cls.new_app, cls.output, cls.tag)
        cls.feed = cls.output / "appcast.xml"
        with patch.dict(os.environ, {"SPARKLE_ED25519_PRIVATE_KEY": cls.key}):
            producer.generate(
                cls.new_app,
                cls.archive,
                cls.feed,
                cls.tag,
                cls.sparkle,
                previous_release_directory=cls.old_directory,
            )
            if "SPARKLE_ED25519_PRIVATE_KEY" in os.environ:
                raise AssertionError(
                    "Signing credential leaked into subsequent child environments."
                )
        cls.delta = next(cls.output.glob("*.delta"))

    @classmethod
    def write_info_and_sign(cls, app, info):
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)

    @classmethod
    def make_archive(cls, app, directory, tag):
        archive = directory / f"ChengYingPlayer-{tag}-Apple-Silicon.dmg"
        subprocess.run(
            [
                "hdiutil",
                "create",
                "-quiet",
                "-srcfolder",
                str(app.parent),
                "-format",
                "UDZO",
                str(archive),
            ],
            check=True,
        )
        return archive

    @classmethod
    def tearDownClass(cls):
        cls.key = ""
        cls.temporary.cleanup()

    def test_real_delta_is_small_and_signed_alongside_full_fallback(self):
        policy.verify(self.feed, self.archive, self.new_info, self.tag)
        content, _ = policy.signed_content(self.feed.read_bytes())
        entries = policy.delta_enclosures(content, self.tag)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["from_build"], "100")
        self.assertEqual(entries[0]["name"], self.delta.name)
        self.assertLess(self.delta.stat().st_size, self.archive.stat().st_size)
        self.assertEqual(
            self.delta.with_suffix(".delta.sha256").read_text(),
            f"{previous.digest(self.delta)}  {self.delta.name}\n",
        )

    def test_real_delta_reconstructs_every_file_permission_and_signature(self):
        destination = self.directory / "independent/ChengYing.app"
        destination.parent.mkdir()
        subprocess.run(
            [
                str(self.sparkle / "bin/BinaryDelta"),
                "apply",
                str(self.old_app),
                str(destination),
                str(self.delta),
            ],
            check=True,
        )
        self.assertEqual(
            builder.tree_manifest(destination), builder.tree_manifest(self.new_app)
        )
        builder.verify_application(destination, self.new_info)

    def test_same_length_delta_tampering_fails_signature(self):
        temporary = self.directory / "tampered"
        temporary.mkdir()
        changed = temporary / self.delta.name
        data = bytearray(self.delta.read_bytes())
        data[len(data) // 2] ^= 1
        changed.write_bytes(data)
        with self.assertRaises(subprocess.CalledProcessError):
            policy.verify(
                self.feed,
                self.archive,
                self.new_info,
                self.tag,
                delta_directory=temporary,
            )

    def test_previous_key_mismatch_is_rejected_before_mount(self):
        info = dict(
            self.new_info, SUPublicEDKey="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        )
        with self.assertRaises(subprocess.CalledProcessError):
            builder.authenticated_previous_app(
                self.old_directory, info, self.tag, self.directory
            )

    def test_base_archive_tampering_is_rejected_even_with_updated_api_digest(self):
        temporary = self.directory / "corrupt-base"
        shutil.copytree(self.old_directory, temporary)
        archive = temporary / self.old_archive.name
        value = bytearray(archive.read_bytes())
        value[16] ^= 1
        archive.write_bytes(value)
        checksum = archive.with_suffix(".dmg.sha256")
        checksum.write_text(f"{previous.digest(archive)}  {archive.name}\n")
        release = copy.deepcopy(self.release)
        for asset in release["assets"]:
            asset["digest"] = f"sha256:{previous.digest(temporary / asset['name'])}"
        (temporary / "release.json").write_text(json.dumps(release))
        with self.assertRaises(subprocess.CalledProcessError):
            builder.authenticated_previous_app(
                temporary, self.new_info, self.tag, self.directory
            )

    def test_no_savings_omits_delta_but_keeps_signed_full_update(self):
        output = self.directory / "full-only/appcast.xml"
        with (
            patch.dict(os.environ, {"SPARKLE_ED25519_PRIVATE_KEY": self.key}),
            patch.object(producer, "build_delta", return_value=None),
        ):
            producer.generate(
                self.new_app,
                self.archive,
                output,
                self.tag,
                self.sparkle,
                previous_release_directory=self.old_directory,
            )
        content, _ = policy.signed_content(output.read_bytes())
        self.assertEqual(policy.delta_enclosures(content, self.tag), [])
        self.assertEqual(list(output.parent.glob("*.delta")), [])
        policy.verify(output, self.archive, self.new_info, self.tag)

    def test_delta_without_size_savings_is_not_offered(self):
        staging = self.directory / "no-savings"
        staging.mkdir()
        archive = staging / "tiny-full.dmg"
        archive.write_bytes(b"x")
        with patch.object(
            builder,
            "authenticated_previous_app",
            return_value=(self.old_app, self.info),
        ):
            result = builder.build_delta(
                self.new_app,
                archive,
                self.tag,
                self.new_info,
                self.old_directory,
                self.sparkle,
                staging,
            )
        self.assertIsNone(result)

    def test_full_archive_and_delta_target_must_match_even_with_identical_version(self):
        changed = self.directory / "mismatched/ChengYing.app"
        changed.parent.mkdir()
        subprocess.run(["ditto", str(self.new_app), str(changed)], check=True)
        (changed / "Contents/Resources/new-resource.txt").write_text(
            "Other signed contents.\n"
        )
        self.write_info_and_sign(changed, self.new_info)
        staging = self.directory / "mismatch-check"
        staging.mkdir()
        with self.assertRaisesRegex(ValueError, "target application differ"):
            builder.verify_archive_application(
                self.archive, changed, self.new_info, staging
            )


if __name__ == "__main__":
    os.environ.pop("SPARKLE_ED25519_PRIVATE_KEY", None)
    unittest.main(verbosity=2)
