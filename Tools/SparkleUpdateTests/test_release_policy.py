"""Offline release continuity checks using public fixtures and no signing tools."""

from __future__ import annotations

import base64
import contextlib
import io
import plistlib
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import validate_release_progress as progress
import verify_appcast as policy

PUBLIC_A = base64.b64encode(bytes(range(32))).decode()
PUBLIC_B = base64.b64encode(bytes(reversed(range(32)))).decode()


def contents(path, data):
    return {
        "type": "file",
        "path": path,
        "encoding": "base64",
        "content": base64.b64encode(data).decode(),
    }


def feed(version="1.1.0", build="11"):
    body = (
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f"<channel><item><sparkle:version>{build}</sparkle:version>"
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        "</item></channel></rss>\n"
    ).encode()
    signature = base64.b64encode(bytes(64))
    return body + b"<!-- sparkle-signatures:\nedSignature: " + signature + b"\nlength: " + str(len(body)).encode() + b"\n-->\n"


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.source = {
            "SUFeedURL": policy.FEED_URL,
            "SUPublicEDKey": PUBLIC_A,
            "SUEnableAutomaticChecks": True,
            "SUAllowsAutomaticUpdates": True,
            "SUAutomaticallyUpdate": False,
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
        }
        self.project = f"PRODUCT_BUNDLE_IDENTIFIER = {policy.BUNDLE_ID}\n"
        self.configuration = contents(
            "Configs/Deployment.xcconfig",
            b"CURRENT_PROJECT_VERSION = 10\nMARKETING_VERSION = 1.0.0\n",
        )
        self.kwargs = {
            "previous_info": contents("iina/Info.plist", plistlib.dumps(self.source)),
            "info": self.source,
            "previous_project_configuration": contents("Configs/iina.xcconfig", self.project.encode()),
            "project_configuration": self.project,
        }
        self.built = dict(
            self.source,
            CFBundleIdentifier=policy.BUNDLE_ID,
            CFBundleVersion="11",
            CFBundleShortVersionString="1.1.0",
            LSMinimumSystemVersion="12.0",
        )
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def validate(self, **changes):
        kwargs = dict(self.kwargs, **changes)
        progress.validate_progress("v1.0.0", "v1.1.0", self.configuration, feed(), **kwargs)

    def test_same_public_key_and_identity_preserve_the_update_chain(self):
        with patch.object(progress, "verify_feed_signature") as verify:
            self.validate()
        verify.assert_not_called()

    def test_changing_current_or_previous_public_key_is_rejected(self):
        self.source["SUPublicEDKey"] = PUBLIC_B
        with self.assertRaisesRegex(ValueError, "public update key changed"):
            self.validate()
        self.source["SUPublicEDKey"] = PUBLIC_A
        old = dict(self.source, SUPublicEDKey=PUBLIC_B)
        with self.assertRaisesRegex(ValueError, "public update key changed"):
            self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps(old)))

    def test_invalid_previous_public_keys_fail_closed(self):
        for key in (None, "invalid", base64.b64encode(bytes(31)).decode(), PUBLIC_A + "\n"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                old = dict(self.source, SUPublicEDKey=key)
                if key is None:
                    del old["SUPublicEDKey"]
                self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps(old)))

    def test_current_and_previous_feed_must_remain_the_stable_url(self):
        for previous in (False, True):
            changed = dict(self.source, SUFeedURL="https://example.invalid/appcast.xml")
            with self.subTest(previous=previous), self.assertRaises(ValueError):
                if previous:
                    self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps(changed)))
                else:
                    self.validate(info=changed)

    def test_source_identity_comes_from_project_configuration_when_plist_omits_it(self):
        self.assertNotIn("CFBundleIdentifier", self.source)
        self.validate()
        for identity in (policy.BUNDLE_ID, "$(PRODUCT_BUNDLE_IDENTIFIER)", "${PRODUCT_BUNDLE_IDENTIFIER}"):
            with self.subTest(identity=identity):
                self.validate(info=dict(self.source, CFBundleIdentifier=identity))

    def test_changed_ambiguous_or_unresolved_project_identity_is_rejected(self):
        configurations = (
            "PRODUCT_BUNDLE_IDENTIFIER = other.application\n",
            self.project + self.project,
            "PRODUCT_BUNDLE_IDENTIFIER = $(OTHER_IDENTIFIER)\n",
            "// Missing identity\n",
        )
        for configuration in configurations:
            for previous in (False, True):
                with self.subTest(configuration=configuration, previous=previous), self.assertRaises(ValueError):
                    if previous:
                        self.validate(previous_project_configuration=contents("Configs/iina.xcconfig", configuration.encode()))
                    else:
                        self.validate(project_configuration=configuration)

    def test_source_plist_cannot_override_the_fixed_identity(self):
        changed = dict(self.source, CFBundleIdentifier="other.application")
        with self.assertRaises(ValueError):
            self.validate(info=changed)
        with self.assertRaises(ValueError):
            self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps(changed)))

    def test_api_response_path_type_and_encoding_are_checked(self):
        for argument in ("previous_info", "previous_project_configuration"):
            for field, value in (("path", "other/file"), ("type", "symlink"), ("encoding", "raw"), ("content", "!invalid!")):
                changed = dict(self.kwargs[argument], **{field: value})
                with self.subTest(argument=argument, field=field), self.assertRaises(ValueError):
                    self.validate(**{argument: changed})

    def test_previous_automatic_preferences_do_not_block_an_upgrade(self):
        old = dict(self.source)
        for key in ("SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate"):
            del old[key]
        self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps(old)))

    def test_current_automatic_update_policy_requires_exact_booleans(self):
        for key, expected in (("SUEnableAutomaticChecks", True), ("SUAllowsAutomaticUpdates", True), ("SUAutomaticallyUpdate", False)):
            for value in (not expected, int(expected), str(expected), None):
                info = dict(self.built, **{key: value})
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    policy.validate_info(info, "v1.1.0")
            missing = dict(self.built)
            del missing[key]
            with self.subTest(key=key, missing=True), self.assertRaises(ValueError):
                policy.validate_info(missing, "v1.1.0")
        policy.validate_info(self.built, "v1.1.0")

    def test_current_source_cannot_disable_automatic_checks(self):
        with self.assertRaisesRegex(ValueError, "SUEnableAutomaticChecks"):
            self.validate(info=dict(self.source, SUEnableAutomaticChecks=False))

    def test_version_and_build_must_still_increase(self):
        for current_tag, current_feed in (("v1.0.0", feed("1.0.0")), ("v0.9.0", feed("0.9.0")),
                                          ("v1.1.0", feed(build="10")), ("v1.1.0", feed(build="9"))):
            with self.subTest(tag=current_tag, feed=current_feed), self.assertRaises(ValueError):
                progress.validate_progress("v1.0.0", current_tag, self.configuration, current_feed, **self.kwargs)

    def test_built_gate_verifies_the_feed_using_the_previous_public_key(self):
        with patch.object(progress, "verify_feed_signature") as verify:
            self.validate(built_info=self.built)
        verify.assert_called_once_with(feed(), PUBLIC_A)

    def test_built_key_identity_build_and_policy_cannot_differ(self):
        changes = {"SUPublicEDKey": PUBLIC_B, "CFBundleIdentifier": "other.application",
                   "CFBundleVersion": "12", "SUFeedURL": "https://example.invalid/appcast.xml",
                   "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": True}
        for field, value in changes.items():
            with self.subTest(field=field), patch.object(progress, "verify_feed_signature") as verify:
                with self.assertRaises(ValueError):
                    self.validate(built_info=dict(self.built, **{field: value}))
                verify.assert_not_called()

    def test_built_gate_propagates_a_failed_signature_check(self):
        with patch.object(progress, "verify_feed_signature", side_effect=ValueError("Signature rejected")):
            with self.assertRaisesRegex(ValueError, "Signature rejected"):
                self.validate(built_info=self.built)

    def test_signature_verifier_receives_only_public_key_signature_and_exact_bytes(self):
        data = feed()
        body, signature = policy.signed_content(data)

        def verify(command, *, check):
            self.assertEqual(command[:3], ["/trusted/public-verifier", PUBLIC_A, signature])
            self.assertEqual(Path(command[3]).read_bytes(), body)
            self.assertTrue(check)

        with patch.object(policy.subprocess, "run", side_effect=verify) as run:
            self.assertEqual(policy.verify_feed_signature(data, PUBLIC_A, "/trusted/public-verifier"), body)
        run.assert_called_once()

    def test_signature_verifier_compiles_the_existing_public_only_tool(self):
        with patch.object(policy, "compile_verifier") as compile_verifier, patch.object(policy.subprocess, "run") as run:
            policy.verify_feed_signature(feed(), PUBLIC_A)
        compile_verifier.assert_called_once()
        self.assertEqual(run.call_args.args[0][0], str(compile_verifier.call_args.args[0]))

    def test_unsigned_feed_fails_before_starting_a_verifier(self):
        with patch.object(policy.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                policy.verify_feed_signature(b"<rss/>", PUBLIC_A, "/trusted/public-verifier")
        run.assert_not_called()

    def test_malformed_old_source_plist_is_rejected(self):
        with self.assertRaises((ValueError, plistlib.InvalidFileException)):
            self.validate(previous_info=contents("iina/Info.plist", b"not a plist"))
        with self.assertRaises(ValueError):
            self.validate(previous_info=contents("iina/Info.plist", plistlib.dumps([self.source])))


if __name__ == "__main__":
    unittest.main(verbosity=2)
