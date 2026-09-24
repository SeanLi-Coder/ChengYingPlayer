"""Offline Kuaishou integration tests; no user profiles or external network."""

from __future__ import annotations

import ast
import io
import json
import shutil
import subprocess
import sys
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from urllib.parse import urlsplit, urlunsplit

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader as engine
from app import kuaishou as ks
from app.errors import (
    AuthenticationRequiredError,
    DiscoveryError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import (
    DownloadJob,
    JobStatus,
    MediaType,
    Platform,
    SourceKind,
)
from app.platforms import UnsupportedUrlError, identify_url
from app.task_manager import DownloadManager
from app.xiaohongshu import RemoteAsset, _XiaohongshuRedirectRejected

VIDEO = "https://www.kuaishou.com/short-video/3xvideo1"
PROFILE = "https://www.kuaishou.com/profile/3xowner1"
MEDIA = "https://v1.kwaicdn.com/upic/video.mp4"


def feed(media_id="3xvideo1", author="3xowner1", **photo_values):
    return {
        "photo": {
            "id": media_id,
            "caption": "Fixture video",
            "duration": 5000,
            "timestamp": 1_720_000_000_000,
            "photoUrl": MEDIA,
            **photo_values,
        },
        "author": {"id": author, "name": "Fixture Author"},
    }


def apollo(value=None, media_id="3xvideo1"):
    value = value or feed(media_id)
    return {
        "ROOT_QUERY": {
            f'visionVideoDetail({{"photoId":"{media_id}","page":"profile"}})': {
                "__ref": "detail"
            }
        },
        "detail": {
            "result": 1,
            "photo": {"__ref": "photo"},
            "author": {"type": "id", "id": "author"},
        },
        "photo": value["photo"],
        "author": value["author"],
    }


@pytest.mark.parametrize(
    ("url", "kind"),
    [
        (VIDEO, "item"),
        (PROFILE, "profile"),
        ("https://v.kuaishou.com/AbCdEF", "short_link"),
        ("https://www.kuaishou.com/f/AbCdEF", "short_link"),
        ("https://m.gifshow.com/fw/photo/3xvideo1", "item"),
        ("https://m.gifshow.com/fw/user/3xowner1", "profile"),
        ("share text https://v.kuaishou.com/AbCdEF。", "short_link"),
    ],
)
def test_source_routes(url, kind):
    identified = identify_url(url)
    assert identified.platform == Platform.KUAISHOU
    assert identified.kind.value == kind


@pytest.mark.parametrize(
    "url",
    [
        "http://www.kuaishou.com/short-video/id",
        "https://www.kuaishou.com:444/short-video/id",
        "https://www.kuaishou.com.evil.test/short-video/id",
        "https://127.0.0.1/short-video/id",
        "https://user:secret@www.kuaishou.com/short-video/id",
        "https://www.kuaishou.com/short-video/../id",
        "https://www.kuaishou.com/short-video/a%2Fb",
        "https://www.kuaishou.com/profile/",
        "https://v.kuaishou.com/id/extra",
        "https://m.gifshow.com/other/id",
    ],
)
def test_reject_unsafe_source(url):
    with pytest.raises((UnsupportedUrlError, ValueError)):
        identify_url(url)


@pytest.mark.parametrize(
    "url", [MEDIA, "https://v1.kwaicdn.com:443/a", "https://v1.yximgs.com/a"]
)
def test_media_allowlist(url):
    assert ks.is_media_url(url)


@pytest.mark.parametrize(
    "url",
    [
        "http://v1.kwaicdn.com/a",
        "https://v1.kwaicdn.com.evil.test/a",
        "https://127.0.0.1/a",
        "https://v1.kwaicdn.com:80/a",
        "https://a:b@v1.kwaicdn.com/a",
        "https://v1.kwaicdn.com./a",
        "https://v1.kwaicdn.com\\@evil.test/a",
        "https://v1.kwaicdn.com/a\nheader",
    ],
)
def test_media_blocklist(url):
    assert not ks.is_media_url(url)


def test_exact_apollo_binding_and_references():
    state = apollo()
    state["ROOT_QUERY"]['visionVideoDetail({"photoId":"unrelated"})'] = feed(
        "unrelated"
    )
    values = ks.apollo_operations(state, "visionVideoDetail", "photoId", "3xvideo1")
    assert len(values) == 1
    assert ks.parse_video(values[0][1], expected_id="3xvideo1").media_id == "3xvideo1"
    assert ks.apollo_operations(state, "visionVideoDetail", "photoId", "missing") == []


def test_apollo_old_reference_layout_and_cycle():
    state = apollo()
    state['$ROOT_QUERY.visionVideoDetail({"photoId":"3xvideo1"})'] = state.pop("detail")
    state["ROOT_QUERY"] = {}
    state["author"]["parent"] = {"__ref": "author"}
    data = ks.apollo_operations(
        {"defaultClient": state}, "visionVideoDetail", "photoId", "3xvideo1"
    )[0][1]
    assert data["author"]["parent"] is None
    assert ks.parse_video(data).author_id == "3xowner1"


def test_highest_dimensions_no_silent_lower_fallback():
    manifest = {
        "adaptationSet": [
            {
                "representation": [
                    {"id": "low", "url": MEDIA + "?low", "width": 640, "height": 360},
                    {
                        "id": "high",
                        "url": MEDIA + "?high",
                        "backupUrl": [MEDIA + "?backup"],
                        "width": 1920,
                        "height": 1080,
                    },
                ]
            }
        ]
    }
    video = ks.parse_video(feed(manifest=json.dumps(manifest)))
    assert all((asset.width, asset.height) == (1920, 1080) for asset in video.assets)
    assert not any("?low" in url for asset in video.assets for url in asset.candidates)
    assert video.assets[0].candidates == [MEDIA + "?high", MEDIA + "?backup"]
    assert all(asset.duration == 5 for asset in video.assets)


def test_highest_bitrate_within_same_codec_without_cross_codec_comparison():
    representations = [
        {
            "id": "low",
            "url": MEDIA + "?low",
            "width": 1920,
            "height": 1080,
            "videoCodec": "avc",
            "avgBitrate": 1000,
        },
        {
            "id": "high",
            "url": MEDIA + "?high",
            "width": 1920,
            "height": 1080,
            "videoCodec": "avc",
            "avgBitrate": 8000,
            "fileSize": 5_000_000,
        },
        {
            "id": "hevc",
            "url": MEDIA + "?hevc",
            "width": 1920,
            "height": 1080,
            "videoCodec": "hevc",
            "avgBitrate": 3000,
        },
    ]
    video = ks.parse_video(
        feed(manifest={"adaptationSet": [{"representation": representations}]})
    )
    assert [asset.format_id for asset in video.assets] == [
        "kuaishou-high",
        "kuaishou-hevc",
    ]
    assert video.assets[0].video_codec == "h264"
    assert video.assets[0].bit_rate is None
    assert video.assets[0].size == 5_000_000


def test_unknown_codec_is_not_ranked_against_another_unknown_codec():
    low = {
        "id": "unknown-hevc",
        "url": MEDIA + "?hevc",
        "width": 1920,
        "height": 1080,
        "avgBitrate": 2000,
    }
    high = {
        "id": "unknown-avc",
        "url": MEDIA + "?avc",
        "width": 1920,
        "height": 1080,
        "avgBitrate": 8000,
    }
    video = ks.parse_video(
        feed(
            manifest={"adaptationSet": [{"representation": [high]}]},
            manifestH265={"adaptationSet": [{"representation": [low]}]},
        )
    )
    assert len(video.assets) == 2
    assert all(asset.video_codec is None for asset in video.assets)


@pytest.mark.skipif(
    not shutil.which("ffmpeg") or not shutil.which("ffprobe"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_real_video_with_high_audio_bitrate_passes_quality_verification(
    monkeypatch, tmp_path
):
    path = tmp_path / "audio-heavy.mp4"
    subprocess.run(
        [
            shutil.which("ffmpeg"),
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=160x90:r=10:d=2",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000:duration=2",
            "-c:v",
            "libx264",
            "-crf",
            "28",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-shortest",
            str(path),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    probe = json.loads(
        subprocess.run(
            [
                shutil.which("ffprobe"),
                "-v",
                "error",
                "-show_streams",
                "-of",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            timeout=10,
        ).stdout
    )
    rates = {
        stream["codec_type"]: int(stream["bit_rate"]) for stream in probe["streams"]
    }
    assert rates["audio"] > rates["video"]
    video = ks.parse_video(
        feed(
            duration=2000,
            photoUrl=None,
            manifest={
                "adaptationSet": [
                    {
                        "representation": [
                            {
                                "id": "original",
                                "url": MEDIA,
                                "width": 160,
                                "height": 90,
                                "videoCodec": "avc",
                                "fileSize": path.stat().st_size,
                                "avgBitrate": 192,
                            }
                        ]
                    }
                ]
            },
        )
    )
    asset = video.assets[0]
    assert asset.bit_rate is None and asset.size == path.stat().st_size
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    monkeypatch.setattr(
        downloader, "_find_ffprobe_executable", lambda: shutil.which("ffprobe")
    )
    verified = downloader._verify_local_video_asset(
        path, asset, should_cancel=lambda: False
    )
    assert (verified.width, verified.height) == (160, 90)


def test_video_resource_and_foreign_author_blocked():
    value = feed(
        videoResource={
            "h264": {
                "adaptationSet": [
                    {
                        "representation": [
                            {"id": "4k", "url": MEDIA, "width": 3840, "height": 2160}
                        ]
                    }
                ]
            }
        },
        photoUrl=None,
    )
    assert ks.parse_video(value).assets[0].width == 3840
    with pytest.raises(DiscoveryError, match="different author"):
        ks.parse_video(value, owner_id="someone-else")
    with pytest.raises(DiscoveryError, match="different video"):
        ks.parse_video(value, expected_id="someone-else")


def test_profile_cursor_chain_dedup_and_completion():
    collector = ks.ProfileCollector("3xowner1", PROFILE)
    assert not collector.accept(
        {"feeds": [feed("foreign")], "pcursor": "no_more"}, owner_id="other", cursor=""
    )
    assert not collector.accept(
        {"feeds": [feed("out-of-order")], "pcursor": "no_more"},
        owner_id="3xowner1",
        cursor="next",
    )
    assert collector.accept(
        {"result": 1, "feeds": [feed()], "pcursor": "next"},
        owner_id="3xowner1",
        cursor="",
    )
    assert not collector.complete
    assert not collector.accept(
        {"feeds": [feed("duplicate-page")], "pcursor": "no_more"},
        owner_id="3xowner1",
        cursor="",
    )
    assert collector.accept(
        {"result": 1, "feeds": [feed(), feed("3xvideo2")], "pcursor": "no_more"},
        owner_id="3xowner1",
        cursor="next",
    )
    assert collector.complete
    assert list(collector.videos) == ["3xvideo1", "3xvideo2"]


@pytest.mark.parametrize("cursor", [None, "", "same"])
def test_profile_without_proven_end_remains_incomplete(cursor):
    collector = ks.ProfileCollector("3xowner1", PROFILE)
    collector.accept(
        {"result": 1, "feeds": [feed()], "pcursor": cursor},
        owner_id="3xowner1",
        cursor="",
    )
    assert not collector.complete


def test_profile_foreign_owner_is_not_downloaded():
    collector = ks.ProfileCollector("3xowner1", PROFILE)
    with pytest.raises(DiscoveryError):
        collector.accept(
            {"feeds": [feed(author="foreign")], "pcursor": "no_more"},
            owner_id="3xowner1",
            cursor="",
        )
    assert not collector.videos


def test_profile_budget_and_unsupported_media_not_false_complete(monkeypatch):
    monkeypatch.setattr(ks, "MAX_PROFILE_ITEMS", 1)
    collector = ks.ProfileCollector("3xowner1", PROFILE)
    collector.accept(
        {"feeds": [feed(), feed("second")], "pcursor": "no_more"},
        owner_id="3xowner1",
        cursor="",
    )
    assert len(collector.videos) == 1 and not collector.complete
    collector = ks.ProfileCollector("3xowner1", PROFILE)
    collector.accept(
        {"feeds": [feed(photoUrl=None)], "pcursor": "no_more"},
        owner_id="3xowner1",
        cursor="",
    )
    assert not collector.complete and not collector.videos


@pytest.mark.parametrize(
    ("payload", "error_type", "issue"),
    [
        ({"result": 109}, AuthenticationRequiredError, SiteIssueCode.LOGIN_REQUIRED),
        (
            {"result": 2, "message": "captcha required"},
            AuthenticationRequiredError,
            SiteIssueCode.VERIFICATION_REQUIRED,
        ),
        ({"result": 429}, TemporaryAccessError, SiteIssueCode.RATE_LIMITED),
        (
            {"result": 2, "message": "deleted"},
            TemporaryAccessError,
            SiteIssueCode.CONTENT_UNAVAILABLE,
        ),
        ({"result": 2}, TemporaryAccessError, SiteIssueCode.REQUEST_REJECTED),
    ],
)
def test_explicit_site_errors(payload, error_type, issue):
    with pytest.raises(error_type) as error:
        ks.response_error(payload, VIDEO)
    assert error.value.issue_code == issue
    if isinstance(error.value, AuthenticationRequiredError):
        assert error.value.verification_url == VIDEO


class BrowserFixture:
    def __init__(self, *, final_url=VIDEO, state=None, responses=()):
        self.final_url = final_url
        self.state = state if state is not None else apollo()
        self.responses = list(responses)
        self.page = self
        self.main_frame = object()
        self.version = "140.0.0.0"
        self.url = VIDEO
        self.listener = None
        self.handler = None
        self.closed = False
        self.added_cookies = []
        self.launch_options = None
        self.scrolls = 0

    def launch(self, **kwargs):
        self.launch_options = kwargs
        return self

    def new_context(self, **kwargs):
        assert kwargs["service_workers"] == "block"
        return self

    def new_page(self):
        return self

    def add_cookies(self, cookies):
        self.added_cookies.extend(cookies)

    def set_default_timeout(self, value):
        pass

    def route(self, pattern, handler):
        self.handler = handler

    def on(self, event, listener):
        self.listener = listener

    def goto(self, url, **kwargs):
        request = SimpleNamespace(
            url=self.final_url,
            is_navigation_request=lambda: True,
            frame=self.main_frame,
            resource_type="document",
            method="GET",
            post_data_buffer=None,
            headers={},
        )
        response = SimpleNamespace(
            url=self.final_url, headers={}, status=200, dispose=Mock()
        )
        route = SimpleNamespace(
            request=request,
            abort=Mock(),
            continue_=Mock(),
            fetch=Mock(return_value=response),
            fulfill=Mock(),
        )
        self.handler(route)
        if route.abort.called:
            raise RuntimeError("Navigation aborted")
        self.url = self.final_url
        if self.responses:
            self.listener(self.responses.pop(0))

    def reload(self, **kwargs):
        self.goto(self.url)

    def title(self):
        return "Kuaishou fixture"

    def locator(self, selector):
        assert selector != "body"
        return SimpleNamespace(all_inner_texts=list)

    def evaluate(self, script):
        if "APOLLO_STATE" in script:
            return self.state
        self.scrolls += 1
        if self.responses:
            self.listener(self.responses.pop(0))

    def wait_for_timeout(self, value):
        pass

    def close(self):
        self.closed = True

    @contextmanager
    def playwright(self):
        yield SimpleNamespace(chromium=self)


def api_response(payload, *, owner="3xowner1", cursor="", path="/rest/v/profile/feed"):
    raw = json.dumps(payload).encode()
    return SimpleNamespace(
        url="https://www.kuaishou.com" + path,
        request=SimpleNamespace(post_data_json={"user_id": owner, "pcursor": cursor}),
        headers={"content-length": str(len(raw))},
        body=lambda: raw,
    )


def test_browser_single_item_no_user_cookies(monkeypatch):
    browser = BrowserFixture()
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ks,
        "_extract_chrome_cookies",
        Mock(side_effect=AssertionError("Must not read cookies")),
    )
    result = ks.discover(VIDEO)
    assert result.videos[0].media_id == "3xvideo1"
    assert result.complete and browser.closed
    assert browser.launch_options == {"channel": "chrome", "headless": True}


def test_browser_profile_real_pagination_observation(monkeypatch):
    responses = [
        api_response({"result": 1, "feeds": [feed()], "pcursor": "next"}),
        api_response(
            {"result": 1, "feeds": [feed(), feed("second")], "pcursor": "no_more"},
            cursor="next",
        ),
    ]
    browser = BrowserFixture(final_url=PROFILE, state={}, responses=responses)
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    messages = []
    result = ks.discover(PROFILE, status_callback=messages.append)
    assert result.complete and len(result.videos) == 2
    assert browser.scrolls >= 1 and any("2 videos" in message for message in messages)


def test_browser_profile_stall_explicit_partial(monkeypatch):
    browser = BrowserFixture(
        final_url=PROFILE,
        state={},
        responses=[api_response({"result": 1, "feeds": [feed()], "pcursor": "next"})],
    )
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    result = ks.discover(PROFILE)
    assert not result.complete and result.warning == ks.PROFILE_INCOMPLETE
    assert len(result.videos) == 1 and browser.closed


def test_unsupported_terminal_page_stops_immediately(monkeypatch):
    browser = BrowserFixture(
        final_url=PROFILE,
        state={},
        responses=[
            api_response(
                {
                    "result": 1,
                    "feeds": [feed(), feed("image", photoUrl=None)],
                    "pcursor": "no_more",
                }
            )
        ],
    )
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    result = ks.discover(PROFILE)
    assert not result.complete and result.warning
    assert browser.scrolls == 0


def test_short_item_rest_response_reobserved_after_identity_known(monkeypatch):
    raw = json.dumps({"data": {"visionVideoDetail": {"result": 1, **feed()}}}).encode()
    response = SimpleNamespace(
        url="https://www.kuaishou.com/graphql",
        headers={},
        body=lambda: raw,
        request=SimpleNamespace(
            post_data_json={
                "operationName": "visionVideoDetail",
                "variables": {"photoId": "3xvideo1"},
            }
        ),
    )
    browser = BrowserFixture(state={}, responses=[response, response])
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    result = ks.discover("https://v.kuaishou.com/share123")
    assert result.videos[0].media_id == "3xvideo1" and not browser.responses


def test_local_web_filter_has_distinct_network_error(monkeypatch):
    browser = BrowserFixture(state={})
    browser.title = lambda: "Domain Blocked"
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    with pytest.raises(TemporaryAccessError) as error:
        ks.discover(VIDEO)
    assert error.value.issue_code == SiteIssueCode.NETWORK_ERROR
    assert "verification is not required" in str(error.value)


def test_short_redirect_resolves_item(monkeypatch):
    browser = BrowserFixture()
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    result = ks.discover("https://v.kuaishou.com/share123")
    assert result.source_kind == "item" and result.source_id == "3xvideo1"


def test_redirect_to_private_or_other_site_aborts_before_navigation(monkeypatch):
    browser = BrowserFixture(final_url="http://127.0.0.1/private")
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    with pytest.raises(DiscoveryError, match="outside trusted"):
        ks.discover("https://v.kuaishou.com/share123")
    assert browser.closed


def test_direct_video_redirect_to_another_identity_blocked(monkeypatch):
    browser = BrowserFixture(final_url="https://www.kuaishou.com/short-video/foreign")
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    with pytest.raises(DiscoveryError, match="different video"):
        ks.discover(VIDEO)


def test_cancel_before_cookie_or_browser_access(monkeypatch):
    monkeypatch.setattr(
        ks, "_browser_cookies", Mock(side_effect=AssertionError("No cookie read"))
    )
    monkeypatch.setattr(
        ks, "sync_playwright", Mock(side_effect=AssertionError("No launch"))
    )
    with pytest.raises(DownloadCancelledError):
        ks.discover(VIDEO, use_browser_cookies=True, should_cancel=lambda: True)


def test_cancel_during_profile_closes_browser(monkeypatch):
    browser = BrowserFixture(final_url=PROFILE, state={})
    monkeypatch.setattr(ks, "sync_playwright", browser.playwright)
    with pytest.raises(DownloadCancelledError):
        ks.discover(PROFILE, should_cancel=lambda: browser.scrolls > 0)
    assert browser.closed


def test_cookie_read_error_never_falls_back_to_anonymous(monkeypatch):
    monkeypatch.setattr(
        ks,
        "_extract_chrome_cookies",
        Mock(side_effect=RuntimeError("fixture unavailable")),
    )
    monkeypatch.setattr(
        ks, "sync_playwright", Mock(side_effect=AssertionError("No anonymous launch"))
    )
    with pytest.raises(TemporaryAccessError) as error:
        ks.discover(VIDEO, use_browser_cookies=True)
    assert error.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE


def test_engine_discovery_persists_only_identity_not_expiring_urls(monkeypatch):
    result = ks.Result(
        [ks.parse_video(feed())], "profile", "3xowner1", False, ks.PROFILE_INCOMPLETE
    )
    monkeypatch.setattr(engine, "discover_kuaishou", lambda *args, **kwargs: result)
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    first = downloader.discover(PROFILE, Platform.KUAISHOU, SourceKind.PROFILE)
    second = downloader.discover(PROFILE, Platform.KUAISHOU, SourceKind.PROFILE)
    assert first.items[0].id == second.items[0].id
    assert first.items[0].metadata["kuaishou_author_id"] == "3xowner1"
    assert MEDIA not in first.items[0].model_dump_json()
    assert not first.discovery_complete and first.warning


def discovered_item(monkeypatch):
    result = ks.Result([ks.parse_video(feed())], "item", "3xvideo1")
    monkeypatch.setattr(engine, "discover_kuaishou", lambda *args, **kwargs: result)
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    item = downloader.discover(VIDEO, Platform.KUAISHOU, SourceKind.ITEM).items[0]
    return downloader, item


def test_download_refreshes_links_and_reuses_ffprobe_pipeline(monkeypatch, tmp_path):
    downloader, item = discovered_item(monkeypatch)
    refreshed = ks.Result(
        [ks.parse_video(feed(photoUrl=MEDIA + "?fresh"))], "item", "3xvideo1"
    )
    refresh = Mock(return_value=refreshed)
    monkeypatch.setattr(engine, "discover_kuaishou", refresh)
    captured = {}

    def transfer(ydl, assets, *args, **kwargs):
        captured.update(kwargs)
        assert assets[0].candidates == [MEDIA + "?fresh"]
        return tmp_path / "result.mp4", RemoteAsset([MEDIA], 1, width=1920, height=1080)

    monkeypatch.setattr(downloader, "_download_first_available_asset", transfer)
    outcome = downloader.download_item(item, Platform.KUAISHOU, tmp_path)
    assert refresh.call_count == 1
    assert captured["verify_declared_dimensions"] is True
    assert captured["platform"] == Platform.KUAISHOU
    assert outcome.resolution == "1920x1080"


def test_download_changed_author_blocked(monkeypatch, tmp_path):
    downloader, item = discovered_item(monkeypatch)
    monkeypatch.setattr(
        engine,
        "discover_kuaishou",
        lambda *args, **kwargs: ks.Result(
            [ks.parse_video(feed(author="foreign"))], "item", "3xvideo1"
        ),
    )
    with pytest.raises(MediaDownloadError, match="author identity"):
        downloader.download_item(item, Platform.KUAISHOU, tmp_path)
    assert not list(tmp_path.iterdir())


def test_media_transfer_uses_guarded_redirect_not_unchecked_urlopen(
    monkeypatch, tmp_path
):
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    calls = []

    def guarded(ydl, request, *, is_trusted_url):
        assert is_trusted_url(MEDIA)
        assert not is_trusted_url("https://127.0.0.1/private")
        calls.append(request.url)
        raise _XiaohongshuRedirectRejected("untrusted-url")

    monkeypatch.setattr(engine, "_open_xiaohongshu_response", guarded)
    ydl = SimpleNamespace(
        urlopen=Mock(side_effect=AssertionError("Unchecked transfer"))
    )
    with pytest.raises(MediaDownloadError, match="redirect was blocked"):
        downloader._download_first_available_asset(
            ydl,
            [RemoteAsset([MEDIA], 1)],
            tmp_path,
            None,
            "Fixture",
            "3xvideo1",
            VIDEO,
            platform=Platform.KUAISHOU,
            media_type=MediaType.VIDEO,
            callback=None,
            should_cancel=lambda: False,
            verify_declared_dimensions=True,
        )
    assert calls == [MEDIA]
    assert not list(tmp_path.iterdir())


def test_media_transfer_cancel_preserves_no_partial_file(monkeypatch, tmp_path):
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    response = io.BytesIO(b"\0\0\0\x18ftypmp42" + b"\0" * 100)
    response.headers = {"Content-Type": "video/mp4"}
    response.url = MEDIA
    monkeypatch.setattr(
        engine, "_open_xiaohongshu_response", lambda *args, **kwargs: response
    )
    cancelled = False

    def callback(event):
        nonlocal cancelled
        if event.event == "downloading":
            cancelled = True

    with pytest.raises(DownloadCancelledError):
        downloader._download_first_available_asset(
            SimpleNamespace(),
            [RemoteAsset([MEDIA], 1)],
            tmp_path,
            None,
            "Fixture",
            "3xvideo1",
            VIDEO,
            platform=Platform.KUAISHOU,
            media_type=MediaType.VIDEO,
            callback=callback,
            should_cancel=lambda: cancelled,
            verify_declared_dimensions=True,
        )
    assert response.closed and not list(tmp_path.iterdir())


def test_kuaishou_output_path_uses_date_title_and_collision_id(tmp_path):
    downloader = engine.MediaDownloader(engine.DownloaderConfig(cookie_browser=None))
    first = downloader._xhs_output_path(
        tmp_path,
        "2026-09-19",
        "#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠",
        "3xvideo1",
        "mp4",
        None,
        Platform.KUAISHOU,
    )
    assert first.name == "2026-09-19-#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠.mp4"
    first.write_bytes(b"existing")
    second = downloader._xhs_output_path(
        tmp_path,
        "2026-09-19",
        "#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠",
        "3xvideo1",
        "mp4",
        None,
        Platform.KUAISHOU,
    )
    assert second.name == "2026-09-19-#平底鞋给不了高跟鞋的优雅 #家纺人聊睡眠 [3xvideo1].mp4"


def test_kuaishou_output_directory_is_separate(tmp_path):
    assert Path(tmp_path, "Kuaishou", "Fixture Author") != Path(tmp_path, "Fixture Author")


def test_incomplete_short_profile_retries_discovery():
    job = DownloadJob(
        id="fixture",
        source_url="https://v.kuaishou.com/share123",
        platform=Platform.KUAISHOU,
        source_kind=SourceKind.SHORT_LINK,
        output_root="/tmp",
        status=JobStatus.PARTIAL,
        discovery_complete=False,
    )
    assert DownloadManager._should_rediscover_on_retry(job)


def test_public_status_strips_share_tokens_without_importing_user_state():
    source = (ROOT / "vendor/rednote/app/main.py").read_text()
    tree = ast.parse(source)
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "_redact_public_url"
    )
    module = ast.Module(body=[function], type_ignores=[])
    namespace = {"urlsplit": urlsplit, "urlunsplit": urlunsplit}
    # Compile only this trusted repository function, without importing main's user state.
    exec(compile(module, "redaction-test", "exec"), namespace)  # noqa: S102
    assert (
        namespace["_redact_public_url"](VIDEO + "?shareToken=private&authorId=owner")
        == VIDEO
    )


@pytest.mark.skipif(
    not Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").is_file(),
    reason="The optional local Chrome runtime is not installed",
)
def test_checked_route_real_chrome_blocks_redirect_before_target_request():
    from playwright.sync_api import sync_playwright

    received = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            received.append(self.path)
            if self.path in {"/start", "/safe-start", "/defer-start"}:
                self.send_response(302)
                self.send_header(
                    "Location",
                    {
                        "/start": "/blocked",
                        "/safe-start": "/allowed",
                        "/defer-start": "/allowed/landing",
                    }[self.path],
                )
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                body = b"<!doctype html><title>Fixture</title>Allowed"
                if self.path == "/allowed/landing":
                    body += b"<script>window.executed=true;fetch('relative-api').then(()=>window.relativeDone=true)</script>"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    errors, resolved = [], []
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                channel="chrome", headless=True, args=["--no-proxy-server"]
            )
            try:
                context = browser.new_context(service_workers="block")
                page = context.new_page()

                def handler(route):
                    try:
                        final = ks.fulfill_checked_route(
                            route,
                            allowed=lambda value: (
                                value.startswith(base + "/")
                                and urlsplit(value).path != "/blocked"
                            ),
                            should_cancel=lambda: False,
                            defer_navigation_redirects=route.request.url.endswith(
                                "/defer-start"
                            ),
                        )
                        resolved.append(final)
                    except DiscoveryError as error:
                        errors.append(error)
                        route.abort()

                context.route("**/*", handler)
                page.goto(
                    base + "/safe-start", wait_until="domcontentloaded", timeout=5000
                )
                assert page.title() == "Fixture"
                assert resolved[-1] == base + "/allowed"
                assert "/allowed" in received
                page.goto(
                    base + "/defer-start", wait_until="domcontentloaded", timeout=5000
                )
                assert page.title() == "Loading"
                assert page.evaluate("() => window.executed === true") is False
                assert (
                    "/relative-api" not in received
                    and "/allowed/relative-api" not in received
                )
                page.goto(resolved[-1], wait_until="domcontentloaded", timeout=5000)
                page.wait_for_function("window.relativeDone === true", timeout=5000)
                assert "/allowed/relative-api" in received
                assert "/relative-api" not in received
                with pytest.raises(Exception, match="net::ERR_FAILED"):
                    page.goto(base + "/start", timeout=5000)
                assert errors and "/blocked" not in received
            finally:
                browser.close()
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


@pytest.mark.skipif(
    not Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").is_file(),
    reason="The optional local Chrome runtime is not installed",
)
def test_checked_route_real_chrome_uses_native_proxy_without_direct_fallback():
    import proxy_transport
    from playwright.sync_api import sync_playwright

    received = []

    class Proxy(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            received.append(self.path)
            body = b"<!doctype html><title>Proxy fixture</title>"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_CONNECT(self):
            received.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            request_line = self.rfile.readline(8192)
            assert request_line.startswith(b"GET /fixture ")
            while self.rfile.readline(8192).strip():
                pass
            body = b"<!doctype html><title>Proxy fixture</title>"
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
            self.wfile.flush()
            self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    cleanup = proxy_transport.install_proxy_transports(
        lambda: f"http://127.0.0.1:{server.server_port}"
    )
    target = "http://127.0.0.1:1/fixture"
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(channel="chrome", headless=True)
            try:
                context = browser.new_context(service_workers="block")
                context.route(
                    "**/*",
                    lambda route: ks.fulfill_checked_route(
                        route,
                        allowed=lambda value: value.startswith("http://127.0.0.1:1/"),
                        should_cancel=lambda: False,
                    ),
                )
                page = context.new_page()
                page.goto(target, wait_until="domcontentloaded", timeout=5000)
                assert page.title() == "Proxy fixture"
                assert target in received or "127.0.0.1:1" in received
            finally:
                browser.close()
    finally:
        cleanup()
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()
