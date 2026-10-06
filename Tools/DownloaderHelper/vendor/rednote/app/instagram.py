# ChengYing integration; not part of the original upstream snapshot.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Observe Instagram's normal browser responses without replaying private APIs.

Instagram serves a profile timeline through its own paginated GraphQL connection
while the page is scrolled. This adapter watches those responses exactly as the
site's own JavaScript produces them. It never signs a request, never replays a
private API, never bypasses a challenge and never strips a watermark.

Four facts measured against a real logged-in profile drive this design:

* A profile timeline response carries ``page_info.has_next_page``. That flag is
  the only site-confirmed end of list, so enumeration is reported complete only
  when it is observed as false.
* The same response set carries ``data.user.media_count``, the author's own
  declared post total, which makes an incomplete walk detectable instead of
  being silently presented as finished.
* A profile renders a virtual list, so the DOM only ever holds a sliding window
  of links. Reading links back from the page at the end loses most of them; the
  works are accumulated as each response arrives instead.
* A post's own ``video_versions`` top out at 720x1280 while the same session
  resolves a 1080x1920 rendition through the normal media pipeline. Videos are
  therefore left to that pipeline instead of being pinned to the lower in-page
  rendition, which would silently downgrade quality.

Images are downloaded from the page's own ``image_versions2`` candidates, which
do include the exact declared dimensions. Media URLs carry an expiring
signature, so they are never persisted and a retry rediscovers them.

A single post is deliberately not resolved here. Instagram serves no per-post
JSON response that can be observed, and a rendered post page mixes the requested
post with home-feed recommendations, so page scraping cannot isolate one post
safely. The caller routes single posts through the existing media pipeline,
which resolves a post by its own shortcode.
"""

from __future__ import annotations

import contextlib
import json
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any
from urllib.parse import parse_qsl, urlsplit

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

from .browser import (
    chrome_cookie_diagnostic,
    chrome_user_agent,
    public_cookie_diagnostic_code,
)
from .errors import (
    AuthenticationRequiredError,
    DiscoveryError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from .xiaohongshu import RemoteAsset, _extract_chrome_cookies

PAGE_HOSTS = {"instagram.com", "www.instagram.com"}
# Media comes from Instagram's own CDN. Page JavaScript and CSS come from that
# CDN and from Meta's static hosts. Blocking the static hosts stops the page
# script from ever running, so the site never issues its timeline request and
# discovery reports "no verified data" even though the author has posts; this is
# the same class of failure that broke Kuaishou profile discovery. They are page
# subresources only: media downloads stay bound to MEDIA_DOMAINS and navigation
# stays bound to PAGE_HOSTS, so neither allowlist is widened by these entries.
MEDIA_DOMAINS = ("cdninstagram.com", "fbcdn.net")
STATIC_ASSET_DOMAINS = ("cdninstagram.com", "fbcdn.net", "facebook.com")
BROWSER_DOMAINS = ("instagram.com", *STATIC_ASSET_DOMAINS)

# A shortcode is the public post identifier used in /p/, /reels/, /tv/ URLs.
SHORTCODE_PATTERN = r"[A-Za-z0-9_-]{4,32}"
# Instagram restricts usernames to these characters and this length.
USERNAME_PATTERN = r"[A-Za-z0-9._]{1,30}"
# Reserved top-level paths are never usernames. Accepting one would turn an
# explore, stories or account URL into a bogus profile request.
RESERVED_PATHS = frozenset(
    {
        "about",
        "accounts",
        "api",
        "ar",
        "create",
        "developer",
        "direct",
        "explore",
        "legal",
        "p",
        "press",
        "reel",
        "reels",
        "share",
        "stories",
        "support",
        "tv",
        "web",
    }
)
POST_PATHS = frozenset({"p", "tv", "reel", "reels"})
# These paths carry content that is not one author's downloadable post. They are
# rejected explicitly rather than downloaded: an audio page is a music track, a
# share page is a redirect wrapper, a hashtag page is a search result, and
# stories are ephemeral content whose access rules must not be worked around.
REJECT_AUDIO = "Instagram audio pages are music tracks, not downloadable posts"
REJECT_STORIES = "Instagram stories are ephemeral and are not downloaded"
REJECT_TAGS = "Instagram hashtag pages are search results, not one author's works"
REJECT_EXPLORE = "Instagram explore pages are recommendations, not one author's works"
REJECT_SHARE = (
    "Instagram share links are redirects; open the post in Chrome and copy its address"
)
REJECT_ACCOUNT = "Instagram account pages are not downloadable content"
REJECT_NESTED = "Only an Instagram profile or a single post URL is supported"

# The timeline connection key inside a profile posts response. A response keyed
# differently belongs to another surface (home feed, reels tab, inbox) and must
# never be mistaken for this author's works.
TIMELINE_CONNECTION_KEY = "xdt_api__v1__feed__user_timeline_graphql_connection"
# The friendly names the page itself uses for profile timeline requests.
# Matching on these keeps the home recommendation feed
# (PolarisFeedTimelineRootV2Query) and the clips tab out of the result, which
# would otherwise attribute other authors' posts to this profile.
TIMELINE_OPERATIONS = frozenset(
    {
        "PolarisProfilePostsQuery",
        "PolarisProfilePostsTabContentQuery_connection",
    }
)
# Carries data.user.media_count, the author's declared post total.
PROFILE_CONTENT_OPERATION = "PolarisProfilePageContentQuery"
GRAPHQL_PATHS = frozenset({"/graphql/query", "/api/graphql"})

# Polaris media_type values measured on a real profile.
MEDIA_TYPE_IMAGE = 1
MEDIA_TYPE_VIDEO = 2
MEDIA_TYPE_CAROUSEL = 8

MAX_RESPONSE_BYTES = 24 * 1024 * 1024
MAX_PROFILE_PAGES = 500
MAX_PROFILE_ITEMS = 10_000
MAX_BROWSER_SECONDS = 300
MAX_CAROUSEL_PARTS = 100
MAX_TITLE_CHARACTERS = 60
# A profile uses a virtual list, so one redraw can add no work without meaning
# the walk is over. Progress is measured in verified works, not visible links.
MAX_IDLE_ROUNDS = 14
# No works at all after this long means the page is showing a wall, not a list.
EMPTY_PROFILE_SECONDS = 25

PROFILE_INCOMPLETE = (
    "Instagram profile discovery is incomplete. Only verified posts were queued; "
    "retry the original profile to continue. The site did not confirm the end of the list."
)
PROFILE_INTERRUPTED = (
    "Instagram stopped serving further profile pages, so discovery is incomplete. "
    "Only verified posts were queued; already saved files are kept. Wait a few "
    "minutes, then retry the original profile to rediscover its posts and reuse "
    "verified saved files."
)
# A recoverable interruption must not discard posts that were already verified.
# Login, verification, identity and security problems stay fatal: reporting them
# as a partial result would hide a real access problem. CONTENT_UNAVAILABLE is
# excluded because it describes one post, not a pagination interruption.
RECOVERABLE_PROFILE_ISSUES = frozenset(
    {
        SiteIssueCode.RATE_LIMITED,
        SiteIssueCode.REQUEST_REJECTED,
        SiteIssueCode.SITE_UNAVAILABLE,
        SiteIssueCode.NETWORK_ERROR,
    }
)
PROFILE_RETRY_ATTEMPTS = 3
PROFILE_RETRY_BASE_SECONDS = 5.0
PROFILE_RETRY_MAX_SECONDS = 20.0

MAX_PROBLEM_DETAILS = 20
MAX_PROBLEM_NAMES = 10

PROBLEM_NO_MEDIA = "no_verifiable_media"
PROBLEM_UNSUPPORTED = "unsupported_media_type"
PROBLEM_FOREIGN_AUTHOR = "not_this_author"
PROBLEM_QUEUE_LIMIT = "queue_limit_reached"
PROBLEM_PAGE_LIMIT = "page_item_limit_reached"
# A carousel member that could not be built is not the same thing as a post that
# could not be parsed: the post still queues its usable members, so reporting
# nothing would silently shrink the album. These say why a member was dropped.
PROBLEM_PART_MISSING_IDENTITY = "carousel_part_missing_identity"
PROBLEM_PART_NO_MEDIA = "carousel_part_no_verifiable_media"
PROBLEM_PART_NO_SIZE = "carousel_part_no_declared_size"
PROBLEM_PART_UNSUPPORTED = "carousel_part_unsupported_media_type"

PROBLEM_LABELS = {
    PROBLEM_NO_MEDIA: "no verifiable media",
    PROBLEM_UNSUPPORTED: "unsupported media type",
    PROBLEM_FOREIGN_AUTHOR: "another author's post",
    PROBLEM_QUEUE_LIMIT: "queue limit reached",
    PROBLEM_PAGE_LIMIT: "page item limit reached",
    PROBLEM_PART_MISSING_IDENTITY: "album member with no usable post identity",
    PROBLEM_PART_NO_MEDIA: "album member with no verifiable media",
    PROBLEM_PART_NO_SIZE: "album member with no declared size",
    PROBLEM_PART_UNSUPPORTED: "album member of an unsupported media type",
}

LOGIN_REQUIRED = (
    "Instagram requires a login for this profile. Sign in to Chrome with the "
    "account that can see these posts, then retry; no content was downloaded."
)
CHALLENGE_REQUIRED = (
    "Instagram asked for a verification step. Complete it in Chrome, then retry; "
    "no content was downloaded."
)
PRIVATE_PROFILE = (
    "This Instagram profile is private or restricted for your account. Only posts "
    "your own logged-in session may see can be downloaded; nothing was queued."
)
NO_VERIFIED_POSTS = (
    "Instagram returned no verified posts for this profile. Open it in Chrome; if "
    "the posts are visible there, retry. No recommendations were downloaded."
)
IMAGE_POST_NEEDS_PROFILE = (
    "This Instagram post is an image or a carousel. Download it from the author's "
    "profile instead: the profile response carries the image renditions that a "
    "single post page does not expose."
)


@dataclass(slots=True)
class WorkPart:
    """One downloadable unit inside a post.

    A post is a single image, a single video, or a carousel of several parts.
    Image parts carry the page's own declared-size candidates. Video parts carry
    only their canonical address: the media pipeline resolves a higher verified
    rendition than the in-page ``video_versions`` list offers.
    """

    position: int
    kind: str  # "image" | "video"
    media_id: str
    url: str
    assets: list[RemoteAsset] = field(default_factory=list)
    width: int | None = None
    height: int | None = None


@dataclass(slots=True)
class Work:
    media_id: str
    author_id: str
    author: str
    title: str
    upload_date: str | None
    parts: list[WorkPart] = field(default_factory=list)
    kind: str = "image"  # "image" | "video" | "carousel"
    # How many members the site declared for this post, and which of them could
    # not be built. Kept with the site's own 1-based position so a dropped member
    # stays identifiable even though the queued parts are renumbered by what
    # survived. Empty for a post whose every member was usable.
    declared_part_count: int = 0
    unresolved_parts: list[tuple[int, str]] = field(default_factory=list)

    @property
    def image_count(self) -> int:
        return sum(1 for part in self.parts if part.kind == "image")

    @property
    def video_count(self) -> int:
        return sum(1 for part in self.parts if part.kind == "video")

    @property
    def missing_part_count(self) -> int:
        return len(self.unresolved_parts)


@dataclass(slots=True)
class Result:
    works: list[Work]
    source_kind: str
    source_id: str
    complete: bool = True
    warning: str | None = None
    declared_count: int | None = None


def canonical_post_url(shortcode: str, *, clips: bool = False) -> str:
    """Build a post's public address from its shortcode alone.

    Only the shortcode is used, so a canonical URL never carries a tracking
    query, a share token or another author's context.
    """
    return f"https://www.instagram.com/{'reels' if clips else 'p'}/{shortcode}/"


def _secure_host(value: str) -> str | None:
    try:
        if not isinstance(value, str) or re.search(r"[\x00-\x20\\]", value):
            return None
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port not in {None, 443}
        ):
            return None
        host = parsed.hostname or ""
        if not re.fullmatch(r"[a-z0-9.-]+", host) or host.endswith("."):
            return None
        return host
    except (TypeError, ValueError):
        return None


def is_page_url(value: str) -> bool:
    return _secure_host(value) in PAGE_HOSTS


def is_media_url(value: str) -> bool:
    host = _secure_host(value)
    return bool(
        host
        and any(
            host == domain or host.endswith("." + domain) for domain in MEDIA_DOMAINS
        )
    )


def _matches_domain(host: str, domains: tuple[str, ...]) -> bool:
    return any(host == domain or host.endswith("." + domain) for domain in domains)


def source_identity(value: str) -> tuple[str, str]:
    """Classify a trusted Instagram URL into ("profile"|"item", identifier).

    Reserved and non-post paths are rejected explicitly. Falling through to a
    profile guess would turn an explore or stories URL into a request for an
    unrelated account page.
    """
    if not is_page_url(value):
        raise DiscoveryError("Instagram URL is not a trusted HTTPS page")
    segments = [part for part in urlsplit(value).path.split("/") if part]
    if not segments:
        raise DiscoveryError("The Instagram home page is not a profile or post")

    first = segments[0].lower()
    if first in POST_PATHS:
        if len(segments) >= 3 and segments[1].lower() == "audio":
            raise DiscoveryError(REJECT_AUDIO)
        # Only "p/<shortcode>" identifies one post. A deeper path is a different
        # surface, so accepting it would download an unrelated post that merely
        # happens to carry a shortcode-shaped first segment.
        if len(segments) == 2 and re.fullmatch(SHORTCODE_PATTERN, segments[1]):
            return "item", segments[1]
        # Instagram's deprecated "<post>/media/" suffix still resolves to the same
        # post, so it keeps working instead of rejecting a previously pasted link.
        if (
            len(segments) == 3
            and segments[2].lower() == "media"
            and re.fullmatch(SHORTCODE_PATTERN, segments[1])
        ):
            return "item", segments[1]
        raise DiscoveryError("Unsupported Instagram post URL")
    if first in RESERVED_PATHS:
        if first == "explore":
            if len(segments) >= 3 and segments[1] == "tags":
                raise DiscoveryError(REJECT_TAGS)
            raise DiscoveryError(REJECT_EXPLORE)
        if first == "stories":
            raise DiscoveryError(REJECT_STORIES)
        if first == "share":
            raise DiscoveryError(REJECT_SHARE)
        if first in {"accounts", "api", "create", "developer", "direct", "web"}:
            raise DiscoveryError(REJECT_ACCOUNT)
        raise DiscoveryError("Unsupported Instagram URL")
    if len(segments) > 1:
        raise DiscoveryError(REJECT_NESTED)
    username = segments[0]
    if not re.fullmatch(USERNAME_PATTERN, username):
        raise DiscoveryError("Unsupported Instagram profile URL")
    return "profile", username


def _positive(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        number = int(value)
        return number if 0 < number < 2**53 else None
    except (TypeError, ValueError, OverflowError):
        return None


def _object(value: Any) -> dict:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (TypeError, ValueError):
            return {}
    return value if isinstance(value, dict) else {}


def _upload_date(node: dict) -> str | None:
    """Convert Polaris ``taken_at`` (unix seconds) to the project date format."""
    timestamp = _positive(node.get("taken_at"))
    if not timestamp:
        return None
    with contextlib.suppress(OverflowError, OSError, ValueError):
        return datetime.fromtimestamp(timestamp, timezone.utc).date().isoformat()
    return None


def _caption_text(value: Any) -> str | None:
    """Read a caption only from the plain-text field the page declares."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        text = value.get("text")
        if isinstance(text, str):
            return text
        edges = value.get("edges")
        if isinstance(edges, list):
            for edge in edges[:1]:
                inner = _object(_object(edge).get("node"))
                text = inner.get("text")
                if isinstance(text, str):
                    return text
    return None


def _first_line(value: str | None) -> str | None:
    """Return the first line that carries visible text.

    Instagram prefixes some captions and accessibility strings with runs of
    invisible formatting characters (Unicode category Cf). ``str.strip`` does not
    remove those, so such a line looks non-empty and would become a filename
    holding no readable character at all. Only the invisible characters at the
    ends of a line are trimmed, so an emoji zero-width joiner sitting between two
    emoji inside the line is preserved; a line is usable only when something
    visible remains.

    The shared filename sanitizer is deliberately not changed for this: it must
    keep emoji zero-width joiners, which are also category Cf.
    """
    if not isinstance(value, str):
        return None
    for line in value.splitlines():
        trimmed = line.strip()
        while trimmed and not trimmed[0].isprintable():
            trimmed = trimmed[1:]
        while trimmed and not trimmed[-1].isprintable():
            trimmed = trimmed[:-1]
        if trimmed:
            return trimmed
    return None


def _title(node: dict, kind: str) -> str:
    """Build a short, filesystem-safe title without echoing private text.

    A caption is the author's own content and can be arbitrarily long, so only a
    bounded first line is used, and only to make a saved file recognizable. The
    full caption is never stored in task state or an error message.
    """
    for candidate in (
        _first_line(node.get("accessibility_caption")),
        _first_line(_caption_text(node.get("caption"))),
    ):
        if candidate:
            return candidate[:MAX_TITLE_CHARACTERS]
    if kind == "video":
        return "Untitled Instagram video"
    if kind == "carousel":
        return "Untitled Instagram carousel"
    return "Untitled Instagram image"


def _image_asset(node: dict) -> RemoteAsset | None:
    """Pick the highest declared-size image rendition from one media node.

    A candidate without its own width and height can never be claimed as the
    highest quality, so it is skipped. Same-dimension alternates are kept as
    backups, so one expired URL does not fail the whole image.
    """
    candidates = _object(node.get("image_versions2")).get("candidates")
    if not isinstance(candidates, list):
        return None
    best: tuple[list[str], int, int] | None = None
    best_pixels = -1
    for entry in candidates[:100]:
        item = _object(entry)
        url = item.get("url")
        if not isinstance(url, str) or not is_media_url(url):
            continue
        width = _positive(item.get("width"))
        height = _positive(item.get("height"))
        if not (width and height):
            continue
        pixels = width * height
        if pixels > best_pixels:
            best_pixels = pixels
            best = ([url], width, height)
        elif best is not None and (width, height) == best[1:]:
            if url not in best[0]:
                best[0].append(url)
    if best is None:
        return None
    urls, width, height = best
    return RemoteAsset(candidates=urls, index=1, width=width, height=height)


def _node_author(node: dict) -> tuple[str | None, str | None]:
    """Return (author_id, username) for a media node, or (None, None)."""
    user = _object(node.get("user"))
    if not user:
        return None, None
    author_id = user.get("pk")
    username = user.get("username")
    return (
        str(author_id) if author_id is not None else None,
        username if isinstance(username, str) and username else None,
    )


def _is_clips(node: dict) -> bool:
    return node.get("product_type") == "clips"


def _part_from_node(node: dict, position: int) -> tuple[WorkPart | None, str | None]:
    """Build one downloadable part from a media node.

    Returns the part, or ``None`` with a fixed reason code. A missing image
    candidate is never substituted with a thumbnail or a cover, because that
    would silently save a lower-quality file than the site actually offers. The
    reason is what lets a caller report a dropped album member instead of
    silently shrinking the post.
    """
    shortcode = node.get("code")
    if not isinstance(shortcode, str) or not re.fullmatch(SHORTCODE_PATTERN, shortcode):
        return None, PROBLEM_PART_MISSING_IDENTITY
    media_type = node.get("media_type")
    declared_width = _positive(node.get("original_width"))
    declared_height = _positive(node.get("original_height"))
    if media_type == MEDIA_TYPE_VIDEO:
        return WorkPart(
            position=position,
            kind="video",
            media_id=shortcode,
            url=canonical_post_url(shortcode, clips=_is_clips(node)),
            width=declared_width,
            height=declared_height,
        ), None
    if media_type == MEDIA_TYPE_IMAGE:
        candidates = _object(node.get("image_versions2")).get("candidates")
        asset = _image_asset(node)
        if asset is None:
            # Distinguish "the site offered nothing" from "it offered renditions
            # that carry no declared size": only the latter can be told apart by
            # a user as a quality problem rather than a removed member.
            if isinstance(candidates, list) and candidates:
                return None, PROBLEM_PART_NO_SIZE
            return None, PROBLEM_PART_NO_MEDIA
        return WorkPart(
            position=position,
            kind="image",
            media_id=shortcode,
            url=canonical_post_url(shortcode),
            assets=[asset],
            width=asset.width or declared_width,
            height=asset.height or declared_height,
        ), None
    return None, PROBLEM_PART_UNSUPPORTED


def _work_kind(parts: list[WorkPart]) -> str:
    kinds = {part.kind for part in parts}
    if len(parts) > 1 or len(kinds) > 1:
        return "carousel"
    return next(iter(kinds))


def parse_work(
    node: dict,
    *,
    expected_author_id: str | None = None,
    expected_username: str | None = None,
) -> Work | None:
    """Parse one profile-timeline node into a Work, or ``None`` if unusable.

    Author identity is verified before anything is accepted. A node whose own
    author differs from the requested profile belongs to someone else (a collab
    post, a reshare, or feed contamination) and is never queued under this
    author's folder.
    """
    shortcode = node.get("code")
    if not isinstance(shortcode, str) or not re.fullmatch(SHORTCODE_PATTERN, shortcode):
        return None
    author_id, username = _node_author(node)
    if expected_author_id and author_id and author_id != expected_author_id:
        return None
    if expected_username and username and username.lower() != expected_username.lower():
        return None
    media_type = node.get("media_type")
    upload_date = _upload_date(node)
    author = username or author_id or ""

    parts: list[WorkPart] = []
    unresolved: list[tuple[int, str]] = []
    declared = 1
    if media_type == MEDIA_TYPE_CAROUSEL:
        children = node.get("carousel_media")
        if isinstance(children, list):
            # Truncating to the supported maximum is a hard cap, not a dropped
            # member, so the declared count is capped the same way: otherwise a
            # 120-member album would look permanently incomplete.
            limited = children[:MAX_CAROUSEL_PARTS]
            declared = len(limited)
            for index, child in enumerate(limited, start=1):
                part, reason = _part_from_node(_object(child), index)
                if part is None:
                    # The site's own position is kept, so the member stays
                    # identifiable even though the queued parts are not renumbered.
                    unresolved.append((index, reason or PROBLEM_PART_NO_MEDIA))
                else:
                    parts.append(part)
    else:
        part, _reason = _part_from_node(node, 1)
        if part is not None:
            parts.append(part)
    if not parts:
        return None
    kind = _work_kind(parts)
    return Work(
        media_id=shortcode,
        author_id=author_id or "",
        author=author,
        title=_title(node, kind),
        upload_date=upload_date,
        parts=parts,
        kind=kind,
        declared_part_count=declared,
        unresolved_parts=unresolved,
    )


def response_error(payload: dict, source_url: str) -> None:
    """Translate a site-reported error into a safe, actionable failure.

    Only fixed categories leave this function. The site's own message is never
    echoed, because it can contain a caption, an account name or another private
    detail; the category is enough for the user to act.
    """
    message = payload.get("message")
    status = payload.get("status")
    if isinstance(message, list):
        message = " ".join(str(part) for part in message[:3])
    text = str(message or "").lower()
    if not text and status not in {"fail", "error"}:
        return
    if any(marker in text for marker in ("challenge", "checkpoint", "confirm it's you", "verify")):
        raise AuthenticationRequiredError(CHALLENGE_REQUIRED, verification_url=source_url)
    if any(marker in text for marker in ("login", "log in", "sign in", "authenticat")):
        raise AuthenticationRequiredError(LOGIN_REQUIRED, verification_url=source_url)
    if any(marker in text for marker in ("private", "not available", "unavailable")):
        raise DiscoveryError(PRIVATE_PROFILE)
    if any(
        marker in text
        for marker in (
            "rate limit",
            "too many requests",
            "temporarily blocked",
            # Instagram's canonical throttle wording; it is a rate limit, not a
            # permanent rejection, so it must carry the wait-and-retry category.
            "wait a few minutes",
        )
    ):
        raise TemporaryAccessError(
            "Instagram rate limited this profile. Already verified posts are kept; "
            "wait a few minutes and retry.",
            issue_code=SiteIssueCode.RATE_LIMITED,
        )
    raise TemporaryAccessError(
        "Instagram rejected the profile request. Already verified posts are kept; "
        "retry shortly.",
        issue_code=SiteIssueCode.REQUEST_REJECTED,
    )


def _form_field(post_data: Any, name: str) -> str | None:
    """Read one field from a form-encoded GraphQL POST body."""
    if isinstance(post_data, dict):
        value = post_data.get(name)
        return value if isinstance(value, str) and value else None
    if not isinstance(post_data, str) or not post_data:
        return None
    try:
        pairs = parse_qsl(post_data, keep_blank_values=True)
    except (TypeError, ValueError):
        return None
    for key, value in pairs:
        if key == name and value:
            return value
    return None


def _variables(post_data: Any) -> dict:
    return _object(_form_field(post_data, "variables"))


def requested_username(post_data: Any) -> str | None:
    """Read the username a timeline request was made for."""
    data = _variables(post_data)
    for source in (data, _object(data.get("data"))):
        username = source.get("username")
        if isinstance(username, str) and username:
            return username
    return None


def requested_cursor(post_data: Any) -> str:
    """Read the pagination cursor a request asked for.

    The cursor is opaque expiring site state. It is used only to detect the site
    re-serving the same page, and is never persisted or reported.
    """
    cursor = _variables(post_data).get("after")
    return cursor if isinstance(cursor, str) else ""


def timeline_nodes(payload: Any) -> tuple[list[dict], dict]:
    """Extract a page's media nodes and its ``page_info`` from a response.

    Only the profile timeline connection key is read. Any other connection (home
    feed, reels tab, inbox, highlights) is ignored, so unrelated works can never
    be attributed to the requested author.
    """
    nodes: list[dict] = []
    page_info: dict = {}

    def walk(value: Any, depth: int = 0) -> None:
        if depth > 12:
            return
        if isinstance(value, dict):
            for key, inner in value.items():
                if key == TIMELINE_CONNECTION_KEY and isinstance(inner, dict):
                    edges = inner.get("edges")
                    if isinstance(edges, list):
                        for edge in edges:
                            node = _object(edge).get("node")
                            if isinstance(node, dict):
                                nodes.append(node)
                    info = _object(inner.get("page_info"))
                    if info:
                        page_info.update(info)
                    continue
                walk(inner, depth + 1)
        elif isinstance(value, list):
            for entry in value[:200]:
                walk(entry, depth + 1)

    walk(payload)
    return nodes, page_info


def _profile_user(payload: Any) -> dict:
    """Read ``data.user`` from a profile content response."""
    return _object(_object(payload).get("data")).get("user") or {}


def profile_media_count(payload: Any) -> int | None:
    """Read the author's declared post total from the profile content response."""
    return _positive(_object(_profile_user(payload)).get("media_count"))


class ProfileCollector:
    """Accumulate verified works across paginated timeline responses.

    A profile renders a virtual list, so the DOM only ever holds a sliding window
    of links. Works are accumulated here as each response arrives instead of
    being read back from the page at the end, which would lose most of them.
    """

    def __init__(self, username: str, source_url: str):
        self.username = username
        self.source_url = source_url
        self.works: dict[str, Work] = {}
        self.seen_cursors: set[str] = set()
        self.declared_count: int | None = None
        self.terminal = False
        self.complete = False
        self.problems: dict[str, list[str]] = {}
        self.problem_count = 0
        # Dropped album members are tracked apart from skipped posts. A post whose
        # members partly failed is still queued, so folding those members into the
        # skipped-post count would inflate it and misreport the profile.
        self.part_problems: dict[str, list[str]] = {}
        self.part_problem_count = 0
        self.pages = 0
        self.author_id: str | None = None

    @property
    def unsupported(self) -> bool:
        return bool(self.problems)

    def _record_problem(self, position: int, media_id: str, reason: str) -> None:
        self.problem_count += 1
        details = self.problems.setdefault(reason, [])
        if len(details) < MAX_PROBLEM_DETAILS:
            details.append(media_id or f"#{position}")

    def _record_part_problem(self, work: Work) -> None:
        """Record every album member that could not be built, with its position.

        The post itself stays queued with the members that were usable, so this is
        what keeps a partly-failed album from being presented as complete.
        """
        for position, reason in work.unresolved_parts:
            self.part_problem_count += 1
            details = self.part_problems.setdefault(reason, [])
            if len(details) < MAX_PROBLEM_DETAILS:
                details.append(f"{work.media_id}#{position}")

    def accept_profile_content(self, payload: dict) -> None:
        user = _profile_user(payload)
        count = _positive(user.get("media_count"))
        if count is not None:
            self.declared_count = count
        author_id = user.get("pk") or user.get("id")
        if author_id is not None and self.author_id is None:
            self.author_id = str(author_id)

    def accept(
        self,
        payload: dict,
        *,
        cursor: str = "",
        page_info: dict | None = None,
    ) -> bool:
        """Accept one timeline page. Returns True when the page carried works.

        Only the request cursor is tracked. The response's ``end_cursor`` is the
        next request's cursor, so recording it here would make the following page
        look like a duplicate and silently drop every page after the first.
        """
        if self.pages >= MAX_PROFILE_PAGES:
            return False
        if cursor and cursor in self.seen_cursors:
            # A repeated request cursor means the site re-served the same page.
            # Treating it as new data would loop without adding works.
            return False
        nodes, info = timeline_nodes(payload)
        if not nodes:
            return False
        self.pages += 1
        if cursor:
            self.seen_cursors.add(cursor)
        accepted = 0
        for position, node in enumerate(nodes, start=1):
            work = parse_work(
                node,
                expected_author_id=self.author_id,
                expected_username=self.username,
            )
            shortcode = node.get("code")
            if work is None:
                if isinstance(shortcode, str) and shortcode:
                    author_id, username = _node_author(node)
                    foreign = bool(
                        (self.author_id and author_id and author_id != self.author_id)
                        or (username and username.lower() != self.username.lower())
                    )
                    self._record_problem(
                        position,
                        shortcode,
                        PROBLEM_FOREIGN_AUTHOR if foreign else PROBLEM_NO_MEDIA,
                    )
                continue
            if self.author_id is None and work.author_id:
                self.author_id = work.author_id
            if len(self.works) >= MAX_PROFILE_ITEMS:
                if work.media_id not in self.works:
                    self._record_problem(position, work.media_id, PROBLEM_QUEUE_LIMIT)
                continue
            if work.media_id not in self.works:
                self.works[work.media_id] = work
                accepted += 1
                # The post is queued with the members that were usable; the ones
                # that were not are reported rather than dropped from the tally.
                if work.unresolved_parts:
                    self._record_part_problem(work)
        info = _object(info or page_info)
        if info.get("has_next_page") is False:
            # The site explicitly confirmed the end of this author's list. This
            # is the only completion evidence accepted.
            self.terminal = True
            self.complete = True
        return accepted > 0

    def finalize(self) -> None:
        """Mark completeness once enumeration has stopped."""
        if self.terminal:
            self.complete = True
        if len(self.works) >= MAX_PROFILE_ITEMS:
            self.complete = False


def problem_summary(collector: ProfileCollector) -> str | None:
    """Summarize posts that could not be queued, using fixed reason codes only.

    Post shortcodes are included so a user can find what was skipped, but no
    caption, media URL or account detail is ever included.
    """
    if not collector.problem_count:
        return None
    parts: list[str] = []
    for reason, details in sorted(collector.problems.items()):
        label = PROBLEM_LABELS.get(reason, reason)
        text = f"{label}: {collector.problem_count if len(collector.problems) == 1 else len(details)}"
        if details:
            shown = details[:MAX_PROBLEM_NAMES]
            text += f" ({', '.join(shown)}"
            if len(details) > MAX_PROBLEM_NAMES:
                text += ", further entries only counted"
            text += ")"
        parts.append(text)
    # Details are capped, so an overflow is counted rather than silently lost.
    uncapped = collector.problem_count - sum(len(v) for v in collector.problems.values())
    if uncapped > 0:
        parts.append(f"{uncapped} further skipped entries only counted")
    return "Skipped posts - " + "; ".join(parts) + "." if parts else None


def part_problem_summary(collector: ProfileCollector) -> str | None:
    """Summarize album members that could not be queued, using fixed codes only.

    These are reported separately from skipped posts: the parent post *was*
    queued, so without this a partly-failed album would look complete. Only
    positions and fixed reason labels appear, never a caption or media address.
    """
    if not collector.part_problem_count:
        return None
    parts: list[str] = []
    for reason, details in sorted(collector.part_problems.items()):
        label = PROBLEM_LABELS.get(reason, reason)
        count = (
            collector.part_problem_count
            if len(collector.part_problems) == 1
            else len(details)
        )
        text = f"{label}: {count}"
        if details:
            shown = details[:MAX_PROBLEM_NAMES]
            text += f" ({', '.join(shown)}"
            if len(details) > MAX_PROBLEM_NAMES:
                text += ", further entries only counted"
            text += ")"
        parts.append(text)
    uncapped = collector.part_problem_count - sum(
        len(v) for v in collector.part_problems.values()
    )
    if uncapped > 0:
        parts.append(f"{uncapped} further album members only counted")
    return "Album members not queued - " + "; ".join(parts) + "." if parts else None


def is_recoverable_profile_interruption(
    exc: BaseException | None, *, paginating: bool = False
) -> bool:
    """True only for transient issues seen while a profile is being paginated."""
    if not paginating or isinstance(
        exc, (DownloadCancelledError, KeyboardInterrupt, SystemExit)
    ):
        return False
    return getattr(exc, "issue_code", None) in RECOVERABLE_PROFILE_ISSUES


def _interruption_category(exc: BaseException | None) -> str:
    issue = getattr(exc, "issue_code", None)
    return str(getattr(issue, "value", issue) or "request_rejected")


def _browser_cookies(profile: str | None) -> list[dict]:
    """Read Instagram cookies from the user's own Chrome session.

    A failure here is classified into one fixed safe category. The underlying
    exception text is never surfaced, because it can contain a profile path or a
    cookie value.
    """
    result: list[dict] = []
    try:
        jar = _extract_chrome_cookies(profile)
        for cookie in jar:
            domain = (cookie.domain or "").lstrip(".")
            if not _matches_domain(domain, ("instagram.com", "cdninstagram.com")):
                continue
            if cookie.expires and cookie.expires <= time.time():
                continue
            item = {
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path or "/",
                "secure": bool(cookie.secure),
                "httpOnly": cookie.has_nonstandard_attr("HttpOnly"),
            }
            if cookie.expires and cookie.expires <= 253_402_300_799:
                item["expires"] = cookie.expires
            result.append(item)
    except (DownloadCancelledError, KeyboardInterrupt, SystemExit):
        # Cancellation and interpreter-exit signals are never cookie failures.
        raise
    except Exception as exc:
        diagnostic = public_cookie_diagnostic_code(chrome_cookie_diagnostic(profile, exc))
        raise TemporaryAccessError(
            "Instagram Chrome cookies could not be read. Quit Chrome and retry, or "
            f"disable Chrome Cookie explicitly. Diagnostic: {diagnostic}.",
            issue_code=SiteIssueCode.COOKIE_UNAVAILABLE,
            diagnostic_code=diagnostic,
        ) from exc
    return result


def has_login_cookie(cookies: list[dict]) -> bool:
    return any(cookie.get("name") == "sessionid" for cookie in cookies)


def best_image_asset(info: dict) -> RemoteAsset | None:
    """Build the highest declared-size image rendition from pipeline info.

    Instagram exposes an image post's renditions as thumbnail entries, and the
    largest one matches the post's declared size, so it is the highest available
    quality rather than a preview. Same-dimension alternates are kept as backups
    so one expired signature does not fail the whole image. A candidate without
    its own width and height can never be claimed as the highest quality, so it
    is skipped.
    """
    thumbnails = info.get("thumbnails")
    if not isinstance(thumbnails, list):
        return None
    best: tuple[list[str], int, int] | None = None
    best_pixels = -1
    for entry in thumbnails:
        item = _object(entry)
        url = item.get("url")
        if not isinstance(url, str) or not is_media_url(url):
            continue
        width = _positive(item.get("width"))
        height = _positive(item.get("height"))
        if not (width and height):
            continue
        pixels = width * height
        if pixels > best_pixels:
            best_pixels = pixels
            best = ([url], width, height)
        elif best is not None and (width, height) == best[1:]:
            if url not in best[0]:
                best[0].append(url)
    if best is None:
        return None
    urls, width, height = best
    return RemoteAsset(candidates=urls, index=1, width=width, height=height)


def post_shortcode(info: dict) -> str | None:
    """Read a post's own shortcode from media-pipeline info."""
    value = info.get("id")
    if isinstance(value, str) and re.fullmatch(SHORTCODE_PATTERN, value):
        return value
    return None


def info_has_video(info: dict) -> bool:
    """True when the pipeline resolved at least one playable rendition.

    An image post legitimately has no video rendition, so this is the shape of
    the data rather than a failure, and it decides which download path a part
    takes.
    """
    formats = info.get("formats")
    return bool(isinstance(formats, list) and formats)


def pipeline_upload_date(info: dict) -> str | None:
    """Normalize the pipeline's compact date into the project date format."""
    value = info.get("upload_date")
    if isinstance(value, str) and re.fullmatch(r"[0-9]{8}", value):
        return f"{value[0:4]}-{value[4:6]}-{value[6:8]}"
    return None


def _pipeline_author(info: dict) -> tuple[str, str]:
    """Read the post's real author identity as the pipeline reports it."""
    author_id = ""
    for key in ("uploader_id", "channel_id"):
        value = info.get(key)
        if value is not None:
            author_id = str(value)
            break
    author = info.get("uploader") or info.get("channel") or ""
    return author_id, str(author or author_id)


def _pipeline_title(info: dict) -> str:
    value = info.get("title")
    if isinstance(value, str) and value.strip():
        return value.strip()[:MAX_TITLE_CHARACTERS]
    return "Untitled Instagram post"


def identity_mismatch(
    info: dict,
    *,
    expected_shortcode: str,
    expected_author_id: str = "",
) -> str | None:
    """Compare what the pipeline actually resolved against the queued identity.

    Returns ``None`` when this resolved entry *is* the queued part, so its
    transfer may proceed. Otherwise it returns a short, user-safe reason: the
    caller skips or rejects the entry instead of fetching bytes for a different
    post or a different author.

    Only the pipeline's own reported identity counts. The queued shortcode and
    author were recorded at discovery time, so re-reading them here would prove
    nothing; this reads ``id`` and the uploader fields the extractor resolved for
    the address it was actually given.

    A carousel is handled explicitly rather than by comparing raw identifiers. A
    child address resolves to that child, while a parent address resolves to a
    playlist whose entries carry their own child shortcodes, so a parent/child
    difference is not evidence of a different post: the expected child is looked
    for among the entries. Missing identity is never treated as a match, because
    an unproven post cannot be shown to belong to this author.
    """
    entries = info.get("entries")
    is_playlist = entries is not None or str(info.get("_type") or "").lower() in {
        "playlist",
        "multi_video",
    }
    if is_playlist:
        if not isinstance(entries, list) or not entries:
            return "Instagram expanded this post into an empty list"
        resolved = [
            post_shortcode(_object(entry))
            for entry in entries
            if isinstance(entry, dict)
        ]
        if expected_shortcode in resolved:
            return None
        return (
            "Instagram expanded this post into a list that does not contain the "
            "queued part"
        )

    actual_shortcode = post_shortcode(info)
    if not actual_shortcode:
        return "Instagram did not report a verifiable post identity"
    if actual_shortcode != expected_shortcode:
        return "Instagram resolved a different post than the one queued"

    if not expected_author_id:
        return None
    actual_author_id, _ = _pipeline_author(info)
    if not actual_author_id:
        return "Instagram did not report a verifiable post author"
    if actual_author_id != expected_author_id:
        return "Instagram resolved a post by a different author"
    return None


def _part_from_pipeline(info: dict, position: int) -> tuple[WorkPart | None, str | None]:
    """Build one downloadable part from a resolved post or carousel member.

    A video part keeps only its canonical address: the media pipeline resolves a
    higher verified rendition than the in-page list offers, so pinning an in-page
    URL would silently downgrade quality. An image part carries its highest
    declared-size rendition. Returns ``None`` with a fixed reason code when the
    member cannot be built, so a dropped album part is reported rather than
    silently shrinking the post.
    """
    shortcode = post_shortcode(info)
    if not shortcode:
        return None, PROBLEM_PART_MISSING_IDENTITY
    if info_has_video(info):
        return WorkPart(
            position=position,
            kind="video",
            media_id=shortcode,
            url=canonical_post_url(shortcode),
            width=_positive(info.get("width")),
            height=_positive(info.get("height")),
        ), None
    asset = best_image_asset(info)
    if asset is None:
        return None, PROBLEM_PART_NO_MEDIA
    return WorkPart(
        position=position,
        kind="image",
        media_id=shortcode,
        url=canonical_post_url(shortcode),
        assets=[asset],
        width=asset.width,
        height=asset.height,
    ), None


def works_from_pipeline_info(info: dict, *, shortcode: str | None = None) -> list[Work]:
    """Build works from media-pipeline info for one requested post.

    A carousel expands into one entry per part and each entry carries its own
    shortcode, so every part is built separately and can be downloaded, retried
    or resumed on its own. A carousel parent shortcode cannot be resolved
    directly, which is exactly why the parts, not the parent, are queued. A
    member that cannot be built is recorded with its own position so the caller
    can report a partial album instead of claiming every part was queued.
    """
    info = _object(info)
    entries = info.get("entries")
    if isinstance(entries, list) and entries:
        parts: list[WorkPart] = []
        unresolved: list[tuple[int, str]] = []
        for index, entry in enumerate(entries, start=1):
            part, reason = _part_from_pipeline(_object(entry), index)
            if part is None:
                unresolved.append((index, reason or PROBLEM_PART_NO_MEDIA))
            else:
                parts.append(part)
        parent = shortcode or post_shortcode(info)
        if not parts or not parent:
            return []
        author_id, author = _pipeline_author(info)
        return [
            Work(
                media_id=parent,
                author_id=author_id,
                author=author,
                title=_pipeline_title(info),
                upload_date=pipeline_upload_date(info),
                parts=parts,
                kind=_work_kind(parts),
                declared_part_count=len(entries),
                unresolved_parts=unresolved,
            )
        ]
    resolved = shortcode or post_shortcode(info)
    part, _reason = _part_from_pipeline(info, 1)
    if part is None or not resolved:
        return []
    author_id, author = _pipeline_author(info)
    return [
        Work(
            media_id=resolved,
            author_id=author_id,
            author=author,
            title=_pipeline_title(info),
            upload_date=pipeline_upload_date(info),
            parts=[part],
            kind=part.kind,
            declared_part_count=1,
        )
    ]


def discover(
    url: str,
    *,
    cookie_profile: str | None = None,
    use_browser_cookies: bool = False,
    should_cancel: Callable[[], bool] = lambda: False,
    status_callback: Callable[[str], None] | None = None,
) -> Result:
    """Enumerate one Instagram profile's posts by observing its own pagination.

    Single posts are not resolved here; the caller routes them through the media
    pipeline. See the module docstring for why a post page cannot be scraped.
    """
    kind, identity = source_identity(url)
    if should_cancel():
        raise DownloadCancelledError("Task cancelled")
    if kind != "profile":
        raise DiscoveryError(
            "Instagram single posts are resolved through the media pipeline"
        )
    cookies = _browser_cookies(cookie_profile) if use_browser_cookies else []
    if use_browser_cookies and not has_login_cookie(cookies):
        # A private or age-restricted profile silently renders nothing without a
        # session. Reporting that as an empty profile would hide the real cause.
        raise AuthenticationRequiredError(LOGIN_REQUIRED, verification_url=url)
    if status_callback:
        status_callback("Opening Instagram in Chrome to read verified post metadata")
    return _discover_profile(
        url,
        identity,
        cookies,
        should_cancel=should_cancel,
        status_callback=status_callback,
    )


def describe_item_failure(message: str) -> DiscoveryError | AuthenticationRequiredError:
    """Map a media-pipeline failure for one post onto an actionable category.

    A single image or carousel post has no video rendition, so the pipeline
    reports "no video formats". That is an access-shape fact, not a bug, and the
    user needs to know to use the author's profile instead.
    """
    text = str(message or "").lower()
    if any(marker in text for marker in ("login", "log in", "authentication", "private")):
        return AuthenticationRequiredError(LOGIN_REQUIRED, verification_url="")
    if "no video formats" in text or "unsupported url" in text:
        return DiscoveryError(IMAGE_POST_NEEDS_PROFILE)
    return DiscoveryError(
        "Instagram returned no verifiable media for this post; nothing was queued."
    )


BLOCKED_RESOURCE_TYPES = frozenset({"Image", "Media", "Font"})


def _install_request_gate(
    context,
    page,
    *,
    should_cancel: Callable[[], bool],
    on_error: Callable[[Exception], None],
    is_trusted_page: Callable[[str], bool] | None = None,
    is_trusted_host: Callable[[str], bool] | None = None,
    blocked_resource_types: frozenset[str] = BLOCKED_RESOURCE_TYPES,
):
    """Gate every request before Chromium dispatches it, including redirect hops.

    CDP ``Fetch`` pauses each request at the ``Request`` stage, which is the only
    point where a redirect hop can still be stopped. Playwright routing cannot do
    this: a native continue never re-enters the route handler, so an allowlist
    enforced there only ever sees the first request of a chain, and an untrusted
    target has already been contacted by the time an observer event arrives.

    Trusted requests are released with ``continueRequest`` instead of being
    fetched and fulfilled here. Relaying bytes through this process was measured
    to stall a real profile page: loading stopped after roughly sixty responses
    and the profile component never mounted, so the site never issued the
    timeline request. Releasing natively keeps the page's own script running
    while still deciding every request before it leaves the browser. Nothing is
    downloaded here, so there is no path that could fall back to a direct
    connection when the configured proxy fails.

    Both predicates default to the production rules. A caller may inject
    substitutes so a regression can drive this exact code against loopback
    origins; that substitution stays in the test and never widens the shipped
    allowlist.
    """
    trusted_page = is_trusted_page if is_trusted_page is not None else is_page_url
    if is_trusted_host is not None:
        trusted_host = is_trusted_host
    else:

        def trusted_host(value: str) -> bool:
            host = _secure_host(value)
            return bool(host and _matches_domain(host, BROWSER_DOMAINS))

    cdp = context.new_cdp_session(page)
    # The first document is the main-frame navigation; later documents belong to
    # subframes. Keeping that distinction stops a trusted non-page frame from
    # being judged as a navigation away from the profile.
    main_frame_id: list[str] = []

    def block_request(request_id: str) -> None:
        with contextlib.suppress(PlaywrightError):
            cdp.send(
                "Fetch.failRequest",
                {"requestId": request_id, "errorReason": "BlockedByClient"},
            )

    def release_request(request_id: str) -> None:
        with contextlib.suppress(PlaywrightError):
            cdp.send("Fetch.continueRequest", {"requestId": request_id})

    def gate_request(params: dict) -> None:
        """Decide one paused request before it reaches its target."""
        request_id = str(params.get("requestId") or "")
        try:
            if should_cancel():
                block_request(request_id)
                return
            url = str((params.get("request") or {}).get("url") or "")
            resource_type = str(params.get("resourceType") or "")
            frame_id = str(params.get("frameId") or "")
            if resource_type == "Document":
                if not main_frame_id:
                    main_frame_id.append(frame_id)
                is_main_navigation = frame_id == main_frame_id[0]
            else:
                is_main_navigation = False
            allowed = trusted_page(url) if is_main_navigation else trusted_host(url)
            if not allowed:
                # Reaching an off-site origin at all is a boundary violation worth
                # surfacing, not merely a request to drop, so every untrusted
                # request fails discovery exactly as the observer it replaces did.
                on_error(
                    DiscoveryError(
                        "Instagram redirected outside trusted pages; navigation "
                        "was blocked"
                    )
                )
            if not allowed or resource_type in blocked_resource_types:
                # Discovery never needs pixels: the timeline response carries the
                # metadata. Skipping these keeps the browser budget for pagination
                # instead of thumbnails, measured on a real profile to avoid over
                # a hundred requests without stopping the timeline query.
                block_request(request_id)
                return
            release_request(request_id)
        except (AttributeError, TypeError, PlaywrightError):
            # A malformed CDP payload or a failed protocol round trip must not
            # leave the request paused, which would hang the page. Blocking is the
            # conservative default and the discovery loop surfaces the failure
            # instead of continuing silently.
            #
            # This is deliberately narrow: the gate never classifies a site
            # problem, it only reports through ``on_error`` for the loop to raise,
            # so nothing a caller must see can be swallowed here. An unexpected
            # error from ``should_cancel`` still propagates.
            block_request(request_id)
            on_error(
                TemporaryAccessError(
                    "Instagram browser request could not be gated, so it was "
                    "blocked. Check the configured proxy and network; no direct "
                    "fallback was attempted.",
                    issue_code=SiteIssueCode.NETWORK_ERROR,
                )
            )

    cdp.on("Fetch.requestPaused", gate_request)
    cdp.send(
        "Fetch.enable",
        {
            "handleAuthRequests": False,
            "patterns": [{"urlPattern": "*", "requestStage": "Request"}],
        },
    )
    return cdp


def _discover_profile(
    url: str,
    username: str,
    cookies: list[dict],
    *,
    should_cancel: Callable[[], bool],
    status_callback: Callable[[str], None] | None,
) -> Result:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        cdp = None
        try:
            context = browser.new_context(
                user_agent=chrome_user_agent(browser.version),
                viewport={"width": 1280, "height": 900},
                service_workers="block",
            )
            if cookies:
                context.add_cookies(cookies)
            page = context.new_page()
            page.set_default_timeout(8000)
            errors: list[Exception] = []
            # A recoverable interruption (rate limit, transient site or network
            # failure) stops pagination but must not discard already verified
            # works, so it is tracked separately from fatal errors.
            interruption: list[Exception] = []
            collector = ProfileCollector(username, url)
            navigation = {"url": url}

            cdp = _install_request_gate(
                context,
                page,
                should_cancel=should_cancel,
                on_error=errors.append,
            )

            def track_navigation(frame):
                """Record the URL the main frame actually committed to.

                This is stronger than checking each requested hop: it observes the
                final rendered location, so a chain that ends on an unrelated
                account or a non-profile page is rejected by the identity check.
                """
                if frame != page.main_frame:
                    return
                navigation["url"] = frame.url
                if not is_page_url(frame.url):
                    errors.append(
                        DiscoveryError(
                            "Instagram redirected outside trusted pages; "
                            "navigation was blocked"
                        )
                    )


            def observe(response):
                if should_cancel() or not is_page_url(response.url):
                    return
                request = response.request
                if request.method != "POST":
                    return
                if urlsplit(response.url).path not in GRAPHQL_PATHS:
                    return
                try:
                    post_data = request.post_data
                    operation = _form_field(post_data, "fb_api_req_friendly_name")
                    if operation == PROFILE_CONTENT_OPERATION:
                        raw = response.body()
                        if len(raw) > MAX_RESPONSE_BYTES:
                            return
                        payload = _object(json.loads(raw))
                        response_error(payload, url)
                        collector.accept_profile_content(payload)
                        return
                    if operation not in TIMELINE_OPERATIONS:
                        # Any other operation is another surface (home feed,
                        # reels tab, inbox). It is never this author's list.
                        return
                    requested = requested_username(post_data)
                    if requested and requested.lower() != username.lower():
                        return
                    size = response.headers.get("content-length", "0")
                    if size.isdigit() and int(size) > MAX_RESPONSE_BYTES:
                        raise DiscoveryError(
                            "Instagram response exceeded the safe size limit"
                        )
                    raw = response.body()
                    if len(raw) > MAX_RESPONSE_BYTES:
                        raise DiscoveryError(
                            "Instagram response exceeded the safe size limit"
                        )
                    payload = _object(json.loads(raw))
                    response_error(payload, url)
                    _, page_info = timeline_nodes(payload)
                    collector.accept(
                        payload,
                        cursor=requested_cursor(post_data),
                        page_info=page_info,
                    )
                except (
                    AuthenticationRequiredError,
                    TemporaryAccessError,
                    DiscoveryError,
                ) as exc:
                    if is_recoverable_profile_interruption(exc, paginating=True):
                        interruption.append(exc)
                    else:
                        errors.append(exc)
                except (PlaywrightError, TypeError, ValueError):
                    # Telemetry and responses that close during teardown must not
                    # become a false login or verification requirement.
                    return

            # The gate is already armed by ``_install_request_gate``: it paused
            # every request at the Request stage and released or blocked it before
            # dispatch. The committed main-frame URL is still tracked separately:
            # gating bounds what can be contacted, while this bounds what was
            # actually rendered, so a chain that ends on another account or a
            # non-profile page is rejected by the identity check below.
            page.on("framenavigated", track_navigation)
            page.on("response", observe)
            started = time.monotonic()
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
            except Exception as exc:
                if should_cancel():
                    raise DownloadCancelledError("Task cancelled") from exc
                if errors:
                    raise errors[0]
                raise TemporaryAccessError(
                    "Instagram page could not be opened. Check the configured "
                    "proxy and network.",
                    issue_code=SiteIssueCode.NETWORK_ERROR,
                ) from exc

            idle = 0
            previous_count = -1
            retry_attempts = 0
            interrupted_reason: Exception | None = None
            while time.monotonic() - started < MAX_BROWSER_SECONDS:
                if should_cancel():
                    raise DownloadCancelledError("Task cancelled")
                if errors:
                    raise errors[0]
                if interruption:
                    # The site stopped serving further pages. Retry from the same
                    # expected cursor with a bounded backoff so already verified
                    # works survive; never discard them on a transient failure.
                    interrupted_reason = interruption[0]
                    if retry_attempts >= PROFILE_RETRY_ATTEMPTS:
                        break
                    delay = min(
                        PROFILE_RETRY_MAX_SECONDS,
                        PROFILE_RETRY_BASE_SECONDS * (2**retry_attempts),
                    )
                    if MAX_BROWSER_SECONDS - (time.monotonic() - started) <= delay:
                        break
                    retry_attempts += 1
                    if status_callback:
                        status_callback(
                            "Instagram rate limited the profile; waiting before "
                            f"continuing ({retry_attempts}/{PROFILE_RETRY_ATTEMPTS})"
                        )
                    waited = 0.0
                    while waited < delay:
                        if should_cancel():
                            raise DownloadCancelledError("Task cancelled")
                        page.wait_for_timeout(200)
                        waited += 0.2
                    interruption.clear()
                    idle = 0
                    previous_count = len(collector.works)
                    continue

                final_kind, final_id = source_identity(navigation["url"])
                if final_kind != "profile" or final_id.lower() != username.lower():
                    raise DiscoveryError(
                        "Instagram navigated to a different page; the response was blocked"
                    )

                count = len(collector.works)
                if count != previous_count:
                    idle = 0
                    previous_count = count
                    if status_callback:
                        status_callback(
                            f"Instagram: verified {count} posts across {collector.pages} pages"
                        )
                else:
                    idle += 1
                collector.finalize()
                if (
                    collector.terminal
                    or count >= MAX_PROFILE_ITEMS
                    or collector.pages >= MAX_PROFILE_PAGES
                    or idle >= MAX_IDLE_ROUNDS
                ):
                    break
                # Scroll the site's real list. Its own JavaScript generates the
                # pagination request; nothing is signed or replayed here.
                with contextlib.suppress(PlaywrightError):
                    page.evaluate(
                        """() => {
                          window.scrollBy(0, window.innerHeight * 0.9);
                          window.scrollTo(0, document.documentElement.scrollHeight);
                        }"""
                    )
                if count == 0 and time.monotonic() - started > EMPTY_PROFILE_SECONDS:
                    _raise_for_visible_block(page, url)
                for _ in range(6):
                    if should_cancel():
                        raise DownloadCancelledError("Task cancelled")
                    page.wait_for_timeout(200)

            collector.finalize()
            if errors:
                raise errors[0]
            interrupted = bool(interruption) or interrupted_reason is not None
            reason = interruption[0] if interruption else interrupted_reason
            if interrupted and not collector.works:
                # Nothing was verified, so this is a real failure rather than a
                # partial result. Reporting it as an empty profile would hide a
                # rate limit or a transient site problem.
                raise TemporaryAccessError(
                    "Instagram stopped serving the profile feed before any post "
                    "could be verified, so nothing was queued. Wait a few minutes, "
                    "then retry the original profile. Reason category: "
                    f"{_interruption_category(reason)}.",
                    issue_code=(
                        getattr(reason, "issue_code", None) or SiteIssueCode.REQUEST_REJECTED
                    ),
                ) from reason
            if not collector.works:
                _raise_for_visible_block(page, url)
                if cookies and collector.declared_count:
                    raise AuthenticationRequiredError(LOGIN_REQUIRED, verification_url=url)
                raise DiscoveryError(NO_VERIFIED_POSTS)

            warning = _completion_warning(collector, interrupted, reason)
            return Result(
                list(collector.works.values()),
                "profile",
                username,
                collector.complete,
                warning,
                collector.declared_count,
            )
        finally:
            # Disable the gate before the browser closes so no request is left
            # paused on a session that is about to disappear. The session stays
            # None if launch or context setup failed before it was created.
            if cdp is not None:
                with contextlib.suppress(PlaywrightError):
                    cdp.send("Fetch.disable")
                with contextlib.suppress(PlaywrightError):
                    cdp.detach()
            browser.close()


def _completion_warning(
    collector: ProfileCollector, interrupted: bool, reason: BaseException | None
) -> str | None:
    """Report incompleteness honestly instead of implying a full profile."""
    warning: str | None = None
    if not collector.complete:
        warning = PROFILE_INCOMPLETE
        if interrupted:
            warning = (
                f"{PROFILE_INTERRUPTED} Reason category: "
                f"{_interruption_category(reason)}."
            )
    elif collector.declared_count and len(collector.works) < collector.declared_count:
        # The site confirmed the end of the list, so enumeration itself finished.
        # A gap against the author's declared total means some posts are not
        # reachable through the timeline (pinned, hidden or removed). That is
        # reported rather than passed over as if everything had been queued.
        missing = collector.declared_count - len(collector.works)
        warning = (
            f"Instagram confirmed the end of this profile's list, but {missing} of "
            f"the {collector.declared_count} declared posts were not served in the "
            "timeline, so they were not queued. Pinned, hidden or removed posts "
            "cannot be enumerated from the profile grid."
        )
    summary = problem_summary(collector)
    if summary:
        warning = f"{warning} {summary}" if warning else summary
    part_summary = part_problem_summary(collector)
    if part_summary:
        warning = f"{warning} {part_summary}" if warning else part_summary
    return warning


def _raise_for_visible_block(page: Any, url: str) -> None:
    """Raise only for an explicit site dialog, never for arbitrary page text.

    A caption or comment can legitimately contain words such as "deleted" or
    "login". Only a real dialog or error container is evidence of a block.
    """
    with contextlib.suppress(Exception):
        title = (page.title() or "").lower()
        if any(marker in title for marker in ("domain blocked", "website filtered")):
            raise TemporaryAccessError(
                "Instagram was blocked by the local DNS or web filter. Check the "
                "configured proxy or network policy.",
                issue_code=SiteIssueCode.NETWORK_ERROR,
            )
    with contextlib.suppress(Exception):
        notices = page.locator(
            "[role='dialog'], [class*='captcha'], [class*='checkpoint'], "
            "[class*='error-page'], [class*='RnEpo']"
        ).all_inner_texts()
        for notice in notices[:10]:
            response_error({"message": notice[:4000]}, url)
