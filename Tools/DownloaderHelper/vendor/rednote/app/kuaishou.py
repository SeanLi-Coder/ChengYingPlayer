# ChengYing integration; not part of the original upstream snapshot.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Observe Kuaishou's normal browser responses without replaying signed APIs."""

from __future__ import annotations

import contextlib
import json
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urljoin, urlsplit

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

from .browser import chrome_user_agent
from .errors import (
    AuthenticationRequiredError,
    DiscoveryError,
    DownloadCancelledError,
    SiteIssueCode,
    TemporaryAccessError,
)
from .xiaohongshu import RemoteAsset, _extract_chrome_cookies

PAGE_HOSTS = {"kuaishou.com", "www.kuaishou.com", "v.kuaishou.com", "m.gifshow.com"}
MEDIA_DOMAINS = (
    "kwaicdn.com",
    "ksyuncdn.com",
    "ksapisrv.com",
    "yximgs.com",
    "kwimgs.com",
)
BROWSER_DOMAINS = (*MEDIA_DOMAINS, "kuaishou.com", "gifshow.com", "gifshowstatic.com")
ID_PATTERN = r"[A-Za-z0-9_-]{1,80}"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_PROFILE_PAGES = 500
MAX_PROFILE_ITEMS = 10_000
MAX_BROWSER_SECONDS = 300
PROFILE_INCOMPLETE = (
    "Kuaishou profile discovery is incomplete. Only verified videos were queued; "
    "retry the original profile to continue. The site did not confirm the end of the list."
)


def fulfill_checked_route(
    route,
    *,
    allowed: Callable[[str], bool],
    should_cancel: Callable[[], bool],
    max_redirects: int = 5,
    defer_navigation_redirects: bool = False,
) -> str:
    """Check every redirect before its request; Playwright routing alone cannot."""
    request = route.request
    current_url = request.url
    method = request.method
    body = request.post_data_buffer
    headers = {
        name: value
        for name, value in request.headers.items()
        if name.lower()
        not in {"cookie", "authorization", "proxy-authorization", "host"}
    }
    deadline = time.monotonic() + 30
    for hop in range(max_redirects + 1):
        if should_cancel():
            raise DownloadCancelledError("Task cancelled")
        if not allowed(current_url):
            raise DiscoveryError(
                "Kuaishou redirected outside trusted pages; navigation was blocked"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TemporaryAccessError(
                "Kuaishou browser request timed out",
                issue_code=SiteIssueCode.NETWORK_ERROR,
            )
        # route.continue_() would let Chromium follow redirects without running
        # our route handler again. route.fetch() uses the same browser-context
        # proxy and cookie jar, with redirects explicitly disabled here.
        response = route.fetch(
            url=current_url,
            method=method,
            post_data=body,
            headers=headers,
            max_redirects=0,
            timeout=max(1, int(remaining * 1000)),
        )
        try:
            if not allowed(response.url):
                raise DiscoveryError("Kuaishou returned an untrusted browser response")
            if response.status in {301, 302, 303, 307, 308}:
                target = urljoin(current_url, response.headers.get("location", ""))
                if (
                    not response.headers.get("location")
                    or hop == max_redirects
                    or not allowed(target)
                ):
                    raise DiscoveryError(
                        "Kuaishou redirected outside trusted pages or exceeded the redirect limit; navigation was blocked"
                    )
                if (
                    method not in {"GET", "HEAD"}
                    and urlsplit(target).netloc != urlsplit(current_url).netloc
                ):
                    raise DiscoveryError(
                        "Kuaishou cross-origin browser submission redirect was blocked"
                    )
                if (
                    response.status == 303
                    or response.status in {301, 302}
                    and method == "POST"
                ):
                    method, body = "GET", None
                    headers = {
                        name: value
                        for name, value in headers.items()
                        if name.lower() not in {"content-length", "content-type"}
                    }
                current_url = target
                continue
            if should_cancel():
                raise DownloadCancelledError("Task cancelled")
            if defer_navigation_redirects and current_url != request.url:
                # Do not execute the destination HTML at the short-link origin.
                # The caller performs a normal navigation to this checked URL.
                route.fulfill(
                    status=200,
                    body="<!doctype html><title>Loading</title>",
                    headers={"content-type": "text/html; charset=utf-8"},
                )
            else:
                route.fulfill(response=response)
            return current_url
        finally:
            response.dispose()
    raise DiscoveryError("Kuaishou browser redirect limit exceeded")


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


def source_identity(value: str) -> tuple[str, str]:
    if not is_page_url(value):
        raise DiscoveryError("Kuaishou URL is not a trusted HTTPS page")
    parsed = urlsplit(value)
    path = parsed.path.rstrip("/")
    if parsed.hostname == "v.kuaishou.com":
        match = re.fullmatch(rf"/({ID_PATTERN})", path)
        if match:
            return "short_link", match[1]
    elif parsed.hostname == "m.gifshow.com":
        match = re.fullmatch(rf"/fw/(photo|user)/({ID_PATTERN})", path)
        if match:
            return ("item" if match[1] == "photo" else "profile"), match[2]
    else:
        match = re.fullmatch(rf"/(short-video|profile|f)/({ID_PATTERN})", path)
        if match:
            return {"short-video": "item", "profile": "profile", "f": "short_link"}[
                match[1]
            ], match[2]
    raise DiscoveryError("Unsupported Kuaishou video, profile, or share URL")


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


def _urls(value: Any) -> list[str]:
    if isinstance(value, dict):
        value = value.get("url")
    if isinstance(value, str):
        return [value] if is_media_url(value) else []
    if isinstance(value, list):
        return list(dict.fromkeys(url for entry in value[:100] for url in _urls(entry)))
    return []


@dataclass(slots=True)
class Video:
    media_id: str
    author_id: str
    author: str
    title: str
    upload_date: str | None
    assets: list[RemoteAsset] = field(default_factory=list)

    @property
    def url(self) -> str:
        return f"https://www.kuaishou.com/short-video/{self.media_id}"


@dataclass(slots=True)
class Result:
    videos: list[Video]
    source_kind: str
    source_id: str
    complete: bool = True
    warning: str | None = None


def parse_video(
    value: dict, *, expected_id: str | None = None, owner_id: str | None = None
) -> Video:
    photo = _object(value.get("photo"))
    author = _object(value.get("author"))
    media_id, author_id = str(photo.get("id") or ""), str(author.get("id") or "")
    if not re.fullmatch(ID_PATTERN, media_id) or not re.fullmatch(
        ID_PATTERN, author_id
    ):
        raise DiscoveryError("Kuaishou returned missing video or author identity")
    if expected_id and media_id != expected_id:
        raise DiscoveryError(
            "Kuaishou returned a different video; the response was blocked"
        )
    if owner_id and author_id != owner_id:
        raise DiscoveryError(
            "Kuaishou profile video belongs to a different author; the response was blocked"
        )
    # Do not reconstruct alternate streams or remove watermarks. Use only URLs
    # that the real page returned for this exact, identity-bound video.
    duration_ms = _positive(photo.get("duration"))
    duration = duration_ms / 1000 if duration_ms else None
    assets: list[RemoteAsset] = []
    bitrate_ranks: dict[int, int] = {}
    for field_name in ("manifest", "manifestH265", "videoResource"):
        manifest = _object(photo.get(field_name))
        roots = [manifest]
        if field_name == "videoResource":
            roots.extend(_object(manifest.get(key)) for key in ("h264", "hevc", "h265"))
        for root in roots:
            sets = root.get("adaptationSet", [])
            if isinstance(sets, dict):
                sets = [sets]
            if not isinstance(sets, list):
                continue
            for adaptation in sets[:20]:
                representations = _object(adaptation).get("representation", [])
                if not isinstance(representations, list):
                    continue
                for representation in representations[:100]:
                    rep = _object(representation)
                    candidates = _urls(rep.get("url")) + _urls(rep.get("backupUrl"))
                    if candidates:
                        codec_name = str(
                            rep.get("videoCodec") or root.get("videoCodec") or ""
                        ).lower()
                        codec = {
                            "avc": "h264",
                            "h264": "h264",
                            "avc1": "h264",
                            "hevc": "hevc",
                            "h265": "hevc",
                            "hev1": "hevc",
                            "hvc1": "hevc",
                            "av1": "av1",
                        }.get(codec_name)
                        size = _positive(rep.get("fileSize"))
                        assets.append(
                            RemoteAsset(
                                candidates=list(dict.fromkeys(candidates)),
                                index=1,
                                width=_positive(rep.get("width")),
                                height=_positive(rep.get("height")),
                                format_id="kuaishou-"
                                + str(rep.get("id") or field_name),
                                duration=duration,
                                size=size,
                                video_codec=codec,
                            )
                        )
                        # avgBitrate's unit is not a stable API contract. It is
                        # used only for relative ordering within the same codec;
                        # Byte size and duration are checked independently. A
                        # container bitrate (size / duration) must not become
                        # a video-stream bitrate floor when audio is present.
                        bitrate_ranks[id(assets[-1])] = (
                            _positive(rep.get("avgBitrate")) or 0
                        )
    for name in ("photoUrl", "photoH265Url", "photoUrls"):
        candidates = _urls(photo.get(name))
        if candidates:
            assets.append(
                RemoteAsset(
                    candidates=candidates,
                    index=1,
                    format_id="kuaishou-" + name,
                    duration=duration,
                )
            )
    floor = max(assets, key=lambda a: (a.width or 0) * (a.height or 0), default=None)
    highest = (floor.width or 0) * (floor.height or 0) if floor else 0
    codec_best: dict[str | None, int] = {}
    for asset in assets:
        if (asset.width or 0) * (asset.height or 0) == highest:
            codec_best[asset.video_codec] = max(
                codec_best.get(asset.video_codec, 0), bitrate_ranks.get(id(asset), 0)
            )
    selected = []
    seen = set()
    for asset in sorted(
        assets, key=lambda a: (a.width or 0) * (a.height or 0), reverse=True
    ):
        pixels = (asset.width or 0) * (asset.height or 0)
        if highest and pixels and pixels < highest:
            continue
        if highest and not pixels:
            # A generic photoUrl may point to the lower default representation.
            # Once the page declares sized variants, do not silently fall back.
            continue
        if asset.video_codec and bitrate_ranks.get(id(asset), 0) < codec_best.get(
            asset.video_codec, 0
        ):
            continue
        asset.candidates = [url for url in asset.candidates if url not in seen]
        seen.update(asset.candidates)
        if asset.candidates:
            selected.append(asset)
    timestamp = _positive(photo.get("timestamp"))
    upload_date = None
    if timestamp:
        with contextlib.suppress(OverflowError, OSError, ValueError):
            upload_date = (
                datetime.fromtimestamp(timestamp / 1000, timezone.utc)
                .date()
                .isoformat()
            )
    return Video(
        media_id,
        author_id,
        str(author.get("name") or author_id),
        str(
            photo.get("caption")
            or photo.get("originCaption")
            or "Untitled Kuaishou video"
        ),
        upload_date,
        selected,
    )


def response_error(payload: dict, source_url: str) -> None:
    code = payload.get("result")
    message = str(
        payload.get("error_msg")
        or payload.get("errorMessage")
        or payload.get("message")
        or ""
    )
    lower = message.lower()
    if any(word in lower for word in ("captcha", "验证码", "安全验证", "滑块")):
        raise AuthenticationRequiredError(
            "Kuaishou requires security verification. Open Chrome to complete the challenge, then retry.",
            verification_url=source_url,
            issue_code=SiteIssueCode.VERIFICATION_REQUIRED,
        )
    if code in (109, 401) or any(
        word in lower
        for word in ("未登录", "请先登录", "登录后查看", "登录后继续", "login required")
    ):
        raise AuthenticationRequiredError(
            "Kuaishou requires login. Open Chrome to sign in, enable Chrome Cookie, then retry.",
            verification_url=source_url,
            issue_code=SiteIssueCode.LOGIN_REQUIRED,
        )
    if code == 429 or any(
        word in lower for word in ("频繁", "too many requests", "rate limit")
    ):
        raise TemporaryAccessError(
            "Kuaishou rate limited this request. Wait before retrying.",
            issue_code=SiteIssueCode.RATE_LIMITED,
        )
    if any(
        word in lower
        for word in ("不存在", "已删除", "不可见", "private", "deleted", "not found")
    ):
        raise TemporaryAccessError(
            "Kuaishou video is deleted, private, or unavailable.",
            issue_code=SiteIssueCode.CONTENT_UNAVAILABLE,
        )
    if code is not None and code != 1:
        raise TemporaryAccessError(
            "Kuaishou rejected the page request. Retry later; no verification bypass was attempted.",
            issue_code=SiteIssueCode.REQUEST_REJECTED,
        )


def _resolve_refs(
    value: Any, cache: dict, seen: frozenset = frozenset(), depth: int = 0
) -> Any:
    if depth > 16:
        return None
    if isinstance(value, dict):
        ref = value.get("__ref") or (
            value.get("id") if value.get("type") == "id" else None
        )
        if isinstance(ref, str) and ref in cache:
            if ref in seen:
                return None
            return _resolve_refs(cache[ref], cache, seen | {ref}, depth + 1)
        return {
            key: _resolve_refs(item, cache, seen, depth + 1)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [
            _resolve_refs(item, cache, seen, depth + 1)
            for item in value[:MAX_PROFILE_ITEMS]
        ]
    return value


def apollo_operations(
    state: Any, operation: str, identity_name: str, identity: str
) -> list[tuple[dict, dict]]:
    cache = _object(state)
    cache = _object(cache.get("defaultClient")) or cache
    roots = list(_object(cache.get("ROOT_QUERY")).items()) + list(cache.items())
    result = []
    for key, value in roots:
        match = re.fullmatch(
            r"(?:\$?ROOT_QUERY\.)?" + re.escape(operation) + r"\((.*)\)", key
        )
        if not match:
            continue
        arguments = _object(match[1])
        if arguments.get(identity_name) != identity:
            continue
        resolved = _resolve_refs(value, cache)
        if isinstance(resolved, dict):
            result.append((arguments, resolved))
    return result


class ProfileCollector:
    """Accept only a contiguous, author-bound pagination chain, never recommendations."""

    def __init__(self, owner_id: str, source_url: str):
        self.owner_id, self.source_url = owner_id, source_url
        self.videos: dict[str, Video] = {}
        self.next_cursor = ""
        self.seen_cursors: set[str] = set()
        self.complete = False
        self.terminal = False
        self.unsupported = False

    def accept(self, payload: dict, *, owner_id: str, cursor: str) -> bool:
        if owner_id != self.owner_id or cursor in self.seen_cursors or self.terminal:
            return False
        if cursor != self.next_cursor or len(self.seen_cursors) >= MAX_PROFILE_PAGES:
            return False
        response_error(payload, self.source_url)
        feeds = payload.get("feeds")
        if not isinstance(feeds, list):
            raise TemporaryAccessError(
                "Kuaishou profile response changed; no unverified list was queued.",
                issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
            )
        for feed in feeds[:MAX_PROFILE_ITEMS]:
            video = parse_video(_object(feed), owner_id=self.owner_id)
            if not video.assets:
                self.unsupported = True
                continue
            if len(self.videos) < MAX_PROFILE_ITEMS:
                self.videos.setdefault(video.media_id, video)
            elif video.media_id not in self.videos:
                self.unsupported = True
        self.seen_cursors.add(cursor)
        next_cursor = payload.get("pcursor")
        if next_cursor == "no_more":
            self.terminal = True
            self.complete = not self.unsupported and len(feeds) <= MAX_PROFILE_ITEMS
        elif (
            isinstance(next_cursor, str)
            and next_cursor
            and next_cursor not in self.seen_cursors
        ):
            self.next_cursor = next_cursor
        return True


def _browser_cookies(profile: str | None) -> list[dict]:
    result = []
    try:
        jar = _extract_chrome_cookies(profile)
        for cookie in jar:
            domain = cookie.domain.lstrip(".")
            if not any(
                domain == root or domain.endswith("." + root)
                for root in ("kuaishou.com", "gifshow.com")
            ):
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
    except Exception as exc:
        raise TemporaryAccessError(
            "Kuaishou Chrome cookies could not be read. Quit Chrome and retry, or disable Chrome Cookie explicitly.",
            issue_code=SiteIssueCode.COOKIE_UNAVAILABLE,
        ) from exc
    return result


def discover(
    url: str,
    *,
    cookie_profile: str | None = None,
    use_browser_cookies: bool = False,
    should_cancel: Callable[[], bool] = lambda: False,
    status_callback: Callable[[str], None] | None = None,
) -> Result:
    kind, identity = source_identity(url)
    if should_cancel():
        raise DownloadCancelledError("Task cancelled")
    cookies = _browser_cookies(cookie_profile) if use_browser_cookies else []
    if should_cancel():
        raise DownloadCancelledError("Task cancelled")
    if status_callback:
        status_callback("Opening Kuaishou in Chrome to read verified video metadata")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        try:
            context = browser.new_context(
                user_agent=chrome_user_agent(browser.version),
                viewport={"width": 1280, "height": 900},
                service_workers="block",
            )
            if cookies:
                context.add_cookies(cookies)
            page = context.new_page()
            page.set_default_timeout(5000)
            errors: list[Exception] = []
            details: dict[str, Video] = {}
            collector = ProfileCollector(identity, url) if kind == "profile" else None
            navigation = {"url": url}

            def route_request(route):
                request = route.request
                if should_cancel():
                    route.abort()
                    return
                host = _secure_host(request.url)
                allowed = bool(
                    host
                    and any(
                        host == root or host.endswith("." + root)
                        for root in BROWSER_DOMAINS
                    )
                )
                is_navigation = (
                    request.is_navigation_request() and request.frame == page.main_frame
                )
                if is_navigation:
                    allowed = is_page_url(request.url)
                    if not allowed:
                        errors.append(
                            DiscoveryError(
                                "Kuaishou redirected outside trusted pages; navigation was blocked"
                            )
                        )
                if not allowed or request.resource_type in {"media", "image", "font"}:
                    route.abort()
                else:

                    def trusted_target(value):
                        if is_navigation:
                            return is_page_url(value)
                        target_host = _secure_host(value)
                        return bool(
                            target_host
                            and any(
                                target_host == root or target_host.endswith("." + root)
                                for root in BROWSER_DOMAINS
                            )
                        )

                    try:
                        final_url = fulfill_checked_route(
                            route,
                            allowed=trusted_target,
                            should_cancel=should_cancel,
                            defer_navigation_redirects=is_navigation,
                        )
                        if is_navigation:
                            navigation["url"] = final_url
                    except (
                        DiscoveryError,
                        DownloadCancelledError,
                        TemporaryAccessError,
                        PlaywrightError,
                    ) as exc:
                        if isinstance(exc, PlaywrightError):
                            if "certificate" in str(exc).lower() or "ERR_CERT" in str(
                                exc
                            ):
                                exc = TemporaryAccessError(
                                    "Kuaishou browser TLS certificate verification failed. Check the configured proxy certificate or network policy; certificate verification was not disabled.",
                                    issue_code=SiteIssueCode.NETWORK_ERROR,
                                )
                            else:
                                exc = TemporaryAccessError(
                                    "Kuaishou browser request failed. Check the configured proxy and network; no direct fallback was attempted.",
                                    issue_code=SiteIssueCode.NETWORK_ERROR,
                                )
                        if is_navigation or isinstance(
                            exc, (DiscoveryError, DownloadCancelledError)
                        ):
                            errors.append(exc)
                        with contextlib.suppress(Exception):
                            route.abort()

            def observe(response):
                if should_cancel() or not is_page_url(response.url):
                    return
                path = urlsplit(response.url).path
                if path not in {
                    "/graphql",
                    "/rest/v/profile/feed",
                    "/rest/v/photo/info",
                }:
                    return
                try:
                    request = response.request
                    body = request.post_data_json or {}
                    if not isinstance(body, dict):
                        return
                    operation = body.get("operationName")
                    variables = (
                        _object(body.get("variables")) if path == "/graphql" else body
                    )
                    is_profile = (
                        path == "/rest/v/profile/feed"
                        or operation == "visionProfilePhotoList"
                    )
                    requested_id = (
                        variables.get("user_id", variables.get("userId"))
                        if is_profile
                        else variables.get("photoId", variables.get("photo_id"))
                    )
                    expected = (
                        collector.owner_id if is_profile and collector else identity
                    )
                    if requested_id != expected:
                        return
                    size = response.headers.get("content-length", "0")
                    if size.isdigit() and int(size) > MAX_RESPONSE_BYTES:
                        raise DiscoveryError(
                            "Kuaishou response exceeded the safe size limit"
                        )
                    raw = response.body()
                    if len(raw) > MAX_RESPONSE_BYTES:
                        raise DiscoveryError(
                            "Kuaishou response exceeded the safe size limit"
                        )
                    payload = _object(json.loads(raw))
                    if path == "/graphql":
                        payload = _object(_object(payload.get("data")).get(operation))
                    response_error(payload, url)
                    if is_profile and collector:
                        collector.accept(
                            payload,
                            owner_id=str(requested_id),
                            cursor=str(variables.get("pcursor") or ""),
                        )
                    elif not is_profile and operation in {None, "visionVideoDetail"}:
                        video = parse_video(payload, expected_id=identity)
                        details[video.media_id] = video
                except (
                    AuthenticationRequiredError,
                    TemporaryAccessError,
                    DiscoveryError,
                ) as exc:
                    errors.append(exc)
                except (PlaywrightError, TypeError, ValueError):
                    # Irrelevant telemetry and responses that close during teardown
                    # must not become false login/verification requirements.
                    return

            context.route("**/*", route_request)
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
                    "Kuaishou page could not be opened. Check the configured proxy and network.",
                    issue_code=SiteIssueCode.NETWORK_ERROR,
                ) from exc
            idle = 0
            previous_count = -1
            while time.monotonic() - started < MAX_BROWSER_SECONDS:
                if should_cancel():
                    raise DownloadCancelledError("Task cancelled")
                if errors:
                    raise errors[0]
                if any(
                    marker in page.title().lower()
                    for marker in ("domain blocked", "website filtered")
                ):
                    raise TemporaryAccessError(
                        "Kuaishou was blocked by the local DNS or web filter. Check the configured proxy or network policy; Chrome verification is not required.",
                        issue_code=SiteIssueCode.NETWORK_ERROR,
                    )
                final_url = navigation["url"]
                final_kind, final_id = source_identity(final_url)
                if kind == "short_link" and final_kind != "short_link":
                    kind, identity = final_kind, final_id
                    collector = (
                        ProfileCollector(identity, final_url)
                        if kind == "profile"
                        else None
                    )
                    # A share redirect may have completed its first request
                    # before its target was known. Observe one normal reload
                    # for item pages as well as profiles (REST-only pages do
                    # not necessarily leave usable Apollo SSR behind).
                    page.goto(final_url, wait_until="domcontentloaded", timeout=30_000)
                elif kind != "short_link" and (
                    final_kind != kind or final_id != identity
                ):
                    raise DiscoveryError(
                        "Kuaishou navigated to a different video or author; the response was blocked"
                    )
                elif final_url != page.url:
                    page.goto(final_url, wait_until="domcontentloaded", timeout=30_000)
                    continue
                state = page.evaluate(
                    "() => window.APOLLO_STATE || window.__APOLLO_STATE__ || {}"
                )
                if kind == "item":
                    for _, payload in apollo_operations(
                        state, "visionVideoDetail", "photoId", identity
                    ):
                        response_error(payload, url)
                        video = parse_video(payload, expected_id=identity)
                        details[video.media_id] = video
                    if identity in details and details[identity].assets:
                        return Result([details[identity]], kind, identity)
                elif collector:
                    for arguments, payload in apollo_operations(
                        state, "visionProfilePhotoList", "userId", identity
                    ):
                        collector.accept(
                            payload,
                            owner_id=identity,
                            cursor=str(arguments.get("pcursor") or ""),
                        )
                    count = len(collector.videos)
                    if count != previous_count:
                        idle = 0
                        previous_count = count
                        if status_callback:
                            status_callback(
                                f"Kuaishou: verified {count} videos across {len(collector.seen_cursors)} pages"
                            )
                    else:
                        idle += 1
                    if collector.terminal or count >= MAX_PROFILE_ITEMS or idle >= 12:
                        break
                    # Scroll the site's real list. Its own JavaScript generates
                    # pagination requests; no signatures or private API replay.
                    page.evaluate("""() => {
                      window.scrollTo(0, document.documentElement.scrollHeight);
                      for (const element of document.querySelectorAll('div,main,section')) {
                        const style = getComputedStyle(element);
                        if (/(auto|scroll)/.test(style.overflowY) && element.scrollHeight > element.clientHeight + 100)
                          element.scrollTop = element.scrollHeight;
                      }
                    }""")
                if time.monotonic() - started > 20 and not (
                    collector and collector.videos
                ):
                    # A caption/comment may contain words such as "deleted" or
                    # "captcha". Only explicit site dialogs/error containers
                    # are evidence of a challenge, not the entire body text.
                    notices = page.locator(
                        "[role='dialog'], [class*='captcha'], [class*='error-page'], [class*='empty-page']"
                    ).all_inner_texts()
                    for notice in notices[:10]:
                        response_error({"message": notice[:4000]}, url)
                    if kind != "profile":
                        break
                for _ in range(5):
                    if should_cancel():
                        raise DownloadCancelledError("Task cancelled")
                    page.wait_for_timeout(200)
            if errors:
                raise errors[0]
            if not (collector and collector.videos):
                for notice in page.locator(
                    "[role='dialog'], [class*='captcha'], [class*='error-page'], [class*='empty-page']"
                ).all_inner_texts()[:10]:
                    response_error({"message": notice[:4000]}, url)
            if collector and collector.videos:
                return Result(
                    list(collector.videos.values()),
                    "profile",
                    collector.owner_id,
                    collector.complete,
                    None if collector.complete else PROFILE_INCOMPLETE,
                )
            if collector and collector.complete:
                return Result([], "profile", collector.owner_id)
            raise TemporaryAccessError(
                "Kuaishou returned no verified video data. Open the original link in Chrome; if it is public, copy a fresh share link and retry. No unrelated recommendations were downloaded.",
                issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
            )
        finally:
            browser.close()
