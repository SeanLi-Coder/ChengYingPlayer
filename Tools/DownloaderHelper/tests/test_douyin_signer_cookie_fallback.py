"""Keep synthetic signing HTTP retries in the same scoped cookie session."""

from __future__ import annotations

import contextlib
import socket
import sys
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
from http.cookiejar import Cookie, CookieJar
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "rednote"))

from app import douyin_signing as signing
from app.errors import DownloadCancelledError, TemporaryAccessError

PROFILE_URL = "https://www.douyin.com/user/fixture-author"
GLUE_HTML = '<script data-sdk-glue="init">window.fixture = true;</script>'
SHELL_HTML = "<html><body>Temporary page shell</body></html>"


@pytest.fixture(autouse=True)
def reject_external_resources(monkeypatch):
    def blocked(*args, **kwargs):
        raise AssertionError("External network, browser, and cookie access is forbidden")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket.socket, "connect_ex", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)
    monkeypatch.setattr(signing, "_load_chrome_cookie_jar", blocked)
    monkeypatch.setattr("playwright.sync_api.sync_playwright", blocked)
    monkeypatch.setattr(signing, "chrome_cookie_read_scope", lambda *a, **k: contextlib.nullcontext())


def cookie(name, value, *, domain="www.douyin.com", path="/", secure=True, expires=None):
    return Cookie(
        version=0, name=name, value=value, port=None, port_specified=False,
        domain=domain, domain_specified=domain.startswith("."),
        domain_initial_dot=domain.startswith("."), path=path, path_specified=True,
        secure=secure, expires=expires, discard=expires is None, comment=None, comment_url=None,
        rest={"HttpOnly": None}, rfc2109=False,
    )


def cookie_key(value):
    return value["name"], value["domain"], value["path"]


class SourceResponse(BytesIO):
    status = 200

    def __init__(self, source_html, set_cookies):
        super().__init__(source_html.encode())
        self.headers = Message()
        self.headers["Content-Type"] = "text/html; charset=utf-8"
        self.headers["Content-Length"] = str(len(self.getvalue()))
        for header in set_cookies:
            self.headers.add_header("Set-Cookie", header)

    def info(self):
        return self.headers

    def geturl(self):
        return PROFILE_URL


class Context:
    def __init__(self, accept):
        self.stored = {}
        self.batches = []
        self.request_count = 0
        self.accept = accept
        self.request = SimpleNamespace(get=self.get)
        self.closed = False
        self.page = SimpleNamespace(
            route=lambda *args: None, goto=lambda *args, **kwargs: None,
            close=lambda: None,
        )

    def add_cookies(self, values):
        self.batches.append([dict(value) for value in values])
        for value in values:
            if value.get("expires") == 1:
                self.stored.pop(cookie_key(value), None)
            else:
                self.stored[cookie_key(value)] = dict(value)

    def get(self, url, **kwargs):
        assert url == PROFILE_URL
        self.request_count += 1
        return SimpleNamespace(
            status=200, url=url, dispose=lambda: None,
            text=lambda: GLUE_HTML if self.accept(self.stored) else SHELL_HTML,
        )

    def new_page(self):
        return self.page

    def close(self):
        self.closed = True


def install_session(monkeypatch, *, set_cookies=(), initial=(), accept=lambda values: True,
                    source_html=SHELL_HTML, context_hook=None):
    jar = CookieJar()
    jar.set_cookie(cookie("sessionid", "fixture-session", domain=".douyin.com"))
    for value in initial:
        jar.set_cookie(value)
    context = Context(accept)
    browser = SimpleNamespace(
        version="154.0.0.0", new_context=lambda **kwargs: context, close=lambda: None,
    )
    manager = contextlib.nullcontext(SimpleNamespace(
        chromium=SimpleNamespace(launch=lambda **kwargs: browser),
    ))
    monkeypatch.setattr(signing, "_load_chrome_cookie_jar", lambda profile: jar)
    monkeypatch.setattr("playwright.sync_api.sync_playwright", lambda: manager)
    monkeypatch.setattr(signing, "_wait_for_signer", lambda *args, **kwargs: None)
    monkeypatch.setattr(signing, "_wait_with_cancel", lambda *args, **kwargs: None)

    def build_opener(processor):
        assert processor.cookiejar is jar

        def open_response(request, **kwargs):
            response = SourceResponse(source_html, set_cookies)
            jar.extract_cookies(response, request)
            if context_hook:
                context_hook(context)
            return response

        return SimpleNamespace(open=open_response)

    monkeypatch.setattr(signing, "build_opener", build_opener)
    return context, jar


def run_session():
    return signing._run_with_signing_page(
        PROFILE_URL, cookie_profile="Fixture Profile", should_cancel=lambda: False,
        navigation_timeout_ms=1000, signer_timeout_ms=1000, signer_settle_ms=0,
        budget=signing.new_signed_discovery_budget(), status_callback=None,
        operation=lambda page: "verified-operation",
    )


def test_missing_glue_retry_receives_new_host_only_cookie(monkeypatch):
    key = ("fixture_nonce", "www.douyin.com", "/user")
    context, _ = install_session(
        monkeypatch,
        set_cookies=["fixture_nonce=new; Path=/user; Secure; HttpOnly"],
        accept=lambda values: values.get(key, {}).get("value") == "new",
    )

    assert run_session() == "verified-operation"
    assert context.request_count == 1
    assert context.stored[key] == {
        "name": "fixture_nonce", "value": "new", "domain": "www.douyin.com",
        "path": "/user", "secure": True, "httpOnly": True,
    }
    assert context.closed


def test_missing_glue_retry_updates_cookie_without_overwriting_unchanged_browser_state(monkeypatch):
    key = ("fixture_nonce", ".douyin.com", "/user")
    session_key = ("sessionid", ".douyin.com", "/")

    def update_browser(context):
        context.stored[session_key]["value"] = "fresh-browser-session"

    context, _ = install_session(
        monkeypatch,
        initial=[cookie("fixture_nonce", "old", domain=".douyin.com", path="/user")],
        set_cookies=["fixture_nonce=new; Domain=.douyin.com; Path=/user; Secure; HttpOnly"],
        context_hook=update_browser,
        accept=lambda values: values[key]["value"] == "new",
    )

    assert run_session() == "verified-operation"
    assert context.stored[session_key]["value"] == "fresh-browser-session"
    assert [value["name"] for value in context.batches[-1]] == ["fixture_nonce"]


def test_missing_glue_retry_applies_only_matching_cookie_deletion(monkeypatch):
    removed_key = ("fixture_nonce", "www.douyin.com", "/user")
    retained_key = ("fixture_nonce", "www.douyin.com", "/")
    context, _ = install_session(
        monkeypatch,
        initial=[cookie("fixture_nonce", "scoped", path="/user"), cookie("fixture_nonce", "root")],
        set_cookies=["fixture_nonce=; Max-Age=0; Path=/user; Secure; HttpOnly"],
        accept=lambda values: removed_key not in values,
    )

    assert run_session() == "verified-operation"
    assert context.stored[retained_key]["value"] == "root"
    assert context.batches[-1] == [{
        "name": "fixture_nonce", "value": "", "domain": "www.douyin.com",
        "path": "/user", "secure": True, "httpOnly": True, "expires": 1,
    }]


@pytest.mark.parametrize("source_html", ["<body>请先登录</body>", "<body>请完成下列验证</body>"])
def test_explicit_authentication_does_not_retry_or_sync_cookie_changes(monkeypatch, source_html):
    context, _ = install_session(
        monkeypatch, source_html=source_html,
        set_cookies=["fixture_nonce=new; Path=/; Secure"],
    )

    with pytest.raises(signing._AuthenticationSigningFailure):
        run_session()

    assert context.request_count == 0
    assert len(context.batches) == 1


def test_source_cookie_updates_reject_unrelated_and_lookalike_domains(monkeypatch):
    context, _ = install_session(monkeypatch, set_cookies=[
        "foreign=bad; Domain=attacker.example; Path=/; Secure",
        "lookalike=bad; Domain=douyin.com.attacker.example; Path=/; Secure",
        "valid=new; Domain=.douyin.com; Path=/; Secure",
    ])

    assert run_session() == "verified-operation"
    assert {value["name"] for value in context.stored.values()} == {"sessionid", "valid"}


@pytest.mark.parametrize("failure_stage", ["source", "browser", "cookie-sync"])
@pytest.mark.parametrize("failure_type", [
    signing._IdentitySigningFailure, signing._AuthenticationSigningFailure,
    signing._NetworkFilterSigningFailure, DownloadCancelledError, KeyboardInterrupt, SystemExit,
])
def test_control_and_identity_failures_preserve_their_type(monkeypatch, failure_type, failure_stage):
    context, _ = install_session(monkeypatch, set_cookies=["fixture_nonce=new; Path=/; Secure"])

    def fail_source(*args, **kwargs):
        raise failure_type("fixture-control")

    if failure_stage == "source":
        monkeypatch.setattr(signing, "_fetch_source_html_with_urllib", fail_source)
    elif failure_stage == "browser":
        context.request.get = fail_source
    else:
        initial_add = context.add_cookies

        def failing_add(values):
            if context.batches:
                fail_source()
            initial_add(values)

        context.add_cookies = failing_add
    with pytest.raises(failure_type):
        run_session()
    assert context.request_count == 0


@pytest.mark.parametrize("failure_stage", ["source", "browser", "cookie-sync"])
def test_wrapped_cancellation_preserves_its_type(monkeypatch, failure_stage):
    context, _ = install_session(monkeypatch, set_cookies=["fixture_nonce=new; Path=/; Secure"])

    def fail_source(*args, **kwargs):
        raise RuntimeError("fixture-wrapper") from DownloadCancelledError("fixture-cancel")

    if failure_stage == "source":
        monkeypatch.setattr(signing, "_fetch_source_html_with_urllib", fail_source)
    elif failure_stage == "browser":
        context.request.get = fail_source
    else:
        initial_add = context.add_cookies

        def failing_add(values):
            if context.batches:
                fail_source()
            initial_add(values)

        context.add_cookies = failing_add
    with pytest.raises(DownloadCancelledError):
        run_session()
    assert context.request_count == 0


def test_parallel_profile_cookie_updates_remain_context_local():
    def update_profile(index):
        jar = CookieJar()
        jar.set_cookie(cookie("sessionid", f"fixture-profile-{index}"))
        jar.set_cookie(cookie("fixture_nonce", "old", path="/user", secure=False))
        baseline = signing._cookie_jar_to_playwright(jar)
        context = Context(lambda values: True)
        context.add_cookies(baseline)
        jar.set_cookie(cookie("fixture_nonce", f"nonce-{index}", path="/user", secure=False))
        signing._sync_changed_source_cookies(context, jar, baseline)
        return index, context.stored

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(update_profile, range(8)))

    for index, stored in results:
        assert stored[("sessionid", "www.douyin.com", "/")]["value"] == f"fixture-profile-{index}"
        assert stored[("fixture_nonce", "www.douyin.com", "/user")] == {
            "name": "fixture_nonce", "value": f"nonce-{index}",
            "domain": "www.douyin.com", "path": "/user", "secure": False, "httpOnly": True,
        }


def test_all_source_cookies_revoked_stop_before_authenticated_retry(monkeypatch):
    context, _ = install_session(monkeypatch, set_cookies=[
        "sessionid=; Max-Age=0; Domain=.douyin.com; Path=/; Secure",
    ])
    with pytest.raises(signing._AuthenticationSigningFailure):
        run_session()
    assert context.request_count == 0
    assert context.closed


def test_failed_cookie_sync_abandons_context_before_fallback(monkeypatch):
    context, _ = install_session(
        monkeypatch, initial=[cookie("fixture_nonce", "old")],
        set_cookies=["fixture_nonce=new; Path=/; Secure"],
    )
    initial_add = context.add_cookies

    def failing_add(values):
        if context.batches:
            raise RuntimeError("Fixture browser cookie update failed")
        initial_add(values)

    context.add_cookies = failing_add
    with pytest.raises(signing._TransientSigningFailure) as failure:
        run_session()
    assert failure.value.category == "signer-cookie-sync"
    assert context.request_count == 0
    assert context.closed


@pytest.mark.parametrize("clear_expired_source_cookies", [False, True])
def test_natural_expiration_does_not_revoke_newer_browser_cookie(monkeypatch, clear_expired_source_cookies):
    clock = [2_000_000_000]
    monkeypatch.setattr(signing.time, "time", lambda: clock[0])
    key = ("fixture_nonce", "www.douyin.com", "/")

    def newer_browser_cookie(context):
        clock[0] += 2
        context.stored[key].update(value="fresh-browser-value", expires=clock[0] + 3600)
        if clear_expired_source_cookies:
            # CookieJar.add_cookie_header() clears expired cookies on requests.
            jar.clear_expired_cookies()

    context, jar = install_session(
        monkeypatch, initial=[cookie("fixture_nonce", "old", expires=clock[0] + 1)],
        context_hook=newer_browser_cookie,
        accept=lambda values: values.get(key, {}).get("value") == "fresh-browser-value",
    )
    assert run_session() == "verified-operation"
    assert context.stored[key]["value"] == "fresh-browser-value"
    assert len(context.batches) == 1


@pytest.mark.parametrize("clear_expired_source_cookies", [False, True])
def test_all_source_cookies_expire_without_revoking_newer_browser_session(monkeypatch, clear_expired_source_cookies):
    clock = [2_000_000_000]
    monkeypatch.setattr(signing.time, "time", lambda: clock[0])
    key = ("sessionid", ".douyin.com", "/")

    def newer_browser_session(context):
        clock[0] += 2
        context.stored[key].update(value="fresh-browser-session", expires=clock[0] + 3600)
        if clear_expired_source_cookies:
            jar.clear_expired_cookies()

    context, jar = install_session(
        monkeypatch,
        initial=[cookie("sessionid", "old", domain=".douyin.com", expires=clock[0] + 1)],
        context_hook=newer_browser_session,
        accept=lambda values: values.get(key, {}).get("value") == "fresh-browser-session",
    )
    assert run_session() == "verified-operation"
    assert context.request_count == 1
    assert context.stored[key]["value"] == "fresh-browser-session"
    assert len(context.batches) == 1


def test_initial_empty_cookie_jar_still_requires_authentication():
    with pytest.raises(signing._AuthenticationSigningFailure):
        signing._cookie_jar_to_playwright(CookieJar())


@pytest.mark.parametrize("kind", ["profile", "detail"])
@pytest.mark.parametrize("always_fail", [False, True])
def test_cookie_sync_failure_uses_bounded_fresh_sessions(monkeypatch, kind, always_fail):
    calls = []

    def fresh_session(*args, **kwargs):
        calls.append(kwargs["cookie_profile"])
        if always_fail or len(calls) == 1:
            raise signing._CookieSyncSigningFailure(
                "Fixture cookie update failed", category="signer-cookie-sync",
            )
        return "verified-operation"

    monkeypatch.setattr(signing, "_run_with_signing_page", fresh_session)
    monkeypatch.setattr(signing, "_wait_without_page_with_cancel", lambda *a, **k: None)

    def fetch():
        if kind == "profile":
            return signing.fetch_signed_profile_awemes(
                PROFILE_URL, "fixture-author", cookie_profile="Fixture Profile",
            )
        return signing.fetch_signed_aweme_detail(
            "1234567890123456789", verification_url=PROFILE_URL,
            expected_sec_uid="fixture-author", cookie_profile="Fixture Profile",
        )

    if always_fail:
        with pytest.raises(TemporaryAccessError, match="signer-cookie-sync"):
            fetch()
        assert calls == ["Fixture Profile"] * 3
    else:
        assert fetch() == "verified-operation"
        assert calls == ["Fixture Profile"] * 2
