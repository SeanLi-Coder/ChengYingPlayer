"""Native authentication policy and immutable, task-bound login adapters."""

from __future__ import annotations

import contextlib
import copy
import functools
import json
import os
import re
import stat
import tempfile
from http.cookiejar import CookieJar, DefaultCookiePolicy
from pathlib import Path

MODES = frozenset({"dedicated", "chrome", "anonymous"})
TOKEN_PREFIX = "cy-session:"
_COOKIE_MARKER = "_chengying_dedicated_session"


def is_session_profile(profile):
    return isinstance(profile, str) and profile.startswith(TOKEN_PREFIX)


class LoginPolicyError(ValueError):
    def __init__(self, code, status=422):
        self.code = code
        self.status = status
        super().__init__("Download login settings are unavailable.")


def mark_session_cookies(jar):
    """Keep browser host-only scope when transport libraries copy cookie jars."""
    if not isinstance(jar, CookieJar) or not isinstance(jar._policy, DefaultCookiePolicy):
        raise LoginPolicyError("login_session_invalid")
    policy = copy.copy(jar._policy)
    policy.strict_ns_domain |= DefaultCookiePolicy.DomainStrictNonDomain
    jar.set_policy(policy)
    setattr(jar, _COOKIE_MARKER, True)
    return jar


def _is_session_jar(jar):
    return isinstance(jar, CookieJar) and getattr(jar, _COOKIE_MARKER, False) is True


def install_session_requests(session):
    """Preserve scoped cookies in this dedicated requests session only.

    requests builds a new RequestsCookieJar in prepare_request and otherwise
    discards the source policy. Rebuild its header before any socket operation;
    redirects copy the prepared jar and preserve its strict policy themselves.
    """
    if not _is_session_jar(session.cookies):
        return session
    original = session.prepare_request
    if getattr(original, _COOKIE_MARKER, False):
        return session

    @functools.wraps(original)
    def prepare(request):
        prepared = original(request)
        # A caller-provided Cookie header has no domain provenance. Dedicated
        # sessions only send cookies represented by the scoped merged jar.
        prepared.headers.pop("Cookie", None)
        # requests otherwise lets Host override the URL used for cookie scope.
        # The connection target is authoritative for dedicated credentials.
        prepared.headers.pop("Host", None)
        prepared.prepare_cookies(mark_session_cookies(prepared._cookies))
        return prepared

    setattr(prepare, _COOKIE_MARKER, True)
    session.prepare_request = prepare
    return session


def install_session_ytdlp(downloader):
    """Protect a standalone summary downloader without process-wide hooks."""
    if not _is_session_jar(downloader.cookiejar):
        return downloader
    from yt_dlp.networking._requests import RequestsRH

    handler = downloader._request_director.handlers.get("Requests")
    if not isinstance(handler, RequestsRH):
        raise LoginPolicyError("login_transport_unavailable")
    original = handler._create_instance
    if getattr(original, _COOKIE_MARKER, False):
        return downloader

    @functools.wraps(original)
    def create_instance(cookiejar, *args, **kwargs):
        session = original(cookiejar, *args, **kwargs)
        return install_session_requests(session) if _is_session_jar(cookiejar) else session

    setattr(create_instance, _COOKIE_MARKER, True)
    handler._create_instance = create_instance
    return downloader


class LoginPolicy:
    """Read legacy login choices while retiring the dedicated-window default."""

    def __init__(self, data_dir: Path):
        self.path = data_dir / "login-policy.json"

    def mode(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            return "chrome"
        except OSError:
            raise LoginPolicyError("login_settings_unavailable", 503) from None
        try:
            with os.fdopen(fd, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 1024:
                    raise ValueError
                data = json.loads(handle.read(1025))
            if not isinstance(data, dict) or set(data) != {"version", "mode"}:
                raise ValueError
            if type(data["version"]) is not int or data["version"] != 1 or data["mode"] not in MODES:
                raise ValueError
            return "chrome" if data["mode"] == "dedicated" else data["mode"]
        except (OSError, ValueError, TypeError):
            raise LoginPolicyError("login_settings_unavailable", 503) from None

    def save(self, mode):
        if not isinstance(mode, str) or mode not in MODES:
            raise LoginPolicyError("login_mode_invalid")
        temporary = None
        try:
            fd, name = tempfile.mkstemp(prefix=".login-policy-", dir=self.path.parent)
            temporary = Path(name)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump({"version": 1, "mode": mode}, handle)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(self.path)
        except OSError:
            raise LoginPolicyError("login_settings_unavailable", 503) from None
        finally:
            if temporary is not None:
                with contextlib.suppress(OSError):
                    temporary.unlink(missing_ok=True)


def restore_chrome_settings(engine, policy):
    """Transfer an explicit anonymous opt-out before retiring its old policy.

    Persisting cookie-off first makes a failed/interrupted migration fail closed.
    Existing task snapshots and every other user preference remain unchanged.
    Once retired, the regular settings checkbox is the only source of truth.
    """
    if policy is None:
        return
    with engine._CONFIG_LOCK:
        if policy.mode() != "anonymous":
            return
        config = engine.get_config().model_copy(deep=True)
        if config.use_chrome_cookies:
            config.use_chrome_cookies = False
            engine.update_config(config)
        policy.save("chrome")


def install_session_cookies(sessions):
    """Intercept every pinned yt-dlp cookie alias before any Chrome disk lookup."""
    from app import browser, task_manager
    from chrome_cookie_runtime import _check_cancelled, _session_guard
    from login_sessions import LoginSessionError
    from yt_dlp import cookies
    from yt_dlp.networking._requests import RequestsRH

    patches = []

    def replace(owner, name, value):
        previous = getattr(owner, name)
        patches.append((owner, name, previous, value))
        setattr(owner, name, value)
        return previous

    original_extract = cookies._extract_chrome_cookies

    def extract(browser_name, profile, keyring, logger):
        if not is_session_profile(profile):
            return original_extract(browser_name, profile, keyring, logger)
        _check_cancelled()
        try:
            if browser_name != "chrome":
                raise LoginPolicyError("login_session_invalid")
            jar = mark_session_cookies(sessions.cookie_jar(profile))
        except (LoginSessionError, LoginPolicyError):
            raise browser.ChromeCookieAccessError("dedicated_login_unavailable") from None
        guard = _session_guard.get()
        if guard:
            domain, names = guard
            # Apply the same task-specific session validation as Chrome reads.
            jar = browser.extract_chrome_cookie_jar(
                lambda *args, **kwargs: jar, profile,
                domain=domain, required_cookie_names=names,
            )
        return jar

    original_has = task_manager.chrome_profile_has_cookies

    def has_cookies(profile, domain, names, **kwargs):
        if not is_session_profile(profile):
            return original_has(profile, domain, names, **kwargs)
        # An invalid dedicated selection must not enter automatic Chrome search.
        try:
            jar = sessions.cookie_jar(profile)
        except LoginSessionError:
            raise browser.ChromeCookieAccessError("dedicated_login_unavailable") from None
        import time

        found = {cookie.name for cookie in jar
                 if cookie.domain.lstrip(".") in {domain, "www." + domain}
                 and cookie.path == "/" and cookie.value
                 and (cookie.expires is None or cookie.expires > time.time())}
        return all(name in found for name in names)

    replace(cookies, "_extract_chrome_cookies", extract)
    replace(task_manager, "chrome_profile_has_cookies", has_cookies)
    original_merge = cookies._merge_cookie_jars

    def merge_cookie_jars(jars):
        jars = tuple(jars)
        merged = original_merge(jars)
        return mark_session_cookies(merged) if any(_is_session_jar(jar) for jar in jars) else merged

    original_instance = RequestsRH._create_instance

    def create_instance(handler, cookiejar, *args, **kwargs):
        session = original_instance(handler, cookiejar, *args, **kwargs)
        return install_session_requests(session) if _is_session_jar(cookiejar) else session

    replace(cookies, "_merge_cookie_jars", merge_cookie_jars)
    replace(RequestsRH, "_create_instance", create_instance)
    original_engine = task_manager.DownloadManager._engine_for_job

    def engine_for_job(manager, job):
        if is_session_profile(job.cookie_profile) and (
            job.cookie_browser != "chrome" or not re.fullmatch(
                r"cy-session:" + re.escape(job.platform.value) + r":[a-f0-9]{32}", job.cookie_profile
            )
        ):
            raise browser.ChromeCookieAccessError("dedicated_login_unavailable")
        result = original_engine(manager, job)
        if is_session_profile(job.cookie_profile):
            result.config.allow_cookie_fallback = False
        return result

    replace(task_manager.DownloadManager, "_engine_for_job", engine_for_job)

    def restore():
        for owner, name, previous, installed in reversed(patches):
            if getattr(owner, name) is installed:
                setattr(owner, name, previous)

    return restore
