"""Offline Instagram integration tests; no user profiles or external network."""

from __future__ import annotations

import contextlib
import hashlib
import importlib
import json
import shutil
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from unittest.mock import Mock
from urllib.parse import urlsplit

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


class FakeCDPSession:
    """Stand in for the CDP session that arms the adapter's request gate.

    Records every command so a test can assert that the gate was really enabled
    and that each request was released or failed before it left the browser.
    """

    def __init__(self, fixture):
        self.fixture = fixture
        self.handlers = {}
        self.commands = []
        self.enabled = False
        self.disabled = False
        self.detached = False

    def on(self, event, handler):
        self.handlers[event] = handler

    def send(self, method, params=None):
        params = dict(params or {})
        self.commands.append((method, params))
        if method == "Fetch.enable":
            self.enabled = True
        elif method == "Fetch.disable":
            self.disabled = True
        elif method == "Fetch.continueRequest":
            self.fixture.record_decision(params.get("requestId"), released=True)
        elif method == "Fetch.failRequest":
            self.fixture.record_decision(params.get("requestId"), released=False)

    def detach(self):
        self.detached = True


class InstagramBrowserFixture:
    """Serve a profile timeline through the adapter's own gate and hooks.

    Requests are paused by the production CDP gate exactly as a real browser
    pauses them, so this fixture exercises the real trusted-host and
    navigation-identity decisions instead of bypassing them: every request is
    offered to the gate before it is "dispatched", redirect hops included, and
    the committed main-frame URL is still tracked. No socket is opened.
    """

    MAIN_FRAME = "frame-main"

    def __init__(self, *, final_url=PROFILE, responses=(), title="Instagram fixture",
                 redirect_requests=()):
        self.final_url = final_url
        self.responses = list(responses)
        self.redirect_requests = list(redirect_requests)
        self.page = self
        self.main_frame = SimpleNamespace(url=PROFILE)
        self.version = "140.0.0.0"
        self.url = PROFILE
        self.listeners = {}
        self.cdp = None
        self.closed = False
        self.added_cookies = []
        self.launch_options = None
        self.scrolls = 0
        # url -> requestId, and the two decision ledgers a test asserts against.
        self.requests_by_id = {}
        self.continued_requests = []
        self.failed_requests = []
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

    def new_cdp_session(self, page):
        assert page is self
        self.cdp = FakeCDPSession(self)
        return self.cdp

    def add_cookies(self, cookies):
        self.added_cookies.extend(cookies)

    def set_default_timeout(self, value):
        pass

    def on(self, event, listener):
        self.listeners[event] = listener

    def record_decision(self, request_id, *, released):
        url = self.requests_by_id.get(str(request_id))
        if released:
            self.continued_requests.append(url)
        else:
            self.failed_requests.append(url)

    def dispatch_request(self, url, resource_type, frame_id=None):
        """Offer one request to the gate and report whether it was released."""
        assert self.cdp is not None, "gate installed after a request was issued"
        handler = self.cdp.handlers.get("Fetch.requestPaused")
        assert handler is not None, "the gate never subscribed to paused requests"
        request_id = f"request-{len(self.requests_by_id)}"
        self.requests_by_id[request_id] = url
        handler({
            "requestId": request_id,
            "request": {"url": url},
            "resourceType": resource_type,
            "frameId": self.MAIN_FRAME if frame_id is None else frame_id,
        })
        return url not in self.failed_requests

    def goto(self, url, **kwargs):
        # The navigation itself is gated first, then each redirect hop is a
        # separate paused request. Playwright routing never sees a hop, which is
        # precisely why the gate has to be armed at the protocol level.
        if not self.dispatch_request(self.final_url, "Document"):
            raise RuntimeError("Navigation blocked by the request gate")
        for redirect_url in self.redirect_requests:
            self.dispatch_request(redirect_url, "Document")
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
    kwargs.setdefault("source_url", f"https://www.instagram.com/p/{shortcode}/")
    kwargs.setdefault("title", "Fixture Instagram post")
    return DownloadItem(
        id=shortcode,
        media_id=shortcode,
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


def test_invisible_formatting_prefix_never_becomes_the_title():
    """Measured on a real profile: 408 of 437 works had this caption shape.

    The site prefixes captions and accessibility strings with runs of invisible
    formatting characters, which ``str.strip`` does not remove. Accepting such a
    line produced a filename holding no readable character at all.
    """
    node = image_node("Cq1invisible")
    node["accessibility_caption"] = "\u2061\u2060\u2061"
    node["caption"] = {"text": "\u2061\u2061Photo by the author"}
    work = ig.parse_work(node, expected_username=USERNAME)
    assert work.title == "Photo by the author"
    assert all(character.isprintable() for character in work.title)


def test_title_falls_back_when_no_candidate_has_visible_text():
    node = image_node("Cq1allinvisible")
    node["accessibility_caption"] = "\u2061\u2060"
    node["caption"] = {"text": "\u2061\n\u2060\n"}
    work = ig.parse_work(node, expected_username=USERNAME)
    assert work.title == "Untitled Instagram image"
    assert all(character.isprintable() for character in work.title)


def test_title_keeps_an_emoji_zero_width_joiner_inside_the_line():
    """Trimming only the ends must not destroy an emoji sequence mid-caption.

    The zero-width joiner is itself a category Cf character, so filtering every
    invisible character out of the line would break emoji that the shared
    filename sanitizer deliberately preserves.
    """
    node = image_node("Cq1emoji")
    node["accessibility_caption"] = "\u2061Family \U0001F468\u200d\U0001F469\u200d\U0001F466 trip"
    work = ig.parse_work(node, expected_username=USERNAME)
    assert "\u200d" in work.title
    assert work.title == "Family \U0001F468\u200d\U0001F469\u200d\U0001F466 trip"


def test_title_uses_the_first_line_with_visible_text():
    node = video_node("Cq1lines")
    node["accessibility_caption"] = "\u2061\n   \nReel by the author\nsecond line"
    work = ig.parse_work(node, expected_username=USERNAME)
    assert work.title == "Reel by the author"


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
    the site never issues its timeline request. The gate therefore releases
    trusted requests with a native ``Fetch.continueRequest`` rather than fetching
    and fulfilling a copy here; this guards against reintroducing the relay,
    which would silently break discovery without failing any request.
    """
    import inspect

    source = inspect.getsource(ig)
    # The gate releases natively and never relays bytes through this process.
    assert "Fetch.continueRequest" in source
    assert "route.fetch(" not in source
    assert "fulfill_checked_route" not in source
    assert "context.route(" not in source

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
    # The trusted navigation was released before dispatch; nothing was blocked.
    assert browser.continued_requests == [PROFILE]
    assert browser.failed_requests == []
    # The gate was really armed at the protocol level and torn down afterwards.
    assert browser.cdp.enabled
    assert browser.cdp.disabled or browser.cdp.detached


def test_every_issued_request_is_rechecked_against_the_host_allowlist(monkeypatch):
    """Every request is gated before dispatch, redirect hops included.

    A native continue does not re-enter a Playwright route handler for redirect
    hops, so the CDP gate pauses each request at the Request stage and applies the
    allowlist there, while the committed main-frame URL is still tracked. An
    off-site redirect is therefore blocked before its target is contacted instead
    of being downloaded silently.
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
    # The committed-URL tracker and timeline observer are still wired, but the
    # per-request allowlist now lives in the armed CDP gate, not a request event.
    assert {"response", "framenavigated"} <= set(browser.listeners)
    assert "request" not in browser.listeners
    assert browser.cdp.enabled
    # Every dispatched request passed through the gate and was explicitly decided.
    assert browser.continued_requests and not browser.failed_requests
    assert set(browser.continued_requests) <= set(browser.requests_by_id.values())


def test_navigation_to_an_untrusted_page_blocks_discovery(monkeypatch):
    """A committed navigation off the trusted profile must fail, not download."""
    browser = InstagramBrowserFixture(final_url="https://evil.example/yiluntan_news/")
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    with pytest.raises((DiscoveryError, TemporaryAccessError)):
        ig.discover(PROFILE)


def test_untrusted_redirect_hop_blocks_discovery_without_reaching_the_handler(monkeypatch):
    """A redirect hop must be caught even though it never re-enters the handler.

    ``route.continue_()`` lets Chromium follow redirects itself, so a hop is only
    visible to the request listener. Without that re-check the host allowlist
    would cover only the first request of each chain, and an off-site redirect
    could be downloaded silently.
    """
    browser = InstagramBrowserFixture(
        redirect_requests=["https://evil.example/steal"],
        responses=[
            InstagramResponse(
                profile_content_response(1), operation=ig.PROFILE_CONTENT_OPERATION
            ),
            InstagramResponse(
                timeline_response([image_node("Cq1a")], has_next_page=False),
                operation="PolarisProfilePostsQuery",
            ),
        ],
    )
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    with pytest.raises(DiscoveryError, match="outside trusted pages"):
        ig.discover(PROFILE)
    # The navigation itself was still allowed natively; the hop was what failed.
    assert browser.continued_requests == [PROFILE]


def test_trusted_redirect_hop_is_allowed(monkeypatch):
    """A hop onto another trusted Instagram host must not be treated as a leak."""
    browser = InstagramBrowserFixture(
        redirect_requests=["https://www.instagram.com/yiluntan_news/"],
        responses=[
            InstagramResponse(
                profile_content_response(1), operation=ig.PROFILE_CONTENT_OPERATION
            ),
            InstagramResponse(
                timeline_response([image_node("Cq1a")], has_next_page=False),
                operation="PolarisProfilePostsQuery",
            ),
        ],
    )
    monkeypatch.setattr(ig, "sync_playwright", browser.playwright)
    monkeypatch.setattr(
        ig, "_extract_chrome_cookies", Mock(side_effect=AssertionError("Must not read cookies"))
    )
    result = ig.discover(PROFILE)
    assert [work.media_id for work in result.works] == ["Cq1a"]


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


# ---------------------------------------------------------------------------
# Real-browser redirect gating (R4)
#
# Playwright routing cannot stop a redirect hop: a native continue never
# re-enters the route handler, so an observer only learns of an off-site request
# after the target already received it. These regressions drive the production
# gate (``_install_request_gate``) in real Chrome against two loopback origins
# and assert the untrusted one records *zero* requests. The loopback exception
# lives only in the injected predicates; the shipped allowlist still requires
# HTTPS on port 443.
# ---------------------------------------------------------------------------

REAL_CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
requires_real_chrome = pytest.mark.skipif(
    not REAL_CHROME.is_file(),
    reason="The optional real Chrome runtime is not installed",
)


@contextmanager
def redirect_origins(status, *, page_script="fetch('/hop').catch(function(){});"):
    """Two loopback origins: a trusted page that redirects to an untrusted one.

    The trusted origin serves ``/page`` (running ``page_script``), ``/hop`` and
    ``/navhop`` (both a ``status`` redirect to the untrusted origin's ``/target``)
    and ``/selfhop`` (a same-origin redirect to its own ``/target``). The
    untrusted origin records every request it actually receives, so a regression
    can assert it was never contacted. Loopback only; no external network.
    """
    untrusted_hits: list[tuple[str, str]] = []
    trusted_target_hits: list[str] = []

    class Untrusted(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _record(self):
            untrusted_hits.append((self.command, self.path))
            body = b"leaked"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = _record
        do_POST = _record
        do_HEAD = _record

        def log_message(self, *args):
            pass

    untrusted = ThreadingHTTPServer(("127.0.0.1", 0), Untrusted)
    untrusted_origin = f"http://127.0.0.1:{untrusted.server_port}"

    class Trusted(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _redirect_to_untrusted(self):
            self.send_response(status)
            self.send_header("Location", untrusted_origin + "/target")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _serve_target(self):
            trusted_target_hits.append(self.path)
            body = b"trusted-target"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _route(self):
            path = urlsplit(self.path).path
            if path == "/page":
                body = (
                    "<title>trusted</title><script>" + page_script + "</script>"
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif path in {"/hop", "/navhop"}:
                self._redirect_to_untrusted()
            elif path == "/selfhop":
                self.send_response(302)
                self.send_header("Location", "/target")
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif path == "/target":
                self._serve_target()
            else:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

        def do_GET(self):
            self._route()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            if length:
                self.rfile.read(length)
            self._route()

        def do_HEAD(self):
            self._route()

        def log_message(self, *args):
            pass

    trusted = ThreadingHTTPServer(("127.0.0.1", 0), Trusted)
    trusted_origin = f"http://127.0.0.1:{trusted.server_port}"

    threads = [
        threading.Thread(target=untrusted.serve_forever, daemon=True),
        threading.Thread(target=trusted.serve_forever, daemon=True),
    ]
    for thread in threads:
        thread.start()
    try:
        yield trusted_origin, untrusted_origin, untrusted_hits, trusted_target_hits
    finally:
        for server, thread in ((untrusted, threads[0]), (trusted, threads[1])):
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()


def drive_gate(goto_url, *, trusted_origin, wait_ms=1500):
    """Run the production gate in real Chrome and return the errors it reported.

    Only the two injected predicates know about the loopback origins; every other
    decision (main-frame detection, resource-type blocking, release-versus-fail)
    is the shipped code path.
    """
    from playwright.sync_api import sync_playwright

    errors: list[Exception] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            channel="chrome", headless=True, timeout=15000
        )
        try:
            context = browser.new_context(service_workers="block")
            page = context.new_page()
            cdp = ig._install_request_gate(
                context,
                page,
                should_cancel=lambda: False,
                on_error=errors.append,
                is_trusted_page=lambda value: value.startswith(trusted_origin),
                is_trusted_host=lambda value: value.startswith(trusted_origin),
            )
            try:
                with contextlib.suppress(Exception):
                    page.goto(goto_url, wait_until="load", timeout=8000)
                page.wait_for_timeout(wait_ms)
            finally:
                cdp.send("Fetch.disable")
        finally:
            browser.close()
    return errors


@requires_real_chrome
@pytest.mark.parametrize("status", [301, 302, 303, 307, 308])
def test_instagram_redirect_is_blocked_before_target_receives_request(status):
    """A subrequest redirect hop never reaches the untrusted origin."""
    with redirect_origins(status) as (trusted_origin, _untrusted, hits, _targets):
        errors = drive_gate(trusted_origin + "/page", trusted_origin=trusted_origin)
    assert hits == [], f"untrusted origin was contacted for status {status}: {hits}"
    assert any("outside trusted pages" in str(error) for error in errors)


@requires_real_chrome
@pytest.mark.parametrize("status", [302, 307])
def test_instagram_navigation_redirect_is_blocked_before_target_receives_request(status):
    """A top-level navigation redirect off-site is blocked before dispatch too."""
    with redirect_origins(status) as (trusted_origin, _untrusted, hits, _targets):
        errors = drive_gate(trusted_origin + "/navhop", trusted_origin=trusted_origin)
    assert hits == [], f"untrusted origin was contacted for navigation {status}: {hits}"
    assert any("outside trusted pages" in str(error) for error in errors)


@requires_real_chrome
@pytest.mark.parametrize("status", [307, 308])
def test_instagram_post_redirect_is_blocked_before_target_receives_request(status):
    """A body-preserving 307/308 POST hop is still blocked before it is sent."""
    script = "fetch('/hop',{method:'POST',body:'secret'}).catch(function(){});"
    with redirect_origins(status, page_script=script) as (
        trusted_origin,
        _untrusted,
        hits,
        _targets,
    ):
        errors = drive_gate(trusted_origin + "/page", trusted_origin=trusted_origin)
    assert hits == [], f"untrusted origin received the POST hop for {status}: {hits}"
    assert any("outside trusted pages" in str(error) for error in errors)


@requires_real_chrome
def test_instagram_trusted_redirect_is_released_to_its_target():
    """A hop that stays on the trusted origin completes instead of being blocked.

    Blocking everything would also stop the real profile from loading, so the gate
    must release a same-origin redirect and let its target be fetched.
    """
    script = "fetch('/selfhop').catch(function(){});"
    with redirect_origins(302, page_script=script) as (
        trusted_origin,
        _untrusted,
        hits,
        targets,
    ):
        errors = drive_gate(trusted_origin + "/page", trusted_origin=trusted_origin)
    assert hits == [], "the untrusted origin must never be involved in a trusted hop"
    assert targets, "the trusted same-origin redirect target was not reached"
    assert not any("outside trusted pages" in str(error) for error in errors)


# ---------------------------------------------------------------------------
# Real-transfer resume regression (R1)
#
# An Instagram video address is re-resolved by yt-dlp on every attempt and the
# signed URL changes between runs, so a retained ``.part`` cannot be proven to
# belong to the same source bytes a resume would append to. These regressions
# drive the real yt-dlp transfer against a slow loopback server, interrupt the
# first attempt mid-flight, then retry the *same* post (same title/id, so the
# same output filename) against a different same-length source. The fixed code
# removes the stale partial and re-downloads in full; the pre-fix code kept the
# partial, sent ``Range: bytes=N-`` and published a spliced file.
# ---------------------------------------------------------------------------


@contextmanager
def resumable_media_server(sources_by_phase, *, honours_range=True):
    """Serve byte sources on one path, slowly, and log Range headers.

    ``sources_by_phase`` is a one-element list holding the payload to serve, so a
    test can swap the source between phases while the URL stays identical. Only
    the served bytes change; the request path and derived output name do not.

    ``honours_range=False`` models a server that ignores ``Range`` and always
    replies with the complete body, so a regression can prove the fix does not
    depend on the server honouring a resume request.
    """
    range_headers: list[str] = []
    state = {"payload": sources_by_phase[0]}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            header = self.headers.get("Range")
            if header:
                range_headers.append(header)
            payload = state["payload"]
            total = len(payload)
            start = 0
            if honours_range and header and header.startswith("bytes="):
                with contextlib.suppress(ValueError):
                    start = int(header.split("=")[1].split("-")[0])
            body = payload[start:]
            if start:
                self.send_response(206)
                self.send_header(
                    "Content-Range", f"bytes {start}-{total - 1}/{total}"
                )
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            # Serve in small chunks with a pause so yt-dlp emits repeated
            # progress events and a cancel can land mid-transfer rather than
            # after the file has already completed.
            for offset in range(0, len(body), 8192):
                try:
                    self.wfile.write(body[offset:offset + 8192])
                    self.wfile.flush()
                except BrokenPipeError:
                    # The client aborted mid-transfer, which is exactly what the
                    # interrupted attempt is meant to do.
                    return
                time.sleep(0.02)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f"http://127.0.0.1:{server.server_port}"

    def set_payload(payload: bytes) -> None:
        state["payload"] = payload

    try:
        yield origin, range_headers, set_payload
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


# Bytes into a transfer at which a test triggers a cancel. Both real videos must
# be several times larger than this, or the cancel lands after the file already
# completed and the resume path is never exercised.
CANCEL_AFTER_BYTES = 16384


@pytest.fixture(scope="session")
def real_video_sources(tmp_path_factory):
    """Two distinct, decodable videos large enough to interrupt mid-transfer.

    Using real media keeps the resume regressions honest: the identity gate and
    the pre-publication media verification both run for real, so nothing about the
    production path is stubbed out. Generated once per session and reused.
    """
    work = tmp_path_factory.mktemp("instagram-real-videos")
    ffmpeg = shutil.which("ffmpeg")
    sources = {}
    for label, pattern, seconds in (("big", "testsrc2", 3), ("small", "testsrc", 3)):
        target = work / f"{label}.mp4"
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error",
                "-f", "lavfi",
                "-i", f"{pattern}=size=1280x720:rate=30:duration={seconds}",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
                "-pix_fmt", "yuv420p", str(target),
            ],
            check=True,
            capture_output=True,
            timeout=180,
        )
        payload = target.read_bytes()
        # Both must be large enough that a cancel lands mid-transfer rather than
        # after the file already completed, or the resume path is never exercised.
        assert len(payload) > 4 * CANCEL_AFTER_BYTES, label
        sources[label] = payload
    assert sources["big"] != sources["small"]
    return sources


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_retry_does_not_splice_changed_source_bytes(
    monkeypatch, tmp_path, real_video_sources
):
    """A retry after an interrupt must not append a stale partial to new bytes.

    The real yt-dlp transfer, staging directory, identity gate, media verification
    and publish path are all exercised; only the cancel predicate is driven by the
    test. The sources differ in length, so a pre-fix resume would splice a prefix
    of the first video onto the second and still report completion.
    """
    source_a = real_video_sources["big"]
    source_b = real_video_sources["small"]
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    # Loopback media must be treated as trusted so the real transfer proceeds.
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    def make_item(url):
        # The loopback path is named after the queued shortcode, so the generic
        # extractor resolves the same identity the queue recorded and the real
        # identity gate passes instead of being stubbed out. Identical title and
        # media_id across both phases keep one output filename, so a surviving
        # ``.part`` would be reused.
        return instagram_item(
            "r1splice", part_kind="video", source_url=url, title="Fixture video",
            author_id="",
        )

    with resumable_media_server([source_a]) as (origin, range_headers, set_payload):
        media_url = origin + "/r1splice.mp4"
        cancel = {"flag": False}

        def callback(event):
            progress = getattr(event, "progress", None)
            if progress and progress.downloaded_bytes > CANCEL_AFTER_BYTES:
                cancel["flag"] = True

        # Phase 1: interrupt a real transfer partway through the first video.
        with pytest.raises(engine.DownloadCancelledError):
            instance._download_with_ytdlp(
                make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
                callback=callback, should_cancel=lambda: cancel["flag"],
            )
        # The failed attempt must not leave a resumable partial behind.
        assert list(out_dir.rglob("*.part")) == []

        # Phase 2: same post, a re-signed source carrying different bytes.
        set_payload(source_b)
        range_headers.clear()
        outcome = instance._download_with_ytdlp(
            make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
            callback=None, should_cancel=lambda: False,
        )

    published = Path(outcome.output_paths[0])
    data = published.read_bytes()
    assert data == source_b, "retry published a spliced file instead of the full source"
    assert data[:1024] != source_a[:1024], "the stale partial prefix survived"
    assert range_headers == [], "a resume Range request was sent against a changed source"
    # The completed event was published for a genuinely complete file.
    assert outcome.resolution == "1280x720"


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_retry_reuses_partial_only_with_verified_source_identity(
    monkeypatch, tmp_path, real_video_sources
):
    """An unchanged source re-downloads cleanly and produces the exact bytes.

    Instagram has no source identity that survives a re-signed URL, so the safe
    behaviour is a full re-download: with the same bytes on both attempts the
    published file must still equal the complete source and no Range is sent.
    """
    source = real_video_sources["small"]
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    with resumable_media_server([source]) as (origin, range_headers, _set_payload):
        media_url = origin + "/r1same.mp4"
        item = instagram_item(
            "r1same", part_kind="video", source_url=media_url,
            title="Fixture video", author_id="",
        )
        outcome = instance._download_with_ytdlp(
            item, out_dir, platform=Platform.INSTAGRAM,
            callback=None, should_cancel=lambda: False,
        )

    data = Path(outcome.output_paths[0]).read_bytes()
    assert data == source
    assert range_headers == [], "a fresh same-source download must not resume"


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_full_redownload_does_not_rely_on_server_honouring_range(
    monkeypatch, tmp_path, real_video_sources
):
    """The fix must not depend on the server answering a Range request.

    A stale partial is removed rather than resumed, so even a server that ignores
    ``Range`` and always replies with the whole body yields the exact new source.
    """
    source_a = real_video_sources["big"]
    source_b = real_video_sources["small"]
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    def make_item(url):
        return instagram_item(
            "r1norang", part_kind="video", source_url=url,
            title="Fixture video", author_id="",
        )

    with resumable_media_server(
        [source_a], honours_range=False
    ) as (origin, range_headers, set_payload):
        media_url = origin + "/r1norang.mp4"
        cancel = {"flag": False}

        def callback(event):
            progress = getattr(event, "progress", None)
            if progress and progress.downloaded_bytes > CANCEL_AFTER_BYTES:
                cancel["flag"] = True

        with pytest.raises(engine.DownloadCancelledError):
            instance._download_with_ytdlp(
                make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
                callback=callback, should_cancel=lambda: cancel["flag"],
            )
        assert list(out_dir.rglob("*.part")) == []

        set_payload(source_b)
        range_headers.clear()
        outcome = instance._download_with_ytdlp(
            make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
            callback=None, should_cancel=lambda: False,
        )

    assert Path(outcome.output_paths[0]).read_bytes() == source_b
    assert range_headers == [], "the retry must not attempt a resume at all"


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_retry_with_a_changed_source_length_publishes_the_new_source(
    monkeypatch, tmp_path, real_video_sources
):
    """A length change between attempts must not truncate or pad the output.

    Resuming against a differently sized source is the clearest way to end up with
    a file that matches neither version, so the retry has to publish the complete
    new source and nothing else.
    """
    source_a = real_video_sources["big"]
    source_b = real_video_sources["small"]
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    def make_item(url):
        return instagram_item(
            "r1length", part_kind="video", source_url=url,
            title="Fixture video", author_id="",
        )

    with resumable_media_server([source_a]) as (origin, range_headers, set_payload):
        media_url = origin + "/r1length.mp4"
        cancel = {"flag": False}

        def callback(event):
            progress = getattr(event, "progress", None)
            if progress and progress.downloaded_bytes > CANCEL_AFTER_BYTES:
                cancel["flag"] = True

        with pytest.raises(engine.DownloadCancelledError):
            instance._download_with_ytdlp(
                make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
                callback=callback, should_cancel=lambda: cancel["flag"],
            )

        set_payload(source_b)
        range_headers.clear()
        outcome = instance._download_with_ytdlp(
            make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
            callback=None, should_cancel=lambda: False,
        )

    data = Path(outcome.output_paths[0]).read_bytes()
    assert data == source_b
    assert len(data) == len(source_b)
    assert len(data) != len(source_a)
    assert range_headers == []


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_failed_attempt_only_cleans_its_own_staging(
    monkeypatch, tmp_path, real_video_sources
):
    """Cleaning up a failed attempt must not touch another task's staged data.

    The staging tree is scoped per job and item, so retiring this task's partial
    has to leave an unrelated job's files exactly as they were.
    """
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    # An unrelated job's staged bytes, plus a finished file the user already has.
    other_job_dir = out_dir / ".parts" / "other-job" / "other-item"
    other_job_dir.mkdir(parents=True)
    other_partial = other_job_dir / "Unknown-Date-other [other].mp4.part"
    other_partial.write_bytes(b"Q" * 4096)
    unrelated_finished = out_dir / "2026-01-01-Kept work [keptid].mp4"
    unrelated_finished.write_bytes(b"K" * 2048)

    source_a = real_video_sources["big"]
    source_b = real_video_sources["small"]

    def make_item(url):
        item = instagram_item(
            "r1scope", part_kind="video", source_url=url,
            title="Fixture video", author_id="",
        )
        item.metadata["_job_id"] = "job-scope"
        return item

    with resumable_media_server([source_a]) as (origin, _range_headers, set_payload):
        media_url = origin + "/r1scope.mp4"
        cancel = {"flag": False}

        def callback(event):
            progress = getattr(event, "progress", None)
            if progress and progress.downloaded_bytes > CANCEL_AFTER_BYTES:
                cancel["flag"] = True

        with pytest.raises(engine.DownloadCancelledError):
            instance._download_with_ytdlp(
                make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
                callback=callback, should_cancel=lambda: cancel["flag"],
            )

        set_payload(source_b)
        outcome = instance._download_with_ytdlp(
            make_item(media_url), out_dir, platform=Platform.INSTAGRAM,
            callback=None, should_cancel=lambda: False,
        )

    assert Path(outcome.output_paths[0]).read_bytes() == source_b
    # This task's own staging is gone; the other job's data is untouched.
    assert not (out_dir / ".parts" / "job-scope").exists()
    assert other_partial.read_bytes() == b"Q" * 4096
    assert unrelated_finished.read_bytes() == b"K" * 2048


# ---------------------------------------------------------------------------
# Video identity and media verification before publication (R2)
#
# A video part used to leave for the generic yt-dlp pipeline with only the queued
# URL compared against the stored shortcode, so a resolved post by another author
# -- or a response that is not video at all -- was still published and reported
# complete. The identity mismatch and the invalid-media cases are constructed
# separately below so one failure cannot mask the other.
# ---------------------------------------------------------------------------


@contextmanager
def static_media_server(files):
    """Serve named byte payloads over a real loopback socket.

    ``files`` maps a request path to bytes. The generic extractor derives a post
    id from the file name, so naming a path after (or deliberately *not* after) a
    queued shortcode is what makes the real identity gate pass or fail.
    """

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            payload = files.get(urlsplit(self.path).path, b"")
            self.send_response(200 if payload else 404)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


@pytest.fixture(scope="session")
def real_media_kinds(tmp_path_factory):
    """Real media for the publication gate: with audio, silent, truncated, junk.

    These are generated once per session. The truncated file still probes by
    header, which is exactly why publication needs a full decode rather than a
    metadata read.
    """
    work = tmp_path_factory.mktemp("instagram-real-media")
    ffmpeg = shutil.which("ffmpeg")

    def encode(target, extra):
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=size=720x1280:rate=30:duration=2",
                *extra,
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26",
                "-pix_fmt", "yuv420p", str(target),
            ],
            check=True, capture_output=True, timeout=180,
        )
        return target

    with_audio = encode(
        work / "with_audio.mp4",
        ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", "-shortest"],
    )
    silent = encode(work / "silent.mp4", [])
    truncated = work / "truncated.mp4"
    whole = with_audio.read_bytes()
    truncated.write_bytes(whole[: int(len(whole) * 0.4)])
    return {
        "with_audio": with_audio.read_bytes(),
        "silent": silent.read_bytes(),
        "truncated": truncated.read_bytes(),
        "junk": b"not-a-video" * 4096,
    }


def instagram_video_info(*, duration=2.0, width=720, height=1280, has_audio=True):
    """Info shaped like the real Instagram extractor's, not the generic one's.

    The loopback fixtures in these tests resolve through yt-dlp's generic
    extractor, which reports no duration, dimensions or codecs. Declaring them
    here is what lets the publication gate be exercised against real files.
    """
    formats = [{"format_id": "v", "vcodec": "h264", "acodec": "none",
                "width": width, "height": height}]
    if has_audio:
        formats.append({"format_id": "a", "vcodec": "none", "acodec": "aac", "abr": 128})
    return {
        "duration": duration,
        "width": width,
        "height": height,
        "requested_formats": formats,
    }


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_video_rejects_resolved_identity_mismatch(
    monkeypatch, tmp_path, real_media_kinds
):
    """A normal video that is not the queued post must not be published.

    The media itself is valid, so only the identity can be wrong here: the
    resolved post carries a different shortcode than the queue recorded.
    """
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )
    good_video = real_media_kinds["with_audio"]

    with static_media_server({"/someone_elses_post.mp4": good_video}) as origin:
        item = instagram_item(
            "QueuedPost", part_kind="video",
            source_url=origin + "/someone_elses_post.mp4",
            title="Fixture video", author_id="",
        )
        with pytest.raises(MediaDownloadError, match="not the queued post"):
            instance._download_with_ytdlp(
                item, out_dir, platform=Platform.INSTAGRAM,
                callback=None, should_cancel=lambda: False,
            )

    # Nothing was published, and the other author's video was never staged as
    # though it belonged to this task.
    assert list(out_dir.rglob("*.mp4")) == []
    assert list(out_dir.rglob("*.part")) == []


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_video_missing_author_identity_is_rejected(
    monkeypatch, tmp_path, real_media_kinds
):
    """Missing author identity must not be treated as a match.

    The post identity is right and the media is valid, so this isolates the
    author check: an unproven author cannot be shown to own the queued post.
    """
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )
    good_video = real_media_kinds["with_audio"]

    with static_media_server({"/r2author.mp4": good_video}) as origin:
        item = instagram_item(
            "r2author", part_kind="video", source_url=origin + "/r2author.mp4",
            title="Fixture video", author_id=AUTHOR_ID,
        )
        with pytest.raises(MediaDownloadError, match="not the queued post"):
            instance._download_with_ytdlp(
                item, out_dir, platform=Platform.INSTAGRAM,
                callback=None, should_cancel=lambda: False,
            )

    assert list(out_dir.rglob("*.mp4")) == []


@pytest.mark.skipif(
    not shutil.which("ffmpeg"),
    reason="The optional local FFmpeg runtime is not installed",
)
def test_instagram_video_rejects_invalid_media_before_publication(
    monkeypatch, tmp_path, real_media_kinds
):
    """Identity correct but the body is not video: reject before publication.

    The response is served with ``Content-Type: video/mp4`` while carrying
    non-video bytes, which is what a captive portal or an error page looks like.
    """
    out_dir = (tmp_path / "out").resolve()
    out_dir.mkdir()
    instance = downloader()
    monkeypatch.setattr(
        engine, "is_instagram_media_url", lambda value: value.startswith("http://127.0.0.1:")
    )

    with static_media_server({"/r2media.mp4": real_media_kinds["junk"]}) as origin:
        item = instagram_item(
            "r2media", part_kind="video", source_url=origin + "/r2media.mp4",
            title="Fixture video", author_id="",
        )
        with pytest.raises(MediaDownloadError):
            instance._download_with_ytdlp(
                item, out_dir, platform=Platform.INSTAGRAM,
                callback=None, should_cancel=lambda: False,
            )

    assert list(out_dir.rglob("*.mp4")) == [], "invalid media was published"


def test_instagram_video_rejects_truncated_file_and_declared_dimension_mismatch(
    tmp_path, real_media_kinds
):
    """A truncated file and an under-delivered rendition must both be rejected.

    FFprobe reads a header without decoding the whole file, so a truncated
    transfer can still look valid; the publication gate decodes it fully.
    """
    instance = downloader()
    media_dir = tmp_path / "media"
    media_dir.mkdir()
    truncated = media_dir / "truncated.mp4"
    truncated.write_bytes(real_media_kinds["truncated"])
    good = media_dir / "good.mp4"
    good.write_bytes(real_media_kinds["with_audio"])

    with pytest.raises(MediaDownloadError):
        instance._verify_instagram_video_file(
            truncated, instagram_video_info(), should_cancel=lambda: False
        )
    # A valid file measured below the rendition that was selected is rejected.
    with pytest.raises(MediaDownloadError, match="below its selected"):
        instance._verify_instagram_video_file(
            good,
            instagram_video_info(width=1080, height=1920),
            should_cancel=lambda: False,
        )
    # A declared duration the file cannot match is rejected.
    with pytest.raises(MediaDownloadError, match="duration"):
        instance._verify_instagram_video_file(
            good, instagram_video_info(duration=45.0), should_cancel=lambda: False
        )


@pytest.mark.skipif(
    not shutil.which("ffmpeg") or not shutil.which("ffprobe"),
    reason="Synthetic video tests require local FFmpeg and FFprobe",
)
def test_instagram_video_preserves_expected_audio_stream(tmp_path, real_media_kinds):
    """Audio is required only when the resolved formats declared sound.

    A legitimately silent video must not be rejected, while a video that lost the
    audio its own metadata promised must be.
    """
    instance = downloader()
    media_dir = tmp_path / "media"
    media_dir.mkdir()
    silent = media_dir / "silent.mp4"
    silent.write_bytes(real_media_kinds["silent"])
    with_audio = media_dir / "with_audio.mp4"
    with_audio.write_bytes(real_media_kinds["with_audio"])

    # A silent video whose formats never declared audio is valid.
    verified = instance._verify_instagram_video_file(
        silent, instagram_video_info(has_audio=False), should_cancel=lambda: False
    )
    assert verified["width"] == 720 and verified["height"] == 1280

    # The same silent file is rejected when the formats did declare audio.
    with pytest.raises(MediaDownloadError, match="audio"):
        instance._verify_instagram_video_file(
            silent, instagram_video_info(has_audio=True), should_cancel=lambda: False
        )

    # A video that really has audio passes the audio expectation.
    verified = instance._verify_instagram_video_file(
        with_audio, instagram_video_info(has_audio=True), should_cancel=lambda: False
    )
    assert verified["duration"] > 0
