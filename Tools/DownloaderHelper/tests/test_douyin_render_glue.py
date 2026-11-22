"""Rendered-page glue recovery and the optional persistent signing profile.

Synthetic pages and fake browser objects only; network, real browsers and real
Chrome profiles are forbidden. The unchanged glue validation, authentication
gates, cancellation and the default ephemeral-context behavior are asserted
together with the new recovery path.
"""

from __future__ import annotations

import contextlib
import socket
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor" / "rednote"))

from app import douyin_signing as signing
from app.errors import DownloadCancelledError, SiteIssueCode

PROFILE_URL = "https://www.douyin.com/user/fixture-author"
GLUE_HTML = '<script data-sdk-glue="init">window.fixture = true;</script>'
SHELL_HTML = "<html><body>Temporary page shell</body></html>"
CAPTCHA_HTML = (
    "<html><head><title>验证码中间页</title></head>"
    "<body>interactive challenge</body></html>"
)


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
    monkeypatch.delenv("CHENGYING_DOUYIN_SIGNING_PROFILE_DIR", raising=False)
    monkeypatch.setattr(signing, "_wait_with_cancel", lambda *a, **k: None)


class FakePage:
    def __init__(self, contents, *, title="Fixture", url=PROFILE_URL):
        self.contents = list(contents)
        self.titles = title if isinstance(title, list) else [title] * len(contents)
        self.url = url
        self.goto_calls = []
        self.index = 0

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = url

    def content(self):
        value = self.contents[min(self.index, len(self.contents) - 1)]
        self.index += 1
        return value

    def title(self):
        return self.titles[max(0, min(self.index - 1, len(self.titles) - 1))]

    def evaluate(self, script):
        return "fixture-user-agent"

    def wait_for_timeout(self, ms):
        pass

    def route(self, *args):
        pass

    def close(self):
        pass


def run_fallback(page, **kwargs):
    return signing._rendered_page_glue_fallback(
        None, page, PROFILE_URL, 1000, lambda: False,
        budget=signing.new_signed_discovery_budget(), **kwargs,
    )


def test_render_fallback_recovers_glue_after_shell_rounds():
    page = FakePage([SHELL_HTML, SHELL_HTML, GLUE_HTML])
    assert run_fallback(page) == signing._extract_sdk_glue_tags(GLUE_HTML)
    assert page.goto_calls == []  # already on the target page; no re-navigation


def test_render_fallback_navigates_when_page_is_elsewhere():
    page = FakePage([GLUE_HTML], url="about:blank")
    assert run_fallback(page) == signing._extract_sdk_glue_tags(GLUE_HTML)
    assert page.goto_calls[0][0] == PROFILE_URL


def test_render_fallback_reports_persistent_captcha_as_verification():
    page = FakePage([CAPTCHA_HTML] * 15, title="验证码中间页")
    with pytest.raises(signing._AuthenticationSigningFailure) as captured:
        run_fallback(page)
    assert captured.value.issue_code == SiteIssueCode.VERIFICATION_REQUIRED


def test_render_fallback_gives_the_site_script_time_before_declaring_captcha():
    page = FakePage(
        [CAPTCHA_HTML] * 5 + [GLUE_HTML],
        title=["验证码中间页"] * 5 + ["Fixture"],
    )
    assert run_fallback(page) == signing._extract_sdk_glue_tags(GLUE_HTML)


def test_render_fallback_keeps_explicit_authentication_errors():
    page = FakePage(["<body>请完成下列验证</body>"])
    with pytest.raises(signing._AuthenticationSigningFailure):
        run_fallback(page)


def test_render_fallback_rejects_untrusted_redirects():
    page = FakePage([GLUE_HTML], url="about:blank")

    def redirect(url, **kwargs):
        page.goto_calls.append((url, kwargs))
        page.url = "https://evil.example/user/fixture"

    page.goto = redirect
    with pytest.raises(signing._SigningFailure):
        run_fallback(page)


def test_render_fallback_respects_cancellation():
    page = FakePage([SHELL_HTML])
    with pytest.raises(DownloadCancelledError):
        signing._rendered_page_glue_fallback(
            None, page, PROFILE_URL, 1000, lambda: True,
            budget=signing.new_signed_discovery_budget(),
        )
    assert page.goto_calls == []


def test_render_fallback_still_rejects_untrusted_glue_scripts():
    bad = '<script data-sdk-glue="x" src="https://evil.example/a.js"></script>'
    page = FakePage([bad] * 15, title="Fixture")
    with pytest.raises(signing._SigningFailure):
        run_fallback(page)


def test_persistent_profile_setting_requires_absolute_path(monkeypatch):
    monkeypatch.setenv("CHENGYING_DOUYIN_SIGNING_PROFILE_DIR", "relative/path")
    with pytest.raises(signing._SigningFailure):
        signing._persistent_signing_user_data_dir()


def test_persistent_profile_setting_defaults_to_ephemeral(monkeypatch):
    assert signing._persistent_signing_user_data_dir() is None
    monkeypatch.setenv("CHENGYING_DOUYIN_SIGNING_PROFILE_DIR", "/tmp/fixture-signing")
    assert signing._persistent_signing_user_data_dir() == "/tmp/fixture-signing"


def test_session_uses_persistent_context_when_configured(monkeypatch, tmp_path):
    from http.cookiejar import Cookie, CookieJar

    jar = CookieJar()
    jar.set_cookie(Cookie(
        version=0, name="sessionid", value="fixture", port=None,
        port_specified=False, domain=".douyin.com", domain_specified=True,
        domain_initial_dot=True, path="/", path_specified=True, secure=True,
        expires=None, discard=True, comment=None, comment_url=None,
        rest={"HttpOnly": None}, rfc2109=False,
    ))
    monkeypatch.setattr(signing, "_load_chrome_cookie_jar", lambda profile: jar)
    monkeypatch.setenv("CHENGYING_DOUYIN_SIGNING_PROFILE_DIR", str(tmp_path / "profile"))
    monkeypatch.setattr(
        signing, "_extract_glue_with_context_fallback",
        lambda *a, **k: (signing._extract_sdk_glue_tags(GLUE_HTML), False),
    )
    monkeypatch.setattr(signing, "_wait_for_signer", lambda *a, **k: None)

    launched = {}
    page = FakePage([GLUE_HTML])

    class FakeContext:
        def __init__(self):
            self.pages = [page]
            self.cookies = []

        def add_cookies(self, values):
            self.cookies.extend(values)

        def new_page(self):
            return page

        def close(self):
            launched["closed"] = True

    context = FakeContext()

    def launch_persistent(user_data_dir, **kwargs):
        launched["dir"] = user_data_dir
        launched["kwargs"] = kwargs
        return context

    def launch(**kwargs):
        raise AssertionError("Ephemeral launch must not run with a persistent profile")

    manager = contextlib.nullcontext(SimpleNamespace(
        chromium=SimpleNamespace(
            launch=launch, launch_persistent_context=launch_persistent,
        ),
    ))
    monkeypatch.setattr("playwright.sync_api.sync_playwright", lambda: manager)

    result = signing._run_with_signing_page(
        PROFILE_URL, cookie_profile="Fixture Profile", should_cancel=lambda: False,
        navigation_timeout_ms=1000, signer_timeout_ms=1000, signer_settle_ms=0,
        budget=signing.new_signed_discovery_budget(), status_callback=None,
        operation=lambda p: "verified-operation",
    )
    assert result == "verified-operation"
    assert launched["dir"] == str(tmp_path / "profile")
    assert launched["kwargs"]["channel"] == "chrome"
    assert launched["closed"]
    assert any(c["name"] == "sessionid" for c in context.cookies)