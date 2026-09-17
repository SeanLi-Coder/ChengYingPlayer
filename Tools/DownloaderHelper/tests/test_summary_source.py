"""Offline contract tests: all cookies, HTTP responses, media, and settings are fixtures."""

from __future__ import annotations

import copy
import json
import math
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from http.cookiejar import CookieJar
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "vendor/rednote")]
import summary_source as source

URL = "https://www.youtube.com/watch?v=abcdefghijk"
CAPTION_URL = "https://www.youtube.com/api/timedtext?v=abcdefghijk"


def caption_blob():
    return json.dumps(
        {
            "body": [
                {"from": 0, "to": 5, "content": "First sentence."},
                {"from": 5, "to": 10, "content": "Second sentence."},
            ]
        }
    ).encode()


def metadata():
    return {
        "id": "abcdefghijk",
        "title": "Fixture video",
        "duration": 10.0,
        "language": "en",
        "subtitles": {"en": [{"ext": "json", "url": CAPTION_URL}]},
    }


class Response:
    def __init__(self, body, status=200, headers=None):
        self.body, self.status_code, self.headers = body, status, headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def iter_content(self, size):
        for index in range(0, len(self.body), size):
            yield self.body[index : index + size]


class Session:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.cookies = CookieJar()
        self.headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.responses.pop(0)


class Downloader:
    def __init__(self, info, folder):
        self.info, self.folder = info, folder
        self.cookiejar = CookieJar()
        self.downloads = 0
        self.options = None
        self.progress = {
            "status": "finished",
            "downloaded_bytes": 20,
            "total_bytes": 20,
            "speed": 10,
            "eta": 0,
            "filename": "PRIVATE-SIGNED-URL",
        }

    def __call__(self, options):
        self.options = options
        self.params = options
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def extract_info(self, url, *, download, process):
        if download or process:
            raise AssertionError(
                "Discovery must not download media or process playlists"
            )
        return copy.deepcopy(self.info)

    def process_ie_result(self, info, *, download):
        if self.params.get("listsubtitles") or self.params.get("simulate"):
            raise AssertionError(
                "Audio fallback must not remain in subtitle-list-only mode"
            )
        self.downloads += 1
        self.options["progress_hooks"][0](self.progress)
        audio = self.folder / "audio.m4a"
        audio.write_bytes(b"fixture audio bytes")
        return {"requested_downloads": [{"filepath": str(audio)}]}


class SummarySourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="summary-source-test-")
        self.root = Path(self.temporary.name).resolve()
        self.data = self.root / "data"
        self.job = self.root / "job"
        self.data.mkdir()
        self.job.mkdir()
        self.ffmpeg = self.root / "ffmpeg"
        self.ffprobe = self.root / "ffprobe"
        for executable in (self.ffmpeg, self.ffprobe):
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o700)
        (self.data / "config.json").write_text(
            json.dumps({"use_chrome_cookies": False})
        )
        self.args = SimpleNamespace(
            data_dir=self.data,
            download_dir=self.job,
            ffmpeg=self.ffmpeg,
            ffprobe=self.ffprobe,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def acquire(self, info=None, responses=None, progress=None):
        downloader = Downloader(info or metadata(), self.job)
        if progress is not None:
            downloader.progress = progress
        session = Session(
            [Response(caption_blob())] if responses is None else responses
        )
        events = []
        with patch.object(source, "validate_audio") as probe:
            path = source.acquire(
                self.args,
                URL,
                "youtube",
                events.append,
                source.Cancellation(),
                ydl_factory=downloader,
                session_factory=lambda: session,
                node=self.root / "node",
            )
        return json.loads(path.read_text()), downloader, session, events, probe

    def test_supported_urls_are_canonical_and_tracking_is_removed(self):
        cases = {
            "https://youtu.be/abcdefghijk?si=private-tracking": URL,
            "http://m.youtube.com/watch?v=abcdefghijk&t=20": URL,
            "https://www.youtube.com/shorts/abcdefghijk": URL,
            URL + "&list=PLxxx&index=9&start_radio=1": URL,
            "https://www.bilibili.com/video/BV1xx411c7mD/?p=2&spm_id_from=private": "https://www.bilibili.com/video/BV1xx411c7mD?p=2",
            "https://b23.tv/abc123?share_session=private": "https://b23.tv/abc123",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(source.source_url(value)[0], expected)

    def test_rejects_unsafe_urls_and_playlists(self):
        for value in [
            "file:///etc/passwd",
            "https://127.0.0.1/a",
            "https://youtube.com.evil.invalid/watch?v=abcdefghijk",
            "https://fixture-user:fixture-pass@youtube.com/watch?v=abcdefghijk",
            "https://www.youtube.com/playlist?list=PLxxx",
            "https://youtube.com/@channel",
            "https://youtube.com/live/abcdefghijk",
            "https://youtube.com:444/watch?v=abcdefghijk",
            "https://b23.tv/a/b",
            "https://youtube.com/watch?v=one&v=two",
            "https://youtube.com\\@evil.invalid/a",
            "https://youtube.com/watch?v=abcdefghijk\n",
            "ftp://www.youtube.com/watch?v=abcdefghijk",
        ]:
            with self.subTest(value=value), self.assertRaises(source.SourceError):
                source.source_url(value)

    def test_request_limits_and_invalid_source_keep_safe_id(self):
        request = {
            "id": "summary-source-smoke-0",
            "source_url": "https://example.invalid/",
        }
        with self.assertRaises(source.SourceError) as caught:
            source.request_from_line(json.dumps(request).encode() + b"\n")
        self.assertEqual(caught.exception.request_id, request["id"])
        for raw in [
            b"[]\n",
            b"{}\n",
            b"x" * (source.MAX_REQUEST + 1),
            b'{"id":"x","source_url":"x","token":"private"}\n',
        ]:
            with self.assertRaises(source.SourceError):
                source.request_from_line(raw)

    def test_bili_json_json3_and_vtt_preserve_timestamps(self):
        bodies = [
            (caption_blob(), "json"),
            (
                json.dumps(
                    {
                        "events": [
                            {
                                "tStartMs": 0,
                                "dDurationMs": 5000,
                                "segs": [{"utf8": "First sentence."}],
                            },
                            {
                                "tStartMs": 5000,
                                "dDurationMs": 5000,
                                "segs": [{"utf8": "Second sentence."}],
                            },
                        ]
                    }
                ).encode(),
                "json3",
            ),
            (
                b"WEBVTT\n\n00:00.000 --> 00:05.000\nFirst sentence.\n\n00:05.000 --> 00:10.000\nSecond sentence.\n",
                "vtt",
            ),
        ]
        for raw, extension in bodies:
            with self.subTest(extension=extension):
                result = source.parse_captions(raw, extension, 10)
                self.assertEqual([item["start"] for item in result], [0, 5])
                self.assertEqual(result[-1]["end"], 10)

    def test_rolling_cues_are_deduplicated_without_losing_coverage(self):
        raw = json.dumps(
            {
                "body": [
                    {"from": 0, "to": 4, "content": "This is"},
                    {"from": 2, "to": 6, "content": "This is a test"},
                    {"from": 5, "to": 10, "content": "a test with an ending"},
                ]
            }
        ).encode()
        result = source.parse_captions(raw, "json", 10)
        self.assertEqual(
            [item["source_text"] for item in result],
            ["This is a test", "with an ending"],
        )
        self.assertEqual(result[0]["start"], 0)
        self.assertEqual(result[-1]["end"], 10)

    def test_rejects_hls_html_partial_and_bad_cues(self):
        invalid = [
            b"#EXTM3U\nhttps://www.youtube.com/api/timedtext?a=1",
            b"<html>Login</html>",
            b'{"body":[{"from":0,"to":1,"content":"Only the intro"}]}',
            b'{"body":[{"from":0,"to":10,"content":"https://signed.example/a"}]}',
            b'{"body":[{"from":0,"to":NaN,"content":"Invalid time"}]}',
            b'{"body":[{"from":11,"to":12,"content":"Beyond media"}]}',
            b"WEBVTT\n\n00:00.000 --> 00:10.000\nFine\n\nmalformed cue",
            b"x" * (source.MAX_BODY + 1),
        ]
        for raw in invalid:
            with (
                self.subTest(raw=raw[:50]),
                self.assertRaises((ValueError, UnicodeError)),
            ):
                source.parse_captions(
                    raw, "json" if raw.startswith(b"{") else "vtt", 10
                )

    def test_caption_limits_and_control_character_sanitization(self):
        with patch.object(source, "MAX_SEGMENTS", 1), self.assertRaises(ValueError):
            source.parse_captions(caption_blob(), "json", 10)
        with patch.object(source, "MAX_TEXT", 10), self.assertRaises(ValueError):
            source.parse_captions(caption_blob(), "json", 10)
        self.assertEqual(
            source.clean_text("<b>Hello</b>\0\u202e\nworld"), "Hello world"
        )

    def test_caption_redirects_validate_every_hop_before_fetching(self):
        for destination in [
            "http://127.0.0.1/private",
            "https://evil.invalid/",
            "file:///secret",
        ]:
            session = Session([Response(b"", 302, {"Location": destination})])
            with self.assertRaises(ValueError):
                source.fetch_caption(session, CAPTION_URL, lambda: None)
            self.assertEqual(len(session.calls), 1)
        session = Session(
            [
                Response(b"", 302, {"Location": "/api/timedtext?v=next"}),
                Response(caption_blob()),
            ]
        )
        self.assertEqual(
            source.fetch_caption(session, CAPTION_URL, lambda: None), caption_blob()
        )
        self.assertTrue(all(not call[1]["allow_redirects"] for call in session.calls))

    def test_track_preference_skips_machine_translation_and_external_hosts(self):
        info = metadata()
        info["subtitles"]["zh"] = [{"ext": "vtt", "url": CAPTION_URL + "&tlang=zh"}]
        info["automatic_captions"] = {
            "en": [{"ext": "vtt", "url": CAPTION_URL + "&kind=asr"}],
            "fr": [{"ext": "vtt", "url": "https://evil.invalid/caption"}],
        }
        tracks = source.caption_tracks(info)
        self.assertEqual(len(tracks), 2)
        self.assertEqual(tracks[0]["ext"], "json")

    def test_complete_captions_avoid_audio_and_use_read_only_settings(self):
        before = (self.data / "config.json").read_bytes()
        result, downloader, session, events, probe = self.acquire()
        self.assertEqual(result["content_source"], "subtitles")
        self.assertEqual(len(result["segments"]), 2)
        self.assertEqual(downloader.downloads, 0)
        probe.assert_not_called()
        self.assertFalse(session.trust_env)
        self.assertEqual(session.proxies, {})
        self.assertNotIn("cookiesfrombrowser", downloader.options)
        self.assertNotIn("cookiefile", downloader.options)
        self.assertEqual(
            downloader.options["js_runtimes"],
            {"node": {"path": str(self.root / "node")}},
        )
        self.assertEqual(downloader.options["remote_components"], [])
        self.assertEqual((self.data / "config.json").read_bytes(), before)
        self.assertEqual({item.name for item in self.data.iterdir()}, {"config.json"})
        self.assertEqual(
            [event["stage"] for event in events], ["reading_source", "reading_source"]
        )

    def test_pinned_bilibili_extractor_discovery_gate_and_embedded_srt(self):
        from yt_dlp import YoutubeDL
        from yt_dlp.extractor.bilibili import BiliBiliIE

        blob = "1\n00:00:00,000 --> 00:00:05,000\nFirst sentence.\n\n2\n00:00:05,000 --> 00:00:10,000\nSecond sentence.\n"
        subtitles = {"en": [{"ext": "srt", "data": blob}]}
        result, downloader, session, _, _ = self.acquire(
            info={**metadata(), "subtitles": subtitles}, responses=[]
        )
        self.assertEqual(result["content_source"], "subtitles")
        self.assertEqual(result["segments"][-1]["end"], 10)
        self.assertEqual(session.calls, [])
        self.assertEqual(downloader.downloads, 0)
        with YoutubeDL(downloader.options, auto_init=False) as real:
            extractor = BiliBiliIE(real)
            with patch.object(
                extractor, "_get_subtitles", return_value=subtitles
            ) as fetch:
                self.assertEqual(
                    extractor.extract_subtitles("fixture", "fixture"), subtitles
                )
                fetch.assert_called_once()
                real.params["listsubtitles"] = False
                self.assertEqual(extractor.extract_subtitles("fixture", "fixture"), {})
            self.assertFalse(real.params["simulate"])

    def test_caption_discovery_failure_retries_metadata_without_caption_fetch(self):
        downloader = Downloader(metadata(), self.job)
        info = {**metadata(), "subtitles": {}}
        with (
            patch.object(
                downloader,
                "extract_info",
                side_effect=[ValueError("fixture-private-failure"), info],
            ) as extraction,
            patch.object(source, "validate_audio"),
        ):
            path = source.acquire(
                self.args,
                URL,
                "youtube",
                lambda _: None,
                source.Cancellation(),
                ydl_factory=downloader,
                session_factory=lambda: Session([]),
                node=self.root / "node",
            )
        self.assertEqual(extraction.call_count, 2)
        self.assertEqual(json.loads(path.read_text())["content_source"], "audio")
        self.assertNotIn("fixture-private-failure", path.read_text())

    def test_unusable_captions_fall_back_to_best_audio_and_real_progress(self):
        result, downloader, _, events, probe = self.acquire(
            responses=[Response(b"#EXTM3U\nhttps://example.invalid/index")]
        )
        self.assertEqual(result["content_source"], "audio")
        self.assertEqual(result["segments"], [])
        self.assertEqual(result["audio_path"], str(self.job / "audio.m4a"))
        self.assertEqual(downloader.options["format"], "bestaudio")
        self.assertTrue(downloader.options["continuedl"])
        self.assertFalse(downloader.options["overwrites"])
        probe.assert_called_once()
        event = events[-1]
        self.assertEqual(event["stage"], "downloading_audio")
        self.assertEqual(event["downloaded_bytes"], 20)
        self.assertEqual(event["bytes_per_second"], 10)
        self.assertNotIn("PRIVATE-SIGNED-URL", json.dumps(events))

    def test_saved_proxy_applies_to_extraction_and_captions_without_leaking(self):
        proxy = "http://fixture-user:fixture-pass@127.0.0.1:7897"
        (self.data / "proxy.json").write_text(
            json.dumps({"version": 1, "enabled": True, "url": proxy})
        )
        before = (self.data / "proxy.json").read_bytes()
        result, downloader, session, events, _ = self.acquire()
        self.assertEqual(downloader.options["proxy"], proxy)
        self.assertEqual(session.proxies["https"], proxy)
        self.assertNotIn("fixture-pass", json.dumps([result, events]))
        self.assertEqual((self.data / "proxy.json").read_bytes(), before)

    def test_fractional_fragment_estimate_decodes_with_production_swift_byte_fields(
        self,
    ):
        _, _, _, events, _ = self.acquire(
            info={**metadata(), "subtitles": {}},
            responses=[],
            progress={
                "status": "finished",
                "downloaded_bytes": 100.9,
                "total_bytes_estimate": 1000 / 3,
                "speed": 12.5,
                "eta": 2.25,
            },
        )
        event = events[-1]
        self.assertEqual(event["downloaded_bytes"], 100)
        self.assertEqual(event["total_bytes"], 334)
        self.assertIs(type(event["downloaded_bytes"]), int)
        self.assertIs(type(event["total_bytes"]), int)
        self.assertEqual(event["bytes_per_second"], 12.5)
        self.assertEqual(event["eta_seconds"], 2.25)
        swift = self.root / "main.swift"
        swift.write_text("""import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
do {
  let event = try JSONDecoder().decode(SubtitleToolsEvent.self, from: data)
  precondition(event.downloadedBytes == 100 && event.totalBytes == 334)
  precondition(event.bytesPerSecond == 12.5 && event.etaSeconds == 2.25)
  print("Production Swift summary-source byte protocol passed")
} catch { exit(2) }
""")
        binary = self.root / "summary-byte-protocol"
        models = ROOT.parents[1] / "iina/SubtitleTools/SubtitleToolsModels.swift"
        subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-swift-version",
                "5",
                str(models),
                str(swift),
                "-o",
                str(binary),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )
        subprocess.run(
            [str(binary)],
            input=json.dumps(event),
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        malformed = {**event, "total_bytes": 1000 / 3}
        rejected = subprocess.run(
            [str(binary)],
            input=json.dumps(malformed),
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(rejected.returncode, 2)

    def test_first_use_without_chrome_or_saved_settings_extracts_anonymously(self):
        class MissingChrome(Downloader):
            def __getattribute__(self, name):
                if name == "cookiejar" and self.options.get("cookiesfrombrowser"):
                    raise RuntimeError(
                        "could not find chrome cookies database: fixture-private-profile/path"
                    )
                return super().__getattribute__(name)

        config = self.data / "config.json"
        config.unlink()
        for settings in (None, {}, {"use_chrome_cookies": False}):
            if settings is not None:
                config.write_text(json.dumps(settings))
            with (
                self.subTest(settings=settings),
                patch.object(source, "validate_audio"),
            ):
                downloader = MissingChrome(metadata(), self.job)
                with patch.object(
                    downloader, "extract_info", wraps=downloader.extract_info
                ) as extraction:
                    path = source.acquire(
                        self.args,
                        URL,
                        "youtube",
                        lambda _: None,
                        source.Cancellation(),
                        ydl_factory=downloader,
                        session_factory=lambda: Session([Response(caption_blob())]),
                        node=self.root / "node",
                    )
                extraction.assert_called_once()
                self.assertNotIn("cookiesfrombrowser", downloader.options)
                self.assertEqual(
                    json.loads(path.read_text())["content_source"], "subtitles"
                )
                self.assertEqual(config.exists(), settings is not None)

    def test_explicit_chrome_cookie_failure_is_not_a_remote_auth_error(self):
        class MissingChrome(Downloader):
            def __getattribute__(self, name):
                if name == "cookiejar":
                    raise RuntimeError(
                        "fixture-private-profile/path fixture-secret-token"
                    )
                return super().__getattribute__(name)

        (self.data / "config.json").write_text(json.dumps({"use_chrome_cookies": True}))
        downloader = MissingChrome(metadata(), self.job)
        with (
            patch.object(downloader, "extract_info") as extraction,
            self.assertRaises(source.SourceError) as caught,
        ):
            source.acquire(
                self.args,
                URL,
                "youtube",
                lambda _: None,
                source.Cancellation(),
                ydl_factory=downloader,
                session_factory=lambda: Session([]),
                node=self.root / "node",
            )
        extraction.assert_not_called()
        self.assertEqual(downloader.options["cookiesfrombrowser"], ("chrome",))
        self.assertEqual(caught.exception.code, "cookies_unavailable")
        self.assertNotIn("fixture-private-profile", str(caught.exception))
        self.assertNotIn("fixture-secret-token", str(caught.exception))

    def test_socks_proxy_resolves_destination_through_proxy(self):
        (self.data / "proxy.json").write_text(
            json.dumps(
                {"version": 1, "enabled": True, "url": "socks5://127.0.0.1:7897"}
            )
        )
        _, downloader, session, _, _ = self.acquire()
        self.assertEqual(downloader.options["proxy"], "socks5h://127.0.0.1:7897")
        self.assertEqual(session.proxies["http"], downloader.options["proxy"])

    def test_corrupt_proxy_never_silently_downloads_directly(self):
        (self.data / "proxy.json").write_text("broken")
        with self.assertRaises(source.SourceError) as caught:
            self.acquire()
        self.assertEqual(caught.exception.code, "configuration_unavailable")

    def test_rejects_playlists_live_unknown_duration_and_invalid_identity(self):
        for replacement in [
            {"_type": "playlist", "entries": []},
            {"is_live": True},
            {"live_status": "is_upcoming"},
            {"duration": math.nan},
            {"duration": source.MAX_DURATION + 1},
            {"id": "../../escape"},
        ]:
            with (
                self.subTest(replacement=replacement),
                self.assertRaises(source.SourceError),
            ):
                self.acquire(info={**metadata(), **replacement})

    def test_short_links_resolve_to_timestamp_capable_canonical_url(self):
        final = "https://www.bilibili.com/video/BV1xx411c7mD?p=2"
        for redirect in (True, False):
            with self.subTest(redirect=redirect):
                info = {**metadata(), "id": "BV1xx411c7mD", "webpage_url": final}
                downloader = Downloader(info, self.job)
                responses = (
                    [{"_type": "url", "url": final}, info] if redirect else [info]
                )
                with patch.object(downloader, "extract_info", side_effect=responses):
                    path = source.acquire(
                        self.args,
                        "https://b23.tv/abc123",
                        "bilibili",
                        lambda _: None,
                        source.Cancellation(),
                        ydl_factory=downloader,
                        session_factory=lambda: Session([Response(caption_blob())]),
                        node=self.root / "node",
                    )
                self.assertEqual(json.loads(path.read_text())["source_url"], final)
        for destination in ("https://b23.tv/abc123", URL, "https://evil.invalid"):
            downloader = Downloader(
                {**metadata(), "webpage_url": destination}, self.job
            )
            with (
                self.subTest(destination=destination),
                self.assertRaises(source.SourceError),
            ):
                source.acquire(
                    self.args,
                    "https://b23.tv/abc123",
                    "bilibili",
                    lambda _: None,
                    source.Cancellation(),
                    ydl_factory=downloader,
                    session_factory=lambda: Session([]),
                    node=self.root / "node",
                )

    def test_caption_redirect_cross_platform_metadata_never_downloads_audio(self):
        for destination in ("file:///secret", "https://b23.tv/abc123"):
            downloader = Downloader({"_type": "url", "url": destination}, self.job)
            with (
                self.subTest(destination=destination),
                self.assertRaises(source.SourceError),
            ):
                source.acquire(
                    self.args,
                    URL,
                    "youtube",
                    lambda _: None,
                    source.Cancellation(),
                    ydl_factory=downloader,
                    session_factory=lambda: Session([]),
                    node=self.root / "node",
                )
            self.assertEqual(downloader.downloads, 0)

    def test_safe_paths_reject_links_parent_roots_and_bundle_outputs(self):
        source.validate_paths(self.args)
        link = self.job / "audio.m4a"
        link.symlink_to(self.ffmpeg)
        with self.assertRaises(source.SourceError):
            source.validate_paths(self.args)
        link.unlink()
        for job in [self.data, self.root, Path.home(), Path("/")]:
            with self.subTest(job=job), self.assertRaises(source.SourceError):
                source.validate_paths(
                    SimpleNamespace(**{**vars(self.args), "download_dir": job})
                )

    def test_job_lock_binds_resume_to_one_source_and_preserves_partials(self):
        partial = self.job / "audio.m4a.part"
        partial.write_bytes(b"partial")
        with (
            source.job_lock(self.job, URL),
            self.assertRaises(source.SourceError),
            source.job_lock(self.job, URL),
        ):
            pass
        with source.job_lock(self.job, URL):
            self.assertEqual(partial.read_bytes(), b"partial")
        with (
            self.assertRaises(source.SourceError),
            source.job_lock(self.job, "https://www.youtube.com/watch?v=zyxwvutsrqp"),
        ):
            pass

    def test_cancel_and_timeout_stop_before_transport(self):
        for control in [source.Cancellation(timeout=-1), source.Cancellation()]:
            if control.deadline > 0 and control.deadline > time.monotonic():
                control.request()
            with self.assertRaises(source.SourceError):
                control.check()

    def test_ffprobe_rejects_video_mixed_media_truncation_and_invalid_output(self):
        for payload in [
            {"format": {"duration": "10"}, "streams": [{"codec_type": "video"}]},
            {"format": {"duration": "1"}, "streams": [{"codec_type": "audio"}]},
            {"format": {"duration": "NaN"}, "streams": [{"codec_type": "audio"}]},
            {
                "format": {"duration": "10", "format_name": "hls"},
                "streams": [{"codec_type": "audio"}],
            },
            {
                "format": {"duration": "10", "format_name": "concat"},
                "streams": [{"codec_type": "audio"}],
            },
        ]:
            payload["format"].setdefault("format_name", "mov,mp4,m4a,3gp,3g2,mj2")
            with (
                patch.object(
                    subprocess,
                    "run",
                    return_value=SimpleNamespace(
                        returncode=0, stdout=json.dumps(payload).encode()
                    ),
                ),
                self.assertRaises(source.SourceError),
            ):
                source.validate_audio(
                    self.job / "audio.m4a", self.ffprobe, 10, source.Cancellation()
                )
        with patch.object(
            subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=0,
                stdout=b'{"format":{"duration":"10","format_name":"mov,mp4,m4a,3gp,3g2,mj2"},"streams":[{"codec_type":"audio"}]}',
            ),
        ) as run:
            source.validate_audio(
                self.job / "audio.m4a", self.ffprobe, 10, source.Cancellation()
            )
            self.assertIn("file", run.call_args.args[0])
            self.assertIn("-format_whitelist", run.call_args.args[0])
            self.assertIn(source.AUDIO_DEMUXERS, run.call_args.args[0])

    def test_cli_rejects_bad_source_before_settings_or_job_state_and_keeps_id(self):
        (self.data / "config.json").write_text("unreadable fixture settings")
        command = [
            sys.executable,
            str(ROOT / "helper.py"),
            "--summary-source",
            "--stdio",
            "--data-dir",
            str(self.data),
            "--download-dir",
            str(self.job),
            "--ffmpeg",
            str(self.ffmpeg),
            "--ffprobe",
            str(self.ffprobe),
        ]
        with subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as child:
            child.stdin.write(
                json.dumps(
                    {
                        "id": "summary-source-smoke-0",
                        "source_url": "https://fixture-user:fixture-pass@youtube.com/watch?v=abcdefghijk",
                    }
                ).encode()
                + b"\n"
            )
            child.stdin.flush()
            self.assertTrue(select.select([child.stdout], [], [], 15)[0])
            event = json.loads(child.stdout.readline())
            self.assertEqual(event["id"], "summary-source-smoke-0")
            self.assertEqual(event["type"], "failed")
            self.assertNotIn("fixture-pass", json.dumps(event))
            self.assertNotEqual(child.wait(timeout=10), 0)
            self.assertEqual(child.stdout.read(), b"")
        self.assertEqual(list(self.job.iterdir()), [])
        self.assertFalse((self.data / "desktop.lock").exists())

    def test_cli_cancellation_owns_and_kills_children_without_raw_output_leaks(self):
        # A deliberately uncooperative mock models an extractor/native child
        # blocked outside progress hooks. No website or browser is accessed.
        script = r"""
import os, signal, subprocess, sys, time
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, sys.argv[1])
import summary_source as source
import helper
helper.prepare_environment = lambda args: None
def acquire(args, url, platform, emit, control):
    os.write(1, b"fixture-private-native-stdout\n")
    os.write(2, b"fixture-private-native-stderr\n")
    print("fixture-private-python-output", flush=True)
    child = subprocess.Popen([sys.executable, "-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)"])
    emit({"type":"progress","stage":"reading_source","child_pid":child.pid})
    if sys.argv[6] == "timeout":
        control.deadline = time.monotonic() + .2
    while True:
        time.sleep(.1)
source.acquire = acquire
args = SimpleNamespace(data_dir=Path(sys.argv[2]), download_dir=Path(sys.argv[3]), ffmpeg=Path(sys.argv[4]), ffprobe=Path(sys.argv[5]))
sys.exit(source.main(args))
"""
        for mode in ("eof", "signal", "timeout"):
            with (
                self.subTest(mode=mode),
                subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        script,
                        str(ROOT),
                        str(self.data),
                        str(self.job),
                        str(self.ffmpeg),
                        str(self.ffprobe),
                        mode,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=mode == "signal",
                ) as child,
            ):
                child.stdin.write(
                    json.dumps({"id": "cancel-fixture", "source_url": URL}).encode()
                    + b"\n"
                )
                child.stdin.flush()
                self.assertTrue(select.select([child.stdout], [], [], 15)[0])
                ready = json.loads(child.stdout.readline())
                self.assertEqual(ready["type"], "progress")
                if mode == "eof":
                    child.stdin.close()
                elif mode == "signal":
                    child.send_signal(signal.SIGTERM)
                self.assertTrue(select.select([child.stdout], [], [], 10)[0])
                failed = json.loads(child.stdout.readline())
                self.assertEqual(
                    failed["code"], "timeout" if mode == "timeout" else "cancelled"
                )
                self.assertNotEqual(child.wait(timeout=10), 0)
                self.assertEqual(child.stdout.read(), b"")
                self.assertEqual(child.stderr.read(), b"")
                status = subprocess.run(
                    ["ps", "-o", "stat=", "-p", str(ready["child_pid"])],
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.strip()
                self.assertTrue(not status or status.startswith("Z"), status)


if __name__ == "__main__":
    unittest.main()
