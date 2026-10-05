"""Offline Instagram integration tests; no user profiles or external network."""

from __future__ import annotations

import hashlib
import importlib
import json
import shutil
import subprocess
import sys
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from unittest.mock import Mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import browser as chrome_browser
from app import downloader as engine
from app import instagram as ig
from app.downloader import DownloadItem
from app.errors import (
    AuthenticationRequiredError,
    DiscoveryError,
    MediaDownloadError,
    TemporaryAccessError,
)
from app.models import (
    DownloadJob,
    ItemStatus,
    JobStatus,
    MediaType,
    Platform,
    SourceKind,
)
from app.platforms import UnsupportedUrlError, identify_url
from app.task_manager import DownloadManager
from app.xiaohongshu import RemoteAsset

PROFILE = "https://www.instagram.com/yiluntan_news/"
USERNAME = "yiluntan_news"
AUTHOR_ID = "17841000000000000"
MEDIA = "https://scontent.cdninstagram.com/v/t51/image.jpg"
POST = "https://www.instagram.com/p/Cq1shortcode/"

# A real profile timeline response nests the author's works under one fixed
# connection key. Any other connection belongs to another surface.
TIMELINE_KEY = ig.TIMELINE_CONNECTION_KEY


def image_node(code, *, username=USERNAME, author_id=AUTHOR_ID, width=1080, height=1350):
    return {
        "code": code,
        "media_type": ig.MEDIA_TYPE_IMAGE,
        "original_width": width,
        "original_height": height,
        "taken_at": 1_720_000_000,
        "accessibility_caption": f"Fixture image {code}",
        "user": {"pk": author_id, "username": username},
        "image_versions2": {
            "candidates": [
                {"url": MEDIA, "width": width, "height": height},
                # A smaller rendition must never win over the declared size.
                {"url": MEDIA + "?small=1", "width": 640, "height": 800},
            ]
        },
    }


def video_node(code, *, username=USERNAME, author_id=AUTHOR_ID, clips=False):
    return {
        "code": code,
        "media_type": ig.MEDIA_TYPE_VIDEO,
        "original_width": 1080,
        "original_height": 1920,
        "taken_at": 1_720_000_000,
        "accessibility_caption": f"Fixture video {code}",
        "product_type": "clips" if clips else "feed",
        "user": {"pk": author_id, "username": username},
        # An in-page rendition is deliberately ignored: the media pipeline
        # resolves a higher verified rendition for the same post.
        "video_versions": [{"url": MEDIA + "?inline=1", "width": 720, "height": 1280}],
    }


def carousel_node(code, children, *, username=USERNAME, author_id=AUTHOR_ID):
    return {
        "code": code,
        "media_type": ig.MEDIA_TYPE_CAROUSEL,
        "taken_at": 1_720_000_000,
        "accessibility_caption": f"Fixture carousel {code}",
        "user": {"pk": author_id, "username": username},
        "carousel_media": children,
    }


def timeline_response(nodes, *, has_next_page=False, end_cursor=""):
    return {
        "data": {
            "user": {
                TIMELINE_KEY: {
                    "edges": [{"node": node} for node in nodes],
                    "page_info": {
                        "has_next_page": has_next_page,
                        "end_cursor": end_cursor,
                    },
                }
            }
        }
    }


def profile_content_response(media_count, *, author_id=AUTHOR_ID):
    return {"data": {"user": {"pk": author_id, "media_count": media_count}}}


class InstagramResponse:
    """One observed GraphQL POST response, as the page's own script produces it."""

    def __init__(self, payload, *, operation, username=USERNAME, cursor="", path="/graphql/query"):
        self._raw = json.dumps(payload).encode()
        self._operation = operation
        self._username = username
        self._cursor = cursor
        self.url = "https://www.instagram.com" + path

    @property
    def request(self):
        return SimpleNamespace(
            method="POST",
            post_data=(
                "fb_api_req_friendly_name=" + self._operation
                + "&variables=" + json.dumps({"username": self._username, "after": self._cursor})
            ),
        )

    @property
    def headers(self):
        return {"content-length": str(len(self._raw))}

    def body(self):
        return self._raw


class InstagramBrowserFixture:
    """Serve a profile timeline through the adapter's own observation hooks.

    Requests are allowed natively, exactly as the adapter now does, so this
    fixture exercises the real trusted-host and navigation-identity gates rather
    than bypassing them: the route handler runs first, then every request the
    page issues is re-checked, and the committed main-frame URL is tracked.
    No socket is opened.
    """

    def __init__(self, *, final_url=PROFILE, responses=(), title="Instagram fixture"):
        self.final_url = final_url
        self.responses = list(responses)
        self.page = self
        self.main_frame = SimpleNamespace(url=PROFILE)
        self.version = "140.0.0.0"
        self.url = PROFILE
        self.listeners = {}
        self.handler = None
        self.closed = False
        self.added_cookies = []
        self.launch_options = None
        self.scrolls = 0
        self.aborted_requests = []
        self.continued_requests = []
        self._title = title

    @property
    def listener(self):
        """The response listener, kept under its old name for subclasses."""
        return self.listeners.get("response")

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
        self.listeners[event] = listener

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
        route = SimpleNamespace(
            request=request,
            abort=Mock(),
            continue_=Mock(),
        )
        self.handler(route)
        if route.abort.called:
            self.aborted_requests.append(request.url)
            raise RuntimeError("Navigation aborted")
        if route.continue_.called:
            self.continued_requests.append(request.url)
        # A native continue lets Chromium follow the navigation itself, so the
        # request and committed-URL events arrive after the handler ran.
        if "request" in self.listeners:
            self.listeners["request"](request)
        self.url = self.final_url
        self.main_frame.url = self.final_url
        if "framenavigated" in self.listeners:
            self.listeners["framenavigated"](self.main_frame)
        self._emit_pending()

    def _emit_pending(self):
        listener = self.listeners.get("response")
        while self.responses and listener:
            listener(self.responses.pop(0))

    def title(self):
        return self._title

    def locator(self, selector):
        assert selector != "body"
        return SimpleNamespace(all_inner_texts=list)

    def evaluate(self, script):
        self.scrolls += 1
        self._emit_pending()

    def wait_for_timeout(self, value):
        pass

    def close(self):
        self.closed = True

    def playwright(self):
        import contextlib

        @contextlib.contextmanager
        def _enter():
            yield SimpleNamespace(chromium=self)

        return _enter()


class StubYoutubeDL:
    """Honour the ``with YoutubeDL(...) as ydl`` contract the engine uses.

    ``SimpleNamespace`` cannot stand in here: Python resolves dunder methods on
    the type, so instance attributes never make an object a context manager.
    """

    def __init__(self, options=None):
        self.options = options

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False


def downloader(**kwargs):
    kwargs.setdefault("cookie_browser", None)
    return engine.MediaDownloader(engine.DownloaderConfig(**kwargs))


@pytest.fixture()
def redact_public_url(monkeypatch, tmp_path):
    """Import ``app.main`` with its writable paths redirected into a temp dir.

    ``app.main`` builds its configuration and job store at import time, which
    creates ``data/`` and ``downloads/`` under the engine directory. Importing it
    at module scope would therefore litter the real vendored source tree during
    collection, and tests that copy the tree to prove it stays clean would then
    copy that litter. The host contract in ``UPSTREAM.md`` requires both writable
    paths to be set to absolute user-owned directories before the import; this
    honours it without touching the process-wide environment, which the native
    configuration tests pass on to a child helper.
    """
    monkeypatch.setenv("CHENGYING_DOWNLOAD_DATA_DIR", str(tmp_path / "engine-data"))
    monkeypatch.setenv("CHENGYING_DOWNLOAD_DEFAULT_DIR", str(tmp_path / "engine-downloads"))
    module = importlib.import_module("app.main")
    try:
        yield module._redact_public_url
    finally:
        module.manager.shutdown(wait=True, cancel_running=True)
        sys.modules.pop("app.main", None)


def instagram_item(shortcode, *, part_kind="image", position=1, count=1,
                   profile_url=PROFILE, author_id=AUTHOR_ID, **kwargs):
    return DownloadItem(
        id=shortcode,
        media_id=shortcode,
        source_url=f"https://www.instagram.com/p/{shortcode}/",
        title="Fixture Instagram post",
        author=USERNAME,
        media_type=MediaType.IMAGE if part_kind == "image" else MediaType.VIDEO,
        metadata={
            "instagram_author_id": author_id,
            "instagram_source_kind": "profile",
            "instagram_source_id": USERNAME,
            "instagram_part_kind": part_kind,
            "instagram_part_position": position,
            "instagram_part_count": count,
            "instagram_profile_url": profile_url,
            "instagram_work_kind": "image" if count == 1 else "carousel",
        },
        **kwargs,
    )


# ---------------------------------------------------------------------------
# URL recognition
# ---------------------------------------------------------------------------


def test_profile_url_is_recognized_and_normalized():
    info = identify_url("https://www.instagram.com/yiluntan_news")
    assert info.platform is Platform.INSTAGRAM
    assert info.kind is SourceKind.PROFILE
    assert info.url == PROFILE


def test_post_url_keeps_its_path_and_drops_share_tracking():
    """A pasted share token identifies nothing, so it must never be persisted."""
    info = identify_url("https://www.instagram.com/p/Cq1shortcode/?igsh=abc123def#top")
    assert info.kind is SourceKind.ITEM
    assert info.url == POST
    assert "igsh" not in info.url


@pytest.mark.parametrize("path", ["reels", "tv", "reel"])
def test_post_path_variants_are_recognized(path):
    info = identify_url(f"https://www.instagram.com/{path}/Cq1shortcode/")
    assert info.platform is Platform.INSTAGRAM
    assert info.kind is SourceKind.ITEM


@pytest.mark.parametrize(
    "url",
    [
        "https://www.instagram.com/explore/",
        "https://www.instagram.com/explore/tags/food/",
        "https://www.instagram.com/stories/someone/123/",
        "https://www.instagram.com/share/abc",
        "https://www.instagram.com/accounts/login/",
        "https://www.instagram.com/p/short/audio/123/",
        "https://www.instagram.com/",
        "https://www.instagram.com/user/reel/123/",
        "http://www.instagram.com/yiluntan_news/",
        "https://user:pass@www.instagram.com/yiluntan_news/",
    ],
)
def test_unsupported_instagram_urls_are_rejected(url):
    """A recommendation, search or account surface is never a downloadable author."""
    with pytest.raises(UnsupportedUrlError):
        identify_url(url)


def test_unsupported_url_message_names_instagram():
    with pytest.raises(UnsupportedUrlError) as excinfo:
        identify_url("https://example.com/video/1")
    assert "Instagram" in str(excinfo.value)


# ---------------------------------------------------------------------------
# Adapter parsing
# ---------------------------------------------------------------------------


def test_image_node_keeps_the_declared_size_rendition():
    work = ig.parse_work(image_node("Cq1image"), expected_username=USERNAME)
    assert work.kind == "image"
    part = work.parts[0]
    assert part.kind == "image" and part.position == 1
    assert part.width == 1080 and part.height == 1350
    assert part.assets[0].candidates[0] == MEDIA
    assert part.url == "https://www.instagram.com/p/Cq1image/"


def test_video_node_ignores_the_lower_in_page_rendition():
    """Pinning the in-page 720p address would silently downgrade quality."""
    work = ig.parse_work(video_node("Cq1video"), expected_username=USERNAME)
    part = work.parts[0]
    assert part.kind == "video"
    assert part.assets == []
    assert "?inline=1" not in part.url


def test_clips_video_uses_the_reels_address():
    part = ig.parse_work(video_node("Cq1reel", clips=True), expected_username=USERNAME).parts[0]
    assert part.url == "https://www.instagram.com/reels/Cq1reel/"


def test_carousel_expands_every_member_with_its_own_shortcode():
    node = carousel_node("Cq1carousel", [image_node("Cq1child1"), video_node("Cq1child2")])
    work = ig.parse_work(node, expected_username=USERNAME)
    assert work.kind == "carousel"
    assert [part.kind for part in work.parts] == ["image", "video"]
    assert [part.media_id for part in work.parts] == ["Cq1child1", "Cq1child2"]
    assert [part.position for part in work.parts] == [1, 2]


def test_image_without_verifiable_dimensions_is_not_substituted():
    """A cover or thumbnail must never stand in for the work's own rendition."""
    node = image_node("Cq1nodim")
    node["image_versions2"] = {"candidates": [{"url": MEDIA}]}
    assert ig.parse_work(node, expected_username=USERNAME) is None


def test_another_authors_post_is_never_queued_under_this_profile():
    foreign = image_node("Cq1foreign", username="someoneelse", author_id="999")
    collector = ig.ProfileCollector(USERNAME, PROFILE)
    collector.accept_profile_content(profile_content_response(1))
    assert collector.accept(timeline_response([foreign])) is False
    assert collector.works == {}
    summary = ig.problem_summary(collector)
    # The summary carries a fixed label, never free-form site text.
    assert ig.PROBLEM_LABELS[ig.PROBLEM_FOREIGN_AUTHOR] in summary
    # The reason code is fixed; no caption or account detail is echoed.
    assert "someoneelse" not in summary


def test_a_different_surface_connection_is_ignored():
    """A home-feed or reels-tab response must not be attributed to this author."""
    payload = {
        "data": {
            "user": {
                "other_timeline_connection": {
                    "edges": [{"node": image_node("Cq1feed")}],
                    "page_info": {"has_next_page": False},
                }
            }
        }
    }
    collector = ig.ProfileCollector(USERNAME, PROFILE)
    assert collector.accept(payload) is False
    assert collector.works == {}


def test_timeline_response_from_another_username_is_ignored(monkeypatch):
    """Only the request's own username proves whose feed a response belongs to.

    The served node still carries this account's author, so a collector alone
    would accept it. The observer has to drop the page first, which leaves
    nothing verified instead of queuing another author's post.
    """
    response = InstagramResponse(
        timeline_response([image_node("Cq1other")]),
        operation=next(iter(ig.TIMELINE_OPERATIONS)),
        username="another_account",
    )
    assert ig.requested_username(response.request.post_data) == "another_account"
    assert ig.timeline_nodes(json.loads(response.body().decode()))[0]

    browser = InstagramBrowserFixture(responses=[response])
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    with pytest.raises(DiscoveryError, match="no verified posts"):
        ig.discover(PROFILE)
    assert browser.closed


def test_completion_requires_the_site_confirmed_end_of_list():
    """Only has_next_page false proves enumeration finished."""
    collector = ig.ProfileCollector(USERNAME, PROFILE)
    collector.accept(timeline_response([image_node("Cq1a")], has_next_page=True))
    collector.finalize()
    assert collector.complete is False
    collector.accept(
        timeline_response([image_node("Cq1b")], has_next_page=False), cursor="next"
    )
    collector.finalize()
    assert collector.complete is True


def test_repeated_cursor_does_not_loop_or_duplicate_works():
    collector = ig.ProfileCollector(USERNAME, PROFILE)
    page = timeline_response([image_node("Cq1a")], has_next_page=True)
    assert collector.accept(page, cursor="c1") is True
    assert collector.accept(page, cursor="c1") is False
    assert len(collector.works) == 1


def test_declared_total_gap_is_reported_rather_than_passed_over():
    collector = ig.ProfileCollector(USERNAME, PROFILE)
    collector.accept_profile_content(profile_content_response(3))
    collector.accept(timeline_response([image_node("Cq1a")], has_next_page=False))
    collector.finalize()
    assert collector.complete is True
    warning = ig._completion_warning(collector, False, None)
    assert "2 of the 3 declared posts were not served" in warning


def test_login_required_when_a_session_cookie_is_missing():
    """A private profile renders nothing anonymously; that is not an empty profile."""
    assert ig.has_login_cookie([{"name": "csrftoken"}]) is False
    assert ig.has_login_cookie([{"name": "sessionid", "value": "x"}]) is True


def test_describe_item_failure_maps_categories_without_echoing_site_text():
    assert isinstance(
        ig.describe_item_failure("This video is not available, please log in"),
        AuthenticationRequiredError,
    )
    image_error = ig.describe_item_failure("ERROR: unable to extract video: no video formats")
    assert isinstance(image_error, DiscoveryError)
    # An image or carousel post has no video rendition; that is an access-shape
    # fact, and the user is pointed at the author's profile, which does carry the
    # declared-size renditions a single post page does not expose.
    assert "profile" in str(image_error).lower()
    generic = ig.describe_item_failure("something unrelated happened")
    assert isinstance(generic, DiscoveryError)
    assert "something unrelated" not in str(generic)


def test_response_error_never_echoes_the_site_message():
    with pytest.raises(AuthenticationRequiredError):
        ig.response_error({"message": "Login required for @private_user"}, PROFILE)
    with pytest.raises(DiscoveryError):
        ig.response_error({"message": "This account is private"}, PROFILE)
    with pytest.raises(TemporaryAccessError) as rate:
        ig.response_error({"message": "Please wait a few minutes (rate limit)"}, PROFILE)
    assert rate.value.issue_code.value == "rate_limited"
    assert "private_user" not in str(rate.value)


# ---------------------------------------------------------------------------
# Profile discovery through the adapter's real observation hooks
# ---------------------------------------------------------------------------


def test_profile_discovery_observations(monkeypatch):
    browser = InstagramBrowserFixture(
        responses=[
            InstagramResponse(
                profile_content_response(3), operation=ig.PROFILE_CONTENT_OPERATION
            ),
            InstagramResponse(
                timeline_response(
                    [image_node("Cq1a"), video_node("Cq1b", clips=True)],
                    has_next_page=True,
                ),
                operation="PolarisProfilePostsQuery",
            ),
            InstagramResponse(
                timeline_response([carousel_node(
                    "Cq1carousel", [image_node("Cq1c1"), image_node("Cq1c2")]
                )], has_next_page=False),
                operation="PolarisProfilePostsTabContentQuery_connection",
                cursor="cursor-2",
            ),
        ]
    )
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    messages = []
    result = ig.discover(PROFILE, status_callback=messages.append)

    assert result.source_kind == "profile" and result.source_id == USERNAME
    assert result.complete is True and result.declared_count == 3
    assert browser.closed and browser.launch_options == {"channel": "chrome", "headless": True}
    # Four downloadable parts from three posts: the carousel expands.
    assert [work.media_id for work in result.works] == ["Cq1a", "Cq1b", "Cq1carousel"]
    assert sum(len(work.parts) for work in result.works) == 4
    assert any("verified 3 posts" in message for message in messages)


def test_profile_discovery_requires_login_when_cookies_are_enabled(monkeypatch):
    """Enabling Chrome Cookie without a session must say so, not return nothing."""
    monkeypatch.setattr(ig, "_browser_cookies", lambda profile: [{"name": "csrftoken"}])
    with pytest.raises(AuthenticationRequiredError) as excinfo:
        ig.discover(PROFILE, use_browser_cookies=True)
    assert "login" in str(excinfo.value).lower()


def test_profile_discovery_rejects_a_non_profile_source(monkeypatch):
    monkeypatch.setattr(ig, "sync_playwright", InstagramBrowserFixture().playwright)
    with pytest.raises(DiscoveryError, match="media pipeline"):
        ig.discover(POST)


def test_interruption_keeps_verified_works_and_reports_the_reason(monkeypatch):
    """A rate limit must not discard posts that were already verified."""
    monkeypatch.setattr(ig, "PROFILE_RETRY_BASE_SECONDS", 0.0)
    monkeypatch.setattr(ig, "PROFILE_RETRY_ATTEMPTS", 1)

    class InterruptedFixture(InstagramBrowserFixture):
        def _emit_pending(self):
            super()._emit_pending()
            if not self.responses and self.listener and not getattr(self, "_raised", False):
                self._raised = True
                self.listener(SimpleNamespace(
                    url="https://www.instagram.com/graphql/query",
                    request=SimpleNamespace(
                        method="POST",
                        post_data=(
                            "fb_api_req_friendly_name=PolarisProfilePostsQuery&variables="
                            + json.dumps({"username": USERNAME, "after": "c9"})
                        ),
                    ),
                    headers={"content-length": "9"},
                    body=lambda: json.dumps({
                        "message": "Please wait a few minutes before you try again",
                        "status": "fail",
                    }).encode(),
                ))

    browser = InterruptedFixture(responses=[
        InstagramResponse(
            timeline_response([image_node("Cq1keep")], has_next_page=True),
            operation="PolarisProfilePostsQuery",
        ),
    ])
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    result = ig.discover(PROFILE)
    assert result.complete is False
    assert [work.media_id for work in result.works] == ["Cq1keep"]
    assert result.warning.startswith(ig.PROFILE_INTERRUPTED)
    assert "Reason category: rate_limited." in result.warning


def test_interruption_before_any_work_is_a_real_failure_not_an_empty_profile(monkeypatch):
    monkeypatch.setattr(ig, "PROFILE_RETRY_BASE_SECONDS", 0.0)
    monkeypatch.setattr(ig, "PROFILE_RETRY_ATTEMPTS", 1)

    class OnlyInterrupted(InstagramBrowserFixture):
        def _emit_pending(self):
            if not getattr(self, "_raised", False):
                self._raised = True
                self.listener(SimpleNamespace(
                    url="https://www.instagram.com/graphql/query",
                    request=SimpleNamespace(
                        method="POST",
                        post_data=(
                            "fb_api_req_friendly_name=PolarisProfilePostsQuery&variables="
                            + json.dumps({"username": USERNAME, "after": ""})
                        ),
                    ),
                    headers={"content-length": "9"},
                    body=lambda: json.dumps({
                        "message": "Please wait a few minutes (rate limit)",
                        "status": "fail",
                    }).encode(),
                ))

    monkeypatch.setattr(ig, "sync_playwright", OnlyInterrupted().playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    with pytest.raises(TemporaryAccessError) as excinfo:
        ig.discover(PROFILE)
    assert "before any post could be verified" in str(excinfo.value)
    assert excinfo.value.issue_code.value == "rate_limited"


def test_cookie_read_failure_reports_a_fixed_diagnostic_category(monkeypatch, tmp_path):
    """The underlying exception text can carry a profile path, so only a code leaves.

    The Chrome data directory is pinned to a complete temporary profile, so the
    classification depends only on the injected failure text and never on whether
    the machine running the test has Chrome installed.
    """
    profile_dir = tmp_path / "Default"
    (profile_dir / "Network").mkdir(parents=True)
    (profile_dir / "Network/Cookies").write_bytes(b"sqlite")
    monkeypatch.setattr(
        chrome_browser, "chrome_user_data_directory", lambda *_: tmp_path
    )
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies",
        Mock(side_effect=RuntimeError("cannot open /Users/someone/Chrome/Default/Cookies")),
    )
    with pytest.raises(TemporaryAccessError) as excinfo:
        ig._browser_cookies("Default")
    assert excinfo.value.diagnostic_code in chrome_browser.COOKIE_DIAGNOSTIC_CODES
    assert excinfo.value.diagnostic_code == "cookie_access_unknown"
    assert "someone" not in str(excinfo.value)
    assert "/Users/" not in str(excinfo.value)


def test_cookie_failure_with_a_missing_chrome_directory_is_classified(monkeypatch, tmp_path):
    """A bare CI runner has no Chrome at all; that is its own fixed category."""
    monkeypatch.setattr(
        chrome_browser, "chrome_user_data_directory", lambda *_: tmp_path / "absent"
    )
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=RuntimeError("opaque failure"))
    )
    with pytest.raises(TemporaryAccessError) as excinfo:
        ig._browser_cookies("Default")
    assert excinfo.value.diagnostic_code == "chrome_data_directory_missing"


def test_cookie_decryption_failure_is_named_without_the_keychain_text(monkeypatch, tmp_path):
    profile_dir = tmp_path / "Default"
    (profile_dir / "Network").mkdir(parents=True)
    (profile_dir / "Network/Cookies").write_bytes(b"sqlite")
    monkeypatch.setattr(chrome_browser, "chrome_user_data_directory", lambda *_: tmp_path)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies",
        Mock(side_effect=RuntimeError("failed to decrypt value with secretbox")),
    )
    with pytest.raises(TemporaryAccessError) as excinfo:
        ig._browser_cookies("Default")
    assert excinfo.value.diagnostic_code == "cookie_decryption_failed"
    assert "secretbox" not in str(excinfo.value)


# ---------------------------------------------------------------------------
# Media-pipeline conversion
# ---------------------------------------------------------------------------


def pipeline_info(*, shortcode="Cq1pipe", uploader_id=AUTHOR_ID, uploader=USERNAME,
                  thumbnails=None, formats=None, entries=None):
    info = {
        "id": shortcode,
        "title": "Fixture pipeline post",
        "uploader": uploader,
        "uploader_id": uploader_id,
        "upload_date": "20260915",
    }
    if thumbnails is not None:
        info["thumbnails"] = thumbnails
    if formats is not None:
        info["formats"] = formats
    if entries is not None:
        info["entries"] = entries
    return info


def test_pipeline_image_post_yields_one_image_part():
    works = ig.works_from_pipeline_info(pipeline_info(
        thumbnails=[{"url": MEDIA, "width": 640, "height": 800},
                    {"url": MEDIA + "?big=1", "width": 1080, "height": 1350}],
    ))
    assert len(works) == 1
    part = works[0].parts[0]
    assert part.kind == "image" and part.media_id == "Cq1pipe"
    assert part.assets[0].candidates[0] == MEDIA + "?big=1"
    assert works[0].upload_date == "2026-09-15"
    assert works[0].author_id == AUTHOR_ID


def test_pipeline_video_post_is_left_to_the_media_pipeline():
    works = ig.works_from_pipeline_info(pipeline_info(formats=[{"format_id": "18"}]))
    part = works[0].parts[0]
    assert part.kind == "video" and part.assets == []


def test_pipeline_carousel_expands_per_member():
    works = ig.works_from_pipeline_info(pipeline_info(
        shortcode="Cq1parent",
        entries=[
            pipeline_info(shortcode="Cq1e1", thumbnails=[{"url": MEDIA, "width": 100, "height": 100}]),
            pipeline_info(shortcode="Cq1e2", formats=[{"format_id": "18"}]),
        ],
    ))
    assert len(works) == 1
    assert works[0].media_id == "Cq1parent"
    assert [part.media_id for part in works[0].parts] == ["Cq1e1", "Cq1e2"]
    assert works[0].kind == "carousel"


def test_pipeline_post_without_a_shortcode_yields_nothing():
    assert ig.works_from_pipeline_info({"thumbnails": [{"url": MEDIA, "width": 1, "height": 1}]}) == []


# ---------------------------------------------------------------------------
# Downloader discovery wiring
# ---------------------------------------------------------------------------


def test_discover_profile_queues_one_item_per_part(monkeypatch):
    result = ig.Result(
        works=[
            ig.Work("Cq1a", AUTHOR_ID, USERNAME, "Fixture image", "2026-09-15",
                    parts=[ig.WorkPart(1, "image", "Cq1a", POST, assets=[RemoteAsset([MEDIA], 1, 1080, 1350)])],
                    kind="image"),
            ig.Work("Cq1carousel", AUTHOR_ID, USERNAME, "Fixture carousel", "2026-09-15",
                    parts=[
                        ig.WorkPart(1, "image", "Cq1c1", "https://www.instagram.com/p/Cq1c1/"),
                        ig.WorkPart(2, "video", "Cq1c2", "https://www.instagram.com/reels/Cq1c2/"),
                    ],
                    kind="carousel"),
        ],
        source_kind="profile",
        source_id=USERNAME,
        complete=True,
        warning=None,
        declared_count=2,
    )
    monkeypatch.setattr(engine, "discover_instagram", lambda *a, **k: result)
    outcome = downloader()._discover_instagram(PROFILE, SourceKind.PROFILE, lambda: False)

    assert outcome.author == USERNAME
    assert outcome.discovery_complete is True
    assert [item.media_id for item in outcome.items] == ["Cq1a", "Cq1c1", "Cq1c2"]
    assert [item.playlist_index for item in outcome.items] == [1, 2, 3]
    assert [item.media_type for item in outcome.items] == [
        MediaType.IMAGE, MediaType.IMAGE, MediaType.VIDEO,
    ]
    first = outcome.items[0]
    assert first.extractor_key == "Instagram"
    assert first.metadata["instagram_source_kind"] == "profile"
    assert first.metadata["instagram_source_id"] == USERNAME
    assert first.metadata["instagram_part_count"] == 1
    assert outcome.items[2].metadata["instagram_part_count"] == 2
    assert len({item.id for item in outcome.items}) == 3


def test_discovered_items_never_persist_a_signed_media_address():
    """An expiring signature must not survive into task state."""
    result = ig.Result(
        works=[ig.Work("Cq1a", AUTHOR_ID, USERNAME, "Fixture", None,
                       parts=[ig.WorkPart(1, "image", "Cq1a", POST,
                                          assets=[RemoteAsset([MEDIA + "?signature=secret"], 1, 10, 10)])],
                       kind="image")],
        source_kind="profile", source_id=USERNAME,
    )
    with mock.patch.object(engine, "discover_instagram", lambda *a, **k: result):
        outcome = downloader()._discover_instagram(PROFILE, SourceKind.PROFILE, lambda: False)
    serialized = json.dumps(
        [item.model_dump(mode="json") for item in outcome.items], ensure_ascii=False
    )
    assert "signature=secret" not in serialized
    assert "cdninstagram.com" not in serialized


def test_discover_profile_rejects_a_non_chrome_cookie_browser():
    with pytest.raises(TemporaryAccessError, match="Chrome Cookie"):
        downloader(cookie_browser="firefox")._discover_instagram(
            PROFILE, SourceKind.PROFILE, lambda: False
        )


def test_discover_profile_honours_cancellation(monkeypatch):
    monkeypatch.setattr(engine, "discover_instagram", lambda *a, **k: ig.Result([], "profile", USERNAME))
    with pytest.raises(engine.DownloadCancelledError):
        downloader()._discover_instagram(PROFILE, SourceKind.PROFILE, lambda: True)


def test_discover_single_post_uses_the_media_pipeline(monkeypatch):
    """A post page mixes recommendations into the render, so scraping cannot isolate it."""
    monkeypatch.setattr(
        engine.MediaDownloader, "_extract_instagram_post_info",
        lambda self, url, should_cancel: (pipeline_info(
            shortcode="Cq1video", formats=[{"format_id": "18"}], uploader_id=AUTHOR_ID
        ), False),
    )
    outcome = downloader()._discover_instagram(POST, SourceKind.ITEM, lambda: False)
    assert len(outcome.items) == 1
    item = outcome.items[0]
    assert item.media_type is MediaType.VIDEO
    assert item.metadata["instagram_source_kind"] == "item"
    assert item.metadata["instagram_profile_url"] == ""


def test_discover_single_image_post_points_the_user_to_the_profile(monkeypatch):
    """The renditions an image needs only exist in the profile response."""
    monkeypatch.setattr(
        engine.MediaDownloader, "_extract_instagram_post_info",
        lambda self, url, should_cancel: ({"_instagram_pipeline_error": "no video formats"}, False),
    )
    with pytest.raises(DiscoveryError) as excinfo:
        downloader()._discover_instagram(POST, SourceKind.ITEM, lambda: False)
    assert "profile" in str(excinfo.value).lower()


def test_discover_without_any_verifiable_media_raises_instead_of_an_empty_result(monkeypatch):
    monkeypatch.setattr(engine, "discover_instagram", lambda *a, **k: ig.Result([], "profile", USERNAME))
    with pytest.raises(DiscoveryError, match="no verified media"):
        downloader()._discover_instagram(PROFILE, SourceKind.PROFILE, lambda: False)


def test_incomplete_discovery_is_carried_to_the_job(monkeypatch):
    monkeypatch.setattr(
        engine, "discover_instagram",
        lambda *a, **k: ig.Result(
            [ig.Work("Cq1a", AUTHOR_ID, USERNAME, "Fixture", None,
                     parts=[ig.WorkPart(1, "image", "Cq1a", POST,
                                        assets=[RemoteAsset([MEDIA], 1, 10, 10)])],
                     kind="image")],
            "profile", USERNAME, complete=False, warning=ig.PROFILE_INCOMPLETE,
        ),
    )
    outcome = downloader()._discover_instagram(PROFILE, SourceKind.PROFILE, lambda: False)
    assert outcome.discovery_complete is False
    assert outcome.warning == ig.PROFILE_INCOMPLETE


# ---------------------------------------------------------------------------
# Download dispatch
# ---------------------------------------------------------------------------


def test_video_part_uses_the_media_pipeline(monkeypatch):
    calls = []

    def fake_pipeline(self, item, output_dir, *, platform, callback, should_cancel):
        calls.append((item.media_id, platform))
        return engine.DownloadOutcome(output_paths=["/tmp/video.mp4"], media_type=MediaType.VIDEO)

    monkeypatch.setattr(engine.MediaDownloader, "_download_with_ytdlp", fake_pipeline)
    item = instagram_item("Cq1video", part_kind="video")
    outcome = downloader()._download_instagram_item(
        item, Path("/tmp"), callback=None, should_cancel=lambda: False
    )
    assert calls == [("Cq1video", Platform.INSTAGRAM)]
    assert outcome.media_type is MediaType.VIDEO


def test_image_part_is_resolved_again_instead_of_reusing_a_stored_address(monkeypatch):
    """The signature expires, so a persisted address would fetch a dead URL."""
    asset = RemoteAsset([MEDIA + "?signature=fresh"], 1, 1080, 1350)
    walks = []

    def fake_walk(self, profile_url, should_cancel):
        walks.append(profile_url)
        return ig.Result(
            [ig.Work("Cq1a", AUTHOR_ID, USERNAME, "Fixture", None,
                     parts=[ig.WorkPart(1, "image", "Cq1a", POST, assets=[asset])],
                     kind="image")],
            "profile", USERNAME,
        )

    monkeypatch.setattr(engine.MediaDownloader, "_instagram_profile_walk", fake_walk)
    seen = {}

    def fake_transfer(self, ydl, assets, output_dir, upload_date, title, media_id, source_url, **kwargs):
        seen.update(kwargs)
        seen["candidates"] = list(assets[0].candidates)
        return Path(output_dir / "fixture.jpg"), assets[0]

    monkeypatch.setattr(engine.MediaDownloader, "_download_first_available_asset", fake_transfer)
    monkeypatch.setattr(engine, "YoutubeDL", StubYoutubeDL)
    events = []
    outcome = downloader()._download_instagram_item(
        instagram_item("Cq1a"), Path("/tmp"), callback=events.append, should_cancel=lambda: False
    )
    assert walks == [PROFILE]
    assert seen["candidates"] == [MEDIA + "?signature=fresh"]
    assert seen["platform"] is Platform.INSTAGRAM
    assert seen["media_type"] is MediaType.IMAGE
    assert seen["verify_declared_dimensions"] is True
    assert outcome.media_type is MediaType.IMAGE
    assert [event.event for event in events] == ["probing", "completed"]


def test_one_profile_walk_serves_every_image_in_a_run(monkeypatch):
    """Walking costs up to the whole browser budget, so it must not repeat per image."""
    calls = []

    def fake_discover(url, **kwargs):
        calls.append(url)
        return ig.Result([ig.Work("Cq1a", AUTHOR_ID, USERNAME, "Fixture", None,
                                  parts=[ig.WorkPart(1, "image", "Cq1a", POST,
                                                    assets=[RemoteAsset([MEDIA], 1, 10, 10)])],
                                  kind="image")], "profile", USERNAME)

    monkeypatch.setattr(engine, "discover_instagram", fake_discover)
    instance = downloader()
    first = instance._instagram_profile_walk(PROFILE, lambda: False)
    second = instance._instagram_profile_walk(PROFILE, lambda: False)
    assert calls == [PROFILE]
    assert first is second
    # A retry builds a new engine, which must walk again for fresh signatures.
    monkeypatch.setattr(engine, "discover_instagram", fake_discover)
    downloader()._instagram_profile_walk(PROFILE, lambda: False)
    assert calls == [PROFILE, PROFILE]


def test_profile_walk_cache_is_keyed_by_the_cookie_context(monkeypatch):
    calls = []
    monkeypatch.setattr(engine, "discover_instagram", lambda url, **kwargs: (
        calls.append((url, kwargs.get("cookie_profile"), kwargs.get("use_browser_cookies")))
        or ig.Result([], "profile", USERNAME)
    ))
    instance = engine.MediaDownloader(engine.DownloaderConfig(
        cookie_browser="chrome", cookie_profile="Default"
    ))
    instance._instagram_profile_walk(PROFILE, lambda: False)
    instance._instagram_profile_walk(PROFILE, lambda: False)
    assert calls == [(PROFILE, "Default", True)]


def test_image_missing_from_a_rewalked_profile_is_reported_not_silently_skipped(monkeypatch):
    """The post may have been removed or made private since discovery."""
    monkeypatch.setattr(engine.MediaDownloader, "_instagram_profile_walk",
                        lambda self, url, should_cancel: ig.Result([], "profile", USERNAME))
    with pytest.raises(MediaDownloadError, match="no longer lists this image"):
        downloader()._download_instagram_item(
            instagram_item("Cq1gone"), Path("/tmp"), callback=None, should_cancel=lambda: False
        )


@pytest.mark.parametrize(
    "mutate",
    [
        lambda item: item.metadata.update({"instagram_part_kind": "audio"}),
        lambda item: item.metadata.update({"instagram_part_kind": ""}),
        lambda item: setattr(item, "media_id", ""),
    ],
)
def test_an_item_without_a_verified_media_kind_is_refused(monkeypatch, mutate):
    monkeypatch.setattr(engine.MediaDownloader, "_instagram_profile_walk",
                        Mock(side_effect=AssertionError("Must not walk the profile")))
    item = instagram_item("Cq1a")
    mutate(item)
    with pytest.raises(MediaDownloadError):
        downloader()._download_instagram_item(
            item, Path("/tmp"), callback=None, should_cancel=lambda: False
        )


def test_changed_item_identity_blocks_the_download(monkeypatch):
    """A queued address must still resolve to the exact post that was discovered."""
    monkeypatch.setattr(engine.MediaDownloader, "_instagram_profile_walk",
                        Mock(side_effect=AssertionError("Must not walk the profile")))
    item = instagram_item("Cq1a")
    item.source_url = "https://www.instagram.com/p/Cq1different/"
    with pytest.raises(MediaDownloadError, match="identity changed"):
        downloader()._download_instagram_item(
            item, Path("/tmp"), callback=None, should_cancel=lambda: False
        )


def test_changed_author_blocks_the_download(monkeypatch):
    """Another author's work must never land in this author's folder."""
    monkeypatch.setattr(
        engine.MediaDownloader, "_instagram_profile_walk",
        lambda self, url, should_cancel: ig.Result(
            [ig.Work("Cq1a", "999888", "someoneelse", "Fixture", None,
                     parts=[ig.WorkPart(1, "image", "Cq1a", POST,
                                        assets=[RemoteAsset([MEDIA], 1, 10, 10)])],
                     kind="image")],
            "profile", USERNAME,
        ),
    )
    with pytest.raises(MediaDownloadError, match="author identity changed"):
        downloader()._download_instagram_item(
            instagram_item("Cq1a"), Path("/tmp"), callback=None, should_cancel=lambda: False
        )


def test_single_post_image_resolves_through_the_pipeline(monkeypatch):
    monkeypatch.setattr(
        engine.MediaDownloader, "_extract_instagram_post_info",
        lambda self, url, should_cancel: (pipeline_info(
            shortcode="Cq1solo",
            thumbnails=[{"url": MEDIA, "width": 1080, "height": 1350}],
        ), False),
    )
    monkeypatch.setattr(engine.MediaDownloader, "_download_first_available_asset",
                        lambda self, ydl, assets, output_dir, *a, **k: (
                            Path(output_dir / "solo.jpg"), assets[0]))
    monkeypatch.setattr(engine, "YoutubeDL", StubYoutubeDL)
    item = instagram_item("Cq1solo", profile_url="")
    item.metadata["instagram_source_kind"] = "item"
    outcome = downloader()._download_instagram_item(
        item, Path("/tmp"), callback=None, should_cancel=lambda: False
    )
    assert outcome.media_type is MediaType.IMAGE


def test_post_url_identity_is_verified_before_transfer(monkeypatch):
    monkeypatch.setattr(engine.MediaDownloader, "_instagram_profile_walk",
                        Mock(side_effect=AssertionError("Must not walk the profile")))
    monkeypatch.setattr(engine, "instagram_source_identity", lambda value: ("profile", USERNAME))
    with pytest.raises(MediaDownloadError, match="identity changed"):
        downloader()._download_instagram_item(
            instagram_item("Cq1a"), Path("/tmp"), callback=None, should_cancel=lambda: False
        )


def test_untrusted_media_host_is_blocked_before_any_request():
    """Only Instagram's own CDN may be fetched; a redirect target is re-checked too."""
    assert engine.is_instagram_media_url(MEDIA)
    assert not engine.is_instagram_media_url("https://evil.example/media.jpg")
    assert not engine.is_instagram_media_url("http://scontent.cdninstagram.com/x.jpg")
    assert not engine.is_instagram_media_url("https://scontent.cdninstagram.com.evil.example/x.jpg")


def test_download_dispatch_routes_instagram(monkeypatch):
    monkeypatch.setattr(engine.MediaDownloader, "_download_instagram_item",
                        lambda self, item, output_dir, *, callback, should_cancel:
                        engine.DownloadOutcome(output_paths=["/tmp/x.jpg"]))
    outcome = downloader().download_item(
        instagram_item("Cq1a"), Platform.INSTAGRAM, "/tmp", should_cancel=lambda: False
    )
    assert outcome.output_paths == ["/tmp/x.jpg"]


# ---------------------------------------------------------------------------
# Task-level resume semantics
# ---------------------------------------------------------------------------


def instagram_job(status, *, complete, source_kind=SourceKind.PROFILE, **kwargs):
    job = DownloadJob(
        id="fixture",
        source_url=PROFILE,
        platform=Platform.INSTAGRAM,
        source_kind=source_kind,
        output_root="/tmp",
        status=status,
        discovery_complete=complete,
        **kwargs,
    )
    return job


def test_incomplete_profile_task_is_rediscovered_on_retry(tmp_path):
    """An interrupted walk must resume, not be presented as a finished profile."""
    assert DownloadManager._should_rediscover_on_retry(
        instagram_job(JobStatus.INTERRUPTED, complete=False)
    )


def test_complete_profile_task_with_no_pending_items_is_not_rewalked(tmp_path):
    job = instagram_job(JobStatus.COMPLETED, complete=True)
    job.items.append(instagram_item("Cq1a", status=ItemStatus.COMPLETED))
    assert not DownloadManager._should_rediscover_on_retry(job)


def test_single_post_task_retries_the_item_without_a_profile_walk():
    job = instagram_job(JobStatus.FAILED, complete=True, source_kind=SourceKind.ITEM)
    job.source_url = POST
    job.items.append(instagram_item("Cq1a", status=ItemStatus.FAILED))
    assert not DownloadManager._should_rediscover_on_retry(job)


def test_needs_auth_profile_task_is_rediscovered():
    assert DownloadManager._should_rediscover_on_retry(
        instagram_job(JobStatus.NEEDS_AUTH, complete=True)
    )


# ---------------------------------------------------------------------------
# Public response redaction
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value,expected",
    [
        ("https://www.instagram.com/yiluntan_news/?igsh=abc123", PROFILE),
        ("https://www.instagram.com/p/Cq1shortcode/?igsh=xyz#comment", POST),
        ("https://instagram.com/yiluntan_news/", "https://instagram.com/yiluntan_news/"),
    ],
)
def test_public_url_redaction_drops_share_tracking(redact_public_url, value, expected):
    assert redact_public_url(value) == expected


def test_public_url_redaction_leaves_other_platforms_unchanged(redact_public_url):
    assert redact_public_url("https://www.xiaohongshu.com/x/a?xsec_token=T&y=1") == (
        "https://www.xiaohongshu.com/x/a?y=1"
    )
    assert redact_public_url("https://example.com/a?b=c") == "https://example.com/a?b=c"


# ---------------------------------------------------------------------------
# Native request loading
# ---------------------------------------------------------------------------


def test_trusted_requests_load_natively_without_relaying(monkeypatch):
    """Relaying every request through fetch+fulfill stalls this page.

    Measured against a real logged-in profile, a fetch-and-fulfill route stops
    loading after roughly sixty responses, the profile component never mounts and
    the site never issues its timeline request. The adapter therefore lets
    trusted requests through natively; this guards against reintroducing the
    relay, which would silently break discovery without failing any request.
    """
    import inspect

    source = inspect.getsource(ig)
    assert "route.continue_()" in source
    assert "route.fetch(" not in source
    assert "fulfill_checked_route" not in source

    browser = InstagramBrowserFixture(responses=[
        InstagramResponse(profile_content_response(1), operation=ig.PROFILE_CONTENT_OPERATION),
        InstagramResponse(
            timeline_response([image_node("Cq1a")], has_next_page=False),
            operation="PolarisProfilePostsQuery",
        ),
    ])
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    result = ig.discover(PROFILE)
    assert [work.media_id for work in result.works] == ["Cq1a"]
    assert browser.continued_requests == [PROFILE]
    assert browser.aborted_requests == []


def test_every_issued_request_is_rechecked_against_the_host_allowlist(monkeypatch):
    """A native continue does not re-enter the route handler for redirect hops.

    The allowlist is therefore re-applied to every request Chromium issues, and
    the committed main-frame URL is tracked, so an off-site redirect still fails
    discovery instead of being downloaded silently.
    """
    browser = InstagramBrowserFixture(responses=[
        InstagramResponse(profile_content_response(1), operation=ig.PROFILE_CONTENT_OPERATION),
        InstagramResponse(
            timeline_response([image_node("Cq1a")], has_next_page=False),
            operation="PolarisProfilePostsQuery",
        ),
    ])
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    ig.discover(PROFILE)
    assert {"response", "request", "framenavigated"} <= set(browser.listeners)


def test_navigation_to_an_untrusted_page_blocks_discovery(monkeypatch):
    """A committed navigation off the trusted profile must fail, not download."""
    browser = InstagramBrowserFixture(final_url="https://evil.example/yiluntan_news/")
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    with pytest.raises((DiscoveryError, TemporaryAccessError)):
        ig.discover(PROFILE)


# ---------------------------------------------------------------------------
# Real byte transfer
# ---------------------------------------------------------------------------


def make_real_jpeg(tmp_path, width, height, *, color="red", name="source.jpg"):
    """Create a real decodable JPEG so the image check is not a header guess."""
    target = tmp_path / name
    subprocess.run(
        [
            shutil.which("ffmpeg"),
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", f"color=c={color}:s={width}x{height}",
            "-frames:v", "1",
            str(target),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return target


@contextmanager
def local_media_server(payload, content_type):
    """Serve real bytes over a real local HTTP socket for transfer regressions."""
    served = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            served.append(self.path)
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", served
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_image_part_transfer_over_local_http_writes_and_verifies_real_bytes(
    monkeypatch, tmp_path
):
    """The image path must really fetch bytes, not only build a candidate list.

    Every other Instagram image test stops at ``_download_first_available_asset``,
    so the transfer layer underneath it had no coverage. This drives it against a
    real local socket: the bytes must land byte-for-byte and pass the FFmpeg
    decode plus declared-dimension gate. Only the CDN host allowlist is relaxed
    for the loopback origin, and that gate itself is covered by
    ``test_untrusted_media_host_is_blocked_before_any_request``.
    """
    width, height = 1080, 1350
    payload = make_real_jpeg(tmp_path, width, height, color="steelblue").read_bytes()
    expected_sha256 = hashlib.sha256(payload).hexdigest()
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    with local_media_server(payload, "image/jpeg") as (base, served):
        asset = RemoteAsset([base + "/image.jpg"], 1, width, height)
        with engine.YoutubeDL(instance._base_options(False)) as ydl:
            path, chosen = instance._download_first_available_asset(
                ydl,
                [asset],
                out_dir,
                "2026-01-01",
                "Fixture Instagram post",
                "Cq1transfer",
                "https://www.instagram.com/p/Cq1transfer/",
                platform=Platform.INSTAGRAM,
                media_type=MediaType.IMAGE,
                callback=None,
                should_cancel=lambda: False,
                asset_index=1,
                progress_index=1,
                progress_count=1,
                verify_declared_dimensions=True,
            )

    landed = Path(path)
    assert landed.is_file()
    assert hashlib.sha256(landed.read_bytes()).hexdigest() == expected_sha256
    assert (chosen.width, chosen.height) == (width, height)
    assert served == ["/image.jpg"]
