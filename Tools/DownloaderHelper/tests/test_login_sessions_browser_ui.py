"""Regression coverage for retiring dedicated login, using real loopback Chrome."""

from __future__ import annotations

import json

import pytest
import test_chrome_profile_browser_ui as profile_fixtures
from playwright.sync_api import expect

# Reuse the real native host and private metadata fixtures, not a parallel HTML
# implementation. The browser owns a fresh nonpersistent profile and blocks all
# requests outside its loopback fixture.
from test_chrome_profile_browser_ui import (
    attempt_new_task,
    open_fixture,
    save_settings,
)

browser_page = profile_fixtures.browser_page
fixture_site = profile_fixtures.fixture_site


def test_restored_login_controls_have_no_dedicated_window_entry(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    requested = []
    page.on("request", lambda request: requested.append(request.url))
    open_fixture(page, site)
    expect(page.locator("#desktop-chrome-cookies")).to_be_visible()
    expect(page.locator("#desktop-chrome-profile")).to_be_visible()
    expect(page.locator("#desktop-login-panel")).to_have_count(0)
    expect(page.locator('[id^="desktop-login-"]')).to_have_count(0)
    assert not page.locator('script[src*="login_sessions"], link[href*="login_sessions"]').count()
    assert not any("/api/native/login" in url for url in requested)
    assert site.saves == [] and site.submissions == []


@pytest.mark.parametrize(("path", "method", "body"), [
    ("/api/native/login", "GET", None),
    ("/api/native/login/mode", "PUT", {"mode": "dedicated"}),
    ("/api/native/login/douyin/open", "POST", {}),
    ("/api/native/login/douyin/save", "POST", {}),
    ("/api/native/login/instagram/open", "POST", {}),
    ("/api/native/login/youtube/open", "POST", {}),
    ("/native/login_sessions.js", "GET", None),
    ("/native/login_sessions.css", "GET", None),
])
def test_stale_pages_cannot_open_retired_login(browser_page, fixture_site, path, method, body):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    response = page.evaluate("""async ({path, method, body}) => {
      const options = {method, credentials: 'same-origin'};
      if (body !== null) {
        options.headers = {'Content-Type': 'application/json'};
        options.body = JSON.stringify(body);
      }
      const result = await fetch(path, options);
      return {status: result.status, body: await result.text()};
    }""", {"path": path, "method": method, "body": body})
    assert response["status"] == 404
    assert "login_open" not in response["body"]
    assert site.saves == [] and site.submissions == []
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Default")


def test_cookie_off_survives_reload_and_can_return_to_explicit_profile(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    page.locator("#desktop-chrome-cookies").uncheck()
    attempt_new_task(page)
    expect(page.locator("#form-error")).to_contain_text("先保存")
    assert site.submissions == []
    save_settings(page, site)
    assert site.get_config().use_chrome_cookies is False
    assert site.get_config().chrome_profile == "Default"
    with page.expect_response(lambda response: response.url.endswith("/api/jobs") and response.request.method == "POST"):
        attempt_new_task(page)
    assert site.submissions[-1]["use_chrome_cookies"] is False
    page.reload()
    expect(page.locator("#desktop-chrome-profile")).to_be_enabled()
    expect(page.locator("#desktop-chrome-cookies")).not_to_be_checked()
    expect(page.locator("#desktop-login-panel")).to_have_count(0)
    page.locator("#desktop-chrome-profile").select_option("Profile 1")
    page.locator("#desktop-chrome-cookies").check()
    save_settings(page, site)
    with page.expect_response(lambda response: response.url.endswith("/api/jobs") and response.request.method == "POST"):
        attempt_new_task(page)
    assert site.submissions[-1]["chrome_profile"] == "Profile 1"
    assert site.submissions[-1]["use_chrome_cookies"] is True
    # A later setting change does not rewrite the previous task's identity.
    assert site.submissions[0]["chrome_profile"] == "Default"
    assert site.submissions[0]["use_chrome_cookies"] is False


def test_retired_job_diagnostic_does_not_offer_removed_panel(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    job = {
        "id": "retired-login-fixture", "platform": "douyin", "source_kind": "item",
        "status": "failed", "title": "Synthetic retired task", "author": "Fixture",
        "revision": 1, "created_at": "2026-10-09T00:00:00Z", "updated_at": "2026-10-09T00:00:00Z",
        "items": [], "total_items": 0, "completed_items": 0, "failed_items": 0,
        "issue_code": "cookie_unavailable", "diagnostic_code": "dedicated_login_unavailable",
        "issue_message": "Diagnostic: dedicated_login_unavailable.",
        "error": "Diagnostic: dedicated_login_unavailable.",
    }
    page.route("**/api/jobs", lambda route: route.fulfill(
        status=200, content_type="application/json", body=json.dumps([job]),
    ))
    open_fixture(page, site)
    expect(page.locator("#job-view")).to_contain_text("专用登录窗口功能已移除")
    expect(page.locator("#job-view")).to_contain_text("从原链接新建任务")
    expect(page.locator("#job-view")).to_contain_text("旧任务不会自动改用其他账号")
    expect(page.locator("#job-view")).not_to_contain_text("保存登录")
    expect(page.locator("#job-view")).not_to_contain_text("下载登录面板")
    assert site.saves == [] and site.submissions == []


def test_restored_controls_keep_live_version_gate(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    page.evaluate("document.body.classList.add('version-blocked')")
    expect(page.locator("#desktop-chrome-profile")).to_be_disabled()
    expect(page.locator("#desktop-chrome-profile-refresh")).to_be_disabled()
    page.evaluate("""() => {
      document.querySelector('#settings-form').dispatchEvent(new Event('submit', {bubbles:true,cancelable:true}));
      document.querySelector('#download-form').dispatchEvent(new Event('submit', {bubbles:true,cancelable:true}));
      document.querySelector('#desktop-chrome-profile-refresh').dispatchEvent(new Event('click'));
    }""")
    expect(page.locator("#form-error")).to_contain_text("不可用")
    assert site.saves == [] and site.submissions == []
    expect(page.locator("#desktop-login-panel")).to_have_count(0)
