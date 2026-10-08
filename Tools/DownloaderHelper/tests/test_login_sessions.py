"""Exercise private login sessions without any real account or browser profile."""

from __future__ import annotations

import contextlib
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from urllib.request import Request

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import login_sessions as sessions


def cookie(**changes):
    result = {
        "name": "sessionid",
        "value": "SYNTHETIC_SESSION",
        "domain": ".douyin.com",
        "path": "/",
        "expires": -1,
        "httpOnly": True,
        "secure": True,
        "sameSite": "Lax",
    }
    result.update(changes)
    return result


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("The bounded session operation did not finish")


def state(manager, platform="douyin"):
    return next(
        record
        for record in manager.status()["platforms"]
        if record["platform"] == platform
    )


class FakePage:
    def __init__(self, owner):
        self.owner = owner
        self.closed = False

    def goto(self, url, **options):
        self.owner.calls.append(("goto", threading.get_ident(), url, options))
        if self.owner.navigation_error:
            from playwright.sync_api import Error as BrowserError

            raise BrowserError("PRIVATE_PROXY_PASSWORD /Users/private/profile")

    def is_closed(self):
        return self.closed

    def wait_for_timeout(self, milliseconds):
        time.sleep(0.01)


class FakeContext:
    def __init__(self, owner):
        self.owner = owner
        self.pages = [FakePage(owner)]
        self.callbacks = {}

    def on(self, event, callback):
        self.callbacks[event] = callback

    def set_default_timeout(self, timeout):
        assert timeout == 5000

    def cookies(self):
        self.owner.calls.append(("cookies", threading.get_ident()))
        return self.owner.cookies

    def close(self):
        self.owner.calls.append(("close", threading.get_ident()))
        self.owner.close_gate.wait(3)
        if self.owner.close_error:
            raise RuntimeError("PRIVATE_CLOSE_SECRET")
        self.callbacks.get("close", lambda: None)()


class FakePlaywright:
    def __init__(self):
        self.calls = []
        self.cookies = [cookie()]
        self.navigation_error = False
        self.launch_error = False
        self.close_error = False
        self.close_gate = threading.Event()
        self.close_gate.set()
        self.context = FakeContext(self)
        self.chromium = SimpleNamespace(launch_persistent_context=self.launch)

    def launch(self, path, **options):
        self.calls.append(("launch", threading.get_ident(), path, options))
        if self.launch_error:
            raise RuntimeError("PRIVATE_COOKIE_VALUE /Users/private/daily-browser")
        return self.context

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.calls.append(("driver_stop", threading.get_ident()))


@pytest.fixture(autouse=True)
def no_external_access(request, monkeypatch):
    if request.node.name == "test_real_chrome_synthetic_capture_and_restart":
        return

    def reject(*args, **kwargs):
        raise AssertionError("External access or a real process is forbidden")

    monkeypatch.setattr(socket.socket, "connect", reject)
    monkeypatch.setattr(socket.socket, "connect_ex", reject)
    monkeypatch.setattr(subprocess, "Popen", reject)


@pytest.fixture
def browser(monkeypatch):
    fake = FakePlaywright()
    monkeypatch.setattr("playwright.sync_api.sync_playwright", lambda: fake)
    return fake


@pytest.fixture
def manager(tmp_path):
    value = sessions.LoginSessions(tmp_path, lambda: None)
    try:
        yield value
    finally:
        assert value.close()


def save(manager, browser, platform="douyin"):
    manager.start(platform)
    wait_for(lambda: state(manager, platform)["status"] == "login_open")
    manager.finish(platform)
    wait_for(lambda: not manager.active())
    assert state(manager, platform)["status"] == "saved"
    return manager.current_token(platform)


def test_empty_state_is_safe_and_never_starts_chrome(manager):
    assert manager.status() == {
        "schema_version": 1,
        "platforms": [
            {"platform": platform, "status": "idle", "has_saved_session": False}
            for platform in sessions.PLATFORM_URLS
        ],
    }
    assert not manager.active()
    with pytest.raises(sessions.LoginSessionError, match="login_session_missing"):
        manager.current_token("douyin")


def test_writable_shared_data_directory_is_rejected(tmp_path):
    tmp_path.chmod(0o777)
    try:
        with pytest.raises(
            sessions.LoginSessionError, match="login_storage_unavailable"
        ):
            sessions.LoginSessions(tmp_path, lambda: None)
        assert not (tmp_path / "login-sessions").exists()
    finally:
        tmp_path.chmod(0o700)


@pytest.mark.parametrize(
    "value",
    ["../douyin", "Default", "Profile 1", "http://douyin.com", "", None, 12, {}, []],
)
def test_invalid_platform_fails_before_browser_or_proxy(manager, value):
    for operation in (manager.start, manager.finish, manager.current_token):
        with pytest.raises(sessions.LoginSessionError) as raised:
            operation(value)
        assert raised.value.code == "login_platform_invalid"
        assert raised.value.status == 422


def test_explicit_save_uses_one_owner_thread_and_survives_restart(
    manager, browser, tmp_path
):
    token = save(manager, browser)
    assert sessions._parse_token(token)[0] == "douyin"
    assert all(call[1] != threading.get_ident() for call in browser.calls)
    assert len({call[1] for call in browser.calls}) == 1
    assert [call[0] for call in browser.calls] == [
        "launch",
        "goto",
        "cookies",
        "close",
        "driver_stop",
    ]
    launch = browser.calls[0]
    assert Path(launch[2]) == tmp_path / "login-sessions/douyin/chrome"
    assert launch[3]["channel"] == "chrome"
    assert launch[3]["headless"] is False
    assert "--no-proxy-server" in launch[3]["args"]
    assert browser.calls[1][2] == "https://www.douyin.com/"
    assert "SYNTHETIC_SESSION" not in json.dumps(manager.status())
    assert str(tmp_path) not in json.dumps(manager.status())
    assert token not in json.dumps(manager.status())
    assert next(iter(manager.cookie_jar(token))).value == "SYNTHETIC_SESSION"
    assert manager.close()
    reopened = sessions.LoginSessions(tmp_path, lambda: None)
    try:
        assert reopened.current_token("douyin") == token
        assert state(reopened) == {
            "platform": "douyin",
            "status": "saved",
            "has_saved_session": True,
        }
    finally:
        reopened.close()


def test_snapshot_is_immutable_and_retry_never_switches_to_new_identity(
    manager, browser
):
    first = save(manager, browser)
    browser.cookies = [cookie(value="SYNTHETIC_OTHER_ACCOUNT")]
    second = save(manager, browser)
    assert second != first
    assert next(iter(manager.cookie_jar(first))).value == "SYNTHETIC_SESSION"
    assert next(iter(manager.cookie_jar(second))).value == "SYNTHETIC_OTHER_ACCOUNT"
    assert manager.current_token("douyin") == second


def test_one_global_login_and_explicit_finish_only(manager, browser):
    manager.start("douyin")
    wait_for(lambda: state(manager)["status"] == "login_open")
    assert manager.active()
    with pytest.raises(sessions.LoginSessionError, match="login_busy"):
        manager.start("bilibili")
    with pytest.raises(sessions.LoginSessionError, match="login_not_open"):
        manager.finish("bilibili")
    browser.context.pages[0].closed = True
    wait_for(lambda: not manager.active())
    assert state(manager)["status"] == "idle"
    assert all(call[0] != "cookies" for call in browser.calls)
    with pytest.raises(sessions.LoginSessionError, match="login_session_missing"):
        manager.current_token("douyin")


def test_close_is_bounded_and_keeps_activity_barrier_until_owned_browser_exits(
    manager, browser
):
    manager.start("douyin")
    wait_for(lambda: state(manager)["status"] == "login_open")
    browser.close_gate.clear()
    start = time.monotonic()
    assert not manager.close(timeout=0.02)
    assert time.monotonic() - start < 0.5
    assert manager.active()
    assert all(call[0] != "cookies" for call in browser.calls)
    browser.close_gate.set()
    wait_for(lambda: not manager.active())
    assert manager.close()
    with pytest.raises(sessions.LoginSessionError, match="login_closed"):
        manager.start("douyin")


def test_unknown_close_failure_keeps_activity_barrier(tmp_path, browser):
    manager = sessions.LoginSessions(tmp_path, lambda: None)
    try:
        manager.start("douyin")
        wait_for(lambda: state(manager)["status"] == "login_open")
        browser.close_error = True
        assert not manager.close()
        assert manager.active()
        assert state(manager)["error_code"] == "login_cleanup_failed"
        assert "PRIVATE_CLOSE_SECRET" not in json.dumps(manager.status())
        assert not manager._thread.is_alive()
    finally:
        # This fake context has no process. Retire only the fixture descriptor;
        # production never clears an unknown browser's cleanup barrier.
        os.close(manager._root_fd)
        manager._root_fd = -1


@pytest.mark.parametrize(
    "platform,domain",
    [
        ("douyin", ".douyin.com"),
        ("xiaohongshu", ".xiaohongshu.com"),
        ("kuaishou", ".kuaishou.com"),
        ("instagram", ".instagram.com"),
        ("bilibili", ".bilibili.com"),
        ("youtube", ".youtube.com"),
    ],
)
def test_platform_login_uses_fixed_url_and_separate_storage(
    manager, browser, platform, domain
):
    names = {
        "douyin": ["sessionid"],
        "xiaohongshu": ["web_session", "id_token"],
        "kuaishou": ["kuaishou.server.web_st"],
        "instagram": ["sessionid"],
        "bilibili": ["SESSDATA"],
        "youtube": ["SAPISID"],
    }[platform]
    browser.cookies = [cookie(domain=domain, name=name) for name in names]
    token = save(manager, browser, platform)
    assert browser.calls[1][2] == sessions.PLATFORM_URLS[platform]
    assert Path(browser.calls[0][2]).parent.name == platform
    assert sessions._parse_token(token)[0] == platform
    assert next(iter(manager.cookie_jar(token))).domain == domain


@pytest.mark.parametrize(
    "url,server,credentials",
    [
        ("http://127.0.0.1:7897", "http://127.0.0.1:7897", {}),
        (
            "https://user:pass@127.0.0.1:7897",
            "https://127.0.0.1:7897",
            {"username": "user", "password": "pass"},
        ),
        ("socks5://127.0.0.1:7897", "socks5://127.0.0.1:7897", {}),
    ],
)
def test_proxy_is_frozen_explicit_and_not_exposed(
    tmp_path, browser, url, server, credentials
):
    current = [url]
    manager = sessions.LoginSessions(tmp_path, lambda: current[0])
    try:
        manager.start("douyin")
        current[0] = None
        wait_for(lambda: state(manager)["status"] == "login_open")
        options = browser.calls[0][3]
        assert options["proxy"] == {
            "server": server,
            "bypass": "<-loopback>",
            **credentials,
        }
        assert "--no-proxy-server" not in options["args"]
        assert "7897" not in json.dumps(manager.status())
    finally:
        assert manager.close()


@pytest.mark.parametrize(
    "url",
    ["socks5://user:pass@localhost:1234", "bad-proxy", "http://user:PRIVATE_SECRET@"],
)
def test_invalid_proxy_blocks_without_direct_fallback(tmp_path, browser, url):
    manager = sessions.LoginSessions(tmp_path, lambda: url)
    try:
        with pytest.raises(sessions.LoginSessionError, match="login_proxy_unavailable"):
            manager.start("douyin")
        assert browser.calls == []
        assert not manager.active()
    finally:
        manager.close()


def test_launch_error_never_leaks_paths_or_private_values(manager, browser):
    browser.launch_error = True
    manager.start("douyin")
    wait_for(lambda: not manager.active())
    assert state(manager) == {
        "platform": "douyin",
        "status": "error",
        "has_saved_session": False,
        "error_code": "login_browser_unavailable",
    }


def test_navigation_failure_keeps_manual_window_and_never_retries_direct(
    manager, browser
):
    browser.navigation_error = True
    save(manager, browser)
    assert len([call for call in browser.calls if call[0] == "goto"]) == 1


def test_empty_save_fails_and_keeps_previous_identity(manager, browser):
    first = save(manager, browser)
    browser.cookies = []
    manager.start("douyin")
    wait_for(lambda: state(manager)["status"] == "login_open")
    manager.finish("douyin")
    wait_for(lambda: not manager.active())
    assert state(manager)["error_code"] == "login_session_empty"
    assert state(manager)["has_saved_session"] is True
    assert manager.current_token("douyin") == first


def test_unrelated_expired_and_partitioned_cookies_are_not_exported(manager, browser):
    browser.cookies += [
        cookie(domain=".evil-douyin.com", value="UNRELATED_SECRET"),
        cookie(domain=".google.com"),
        cookie(partitionKey="https://other.invalid"),
        cookie(partitionKey=""),
        cookie(partitionKey=None),
        cookie(name="old", expires=1),
    ]
    token = save(manager, browser)
    assert len(manager.cookie_jar(token)) == 1


@pytest.mark.parametrize(
    "changes",
    [
        {"name": "bad\nname"},
        {"name": ""},
        {"value": "bad\rvalue"},
        {"domain": "..douyin.com"},
        {"path": "relative"},
        {"secure": 1},
        {"expires": True},
        {"expires": 0},
        {"expires": float("nan")},
        {"expires": float("inf")},
        {"expires": 10**400},
        {"httpOnly": "yes"},
        {"sameSite": "unexpected"},
        {"value": "x" * 16_385},
    ],
)
def test_malformed_cookie_snapshot_rejected(changes):
    with pytest.raises(sessions.LoginSessionError, match="login_session_invalid"):
        sessions._snapshot_cookies([cookie(**changes)], "douyin")


@pytest.mark.parametrize(
    "token",
    [
        "../chrome/Cookies",
        "Default",
        "cy-session:douyin:../../private",
        "cy-session:other:" + "a" * 32,
        "cy-session:douyin:" + "a" * 33,
        None,
        1,
        {},
    ],
)
def test_invalid_token_never_becomes_filesystem_path(manager, token):
    with pytest.raises(sessions.LoginSessionError, match="login_session_invalid"):
        manager.cookie_jar(token)


def test_domain_scoping_host_only_cookie_and_secure_flag(manager, browser):
    browser.cookies = [cookie(domain="www.douyin.com")]
    jar = manager.cookie_jar(save(manager, browser))
    for url, permitted in [
        ("https://www.douyin.com/", True),
        ("https://child.www.douyin.com/", False),
        ("https://douyin.com/", False),
        ("https://www.douyin.com.evil.invalid/", False),
        ("http://www.douyin.com/", False),
    ]:
        request = Request(url)
        jar.add_cookie_header(request)
        assert bool(request.get_header("Cookie")) == permitted


def test_snapshot_and_index_are_owner_only(manager, browser, tmp_path):
    save(manager, browser)
    for path in (tmp_path / "login-sessions").rglob("*"):
        assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)


@pytest.mark.parametrize(
    "location",
    [
        "login-sessions",
        "login-sessions/douyin",
        "login-sessions/douyin/chrome",
        "login-sessions/douyin/snapshots",
    ],
)
def test_symlinked_private_directory_is_never_followed(tmp_path, browser, location):
    outside = tmp_path / "unrelated"
    outside.mkdir()
    target = tmp_path / location
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.symlink_to(outside, target_is_directory=True)
    try:
        manager = sessions.LoginSessions(tmp_path, lambda: None)
    except sessions.LoginSessionError:
        assert not list(outside.iterdir())
        return
    try:
        manager.start("douyin")
        wait_for(lambda: state(manager)["status"] in {"login_open", "error"})
        if state(manager)["status"] == "login_open":
            manager.finish("douyin")
        wait_for(lambda: not manager.active())
        assert state(manager)["status"] == "error"
        assert not list(outside.iterdir())
    finally:
        manager.close()


@pytest.mark.parametrize(
    "variant",
    ["symlink", "hardlink", "public", "oversized", "duplicate", "foreign-token"],
)
def test_untrusted_snapshot_is_rejected_without_exposure(
    manager, browser, tmp_path, variant
):
    token = save(manager, browser)
    revision = sessions._parse_token(token)[1]
    path = tmp_path / "login-sessions/douyin/snapshots" / (revision + ".json")
    if variant == "symlink":
        path.unlink()
        private = tmp_path / "PRIVATE_SECRET"
        private.write_text("secret unrelated content")
        path.symlink_to(private)
    elif variant == "hardlink":
        os.link(path, tmp_path / "private-copy")
    elif variant == "public":
        path.chmod(0o644)
    elif variant == "oversized":
        with path.open("r+b") as handle:
            handle.truncate(sessions._MAX_BYTES + 1)
    elif variant == "duplicate":
        path.write_text(
            '{"schema_version":1,"schema_version":1,"token":"PRIVATE_SECRET"}'
        )
    else:
        payload = json.loads(path.read_text())
        payload["token"] = "cy-session:youtube:" + revision
        path.write_text(json.dumps(payload))
    with pytest.raises(sessions.LoginSessionError) as raised:
        manager.cookie_jar(token)
    assert "PRIVATE_SECRET" not in str(raised.value)
    assert str(tmp_path) not in str(raised.value)


def test_expired_snapshot_is_distinct_and_never_reads_live_profile(
    manager, browser, monkeypatch
):
    browser.cookies = [
        cookie(expires=time.time() + 60),
        cookie(name="analytics", expires=time.time() + 3600),
    ]
    token = save(manager, browser)
    now = time.time()
    monkeypatch.setattr(sessions.time, "time", lambda: now + 120)
    with pytest.raises(sessions.LoginSessionError, match="login_session_expired"):
        manager.current_token("douyin")
    with pytest.raises(sessions.LoginSessionError, match="login_session_expired"):
        manager.cookie_jar(token)
    assert len([call for call in browser.calls if call[0] == "cookies"]) == 1


@pytest.mark.parametrize(
    "platform,records",
    [
        ("douyin", [cookie(name="analytics")]),
        ("douyin", [cookie(value="")]),
        ("douyin", [cookie(path="/private")]),
        ("douyin", [cookie(domain="auth.douyin.com")]),
        ("douyin", [cookie(expires=1), cookie(name="analytics")]),
        ("xiaohongshu", [cookie(name="web_session", domain=".xiaohongshu.com")]),
        ("xiaohongshu", [cookie(name="id_token", domain=".xiaohongshu.com")]),
        ("youtube", [cookie(name="SAPISID", domain=".google.com")]),
        ("youtube", [cookie(name="analytics", domain=".youtube.com")]),
        ("bilibili", [cookie(name="analytics", domain=".bilibili.com")]),
        ("kuaishou", [cookie(name="analytics", domain=".kuaishou.com")]),
        ("instagram", [cookie(name="analytics", domain=".instagram.com")]),
    ],
)
def test_analytics_or_wrong_scope_never_count_as_login(platform, records):
    with pytest.raises(sessions.LoginSessionError, match="login_session_empty"):
        sessions._snapshot_cookies(records, platform)


@pytest.mark.parametrize(
    "name", ["SAPISID", "APISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]
)
def test_youtube_authentication_variants_require_youtube_scope(name):
    records = [cookie(name=name, domain=".youtube.com")]
    assert sessions._snapshot_cookies(records, "youtube") == records


def test_sessionid_ss_is_a_supported_douyin_authentication_variant():
    records = [cookie(name="sessionid_ss")]
    assert sessions._snapshot_cookies(records, "douyin") == records


def test_current_index_cannot_rebind_platform(manager, browser, tmp_path):
    token = save(manager, browser)
    path = tmp_path / "login-sessions/youtube/current.json"
    path.write_text(json.dumps({"schema_version": 1, "token": token}))
    path.chmod(0o600)
    with pytest.raises(sessions.LoginSessionError, match="login_session_invalid"):
        manager.current_token("youtube")


def test_shutdown_before_finish_does_not_save(manager, browser):
    manager.start("douyin")
    wait_for(lambda: state(manager)["status"] == "login_open")
    assert manager.close()
    assert not any(call[0] == "cookies" for call in browser.calls)


def test_real_chrome_synthetic_capture_and_restart(tmp_path, monkeypatch):
    if (
        sys.platform != "darwin"
        or not Path(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ).is_file()
    ):
        pytest.skip(
            "The isolated Chrome integration requires installed macOS Google Chrome"
        )
    from playwright.sync_api import sync_playwright

    launches = []

    @contextlib.contextmanager
    def isolated_playwright():
        with sync_playwright() as playwright:

            def launch(path, **options):
                assert options["proxy"] == {
                    "server": "http://127.0.0.1:9",
                    "bypass": "<-loopback>",
                }
                # Use a headless synthetic fixture instead of opening a user UI.
                # Every page request is fulfilled locally; the explicit dead
                # loopback proxy also prevents external browser transport.
                options["headless"] = True
                context = playwright.chromium.launch_persistent_context(path, **options)
                context.route(
                    "**/*",
                    lambda route: route.fulfill(
                        status=200,
                        content_type="text/html",
                        body="<title>Synthetic Login Fixture</title>",
                    ),
                )
                context.add_cookies([cookie()])
                launches.append(path)
                return context

            yield SimpleNamespace(
                chromium=SimpleNamespace(launch_persistent_context=launch)
            )

    monkeypatch.setattr("playwright.sync_api.sync_playwright", isolated_playwright)
    manager = sessions.LoginSessions(tmp_path, lambda: "http://127.0.0.1:9")
    try:
        manager.start("douyin")
        wait_for(
            lambda: state(manager)["status"] in {"login_open", "error"}, timeout=30
        )
        assert state(manager)["status"] == "login_open"
        manager.finish("douyin")
        wait_for(lambda: not manager.active(), timeout=15)
        token = manager.current_token("douyin")
        assert next(iter(manager.cookie_jar(token))).value == "SYNTHETIC_SESSION"
        assert len(launches) == 1
        assert Path(launches[0]).is_relative_to(tmp_path)
    finally:
        assert manager.close()
    restored = sessions.LoginSessions(tmp_path, lambda: None)
    try:
        assert restored.current_token("douyin") == token
        assert len(launches) == 1
    finally:
        restored.close()
