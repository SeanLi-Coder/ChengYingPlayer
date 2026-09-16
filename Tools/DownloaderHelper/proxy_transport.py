"""Proxy-aware transports for the unmodified, pinned downloader engine."""

from __future__ import annotations

import functools
import importlib
import re
import threading
import time
from collections.abc import Callable
from http.cookiejar import CookieJar
from urllib.error import HTTPError as UrllibHTTPError
from urllib.error import URLError
from urllib.parse import quote, unquote, urlsplit, urlunsplit
from urllib.request import HTTPCookieProcessor
from urllib.request import Request as UrllibRequest

from yt_dlp import YoutubeDL
from yt_dlp.networking import Request
from yt_dlp.networking._requests import RequestsRH, RequestsSession
from yt_dlp.networking.exceptions import HTTPError, RequestError

_INSTALL_LOCK = threading.RLock()
_installation = None
_PROBE_URL = "https://www.youtube.com/robots.txt"


def _download_proxy(value: str | None) -> str:
    # Chrome always resolves SOCKS5 destinations remotely. Keep extraction,
    # browser signing, and media downloads on the same DNS path.
    if value and value.startswith("socks5://"):
        return "socks5h://" + value[len("socks5://") :]
    return value or ""


def _browser_proxy(value: str) -> dict[str, str]:
    parsed = urlsplit(value)
    authority = parsed.netloc.rsplit("@", 1)[-1]
    scheme = "socks5" if parsed.scheme == "socks5h" else parsed.scheme
    result = {
        "server": urlunsplit((scheme, authority, "", "", "")),
        "bypass": "<-loopback>",
    }
    if parsed.username is not None:
        result["username"] = unquote(parsed.username)
    if parsed.password is not None:
        result["password"] = unquote(parsed.password)
    return result


def _redact(value: str, proxy: str | None) -> str:
    value = re.sub(r"(?i)\b((?:https?|socks5h?)://)[^\s/@]+@", r"\1[redacted]@", value)
    if not proxy:
        return value
    parsed = urlsplit(proxy)
    secrets = set()
    for part in (parsed.username, parsed.password):
        if part:
            decoded = unquote(part)
            secrets.update((part, decoded, quote(decoded, safe="")))
    for secret in sorted(secrets, key=len, reverse=True):
        value = re.sub(
            r"(?<![\w])" + re.escape(secret) + r"(?![\w])",
            "[redacted]",
            value,
            flags=re.IGNORECASE,
        )
    return value


def _sanitize_exception(error: BaseException, proxy: str | None) -> None:
    """Preserve exception classes and business diagnostics, but remove secrets."""
    pending = [error]
    seen = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        current.args = tuple(
            _redact(item, proxy) if isinstance(item, str) else item
            for item in current.args
        )
        for name in (
            "msg",
            "message",
            "_message",
            "stack",
            "_stack",
            "reason",
            "url",
            "cause",
        ):
            item = getattr(current, name, None)
            if isinstance(item, str):
                try:
                    setattr(current, name, _redact(item, proxy))
                except (AttributeError, TypeError):
                    pass
            elif isinstance(item, BaseException):
                pending.append(item)
        pending.extend(item for item in current.args if isinstance(item, BaseException))
        pending.extend(
            item
            for item in (current.__cause__, current.__context__)
            if isinstance(item, BaseException)
        )


class _Logger:
    def debug(self, *_):
        pass

    def warning(self, *_):
        pass

    def error(self, *_):
        pass


class _RedactedLogger:
    def __init__(self, original, proxy):
        self.original = original
        self.proxy = proxy

    def __getattr__(self, name):
        original = getattr(self.original, name)
        if name not in {"debug", "warning", "error", "info"}:
            return original

        def write(message, *args, **kwargs):
            return original(_redact(str(message), self.proxy), *args, **kwargs)

        return write


class _OwnedResponse:
    """Keep the request handler alive until the caller closes its response."""

    def __init__(self, response, handler, proxy):
        self.response = response
        self.handler = handler
        self.proxy = proxy
        self.closed = False

    def __getattr__(self, name):
        return getattr(self.response, name)

    def geturl(self):
        return self.response.url

    def read(self, size=None):
        try:
            return self.response.read(size)
        except RequestError as error:
            _sanitize_exception(error, self.proxy)
            raise URLError(str(error)) from error

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.response.close()
        finally:
            self.handler.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class _SigningOpener:
    def __init__(self, handlers, proxy):
        self.proxy = proxy
        self.cookiejar = next(
            (
                handler.cookiejar
                for handler in handlers
                if isinstance(handler, HTTPCookieProcessor)
            ),
            CookieJar(),
        )

    def open(self, fullurl, data=None, timeout=10):
        request = (
            fullurl if isinstance(fullurl, UrllibRequest) else UrllibRequest(fullurl)
        )
        handler = RequestsRH(
            logger=_Logger(),
            cookiejar=self.cookiejar,
            timeout=timeout,
            proxies={"all": _download_proxy(self.proxy)} if self.proxy else {},
        )
        translated = Request(
            request.full_url,
            data=request.data if data is None else data,
            headers=dict(request.header_items()),
            method=request.get_method(),
        )
        try:
            response = handler.send(translated)
        except HTTPError as error:
            response = _OwnedResponse(error.response, handler, self.proxy)
            raise UrllibHTTPError(
                error.response.url,
                error.status,
                error.reason,
                error.response.headers,
                response,
            ) from None
        except BaseException as error:
            handler.close()
            _sanitize_exception(error, self.proxy)
            if isinstance(error, RequestError):
                raise URLError(str(error)) from error
            raise
        return _OwnedResponse(response, handler, self.proxy)


def install_proxy_transports(get_proxy: Callable[[], str | None]) -> Callable[[], None]:
    """Install once per helper process; return an idempotent restoration hook."""
    global _installation
    with _INSTALL_LOCK:
        if _installation is not None:
            if _installation[0] is get_proxy:
                return _installation[1]
            raise RuntimeError("Downloader proxy transports are already installed")
        downloader = importlib.import_module("app.downloader")
        xiaohongshu = importlib.import_module("app.xiaohongshu")
        signing = importlib.import_module("app.douyin_signing")
        from playwright.sync_api import BrowserType

        patches = []

        def replace(owner, name, replacement):
            original = getattr(owner, name)
            patches.append((owner, name, original, replacement))
            setattr(owner, name, replacement)

        class DesktopYoutubeDL(YoutubeDL):
            def __init__(self, params=None, auto_init=True):
                self._desktop_proxy = get_proxy()
                options = dict(params or {})
                options["proxy"] = _download_proxy(self._desktop_proxy)
                # Verbose wire debugging can bypass the normal logger and print
                # Proxy-Authorization headers from the underlying HTTP client.
                options["verbose"] = False
                if options.get("logger") is not None:
                    options["logger"] = _RedactedLogger(
                        options["logger"], self._desktop_proxy
                    )
                super().__init__(options, auto_init=auto_init)

            def to_stderr(self, message, *args, **kwargs):
                return super().to_stderr(
                    _redact(str(message), self._desktop_proxy), *args, **kwargs
                )

            def to_screen(self, message, *args, **kwargs):
                return super().to_screen(
                    _redact(str(message), self._desktop_proxy), *args, **kwargs
                )

            def urlopen(self, request):
                try:
                    return super().urlopen(request)
                except Exception as error:
                    _sanitize_exception(error, self._desktop_proxy)
                    raise

            def trouble(self, message=None, *args, **kwargs):
                message = (
                    _redact(message, self._desktop_proxy)
                    if message is not None
                    else None
                )
                return super().trouble(message, *args, **kwargs)

        original_launch = BrowserType.launch

        @functools.wraps(original_launch)
        def launch(browser_type, *args, **kwargs):
            proxy = get_proxy()
            kwargs = dict(kwargs)
            arguments = [
                argument
                for argument in (kwargs.get("args") or [])
                if not argument.startswith(("--proxy-", "--no-proxy-server"))
            ]
            if proxy:
                kwargs["proxy"] = _browser_proxy(proxy)
            else:
                kwargs["proxy"] = None
                arguments.append("--no-proxy-server")
            kwargs["args"] = arguments
            # The pinned Playwright driver also derives context.request's agent
            # from browser.options.proxy, without consulting environment proxies.
            try:
                return original_launch(browser_type, *args, **kwargs)
            except Exception as error:
                _sanitize_exception(error, proxy)
                raise

        original_request = RequestsSession.request

        @functools.wraps(original_request)
        def session_request(session, *args, **kwargs):
            try:
                return original_request(session, *args, **kwargs)
            except Exception as error:
                _sanitize_exception(error, get_proxy())
                raise

        def build_opener(*handlers):
            return _SigningOpener(handlers, get_proxy())

        replace(downloader, "YoutubeDL", DesktopYoutubeDL)
        replace(xiaohongshu, "YoutubeDL", DesktopYoutubeDL)
        replace(signing, "build_opener", build_opener)
        replace(BrowserType, "launch", launch)
        replace(RequestsSession, "request", session_request)

        def cleanup():
            global _installation
            with _INSTALL_LOCK:
                for owner, name, original, replacement in reversed(patches):
                    if getattr(owner, name) is replacement:
                        setattr(owner, name, original)
                if _installation is not None and _installation[1] is cleanup:
                    _installation = None

        _installation = (get_proxy, cleanup)
        return cleanup


def probe_proxy(url: str, timeout=10) -> int:
    """Perform a bounded, cookie-free HTTPS request through the actual transport."""
    start = time.monotonic()
    handler = RequestsRH(
        logger=_Logger(),
        timeout=timeout,
        proxies={"all": _download_proxy(url)},
    )
    try:
        with handler.send(
            Request(_PROBE_URL, headers={"Accept": "text/plain"})
        ) as response:
            response.read(1)
        return round((time.monotonic() - start) * 1000)
    except Exception as error:
        _sanitize_exception(error, url)
        if isinstance(error, HTTPError):
            error.close()
        raise
    finally:
        handler.close()
