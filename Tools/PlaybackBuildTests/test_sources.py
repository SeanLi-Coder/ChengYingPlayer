"""Exercise the production source-fetching shell functions without network access."""

import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
PLAYBACK_SOURCES = PROJECT_ROOT / "other/playback_sources.sh"
THIRD_PARTY_SOURCES = PROJECT_ROOT / "other/third_party_sources.sh"
PRIMARY_URL = (
    "https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz"
)
MIRROR_URL = "https://sources.buildroot.net/dav1d/dav1d-1.5.3.tar.xz"
SOURCE_FILENAME = "dav1d-1.5.3.tar.xz"
PINNED_SHA256 = "732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011"
FIXTURE_BYTES = b"Verified source fixture\x00\xff\x10\n"
FIXTURE_SHA256 = hashlib.sha256(FIXTURE_BYTES).hexdigest()


def fake_curl(arguments):
    """Replace only HTTP transport; the shell still performs real file hashing."""
    plan = json.loads(Path(os.environ["PLAYBACK_TEST_PLAN"]).read_text())
    urls = [argument for argument in arguments if "://" in argument]
    output = Path(arguments[arguments.index("--output") + 1])
    before = output.read_bytes().hex() if output.exists() else None
    with Path(os.environ["PLAYBACK_TEST_REQUESTS"]).open("a") as requests:
        requests.write(json.dumps({"arguments": arguments, "output_before": before}) + "\n")
    if len(urls) != 1 or urls[0] not in plan:
        return 97
    response = plan[urls[0]]
    if "body" in response:
        mode = "ab" if response.get("append") else "wb"
        with output.open(mode) as target:
            target.write(bytes.fromhex(response["body"]))
    return response.get("status", 0)


class PlaybackSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="playback-sources-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.cache = self.directory / "source cache"
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.plan_path = self.directory / "plan.json"
        self.requests_path = self.directory / "requests.jsonl"
        fake = self.bin / "curl"
        fake.write_text(
            "#!/bin/bash\nexec "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(str(Path(__file__).resolve()))
            + ' --fake-curl "$@"\n'
        )
        fake.chmod(0o755)
        self.set_plan({})

    @property
    def destination(self):
        return self.cache / SOURCE_FILENAME

    def set_plan(self, plan):
        self.plan_path.write_text(json.dumps(plan))

    def response(self, status=0, body=FIXTURE_BYTES, **extra):
        return {"status": status, "body": body.hex(), **extra}

    def requests(self):
        if not self.requests_path.exists():
            return []
        return [json.loads(line) for line in self.requests_path.read_text().splitlines()]

    def urls(self):
        return [
            next(argument for argument in entry["arguments"] if "://" in argument)
            for entry in self.requests()
        ]

    def fetch(
        self,
        *,
        entrypoint="fetch_playback_source",
        component="dav1d",
        record_name="dav1d",
        version="1.5.3",
        filename=SOURCE_FILENAME,
        url=PRIMARY_URL,
        conditional=False,
    ):
        # Replace source fixture data, not any production retrieval or hash logic.
        record = f"{record_name}\t{version}\t{filename}\t{url}\t{FIXTURE_SHA256}"
        environment = os.environ.copy()
        environment.update(
            PATH=str(self.bin) + os.pathsep + os.defpath,
            PLAYBACK_TEST_PLAN=str(self.plan_path),
            PLAYBACK_TEST_REQUESTS=str(self.requests_path),
            PLAYBACK_TEST_RECORDS=record,
        )
        script = (
            THIRD_PARTY_SOURCES
            if entrypoint == "fetch_verified_source"
            else PLAYBACK_SOURCES
        )
        invocation = '"$2" "$3" "$4"'
        if conditional:
            invocation = 'if ' + invocation + '; then exit 0; else exit "$?"; fi'
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; playback_source_records() { '
                'printf "%s\\n" "$PLAYBACK_TEST_RECORDS"; }; ' + invocation,
                "source-test",
                str(script),
                entrypoint,
                component,
                str(self.cache),
            ],
            env=environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.destination) + "\n")
        self.assertEqual(self.destination.read_bytes(), FIXTURE_BYTES)
        self.assert_no_partials()

    def assert_no_partials(self):
        self.assertEqual(list(self.cache.glob("*.partial*")), [])

    def assert_failure(self, result, status):
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assert_no_partials()

    def test_verified_cached_source_skips_network(self):
        self.cache.mkdir()
        self.destination.write_bytes(FIXTURE_BYTES)
        old_stat = self.destination.stat()
        result = self.fetch()
        self.assert_success(result)
        self.assertEqual(self.urls(), [])
        self.assertEqual(self.destination.stat().st_ino, old_stat.st_ino)
        self.assertEqual(self.destination.stat().st_mtime_ns, old_stat.st_mtime_ns)

    def test_primary_success_does_not_request_mirror(self):
        self.set_plan({PRIMARY_URL: self.response()})
        self.assert_success(self.fetch())
        self.assertEqual(self.urls(), [PRIMARY_URL])

    def test_primary_requests_are_bounded_and_https_only(self):
        self.set_plan({PRIMARY_URL: self.response()})
        self.assert_success(self.fetch())
        arguments = self.requests()[0]["arguments"]
        for flag, expected in (
            ("--connect-timeout", "15"),
            ("--max-time", "120"),
            ("--retry", "0"),
            ("--proto", "=https"),
            ("--proto-redir", "=https"),
        ):
            self.assertEqual(arguments[arguments.index(flag) + 1], expected)
        self.assertNotIn("--insecure", arguments)
        self.assertNotIn("--retry-all-errors", arguments)

    def test_connection_failures_use_only_verified_mirror(self):
        for status in (6, 7, 28):
            with self.subTest(status=status):
                self.set_plan(
                    {PRIMARY_URL: self.response(status, b"partial"), MIRROR_URL: self.response()}
                )
                self.assert_success(self.fetch())
                self.destination.unlink()
        self.assertEqual(self.urls(), [PRIMARY_URL, MIRROR_URL] * 3)

    def test_failed_partial_is_not_appended_to_mirror_response(self):
        self.set_plan(
            {
                PRIMARY_URL: self.response(28, b"unverified original partial"),
                MIRROR_URL: self.response(append=True),
            }
        )
        self.assert_success(self.fetch())
        self.assertEqual(self.requests()[1]["output_before"], "")

    def test_mirror_uses_identical_https_and_timeout_policy(self):
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response()})
        self.assert_success(self.fetch())
        primary_arguments, mirror_arguments = [item["arguments"] for item in self.requests()]
        self.assertEqual(
            [MIRROR_URL if argument == PRIMARY_URL else argument for argument in primary_arguments],
            mirror_arguments,
        )

    def test_primary_checksum_mismatch_never_falls_back(self):
        self.set_plan(
            {PRIMARY_URL: self.response(body=b"incorrect archive"), MIRROR_URL: self.response()}
        )
        result = self.fetch()
        self.assert_failure(result, 1)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(self.urls(), [PRIMARY_URL])
        self.assertFalse(self.destination.exists())

    def test_mirror_checksum_mismatch_is_fatal(self):
        self.set_plan(
            {PRIMARY_URL: self.response(28), MIRROR_URL: self.response(body=b"incorrect mirror")}
        )
        self.assert_failure(self.fetch(), 1)
        self.assertEqual(self.urls(), [PRIMARY_URL, MIRROR_URL])
        self.assertFalse(self.destination.exists())

    def test_both_endpoints_failing_leave_no_destination_or_partial(self):
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response(7)})
        self.assert_failure(self.fetch(), 7)
        self.assertEqual(self.urls(), [PRIMARY_URL, MIRROR_URL])
        self.assertFalse(self.destination.exists())

    def test_tls_http_partial_and_local_write_errors_do_not_fall_back(self):
        statuses = (1, 18, 22, 23, 35, 47, 51, 52, 55, 56, 58, 60, 77)
        for status in statuses:
            with self.subTest(status=status):
                self.set_plan({PRIMARY_URL: self.response(status), MIRROR_URL: self.response()})
                self.assert_failure(self.fetch(), status)
                self.assertFalse(self.destination.exists())
        self.assertEqual(self.urls(), [PRIMARY_URL] * len(statuses))

    def test_invalid_cached_source_survives_transport_failure(self):
        self.cache.mkdir()
        self.destination.write_bytes(b"old invalid cache")
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response(7)})
        self.assert_failure(self.fetch(), 7)
        self.assertEqual(self.destination.read_bytes(), b"old invalid cache")

    def test_invalid_cached_source_survives_checksum_failure(self):
        self.cache.mkdir()
        self.destination.write_bytes(b"old invalid cache")
        self.set_plan({PRIMARY_URL: self.response(body=b"bad new bytes")})
        self.assert_failure(self.fetch(), 1)
        self.assertEqual(self.destination.read_bytes(), b"old invalid cache")

    def test_invalid_cached_source_is_replaced_after_successful_verification(self):
        self.cache.mkdir()
        self.destination.write_bytes(b"old invalid cache")
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response()})
        self.assert_success(self.fetch())

    def test_cleanup_does_not_remove_other_downloads(self):
        self.cache.mkdir()
        unrelated = self.cache / (SOURCE_FILENAME + ".partial-unrelated")
        unrelated.write_bytes(b"another download")
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response(7)})
        result = self.fetch()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(unrelated.read_bytes(), b"another download")
        self.assertEqual(list(self.cache.glob("*.partial*")), [unrelated])

    def test_mirror_is_scoped_to_exact_component_version_filename_and_url(self):
        variants = (
            {"component": "other", "record_name": "other"},
            {"version": "1.5.4"},
            {"filename": "different.tar.xz"},
            {"url": "https://example.invalid/dav1d-1.5.3.tar.xz"},
        )
        for variant in variants:
            with self.subTest(variant=variant):
                source_url = variant.get("url", PRIMARY_URL)
                self.set_plan({source_url: self.response(28), MIRROR_URL: self.response()})
                self.assert_failure(self.fetch(**variant), 28)
        self.assertNotIn(MIRROR_URL, self.urls())
        self.assertEqual(len(self.urls()), len(variants))

    def test_non_https_source_is_rejected_before_curl(self):
        for url in (
            "http://downloads.videolan.org/dav1d.tar.xz",
            "file:///tmp/dav1d.tar.xz",
            "ftp://example.invalid/dav1d.tar.xz",
        ):
            with self.subTest(url=url):
                result = self.fetch(url=url)
                self.assert_failure(result, 2)
                self.assertIn("must use HTTPS", result.stderr)
        self.assertEqual(self.urls(), [])

    def test_unknown_component_is_rejected_without_network(self):
        result = self.fetch(component="not-a-component")
        self.assert_failure(result, 2)
        self.assertIn("Unknown playback source component", result.stderr)
        self.assertEqual(self.urls(), [])

    def test_release_source_entrypoint_uses_same_mirror_policy(self):
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response()})
        self.assert_success(self.fetch(entrypoint="fetch_verified_source"))
        self.assertEqual(self.urls(), [PRIMARY_URL, MIRROR_URL])

    def test_release_source_entrypoint_never_falls_back_on_bad_checksum(self):
        self.set_plan(
            {PRIMARY_URL: self.response(body=b"bad source"), MIRROR_URL: self.response()}
        )
        self.assert_failure(self.fetch(entrypoint="fetch_verified_source"), 1)
        self.assertEqual(self.urls(), [PRIMARY_URL])

    def test_release_source_entrypoint_reuses_verified_cache(self):
        self.cache.mkdir()
        self.destination.write_bytes(FIXTURE_BYTES)
        self.assert_success(self.fetch(entrypoint="fetch_verified_source"))
        self.assertEqual(self.urls(), [])

    def fail_command(self, command, status=73):
        fake = self.bin / command
        fake.write_text(f"#!/bin/bash\nexit {status}\n")
        fake.chmod(0o755)

    def assert_command_failure_in_all_call_contexts(self):
        for entrypoint in ("fetch_playback_source", "fetch_verified_source"):
            for conditional in (False, True):
                with self.subTest(entrypoint=entrypoint, conditional=conditional):
                    self.assert_failure(
                        self.fetch(entrypoint=entrypoint, conditional=conditional), 73
                    )

    def test_cache_directory_failure_is_not_reported_as_success(self):
        self.fail_command("mkdir")
        self.assert_command_failure_in_all_call_contexts()
        self.assertEqual(self.urls(), [])

    def test_partial_creation_failure_is_not_reported_as_success(self):
        self.fail_command("mktemp")
        self.assert_command_failure_in_all_call_contexts()
        self.assertEqual(self.urls(), [])

    def test_cached_hash_read_failure_keeps_cache_and_stops(self):
        self.cache.mkdir()
        self.destination.write_bytes(FIXTURE_BYTES)
        self.fail_command("shasum")
        self.assert_command_failure_in_all_call_contexts()
        self.assertEqual(self.destination.read_bytes(), FIXTURE_BYTES)
        self.assertEqual(self.urls(), [])

    def test_downloaded_hash_read_failure_is_not_reported_as_success(self):
        self.set_plan({PRIMARY_URL: self.response()})
        self.fail_command("shasum")
        self.assert_command_failure_in_all_call_contexts()
        self.assertFalse(self.destination.exists())
        self.assertNotIn(MIRROR_URL, self.urls())

    def test_cache_publication_failure_keeps_original_cache(self):
        self.cache.mkdir()
        self.destination.write_bytes(b"old invalid cache")
        self.set_plan({PRIMARY_URL: self.response(28), MIRROR_URL: self.response()})
        self.fail_command("mv")
        self.assert_command_failure_in_all_call_contexts()
        self.assertEqual(self.destination.read_bytes(), b"old invalid cache")

    def test_conditional_calls_still_reject_bad_mirror_digest(self):
        self.set_plan(
            {PRIMARY_URL: self.response(28), MIRROR_URL: self.response(body=b"bad digest")}
        )
        for entrypoint in ("fetch_playback_source", "fetch_verified_source"):
            with self.subTest(entrypoint=entrypoint):
                self.assert_failure(self.fetch(entrypoint=entrypoint, conditional=True), 1)
        self.assertFalse(self.destination.exists())

    def test_production_source_records_keep_original_identity(self):
        expected = ["dav1d", "1.5.3", SOURCE_FILENAME, PRIMARY_URL, PINNED_SHA256]
        for script, function in (
            (PLAYBACK_SOURCES, "playback_source_records"),
            (THIRD_PARTY_SOURCES, "third_party_source_records"),
        ):
            with self.subTest(function=function):
                result = subprocess.run(
                    ["/bin/bash", "-c", 'source "$1"; "$2"', "source-records", str(script), function],
                    check=True,
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                records = [line.split("\t") for line in result.stdout.splitlines()]
                self.assertEqual([record for record in records if record[0] == "dav1d"], [expected])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fake-curl"]:
        sys.exit(fake_curl(sys.argv[2:]))
    unittest.main()
