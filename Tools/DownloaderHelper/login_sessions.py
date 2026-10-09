"""Explicit, app-owned Chrome login sessions, independent of daily browser data."""

from __future__ import annotations

import contextlib
import json
import math
import os
import re
import secrets
import stat
import threading
import time
from collections.abc import Callable
from http.cookiejar import Cookie, DefaultCookiePolicy
from pathlib import Path

from proxy_config import normalize_proxy_url
from proxy_transport import _browser_proxy

PLATFORM_URLS = {
    "douyin": "https://www.douyin.com/",
    "xiaohongshu": "https://www.xiaohongshu.com/",
    "kuaishou": "https://www.kuaishou.com/",
    "instagram": "https://www.instagram.com/",
    "bilibili": "https://www.bilibili.com/",
    "youtube": "https://www.youtube.com/",
}
_DOMAINS = {
    "douyin": ("douyin.com", "iesdouyin.com"),
    "xiaohongshu": ("xiaohongshu.com",),
    "kuaishou": ("kuaishou.com", "gifshow.com"),
    "instagram": ("instagram.com",),
    "bilibili": ("bilibili.com",),
    "youtube": ("youtube.com", "google.com"),
}
# These are local readiness heuristics, not proof of server authentication.
# The website may still require a fresh login, a challenge or access permission.
_AUTH_GROUPS = {
    "douyin": ({"sessionid", "sessionid_ss"},),
    "xiaohongshu": ({"web_session"}, {"id_token"}),
    "kuaishou": ({"kuaishou.server.web_st"},),
    "instagram": ({"sessionid"},),
    "bilibili": ({"SESSDATA"},),
    "youtube": ({"SAPISID", "APISID", "__Secure-1PAPISID", "__Secure-3PAPISID"},),
}
_TOKEN = re.compile(r"cy-session:([a-z]+):([0-9a-f]{32})\Z")
_COOKIE_NAME = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+\Z")
_DOMAIN = re.compile(r"\.?[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\Z")
_MAX_BYTES = 8 * 1024 * 1024
_MAX_COOKIES = 4096
_COOKIE_KEYS = frozenset(
    ("name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite")
)


class LoginSessionError(ValueError):
    """Only fixed codes leave this component; underlying errors remain private."""

    def __init__(self, code: str, status: int = 409):
        super().__init__(code)
        self.code = code
        self.status = status


def _platform(value: object) -> str:
    if not isinstance(value, str) or value not in PLATFORM_URLS:
        raise LoginSessionError("login_platform_invalid", 422)
    return value


def _parse_token(value: object) -> tuple[str, str]:
    match = _TOKEN.fullmatch(value) if isinstance(value, str) else None
    if match is None or match[1] not in PLATFORM_URLS:
        raise LoginSessionError("login_session_invalid", 422)
    return match[1], match[2]


def _same_family(domain: str, platform: str) -> bool:
    hostname = domain.lstrip(".")
    return any(
        hostname == parent or hostname.endswith("." + parent)
        for parent in _DOMAINS[platform]
    )


def _has_authentication(records: list[dict], platform: str) -> bool:
    root = _DOMAINS[platform][0]
    names = {
        record["name"]
        for record in records
        if record["domain"].lstrip(".") in {root, "www." + root}
        and record["path"] == "/"
        and record["value"]
    }
    return all(names & alternatives for alternatives in _AUTH_GROUPS[platform])


def _text(value: object, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= maximum
        and not any(ord(char) < 32 or ord(char) == 127 for char in value)
    )


def _cookie(record: object, platform: str) -> dict:
    if not isinstance(record, dict) or set(record) != _COOKIE_KEYS:
        raise LoginSessionError("login_session_invalid", 422)
    name, value, domain, path, expiry = (
        record[key] for key in ("name", "value", "domain", "path", "expires")
    )
    if (
        not _text(name, 1024)
        or not _COOKIE_NAME.fullmatch(name)
        or not _text(value, 16_384)
        or not isinstance(domain, str)
        or not _DOMAIN.fullmatch(domain)
        or ".." in domain
        or not _same_family(domain, platform)
        or not _text(path, 4096)
        or not path.startswith("/")
        or type(expiry) not in (int, float)
        or (expiry != -1 and not 0 < expiry <= 253402300799)
        or not math.isfinite(expiry)
        or type(record["httpOnly"]) is not bool
        or type(record["secure"]) is not bool
        or record["sameSite"] not in ("Strict", "Lax", "None")
    ):
        raise LoginSessionError("login_session_invalid", 422)
    return dict(record)


def _snapshot_cookies(records: object, platform: str) -> list[dict]:
    if not isinstance(records, list) or len(records) > _MAX_COOKIES:
        raise LoginSessionError("login_session_invalid", 422)
    result = []
    now = time.time()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("domain"), str):
            raise LoginSessionError("login_session_invalid", 422)
        # Never export unrelated account cookies or flatten partitioned cookies
        # into unrestricted cookies: CookieJar cannot represent partition keys.
        if not _same_family(record["domain"], platform) or "partitionKey" in record:
            continue
        cleaned = _cookie({key: record.get(key) for key in _COOKIE_KEYS}, platform)
        if cleaned["expires"] == -1 or cleaned["expires"] > now:
            result.append(cleaned)
    if not _has_authentication(result, platform):
        raise LoginSessionError("login_session_empty")
    return result


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate field")
        result[key] = value
    return result


def _private_directory(parent: int, name: str) -> int:
    try:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
        descriptor = os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
        )
    except OSError:
        raise LoginSessionError("login_storage_unavailable", 503) from None
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(descriptor)
        raise LoginSessionError("login_storage_unavailable", 503)
    return descriptor


def _read_json(directory: int, name: str) -> dict:
    descriptor = os.open(
        name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory
    )
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or not 0 < before.st_size <= _MAX_BYTES
        ):
            raise LoginSessionError("login_storage_unavailable", 503)
        raw = handle.read(_MAX_BYTES + 1)
        after = os.fstat(handle.fileno())
        if (
            any(
                getattr(before, field) != getattr(after, field)
                for field in (
                    "st_dev",
                    "st_ino",
                    "st_size",
                    "st_mtime_ns",
                    "st_ctime_ns",
                )
            )
            or len(raw) != before.st_size
        ):
            raise LoginSessionError("login_storage_unavailable", 503)
    value = json.loads(raw, object_pairs_hook=_unique_object)
    if not isinstance(value, dict):
        raise LoginSessionError("login_session_invalid", 422)
    return value


def _write_json(directory: int, name: str, value: dict, *, replace: bool) -> None:
    raw = json.dumps(
        value, ensure_ascii=True, allow_nan=False, separators=(",", ":")
    ).encode("utf-8")
    if len(raw) > _MAX_BYTES:
        raise LoginSessionError("login_session_invalid", 422)
    temporary = ".pending-" + secrets.token_hex(16)
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        if replace:
            # Replacing a directory entry never follows a pre-existing symlink.
            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        else:
            os.link(
                temporary,
                name,
                src_dir_fd=directory,
                dst_dir_fd=directory,
                follow_symlinks=False,
            )
        os.fsync(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=directory)


class LoginSessions:
    """One visible Chrome context, plus immutable task-bound cookie snapshots.

    A saved snapshot is not proof that a website accepts a login. All website
    authorization, identity, quality and challenge checks remain in the engine.
    Playwright objects are created, polled and closed only by their owner thread.
    """

    def __init__(self, data_dir: Path, get_proxy: Callable[[], str | None]):
        self._lock = threading.RLock()
        self._get_proxy = get_proxy
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._finish = threading.Event()
        self._closed = False
        self._cleanup_failed = False
        self._active_platform: str | None = None
        self._root_fd = -1
        self._path = Path(data_dir) / "login-sessions"
        self._states = {
            platform: {
                "platform": platform,
                "status": "idle",
                "has_saved_session": False,
            }
            for platform in PLATFORM_URLS
        }
        try:
            if not Path(data_dir).is_absolute():
                raise LoginSessionError("login_storage_unavailable", 503)
            parent = os.open(data_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                parent_info = os.fstat(parent)
                if parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o022:
                    raise LoginSessionError("login_storage_unavailable", 503)
                self._root_fd = _private_directory(parent, "login-sessions")
            finally:
                os.close(parent)
            for platform in PLATFORM_URLS:
                try:
                    self.current_token(platform)
                    self._states[platform].update(
                        status="saved", has_saved_session=True
                    )
                except LoginSessionError as error:
                    if error.code != "login_session_missing":
                        self._states[platform].update(
                            status="error", error_code=error.code
                        )
        except (OSError, ValueError):
            if self._root_fd >= 0:
                os.close(self._root_fd)
                self._root_fd = -1
            raise LoginSessionError("login_storage_unavailable", 503) from None

    @contextlib.contextmanager
    def _directory(self, platform: str, child: str | None = None):
        if self._root_fd < 0:
            raise LoginSessionError("login_closed", 503)
        descriptor = _private_directory(self._root_fd, platform)
        try:
            if child is None:
                yield descriptor
            else:
                nested = _private_directory(descriptor, child)
                try:
                    yield nested
                finally:
                    os.close(nested)
        finally:
            os.close(descriptor)

    def status(self) -> dict:
        with self._lock:
            return {
                "schema_version": 1,
                "platforms": [dict(state) for state in self._states.values()],
            }

    def active(self) -> bool:
        with self._lock:
            return self._active_platform is not None

    def current_token(self, platform: str) -> str:
        platform = _platform(platform)
        try:
            with self._lock, self._directory(platform) as directory:
                index = _read_json(directory, "current.json")
                if (
                    set(index) != {"schema_version", "token"}
                    or type(index["schema_version"]) is not int
                    or index["schema_version"] != 1
                ):
                    raise LoginSessionError("login_session_invalid", 422)
                token = index["token"]
                if _parse_token(token)[0] != platform:
                    raise LoginSessionError("login_session_invalid", 422)
                self.cookie_jar(token)
                return token
        except FileNotFoundError:
            raise LoginSessionError("login_session_missing") from None
        except LoginSessionError:
            raise
        except (OSError, ValueError, UnicodeError):
            raise LoginSessionError("login_storage_unavailable", 503) from None

    def cookie_jar(self, token: str):
        from yt_dlp.cookies import YoutubeDLCookieJar

        platform, revision = _parse_token(token)
        try:
            with self._lock, self._directory(platform, "snapshots") as directory:
                payload = _read_json(directory, revision + ".json")
            if (
                set(payload) != {"schema_version", "token", "cookies"}
                or type(payload["schema_version"]) is not int
                or payload["schema_version"] != 1
                or payload["token"] != token
                or not isinstance(payload["cookies"], list)
                or not 0 < len(payload["cookies"]) <= _MAX_COOKIES
            ):
                raise LoginSessionError("login_session_invalid", 422)
            jar = YoutubeDLCookieJar()
            jar.set_policy(
                DefaultCookiePolicy(
                    strict_ns_domain=DefaultCookiePolicy.DomainStrictNonDomain
                )
            )
            now = time.time()
            usable = []
            for raw in payload["cookies"]:
                record = _cookie(raw, platform)
                expiry = record["expires"]
                if expiry != -1 and expiry <= now:
                    continue
                usable.append(record)
                rest = {"SameSite": record["sameSite"]}
                if record["httpOnly"]:
                    rest["HttpOnly"] = None
                jar.set_cookie(
                    Cookie(
                        version=0,
                        name=record["name"],
                        value=record["value"],
                        port=None,
                        port_specified=False,
                        domain=record["domain"],
                        domain_specified=record["domain"].startswith("."),
                        domain_initial_dot=record["domain"].startswith("."),
                        path=record["path"],
                        path_specified=True,
                        secure=record["secure"],
                        expires=None if expiry == -1 else int(expiry),
                        discard=expiry == -1,
                        comment=None,
                        comment_url=None,
                        rest=rest,
                        rfc2109=False,
                    )
                )
            if not _has_authentication(usable, platform):
                raise LoginSessionError("login_session_expired")
            return jar
        except FileNotFoundError:
            raise LoginSessionError("login_session_missing") from None
        except LoginSessionError:
            raise
        except (OSError, ValueError, UnicodeError):
            raise LoginSessionError("login_storage_unavailable", 503) from None

    def start(self, platform: str) -> dict:
        platform = _platform(platform)
        with self._lock:
            if self._closed:
                raise LoginSessionError("login_closed", 503)
            if self._active_platform is not None:
                raise LoginSessionError("login_busy")
            try:
                proxy = self._get_proxy()
                proxy = normalize_proxy_url(proxy) if proxy is not None else None
            except (OSError, ValueError):
                raise LoginSessionError("login_proxy_unavailable", 503) from None
            self._stop.clear()
            self._finish.clear()
            self._active_platform = platform
            self._states[platform].update(status="opening")
            self._states[platform].pop("error_code", None)
            self._thread = threading.Thread(
                target=self._run,
                args=(platform, proxy),
                name="download-login",
                daemon=True,
            )
            try:
                self._thread.start()
            except RuntimeError:
                self._active_platform = None
                self._states[platform].update(
                    status="error", error_code="login_browser_unavailable"
                )
                raise LoginSessionError("login_browser_unavailable", 503) from None
            return dict(self._states[platform])

    def finish(self, platform: str) -> dict:
        platform = _platform(platform)
        with self._lock:
            if (
                self._active_platform != platform
                or self._states[platform]["status"] != "login_open"
            ):
                raise LoginSessionError("login_not_open")
            self._states[platform]["status"] = "saving"
            self._finish.set()
            return dict(self._states[platform])

    def _store(self, platform: str, records: list[dict]) -> None:
        token = f"cy-session:{platform}:{secrets.token_hex(16)}"
        payload = {
            "schema_version": 1,
            "token": token,
            "cookies": _snapshot_cookies(records, platform),
        }
        revision = _parse_token(token)[1]
        with self._lock:
            if self._stop.is_set():
                return
            with self._directory(platform, "snapshots") as directory:
                _write_json(directory, revision + ".json", payload, replace=False)
            with self._directory(platform) as directory:
                _write_json(
                    directory,
                    "current.json",
                    {"schema_version": 1, "token": token},
                    replace=True,
                )
            self._states[platform].update(status="saved", has_saved_session=True)

    def _run(self, platform: str, proxy: str | None) -> None:
        try:
            from playwright.sync_api import sync_playwright

            with self._directory(platform, "chrome"):
                pass
            with sync_playwright() as playwright:
                self._run_browser(playwright, platform, proxy)
        except LoginSessionError as error:
            with self._lock:
                self._states[platform].update(status="error", error_code=error.code)
        except Exception:  # noqa: BLE001 - The worker boundary must not expose browser secrets.
            with self._lock:
                self._states[platform].update(
                    status="error", error_code="login_browser_unavailable"
                )
        finally:
            with self._lock:
                if self._states[platform]["status"] in {
                    "opening",
                    "login_open",
                    "saving",
                }:
                    self._states[platform]["status"] = (
                        "saved"
                        if self._states[platform]["has_saved_session"]
                        else "idle"
                    )
                if not self._cleanup_failed:
                    self._active_platform = None

    def _run_browser(self, playwright, platform: str, proxy: str | None) -> None:
        from playwright.sync_api import Error as BrowserError

        arguments = ["--disable-sync", "--no-first-run", "--no-default-browser-check"]
        if not proxy:
            arguments.append("--no-proxy-server")
        options = {
            "channel": "chrome",
            "headless": False,
            "args": arguments,
            "timeout": 20_000,
        }
        if proxy:
            options["proxy"] = _browser_proxy(proxy)
        context = playwright.chromium.launch_persistent_context(
            str(self._path / platform / "chrome"), **options
        )
        browser_closed = threading.Event()
        try:
            context.on("close", lambda *_: browser_closed.set())
            context.set_default_timeout(5000)
            page = context.pages[0] if context.pages else context.new_page()
            try:
                page.goto(
                    PLATFORM_URLS[platform],
                    wait_until="domcontentloaded",
                    timeout=20_000,
                )
            except BrowserError:
                # The user can repair a transient site/proxy failure in the
                # visible window; never retry the navigation on a direct route.
                if browser_closed.is_set():
                    raise LoginSessionError("login_window_closed") from None
            with self._lock:
                if not self._stop.is_set():
                    self._states[platform]["status"] = "login_open"
            deadline = time.monotonic() + 1800
            while not self._stop.is_set() and not browser_closed.is_set():
                if self._finish.is_set():
                    self._store(platform, context.cookies())
                    break
                if time.monotonic() >= deadline:
                    raise LoginSessionError("login_timed_out")
                pages = [
                    candidate
                    for candidate in context.pages
                    if not candidate.is_closed()
                ]
                if not pages:
                    break
                pages[0].wait_for_timeout(100)
        finally:
            # A sync Playwright context must close before its owning driver exits.
            try:
                context.close()
            except Exception:  # noqa: BLE001 - Unknown cleanup cannot release the activity barrier.
                with self._lock:
                    self._cleanup_failed = True
                raise LoginSessionError("login_cleanup_failed", 503) from None

    def close(self, timeout: float = 5.0) -> bool:
        with self._lock:
            self._closed = True
            self._stop.set()
            thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=max(0.0, min(float(timeout), 5.0)))
        with self._lock:
            if self._active_platform is not None:
                return False
            if self._root_fd >= 0:
                os.close(self._root_fd)
                self._root_fd = -1
            return True


class LegacyLoginSnapshots:
    """Read only the exact immutable snapshot already bound to a legacy task.

    No browser worker, directory creation, current-session lookup, or login
    action is exposed. Missing or inaccessible state fails at that task's read,
    never by switching to another Chrome profile or an anonymous session.
    """

    def __init__(self, data_dir: Path):
        self._data_dir = Path(data_dir)
        self._lock = threading.RLock()

    @contextlib.contextmanager
    def _directory(self, platform: str, child: str | None = None):
        descriptors = []
        try:
            if not self._data_dir.is_absolute():
                raise LoginSessionError("login_storage_unavailable", 503)
            parent = os.open(self._data_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            descriptors.append(parent)
            parent_info = os.fstat(parent)
            if parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o022:
                raise LoginSessionError("login_storage_unavailable", 503)
            components = ["login-sessions", _platform(platform)]
            if child is not None:
                if child != "snapshots":
                    raise LoginSessionError("login_session_invalid", 422)
                components.append(child)
            for name in components:
                descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptors[-1])
                descriptors.append(descriptor)
                info = os.fstat(descriptor)
                if info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise LoginSessionError("login_storage_unavailable", 503)
            yield descriptors[-1]
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    cookie_jar = LoginSessions.cookie_jar
