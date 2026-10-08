"""Verify isolated login routing without opening any real browser data."""

from __future__ import annotations

import importlib
import json
import shutil
import socket
import subprocess
import sys
import time
from http.cookiejar import Cookie
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from login_auth import (
    LoginPolicy,
    LoginPolicyError,
    install_session_cookies,
    install_session_requests,
    install_session_ytdlp,
    mark_session_cookies,
)


def reject_private_access(*args, **kwargs):
    __tracebackhide__ = True
    raise AssertionError("Real browser data and network access are forbidden")


@pytest.fixture
def isolated_app(tmp_path, monkeypatch):
    """Import modules from a disposable copy; never import the stateful app.main."""
    # Cryptodome performs a local architecture probe while importing yt-dlp.
    # Complete that dependency import before rejecting all child processes.
    from yt_dlp import cookies

    previous = {key: value for key, value in sys.modules.items()
                if key == "app" or key.startswith("app.")}
    for key in previous:
        del sys.modules[key]
    engine = tmp_path / "engine"
    shutil.copytree(ROOT / "vendor/rednote/app", engine / "app",
                    ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
    monkeypatch.syspath_prepend(str(engine))
    monkeypatch.setattr(subprocess, "Popen", reject_private_access)
    monkeypatch.setattr(socket.socket, "connect", reject_private_access)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_private_access)
    try:
        modules = SimpleNamespace(**{name: importlib.import_module("app." + name)
                                    for name in ("browser", "task_manager", "downloader",
                                                 "xiaohongshu", "douyin", "douyin_signing",
                                                 "kuaishou", "instagram", "models", "errors")})
        monkeypatch.setattr(cookies, "_get_chromium_based_browser_settings", reject_private_access)
        monkeypatch.setattr(cookies, "_open_database_copy", reject_private_access)
        monkeypatch.setattr(modules.browser, "chrome_user_data_directory", reject_private_access)
        monkeypatch.setattr(modules.task_manager, "select_chrome_profile_with_cookies", reject_private_access)
        yield modules
    finally:
        for key in list(sys.modules):
            if key == "app" or key.startswith("app."):
                del sys.modules[key]
        sys.modules.update(previous)


def synthetic_jar(platform):
    from yt_dlp.cookies import YoutubeDLCookieJar

    domains = {"xiaohongshu": "xiaohongshu.com", "douyin": "douyin.com",
               "kuaishou": "kuaishou.com", "instagram": "instagram.com",
               "youtube": "youtube.com", "bilibili": "bilibili.com"}
    names = {"xiaohongshu": ("web_session", "id_token"), "douyin": ("sessionid",),
             "kuaishou": ("kuaishou.server.web_st",), "instagram": ("sessionid",),
             "youtube": ("SAPISID",), "bilibili": ("SESSDATA",)}
    jar = YoutubeDLCookieJar()
    for name in names[platform]:
        jar.set_cookie(Cookie(0, name, "synthetic-login-value", None, False,
                              "." + domains[platform], True, True, "/", True,
                              True, int(time.time()) + 3600, False, None, None,
                              {"HttpOnly": None}, False))
    return jar


class SyntheticSessions:
    def __init__(self):
        self.calls = []
        self.failure = None

    def cookie_jar(self, token):
        from login_sessions import LoginSessionError

        self.calls.append(token)
        if self.failure is not None:
            raise self.failure
        parts = token.split(":")
        if len(parts) != 3 or parts[0] != "cy-session" or parts[1] not in {
            "xiaohongshu", "douyin", "kuaishou", "instagram", "youtube", "bilibili",
        } or len(parts[2]) != 32 or any(character not in "0123456789abcdef" for character in parts[2]):
            raise LoginSessionError("login_session_invalid")
        return synthetic_jar(parts[1])


@pytest.fixture
def routed(isolated_app):
    sessions = SyntheticSessions()
    restore = install_session_cookies(sessions)
    try:
        yield isolated_app, sessions
    finally:
        restore()


def token(platform, revision="a"):
    return "cy-session:" + platform + ":" + revision * 32


def test_policy_defaults_to_dedicated_without_rewriting_legacy_settings(tmp_path):
    legacy = tmp_path / "config.json"
    legacy.write_text('{"use_chrome_cookies":true,"chrome_profile":"Profile 3"}')
    before = legacy.read_bytes()
    assert LoginPolicy(tmp_path).mode() == "dedicated"
    assert legacy.read_bytes() == before
    assert not (tmp_path / "login-policy.json").exists()


@pytest.mark.parametrize("mode", ["dedicated", "chrome", "anonymous"])
def test_policy_is_private_persistent_and_independent_of_app_version(tmp_path, mode):
    LoginPolicy(tmp_path).save(mode)
    assert LoginPolicy(tmp_path).mode() == mode
    assert (tmp_path / "login-policy.json").stat().st_mode & 0o777 == 0o600
    assert list(tmp_path.glob(".login-policy-*")) == []


@pytest.mark.parametrize("mode", [None, True, [], {}, "automatic", "../private", "chrome\n"])
def test_invalid_policy_does_not_replace_last_saved_value(tmp_path, mode):
    policy = LoginPolicy(tmp_path)
    policy.save("anonymous")
    before = policy.path.read_bytes()
    with pytest.raises(LoginPolicyError):
        policy.save(mode)
    assert policy.path.read_bytes() == before


@pytest.mark.parametrize("payload", [b"{", b"x" * 1025, b"[]",
    b'{"version":true,"mode":"dedicated"}', b'{"version":1,"mode":{}}',
    b'{"version":1,"mode":"chrome","private":"must-not-escape"}'])
def test_corrupt_policy_fails_closed_and_redacted(tmp_path, payload):
    (tmp_path / "login-policy.json").write_bytes(payload)
    with pytest.raises(LoginPolicyError) as caught:
        LoginPolicy(tmp_path).mode()
    assert caught.value.code == "login_settings_unavailable"
    assert "must-not-escape" not in str(caught.value)


def test_linked_policy_is_not_read(tmp_path):
    target = tmp_path / "private-target"
    target.write_text(json.dumps({"version": 1, "mode": "chrome"}))
    (tmp_path / "login-policy.json").symlink_to(target)
    with pytest.raises(LoginPolicyError):
        LoginPolicy(tmp_path).mode()


def test_failed_policy_atomic_save_retains_previous_bytes(tmp_path, monkeypatch):
    policy = LoginPolicy(tmp_path)
    policy.save("chrome")
    before = policy.path.read_bytes()

    def fail_replace(*args, **kwargs):
        raise OSError("synthetic private path must not escape")

    monkeypatch.setattr(Path, "replace", fail_replace)
    with pytest.raises(LoginPolicyError):
        policy.save("dedicated")
    assert policy.path.read_bytes() == before
    assert list(tmp_path.glob(".login-policy-*")) == []


@pytest.mark.parametrize("platform", ["xiaohongshu", "douyin", "kuaishou", "instagram", "youtube", "bilibili"])
def test_actual_ytdlp_parser_and_cookiejar_keep_dedicated_identity(routed, platform):
    from yt_dlp import YoutubeDL, cookies

    _, sessions = routed
    profile = token(platform)
    assert cookies._parse_browser_specification("chrome", profile)[1] == profile
    with YoutubeDL({"cookiesfrombrowser": ("chrome", profile), "quiet": True,
                    "no_warnings": True, "cachedir": False}) as downloader:
        assert [cookie.name for cookie in downloader.cookiejar] == [cookie.name for cookie in synthetic_jar(platform)]
    assert sessions.calls == [profile]


@pytest.mark.parametrize("consumer,platform", [
    ("xiaohongshu", "xiaohongshu"), ("douyin", "douyin"),
    ("douyin_signing", "douyin"), ("kuaishou", "kuaishou"), ("instagram", "instagram"),
])
def test_imported_cookie_aliases_all_use_owned_snapshot(routed, consumer, platform):
    modules, sessions = routed
    readers = {"xiaohongshu": modules.xiaohongshu._extract_chrome_cookies,
               "douyin": modules.douyin._extract_cookies,
               "douyin_signing": modules.douyin_signing._load_chrome_cookie_jar,
               "kuaishou": modules.kuaishou._browser_cookies,
               "instagram": modules.instagram._browser_cookies}
    assert list(readers[consumer](token(platform)))
    assert sessions.calls == [token(platform)]


@pytest.mark.parametrize("profile", ["cy-session:", "cy-session:douyin:short", "cy-session:unknown:" + "a" * 32,
    "cy-session:douyin:../../private", "cy-session:douyin:" + "Z" * 32])
def test_malformed_dedicated_tokens_fail_without_legacy_lookup(routed, profile):
    modules, _ = routed
    from yt_dlp import cookies

    with pytest.raises(modules.browser.ChromeCookieAccessError) as caught:
        cookies.extract_cookies_from_browser("chrome", profile=profile)
    assert caught.value.diagnostic_code == "dedicated_login_unavailable"
    assert modules.browser.chrome_cookie_diagnostic(profile, caught.value) == "dedicated_login_unavailable"
    assert "private" not in str(caught.value)


def test_xiaohongshu_validation_does_not_scan_other_profiles(routed):
    modules, sessions = routed
    profile, automatic = modules.task_manager.DownloadManager._resolve_xiaohongshu_chrome_profile(
        modules.models.Platform.XIAOHONGSHU, "chrome", token("xiaohongshu"))
    assert (profile, automatic) == (token("xiaohongshu"), False)
    assert sessions.calls == [profile]


def test_xiaohongshu_expired_revision_does_not_select_another_account(routed):
    from login_sessions import LoginSessionError

    modules, sessions = routed
    sessions.failure = LoginSessionError("login_session_missing")
    with pytest.raises(modules.browser.ChromeCookieAccessError):
        modules.task_manager.DownloadManager._resolve_xiaohongshu_chrome_profile(
            modules.models.Platform.XIAOHONGSHU, "chrome", token("xiaohongshu"))
    assert sessions.calls == [token("xiaohongshu")]


@pytest.mark.parametrize("platform", ["xiaohongshu", "douyin", "kuaishou", "instagram", "youtube", "bilibili"])
def test_job_engine_preserves_revision_and_disables_anonymous_fallback(routed, platform):
    modules, _ = routed
    manager = SimpleNamespace(downloader_config=modules.downloader.DownloaderConfig(allow_cookie_fallback=True))
    job = SimpleNamespace(cookie_browser="chrome", cookie_profile=token(platform),
                          platform=modules.models.Platform(platform), output_layout=modules.models.OutputLayout.AUTHOR)
    downloader = modules.task_manager.DownloadManager._engine_for_job(manager, job)
    assert downloader.config.cookie_profile == token(platform)
    assert downloader.config.allow_cookie_fallback is False
    assert manager.downloader_config.allow_cookie_fallback is True


def test_job_engine_rejects_snapshot_from_different_platform(routed):
    modules, _ = routed
    manager = SimpleNamespace(downloader_config=modules.downloader.DownloaderConfig())
    job = SimpleNamespace(cookie_browser="chrome", cookie_profile=token("youtube"),
                          platform=modules.models.Platform.DOUYIN, output_layout=modules.models.OutputLayout.AUTHOR)
    with pytest.raises(modules.browser.ChromeCookieAccessError):
        modules.task_manager.DownloadManager._engine_for_job(manager, job)


def test_existing_task_configuration_is_not_migrated(routed):
    modules, _ = routed
    manager = SimpleNamespace(downloader_config=modules.downloader.DownloaderConfig(allow_cookie_fallback=True))
    job = SimpleNamespace(cookie_browser="chrome", cookie_profile="Profile 7",
                          platform=modules.models.Platform.DOUYIN, output_layout=modules.models.OutputLayout.PLATFORM_AUTHOR)
    downloader = modules.task_manager.DownloadManager._engine_for_job(manager, job)
    assert downloader.config.cookie_profile == "Profile 7"
    assert downloader.config.allow_cookie_fallback is True


@pytest.mark.parametrize("platform", ["xiaohongshu", "douyin", "kuaishou", "instagram", "youtube", "bilibili"])
def test_failed_cookie_operation_never_retries_anonymously(routed, platform):
    from yt_dlp.cookies import CookieLoadError
    from yt_dlp.utils import DownloadError

    modules, _ = routed
    manager = SimpleNamespace(downloader_config=modules.downloader.DownloaderConfig(allow_cookie_fallback=True))
    job = SimpleNamespace(cookie_browser="chrome", cookie_profile=token(platform),
                          platform=modules.models.Platform(platform), output_layout=modules.models.OutputLayout.AUTHOR)
    downloader = modules.task_manager.DownloadManager._engine_for_job(manager, job)
    attempts = []

    def operation(use_cookies):
        attempts.append(use_cookies)
        raise DownloadError("failed to load cookies") from CookieLoadError("Synthetic cookie failure")

    with pytest.raises(modules.errors.TemporaryAccessError):
        downloader._run_with_cookie_fallback(operation, url="https://www." + platform + ".com/")
    assert attempts == [True]


@pytest.mark.parametrize("consumer,platform", [
    ("xiaohongshu", "xiaohongshu"), ("douyin", "douyin"),
    ("douyin_signing", "douyin"), ("kuaishou", "kuaishou"), ("instagram", "instagram"),
])
def test_missing_snapshot_through_each_browser_consumer_stays_private(routed, consumer, platform, capsys):
    from login_sessions import LoginSessionError

    modules, sessions = routed
    sessions.failure = LoginSessionError("login_session_missing")
    readers = {"xiaohongshu": modules.xiaohongshu._extract_chrome_cookies,
               "douyin": modules.douyin._extract_cookies,
               "douyin_signing": modules.douyin_signing._load_chrome_cookie_jar,
               "kuaishou": modules.kuaishou._browser_cookies,
               "instagram": modules.instagram._browser_cookies}
    with pytest.raises((modules.browser.ChromeCookieAccessError,
                        modules.douyin_signing._CookieAccessSigningFailure,
                        modules.errors.TemporaryAccessError)) as caught:
        readers[consumer](token(platform))
    assert "dedicated_login_unavailable" in str(caught.value)
    assert token(platform) not in str(caught.value)
    assert sessions.calls == [token(platform)]
    assert capsys.readouterr() == ("", "")


def test_cancellation_precedes_any_snapshot_access(routed):
    from chrome_cookie_runtime import cookie_read_scope
    from yt_dlp import cookies

    modules, sessions = routed
    with cookie_read_scope(lambda: True), pytest.raises(modules.errors.DownloadCancelledError):
        cookies.extract_cookies_from_browser("chrome", profile=token("douyin"))
    assert sessions.calls == []


def test_cookie_adapter_restores_only_its_own_function(isolated_app):
    from yt_dlp import cookies

    previous = cookies._extract_chrome_cookies
    restore = install_session_cookies(SyntheticSessions())
    restore()
    assert cookies._extract_chrome_cookies is previous


@pytest.mark.parametrize("signal", [KeyboardInterrupt, SystemExit])
def test_cookie_adapter_preserves_control_signals(routed, signal):
    from yt_dlp import cookies

    _, sessions = routed
    sessions.failure = signal()
    with pytest.raises(signal):
        cookies.extract_cookies_from_browser("chrome", profile=token("douyin"))


def host_only_jar():
    jar = synthetic_jar("youtube")
    cookie = next(iter(jar))
    jar.clear()
    cookie.domain = "accounts.google.com"
    cookie.domain_specified = False
    cookie.domain_initial_dot = False
    jar.set_cookie(cookie)
    return jar


def test_real_ytdlp_merge_and_requests_preparation_preserve_host_only_scope(routed, monkeypatch):
    from urllib.request import Request as URLRequest

    import requests
    from yt_dlp import YoutubeDL

    _, sessions = routed
    monkeypatch.setattr(sessions, "cookie_jar", lambda profile: host_only_jar())
    with YoutubeDL({"cookiesfrombrowser": ("chrome", token("youtube")), "quiet": True,
                    "no_warnings": True, "cachedir": False}) as downloader:
        jar = downloader.cookiejar
        request = URLRequest("https://sub.accounts.google.com/")
        jar.add_cookie_header(request)
        assert not request.has_header("Cookie")
        handler = downloader._request_director.handlers["Requests"]
        session = handler._get_instance(cookiejar=jar, legacy_ssl_support=None)
        for url, expected in [("https://accounts.google.com/", True),
                              ("https://sub.accounts.google.com/", False),
                              ("http://accounts.google.com/", False),
                              ("https://google.com/", False)]:
            prepared = session.prepare_request(requests.Request("GET", url))
            assert ("Cookie" in prepared.headers) is expected


def test_requests_redirect_preparation_keeps_host_only_cookie_off_other_hosts(routed, monkeypatch):
    import requests
    from yt_dlp import YoutubeDL

    _, sessions = routed
    monkeypatch.setattr(sessions, "cookie_jar", lambda profile: host_only_jar())
    with YoutubeDL({"cookiesfrombrowser": ("chrome", token("youtube")), "quiet": True,
                    "no_warnings": True, "cachedir": False}) as downloader:
        handler = downloader._request_director.handlers["Requests"]
        session = handler._get_instance(cookiejar=downloader.cookiejar, legacy_ssl_support=None)
        prepared = session.prepare_request(requests.Request("GET", "https://accounts.google.com/"))
        assert "Cookie" in prepared.headers
        response = requests.Response()
        response.status_code = 302
        response.url = prepared.url
        response.request = prepared
        response._content = b""
        response.headers["Location"] = "https://sub.accounts.google.com/"
        redirects = session.resolve_redirects(response, prepared, yield_requests=True)
        try:
            redirected = next(redirects)
            assert redirected.url == "https://sub.accounts.google.com/"
            assert "Cookie" not in redirected.headers
        finally:
            redirects.close()


def test_summary_requests_instance_rebuilds_cookie_header_without_network():
    import requests

    with requests.Session() as session:
        session.trust_env = False
        session.cookies = mark_session_cookies(host_only_jar())
        install_session_requests(session)
        prepared = session.prepare_request(requests.Request(
            "GET", "https://sub.accounts.google.com/", headers={"Cookie": "synthetic=value"}))
        assert "Cookie" not in prepared.headers
        prepared = session.prepare_request(requests.Request(
            "GET", "https://unrelated.invalid/", headers={"Host": "accounts.google.com"}))
        assert "Cookie" not in prepared.headers
        assert "Host" not in prepared.headers
        prepared = session.prepare_request(requests.Request("GET", "https://accounts.google.com/"))
        assert "Cookie" in prepared.headers


def test_non_dedicated_requests_instance_is_not_modified():
    import requests

    with requests.Session() as session:
        original = session.prepare_request
        install_session_requests(session)
        assert session.prepare_request == original


def test_legacy_ytdlp_merge_keeps_existing_cookie_policy(routed):
    from yt_dlp import cookies

    jar = host_only_jar()
    merged = cookies._merge_cookie_jars([jar])
    assert merged._policy.strict_ns_domain == jar._policy.strict_ns_domain


def test_standalone_ytdlp_instance_preserves_cookie_scope_without_global_hooks():
    import requests
    from yt_dlp import YoutubeDL
    from yt_dlp.networking._requests import RequestsRH

    original = RequestsRH._create_instance
    with YoutubeDL({"quiet": True, "cachedir": False}) as downloader:
        downloader.cookiejar = mark_session_cookies(host_only_jar())
        install_session_ytdlp(downloader)
        handler = downloader._request_director.handlers["Requests"]
        session = handler._get_instance(cookiejar=downloader.cookiejar, legacy_ssl_support=None)
        prepared = session.prepare_request(requests.Request("GET", "https://sub.accounts.google.com/"))
        assert "Cookie" not in prepared.headers
        prepared = session.prepare_request(requests.Request("GET", "https://accounts.google.com/"))
        assert "Cookie" in prepared.headers
        assert RequestsRH._create_instance is original
