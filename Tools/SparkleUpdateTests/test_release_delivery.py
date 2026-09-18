"""Network-free regression tests for reliable release upload and public discovery."""

import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "other"))
import release_delivery as delivery


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-delivery-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.tag = "v99.0.1"
        self.names = delivery.asset_names(self.tag)
        self.remote = {"tagName": self.tag, "isDraft": True, "isPrerelease": False, "assets": []}
        self.uploads = []
        for name in self.names:
            (self.directory / name).write_bytes(b"Release fixture: " + name.encode())

    def asset(self, name):
        data = (self.directory / name).read_bytes()
        return {"name": name, "state": "uploaded", "size": len(data),
                "digest": "sha256:" + hashlib.sha256(data).hexdigest()}

    def run_gh(self, *args):
        if args[:2] == ("release", "view"):
            return json.dumps(self.remote)
        self.assertEqual(args[:3], ("release", "upload", self.tag))
        self.assertNotIn("--clobber", args)
        self.assertEqual(len(args), 4)
        name = Path(args[3]).name
        self.uploads.append(name)
        self.remote["assets"] = [asset for asset in self.remote["assets"] if asset["name"] != name]
        self.remote["assets"].append(self.asset(name))
        return ""

    def test_complete_upload_and_resume_skip_verified_assets(self):
        delivery.upload_assets(self.tag, self.directory, self.run_gh, lambda _: None)
        self.assertEqual(self.uploads, list(self.names))
        delivery.upload_assets(self.tag, self.directory, self.run_gh, lambda _: None)
        self.assertEqual(self.uploads, list(self.names))

    def test_transient_upload_failure_retries_only_missing_asset(self):
        self.remote["assets"] = [self.asset(name) for name in self.names if name != self.names[2]]
        failures = [True, False]
        waits = []
        def flaky(*args):
            if args[:2] == ("release", "upload") and failures.pop(0):
                raise subprocess.CalledProcessError(1, "gh")
            return self.run_gh(*args)
        delivery.upload_assets(self.tag, self.directory, flaky, waits.append)
        self.assertEqual(self.uploads, [self.names[2]])
        self.assertEqual(waits, [5])

    def test_ambiguous_success_rechecks_digest_before_reupload(self):
        def ambiguous(*args):
            value = self.run_gh(*args)
            if args[:2] == ("release", "upload"):
                raise subprocess.TimeoutExpired("gh", 240)
            return value
        delivery.upload_assets(self.tag, self.directory, ambiguous, lambda _: self.fail("Unexpected retry"))
        self.assertEqual(self.uploads, list(self.names))

    def test_persistent_failure_is_bounded(self):
        attempts = []
        def failed(*args):
            if args[:2] == ("release", "upload"):
                attempts.append(args)
                raise subprocess.CalledProcessError(1, "gh")
            return self.run_gh(*args)
        with self.assertRaisesRegex(ValueError, "did not pass"):
            delivery.upload_assets(self.tag, self.directory, failed, lambda _: None)
        self.assertEqual(len(attempts), 3)

    def test_published_prerelease_and_unexpected_assets_are_not_mutated(self):
        for field, value in (("isDraft", False), ("isPrerelease", True), ("tagName", "v1.0.0"),
                             ("assets", [{"name": "unrelated.txt"}])):
            saved = copy.deepcopy(self.remote)
            self.remote[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                delivery.upload_assets(self.tag, self.directory, self.run_gh, lambda _: None)
            self.remote = saved
        self.assertEqual(self.uploads, [])

    def test_published_during_retry_stops_next_upload(self):
        def raced(*args):
            if args[:2] == ("release", "upload"):
                self.remote["isDraft"] = False
                raise subprocess.CalledProcessError(1, "gh")
            return self.run_gh(*args)
        with self.assertRaisesRegex(ValueError, "exact stable draft"):
            delivery.upload_assets(self.tag, self.directory, raced, lambda _: None)
        self.assertEqual(self.uploads, [])

    def test_conflicting_remote_asset_is_never_overwritten(self):
        remote = self.asset(self.names[0])
        remote["digest"] = "sha256:" + "0" * 64
        self.remote["assets"] = [remote]
        with self.assertRaisesRegex(ValueError, "conflicts"):
            delivery.upload_assets(self.tag, self.directory, self.run_gh, lambda _: None)
        self.assertEqual(self.uploads, [])
        self.assertEqual(self.remote["assets"], [remote])

    def test_publish_and_asset_creation_race_cannot_clobber_existing_bytes(self):
        original = self.asset(self.names[0])
        original["digest"] = "sha256:" + "0" * 64
        attempted = []
        def raced(*args):
            if args[:2] == ("release", "upload"):
                attempted.append(args)
                self.remote.update(isDraft=False, assets=[original])
                self.assertNotIn("--clobber", args)
                raise subprocess.CalledProcessError(1, "gh")
            return self.run_gh(*args)
        with self.assertRaisesRegex(ValueError, "exact stable draft"):
            delivery.upload_assets(self.tag, self.directory, raced, lambda _: None)
        self.assertEqual(len(attempted), 1)
        self.assertEqual(self.remote["assets"], [original])

    def public_fixture(self):
        (self.directory / self.names[0]).write_bytes(b"d" * 123)
        content = (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                   f'<sparkle:shortVersionString>{self.tag[1:]}</sparkle:shortVersionString>'
                   f'<enclosure url="{delivery.RELEASES}/download/{self.tag}/{self.names[0]}" length="123"/>'
                   '</item></channel></rss>').encode()
        feed = content + b'<!-- sparkle-signatures:\nedSignature: ' + b'A' * 86 + b'==\nlength: ' + str(len(content)).encode() + b'\n-->\n'
        release = {"tag_name": self.tag, "draft": False, "prerelease": False,
                   "assets": [self.asset(name) for name in self.names]}
        release["assets"][0]["size"] = 123
        release["assets"][-1]["digest"] = "sha256:" + hashlib.sha256(feed).hexdigest()
        return feed, release

    def test_public_exact_feed_and_archive_verified_without_credentials(self):
        feed, release = self.public_fixture()
        calls = []
        def request(url, method="GET"):
            calls.append((url, method))
            if url.startswith("https://api.github.com/"):
                return json.dumps(release).encode(), {}
            return (b"", {"Content-Length": "123"}) if method == "HEAD" else (feed, {})
        download = Mock()
        delivery.verify_public(self.tag, feed, self.directory / self.names[0], request, download)
        self.assertEqual(calls[1], (delivery.FEED_URL, "GET"))
        self.assertEqual(len(calls), 2)
        download.assert_called_once_with(f"{delivery.RELEASES}/download/{self.tag}/{self.names[0]}",
                                         123, hashlib.sha256(b"d" * 123).hexdigest())

    def test_old_latest_draft_prerelease_missing_asset_and_stale_feed_rejected(self):
        feed, release = self.public_fixture()
        cases = [{"tag_name": "v99.0.0"}, {"draft": True}, {"prerelease": True},
                 {"assets": release["assets"][:-1]}]
        for fields in cases:
            changed = dict(release, **fields)
            with self.subTest(fields=list(fields)), self.assertRaises(ValueError):
                delivery.verify_public(self.tag, feed, self.directory / self.names[0],
                                       lambda *args: (json.dumps(changed).encode(), {}))
        def stale(url, method="GET"):
            return (json.dumps(release).encode(), {}) if "api.github.com" in url else (b"old feed", {})
        with self.assertRaisesRegex(ValueError, "stale or changed"):
            delivery.verify_public(self.tag, feed, self.directory / self.names[0], stale)

    def test_public_archive_digest_must_match(self):
        feed, release = self.public_fixture()
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        def request(url, method="GET"):
            if "api.github.com" in url:
                return json.dumps(release).encode(), {}
            self.fail("Digest mismatch must stop before download")
        with self.assertRaisesRegex(ValueError, "DMG asset digest"):
            delivery.verify_public(self.tag, feed, self.directory / self.names[0], request)

    def test_streamed_download_checks_exact_get_bytes_and_uses_no_credentials(self):
        class Response(io.BytesIO):
            status = 200
        expected = b"verified archive bytes"
        expected_digest = hashlib.sha256(expected).hexdigest()
        for body in (expected, b"X" * len(expected), expected[:-1], expected + b"extra"):
            opener = Mock()
            opener.open.return_value = Response(body)
            with self.subTest(body=body):
                if body == expected:
                    delivery.verify_download(delivery.FEED_URL, len(expected), expected_digest, opener)
                else:
                    with self.assertRaises(ValueError):
                        delivery.verify_download(delivery.FEED_URL, len(expected), expected_digest, opener)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.get_method(), "GET")
            self.assertFalse(request.has_header("Authorization"))

    def test_download_failure_and_timeout_cannot_pass(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(delivery.FEED_URL, 503, "Unavailable", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            delivery.verify_download(delivery.FEED_URL, 1, "0" * 64, opener)
        class Response(io.BytesIO):
            status = 200
        opener.open.side_effect = None
        opener.open.return_value = Response(b"A")
        clock = Mock(side_effect=[0, 301])
        with self.assertRaisesRegex(ValueError, "time limit"):
            delivery.verify_download(delivery.FEED_URL, 1, "0" * 64, opener, clock)

    def test_download_deadline_is_checked_after_data_and_eof(self):
        class Response(io.BytesIO):
            status = 200
        for body in (b"A", b""):
            opener = Mock()
            opener.open.return_value = Response(body)
            clock = Mock(side_effect=[0, 1, 301])
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "time limit"):
                delivery.verify_download(delivery.FEED_URL, 1, hashlib.sha256(b"A").hexdigest(), opener, clock)

    def test_redirects_keep_head_and_reject_untrusted_destinations(self):
        redirect = delivery.ReleaseRedirects()
        original = urllib.request.Request(delivery.FEED_URL, method="HEAD")
        redirected = redirect.redirect_request(original, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/asset")
        self.assertEqual(redirected.get_method(), "HEAD")
        for url in ("http://github.com/asset", "https://github.com.evil.invalid/asset", "https://user:pass@github.com/asset"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                redirect.redirect_request(original, None, 302, "Found", {}, url)


if __name__ == "__main__":
    unittest.main(verbosity=2)
