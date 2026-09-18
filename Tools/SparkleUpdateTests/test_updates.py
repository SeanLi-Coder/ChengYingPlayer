"""Exercise real Sparkle signing with disposable keys, never production credentials."""

from __future__ import annotations

import base64
import copy
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import generate_update_feed as producer
import validate_release_progress as progress
import verify_appcast as policy


class SignedUpdates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="chengying-update-tests-")
        cls.directory = Path(cls.temporary.name)
        cls.sparkle = Path(os.environ["SPARKLE_TEST_ROOT"])
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
        cls.key = (cls.directory / "test-seed").read_bytes()
        cls.public = (cls.directory / "test-public").read_text()
        cls.verifier = cls.directory / "verify-ed25519"
        policy.compile_verifier(cls.verifier)
        cls.info = {
            "CFBundleIdentifier": policy.BUNDLE_ID,
            "CFBundleName": "ChengYing",
            "CFBundleExecutable": "ChengYing",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "100",
            "CFBundleShortVersionString": "99.0.1",
            "LSMinimumSystemVersion": "12.0",
            "SUFeedURL": policy.FEED_URL,
            "SUPublicEDKey": cls.public,
            "SUEnableAutomaticChecks": True,
            "SUAllowsAutomaticUpdates": True,
            "SUAutomaticallyUpdate": False,
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
        }
        cls.tag = "v99.0.1"
        cls.app = cls.directory / "volume/ChengYing.app"
        executable = cls.app / "Contents/MacOS/ChengYing"
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
        (cls.app / "Contents/Info.plist").write_bytes(plistlib.dumps(cls.info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(cls.app)], check=True)
        (cls.app.parent / "Applications").symlink_to("/Applications")
        cls.archive = cls.directory / f"ChengYingPlayer-{cls.tag}-Apple-Silicon.dmg"
        subprocess.run(
            [
                "hdiutil",
                "create",
                "-quiet",
                "-srcfolder",
                str(cls.app.parent),
                "-format",
                "UDZO",
                str(cls.archive),
            ],
            check=True,
        )
        cls.feed = cls.directory / "appcast.xml"
        environment = dict(os.environ, SPARKLE_ED25519_PRIVATE_KEY=cls.key.decode())
        with patch.dict(os.environ, environment, clear=True):
            producer.generate(cls.app, cls.archive, cls.feed, cls.tag, cls.sparkle)
            if "SPARKLE_ED25519_PRIVATE_KEY" in os.environ:
                raise AssertionError(
                    "Signing credential leaked into later child environments."
                )
        cls.original = cls.feed.read_bytes()
        cls.content, cls.signature = policy.signed_content(cls.original)

    @classmethod
    def tearDownClass(cls):
        cls.key = b""
        cls.temporary.cleanup()

    def setUp(self):
        self.feed = self.directory / "case.xml"
        self.feed.write_bytes(self.original)
        self.info = copy.deepcopy(type(self).info)

    def verify(self):
        policy.verify(self.feed, self.archive, self.info, self.tag, self.verifier)

    def signed_mutation(self, mutate):
        tree = ET.fromstring(self.content)
        mutate(tree.find("channel/item"))
        self.feed.write_bytes(ET.tostring(tree, encoding="utf-8", xml_declaration=True))
        subprocess.run(
            [
                str(self.sparkle / "bin/sign_update"),
                "--ed-key-file",
                "-",
                str(self.feed),
            ],
            input=self.key,
            check=True,
            capture_output=True,
        )

    def test_actual_sparkle_signed_dmg_and_feed(self):
        self.verify()

    def test_changed_feed_bytes(self):
        self.feed.write_bytes(self.original.replace(b"99.0.1", b"99.0.2", 1))
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_changed_archive_same_length(self):
        directory = self.directory / "tampered"
        directory.mkdir(exist_ok=True)
        archive = directory / self.archive.name
        data = bytearray(self.archive.read_bytes())
        data[16] ^= 1
        archive.write_bytes(data)
        with self.assertRaises(subprocess.CalledProcessError):
            policy.verify(self.feed, archive, self.info, self.tag, self.verifier)

    def test_wrong_public_key(self):
        self.info["SUPublicEDKey"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_unsigned_feed(self):
        self.feed.write_bytes(self.content)
        with self.assertRaises(ValueError):
            self.verify()

    def test_signature_envelope_boundaries(self):
        for data in (
            self.original + b"<item/>",
            self.original + self.original,
            self.original.replace(b"length: ", b"length: 1"),
            self.original.replace(b"edSignature: ", b"edSignature: ?"),
        ):
            with self.subTest(data=data[-30:]), self.assertRaises(ValueError):
                policy.signed_content(data)

    def test_security_info_policy(self):
        cases = {
            "CFBundleIdentifier": "io.iina.iina",
            "CFBundleShortVersionString": "99.0.2",
            "CFBundleVersion": "100-beta",
            "SUFeedURL": "https://iina.io/appcast.xml",
            "SUPublicEDKey": "invalid",
            "SUEnableAutomaticChecks": False,
            "SUAllowsAutomaticUpdates": False,
            "SUAutomaticallyUpdate": True,
            "SURequireSignedFeed": False,
            "SUVerifyUpdateBeforeExtraction": False,
            "SUSignedFeedFailureExpirationInterval": 1728000,
            "LSMinimumSystemVersion": "11.0",
        }
        for key, value in cases.items():
            with self.subTest(key=key):
                info = dict(self.info, **{key: value})
                with self.assertRaises(ValueError):
                    policy.validate_info(info, self.tag)

    def test_signed_wrong_version_build_architecture_os_and_website(self):
        fields = {
            policy.SPARKLE + "version": "101",
            policy.SPARKLE + "shortVersionString": "99.0.2",
            policy.SPARKLE + "hardwareRequirements": "x86_64",
            policy.SPARKLE + "minimumSystemVersion": "13.0",
            "link": "https://github.com/iina/iina/releases",
        }
        for field, value in fields.items():
            with self.subTest(field=field):
                self.signed_mutation(
                    lambda item, field=field, value=value: setattr(
                        item.find(field), "text", value
                    )
                )
                with self.assertRaises(ValueError):
                    self.verify()

    def test_signed_wrong_archive_locations_sizes_and_types(self):
        valid = f"{policy.RELEASES}/download/{self.tag}/{self.archive.name}"
        cases = [
            ("url", valid.replace("SeanLi-Coder/ChengYingPlayer", "iina/iina")),
            ("url", valid.replace("https:", "http:")),
            ("url", valid + "?download=1"),
            ("url", valid.replace(self.tag, "v99.0.0")),
            ("length", "1"),
            ("type", "application/zip"),
            (policy.SPARKLE + "installationType", "package"),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                self.signed_mutation(
                    lambda item, key=key, value=value: item.find("enclosure").set(
                        key, value
                    )
                )
                with self.assertRaises(ValueError):
                    self.verify()

    def test_signed_ambiguous_or_external_metadata(self):
        for name in (
            "version",
            "hardwareRequirements",
            "deltas",
            "releaseNotesLink",
            "channel",
            "minimumUpdateVersion",
        ):
            with self.subTest(name=name):
                self.signed_mutation(
                    lambda item, name=name: ET.SubElement(item, policy.SPARKLE + name)
                )
                with self.assertRaises(ValueError):
                    self.verify()

    def test_missing_signing_secret_fails_closed(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            self.assertRaisesRegex(ValueError, "not configured"),
        ):
            producer.generate(
                self.app,
                self.archive,
                self.directory / "missing/appcast.xml",
                self.tag,
                self.sparkle,
            )

    def test_generator_rejects_incompatible_app_architecture(self):
        with (
            patch.dict(os.environ, {"SPARKLE_ED25519_PRIVATE_KEY": self.key.decode()}),
            patch.object(subprocess, "check_output", return_value="x86_64\n"),
            self.assertRaisesRegex(ValueError, "ARM64-only"),
        ):
            producer.generate(
                self.app,
                self.archive,
                self.directory / "intel/appcast.xml",
                self.tag,
                self.sparkle,
            )

    def test_no_credentials_in_public_verifier(self):
        source = (ROOT / "other/verify_ed25519.swift").read_text()
        self.assertNotIn("PrivateKey", source)
        self.assertNotIn("Keychain", source)
        self.assertNotIn("environment", source)

    def test_release_version_and_build_must_both_increase(self):
        configuration = {
            "type": "file",
            "path": "Configs/Deployment.xcconfig",
            "encoding": "base64",
            "content": base64.b64encode(
                b"CURRENT_PROJECT_VERSION = 99\nMARKETING_VERSION = 99.0.0\n"
            ).decode(),
        }
        project_configuration = f"PRODUCT_BUNDLE_IDENTIFIER = {policy.BUNDLE_ID}\n"
        continuity = {
            "previous_info": {
                "type": "file",
                "path": "iina/Info.plist",
                "encoding": "base64",
                "content": base64.b64encode(plistlib.dumps(self.info)).decode(),
            },
            "info": self.info,
            "previous_project_configuration": {
                "type": "file",
                "path": "Configs/iina.xcconfig",
                "encoding": "base64",
                "content": base64.b64encode(project_configuration.encode()).decode(),
            },
            "project_configuration": project_configuration,
        }
        progress.validate_progress(
            "v99.0.0", self.tag, configuration, self.original,
            **continuity, built_info=self.info,
        )
        for previous, current in (
            (self.tag, self.tag),
            ("v100.0.0", self.tag),
            ("v99.0.0-rc1", self.tag),
        ):
            with self.subTest(previous=previous), self.assertRaises(ValueError):
                progress.validate_progress(
                    previous, current, configuration, self.original, **continuity
                )
        for build in ("100", "101", "invalid"):
            changed = dict(
                configuration,
                content=base64.b64encode(
                    f"CURRENT_PROJECT_VERSION = {build}\nMARKETING_VERSION = 99.0.0\n".encode()
                ).decode(),
            )
            with self.subTest(build=build), self.assertRaises(ValueError):
                progress.validate_progress(
                    "v99.0.0", self.tag, changed, self.original, **continuity
                )

    def test_new_feed_must_verify_with_the_previously_installed_public_key(self):
        policy.verify_feed_signature(self.original, self.public, self.verifier)
        with self.assertRaises(subprocess.CalledProcessError):
            policy.verify_feed_signature(
                self.original, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", self.verifier
            )

    def test_signing_failure_does_not_echo_private_input_or_tool_output(self):
        failure = subprocess.CompletedProcess(
            [], 1, b"sensitive tool output", b"sensitive tool error"
        )
        with (
            patch.dict(os.environ, {"SPARKLE_ED25519_PRIVATE_KEY": self.key.decode()}),
            patch.object(subprocess, "check_output", return_value="arm64\n"),
            patch.object(subprocess, "run", return_value=failure),
            self.assertRaises(ValueError) as caught,
        ):
            producer.generate(
                self.app,
                self.archive,
                self.directory / "failure/appcast.xml",
                self.tag,
                self.sparkle,
            )
        self.assertNotIn(self.key.decode(), str(caught.exception))
        self.assertNotIn("sensitive", str(caught.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
