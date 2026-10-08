"""Dedicated login UI exercised in an isolated Chrome against loopback only."""

from __future__ import annotations

import copy
import json
import os
import socket
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
PLATFORMS = ("douyin", "xiaohongshu", "kuaishou", "instagram", "bilibili", "youtube")


@pytest.fixture
def login_site(tmp_path):
    state = {
        "schema_version": 1,
        "mode": "dedicated",
        "platforms": [{"platform": name, "status": "idle", "has_saved_session": False} for name in PLATFORMS],
    }
    config = {"download_dir": str(tmp_path / "fixture-output"), "use_chrome_cookies": True, "chrome_profile": "Profile 4"}
    calls = []
    profile_scans = []
    jobs = []
    saves = []
    app = FastAPI()
    lock = threading.RLock()
    static = ROOT / "vendor/rednote/app/static"

    @app.get("/")
    def index():
        text = static.joinpath("index.html").read_text(encoding="utf-8")
        for name, value in (("__APP_ID__", "login-ui-fixture"), ("__APP_VERSION__", "1.0.0"), ("__BUILD_ID__", "fixture-build")):
            text = text.replace(name, value)
        native = '<link rel="stylesheet" href="/desktop/login_sessions.css"><script src="/desktop/login_sessions.js" defer></script>'
        if state["mode"] == "chrome":
            native += '<link rel="stylesheet" href="/desktop/chrome_profiles.css"><script src="/desktop/chrome_profiles.js" defer></script>'
        text = text.replace("</head>", native + "</head>")
        return HTMLResponse(text)

    @app.get("/api/health")
    def health():
        return {"status": "ok", "app_id": "login-ui-fixture", "version": "1.0.0", "build_id": "fixture-build",
                "source_build_id": "fixture-build", "restart_required": False}

    @app.get("/api/events")
    def events():
        return Response(": fixture\n\n", media_type="text/event-stream")

    @app.get("/api/jobs")
    def list_jobs():
        return []

    @app.post("/api/jobs")
    def create_job(body: dict):
        jobs.append(body)
        return {"accepted": True}

    @app.get("/api/config")
    def get_config():
        return copy.deepcopy(config)

    @app.put("/api/config")
    def save_config(body: dict):
        saves.append(body)
        config.update(body)
        return copy.deepcopy(config)

    @app.get("/api/native/login")
    def login_status():
        with lock:
            calls.append(("GET", "status", None))
            return copy.deepcopy(state)

    @app.get("/api/native/chrome-profiles")
    def profile_inventory():
        # Synthetic metadata only, without calling the Chrome inventory module.
        profile_scans.append("fixture-scan")
        return {"schema_version": 1, "status": "ok", "selected_profile": config["chrome_profile"],
                "selected_status": "available", "use_chrome_cookies": config["use_chrome_cookies"],
                "profiles": [{"directory": "Profile 4", "has_cookie_database": True}]}

    @app.put("/api/native/login/mode")
    def login_mode(body: dict):
        with lock:
            calls.append(("PUT", "mode", body))
            state["mode"] = body["mode"]
            return copy.deepcopy(state)

    @app.post("/api/native/login/{platform}/{action}")
    def login_action(platform: str, action: str, body: dict):
        with lock:
            calls.append(("POST", f"{platform}/{action}", body))
            item = next(row for row in state["platforms"] if row["platform"] == platform)
            if action == "open":
                item["status"] = "login_open"
            else:
                item["status"] = "saved"
                item["has_saved_session"] = True
            return copy.deepcopy(state)

    @app.exception_handler(Exception)
    async def fixed_error(_request: Request, _error: Exception):
        return JSONResponse({"error": "fixture_error"}, status_code=500)

    app.mount("/static", StaticFiles(directory=static), name="engine-static")
    app.mount("/desktop", StaticFiles(directory=ROOT / "static"), name="native-static")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    origin = f"http://127.0.0.1:{listener.getsockname()[1]}"
    server = uvicorn.Server(uvicorn.Config(app, log_level="error", access_log=False, lifespan="off"))
    worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    worker.start()
    deadline = time.monotonic() + 5
    try:
        while not server.started and worker.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started, "The login fixture server did not start"
        yield SimpleNamespace(origin=origin, state=state, config=config, calls=calls, jobs=jobs, saves=saves,
                              profile_scans=profile_scans)
    finally:
        server.should_exit = True
        worker.join(timeout=5)
        if worker.is_alive():
            server.force_exit = True
            worker.join(timeout=5)
        listener.close()
        assert not worker.is_alive(), "The login fixture server did not stop"


@pytest.fixture
def login_page(login_site):
    if not CHROME.is_file():
        if os.environ.get("CHENGYING_REQUIRE_CHROME_UI") == "1":
            pytest.fail("The required real Chrome UI runtime is not installed")
        pytest.skip("The optional real Chrome UI runtime is not installed")
    errors = []
    outside = []
    with sync_playwright() as playwright:
        # A fresh nonpersistent browser context never opens a real Chrome profile.
        browser = playwright.chromium.launch(channel="chrome", headless=True, args=["--no-proxy-server"], timeout=15000)
        try:
            context = browser.new_context(service_workers="block", viewport={"width": 1280, "height": 1200})

            def local_only(route):
                if route.request.url.startswith(login_site.origin + "/"):
                    route.continue_()
                else:
                    outside.append("non-fixture request")
                    route.abort()

            context.route("**/*", local_only)
            page = context.new_page()
            page.set_default_timeout(5000)
            page.on("pageerror", lambda error: errors.append(type(error).__name__))
            yield page
            assert not errors
            assert not outside
        finally:
            browser.close()


def open_page(page, site):
    page.goto(site.origin)
    expect(page.locator("#desktop-login-mode")).to_be_enabled()
    expect(page.locator("#download-dir")).to_have_value(site.config["download_dir"])
    expect(page.locator("body")).not_to_have_class("version-blocked")


def open_with_held_login_request(page, site):
    pending = []
    # This fresh page sends the login request from its new document's deferred
    # script. The load event alone does not synchronize Python's route callback.
    # Keep the predicate synchronous: a Promise is truthy before it resolves.
    page.add_init_script("window.__fixtureLoginRouteObserved = false;")

    def hold_login_request(route):
        pending.append(route)
        page.evaluate("window.__fixtureLoginRouteObserved = true")

    page.route("**/api/native/login", hold_login_request)
    page.goto(site.origin)
    observed = page.wait_for_function(
        "window.__fixtureLoginRouteObserved === true", timeout=5000,
    )
    observed.dispose()
    return pending


def new_task(page):
    page.locator("#url-input").fill("https://www.douyin.com/video/123456")
    page.locator("#download-button").click()


def test_dedicated_default_does_not_read_chrome_or_modify_legacy_fields(login_page, login_site):
    page, site = login_page, login_site
    open_page(page, site)
    expect(page.locator("#desktop-login-mode")).to_have_value("dedicated")
    expect(page.locator("#chrome-profile")).to_be_hidden()
    expect(page.locator("#chrome-cookies")).to_be_hidden()
    expect(page.locator("#chrome-profile-help")).to_be_hidden()
    expect(page.locator("#download-dir")).to_be_visible()
    expect(page.locator("#save-settings-button")).to_be_visible()
    expect(page.locator("#chrome-profile")).to_have_value("Profile 4")
    assert page.locator("#chrome-cookies").evaluate("node => node.checked") is True
    assert page.locator(".desktop-login-platform").count() == 6
    assert page.locator("#desktop-login-panel").evaluate("node => getComputedStyle(node).borderRadius") == "16px"
    assert site.calls == [("GET", "status", None)]
    assert site.profile_scans == []
    with page.expect_response(lambda response: response.url.endswith("/api/jobs") and response.request.method == "POST"):
        new_task(page)
    assert site.jobs == [{"url": "https://www.douyin.com/video/123456"}]
    page.locator("#download-dir").fill("synthetic-new-directory")
    with page.expect_response(lambda response: response.url.endswith("/api/config") and response.request.method == "PUT"):
        page.locator("#save-settings-button").click()
    assert len(site.saves) == 1
    assert site.saves[0]["chrome_profile"] == "Profile 4"
    assert site.saves[0]["use_chrome_cookies"] is True
    assert "mode" not in site.saves[0]


@pytest.mark.parametrize("platform", PLATFORMS)
def test_open_and_explicit_save_are_platform_scoped(login_page, login_site, platform):
    page, site = login_page, login_site
    open_page(page, site)
    page.locator(f"#desktop-login-{platform}-open").click()
    expect(page.locator(f"#desktop-login-{platform}-save")).to_be_enabled()
    expect(page.locator(f"#desktop-login-{platform}-status")).to_contain_text("完成登录")
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    new_task(page)
    expect(page.locator("#form-error")).to_contain_text("保存登录")
    assert site.jobs == []
    page.locator(f"#desktop-login-{platform}-save").click()
    expect(page.locator(f"#desktop-login-{platform}-status")).to_contain_text("下载时确认")
    expect(page.locator("#desktop-login-mode")).to_be_enabled()
    assert [call for call in site.calls if call[0] == "POST"] == [
        ("POST", f"{platform}/open", {}), ("POST", f"{platform}/save", {})]
    page.reload()
    expect(page.locator(f"#desktop-login-{platform}-status")).to_contain_text("下载时确认")
    assert site.saves == []


@pytest.mark.parametrize("mode", ["chrome", "anonymous"])
def test_mode_change_is_explicit_and_reload_follows_confirmed_save(login_page, login_site, mode):
    page, site = login_page, login_site
    open_page(page, site)
    page.locator("#desktop-login-mode").select_option(mode)
    expect(page.locator("#desktop-login-status")).to_contain_text("尚未保存")
    assert site.state["mode"] == "dedicated"
    new_task(page)
    expect(page.locator("#form-error")).to_contain_text("保存登录方式")
    assert site.jobs == []
    with page.expect_navigation():
        page.locator("#desktop-login-save-mode").click()
    expect(page.locator("#desktop-login-mode")).to_be_enabled()
    expect(page.locator("#desktop-login-mode")).to_have_value(mode)
    expect(page.locator(".desktop-login-platforms")).to_be_hidden()
    assert ("PUT", "mode", {"mode": mode}) in site.calls
    if mode == "chrome":
        expect(page.locator("#desktop-chrome-profile")).to_be_visible()
        expect(page.locator("#desktop-chrome-profile")).to_be_enabled()
        assert site.profile_scans == ["fixture-scan"]
        expect(page.locator("#desktop-login-mode-note")).to_contain_text("不会自动授予权限")
    else:
        expect(page.locator("#chrome-profile")).to_be_hidden()
        expect(page.locator("#desktop-login-mode-note")).to_contain_text("不会从其他方式自动降级")


def test_failed_mode_save_preserves_all_inputs_and_requires_status_refresh(login_page, login_site):
    page, site = login_page, login_site
    open_page(page, site)
    page.route("**/api/native/login/mode", lambda route: route.fulfill(status=409, content_type="application/json", body='{"detail":"private data must not render"}'))
    page.locator("#download-dir").fill("synthetic-unsaved-path")
    page.locator("#url-input").fill("https://www.douyin.com/video/123456")
    page.locator("#desktop-login-mode").select_option("anonymous")
    page.locator("#desktop-login-save-mode").click()
    expect(page.locator("#desktop-login-status")).to_contain_text("输入已保留")
    expect(page.locator("#download-dir")).to_have_value("synthetic-unsaved-path")
    expect(page.locator("#desktop-login-mode")).to_have_value("anonymous")
    expect(page.locator("#url-input")).to_have_value("https://www.douyin.com/video/123456")
    assert "private data must not render" not in page.locator("body").inner_text()
    assert site.state["mode"] == "dedicated"
    assert site.saves == []
    # Editing the draft cannot erase an uncertain server-side save outcome.
    page.locator("#desktop-login-mode").select_option("dedicated")
    expect(page.locator("#desktop-login-douyin-open")).to_be_disabled()
    new_task(page)
    expect(page.locator("#form-error")).to_contain_text("尚未核实")
    assert site.jobs == []
    page.locator("#desktop-login-mode").select_option("anonymous")
    page.locator("#desktop-login-refresh").click()
    expect(page.locator("#desktop-login-status")).to_contain_text("尚未保存")
    expect(page.locator("#desktop-login-mode")).to_have_value("anonymous")


@pytest.mark.parametrize("kind", ["status", "duplicate", "mode", "oversized", "html", "http", "code"])
def test_invalid_state_never_enables_new_jobs_or_exposes_raw_response(login_page, login_site, kind):
    page, site = login_page, login_site
    data = copy.deepcopy(site.state)
    body = None
    content_type = "application/json"
    http_status = 200
    if kind == "status":
        data["platforms"][0]["status"] = "private-server-error"
    elif kind == "duplicate":
        data["platforms"][1] = data["platforms"][0]
    elif kind == "mode":
        data["mode"] = "automatic-account-switch"
    elif kind == "oversized":
        data["private"] = "x" * 20000
    elif kind == "html":
        content_type = "text/html"
        body = "<script>private-server-error</script>"
    elif kind == "http":
        http_status = 500
    else:
        data["platforms"][0]["error_code"] = "/private-server-error"
    page.route("**/api/native/login", lambda route: route.fulfill(status=http_status, content_type=content_type,
                                                                body=body or json.dumps(data)))
    page.goto(site.origin)
    expect(page.locator("#desktop-login-status")).to_contain_text("无法完成")
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    expect(page.locator("#desktop-login-refresh")).to_be_enabled()
    new_task(page)
    expect(page.locator("#form-error")).to_contain_text("尚未核实")
    assert site.jobs == []
    assert "private-server-error" not in page.locator("body").inner_text()


def test_late_status_preserves_mode_draft_and_unknown_fields_are_not_displayed(login_page, login_site):
    page, site = login_page, login_site
    open_page(page, site)
    site.state["private"] = "fixture-private-not-for-display"
    site.state["platforms"][0]["error_code"] = "unknown_fixed_code"
    site.state["platforms"][0]["status"] = "error"
    site.state["platforms"][0]["has_saved_session"] = True
    page.locator("#desktop-login-mode").select_option("anonymous")
    page.locator("#desktop-login-refresh").click()
    expect(page.locator("#desktop-login-status")).to_contain_text("尚未保存")
    expect(page.locator("#desktop-login-mode")).to_have_value("anonymous")
    expect(page.locator("#desktop-login-douyin-status")).to_contain_text("先前")
    assert "fixture-private-not-for-display" not in page.locator("body").inner_text()
    assert "unknown_fixed_code" not in page.locator("body").inner_text()


def test_poll_only_while_open_and_pagehide_stops_all_actions(login_page, login_site):
    page, site = login_page, login_site
    page.clock.install()
    open_page(page, site)
    page.clock.fast_forward(5000)
    assert len([call for call in site.calls if call[0] == "GET"]) == 1
    page.locator("#desktop-login-douyin-open").click()
    expect(page.locator("#desktop-login-douyin-save")).to_be_enabled()
    with page.expect_response(lambda response: response.url.endswith("/api/native/login")):
        page.clock.fast_forward(1600)
    expect(page.locator("#desktop-login-douyin-save")).to_be_enabled()
    page.locator("#desktop-login-douyin-save").click()
    expect(page.locator("#desktop-login-douyin-status")).to_contain_text("下载时确认")
    count = len(site.calls)
    page.clock.fast_forward(5000)
    assert len(site.calls) == count
    page.evaluate("window.dispatchEvent(new Event('pagehide'))")
    expect(page.locator("#desktop-login-refresh")).to_be_disabled()
    page.clock.fast_forward(5000)
    assert len(site.calls) == count


def test_version_block_cancels_pending_and_rejects_late_result(login_page, login_site):
    page, site = login_page, login_site
    pending = open_with_held_login_request(page, site)
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    assert len(pending) == 1
    page.evaluate("document.body.classList.add('version-blocked')")
    pending[0].fulfill(status=200, content_type="application/json", body=json.dumps(site.state))
    expect(page.locator("#desktop-login-refresh")).to_be_disabled()
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    page.evaluate("document.querySelector('#download-form').dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}))")
    expect(page.locator("#form-error")).to_contain_text("版本检查")
    assert site.jobs == []


@pytest.mark.parametrize("code, phrase", [
    ("login_proxy_unavailable", "不会自动改为直连"),
    ("login_busy", "还有登录操作"),
    ("login_browser_unavailable", "Google Chrome 已安装"),
    ("login_session_expired", "已过期"),
    ("login_storage_unavailable", "无需为日常 Chrome 添加权限"),
    ("login_cleanup_failed", "不要强制结束日常 Chrome"),
])
def test_fixed_operation_errors_give_safe_guidance(login_page, login_site, code, phrase):
    page, site = login_page, login_site
    open_page(page, site)
    payload = {"detail": {"code": code, "message": "private-diagnostic-payload"}}
    page.route("**/api/native/login/douyin/open", lambda route: route.fulfill(status=409, content_type="application/json", body=json.dumps(payload)))
    page.locator("#desktop-login-douyin-open").click()
    expect(page.locator("#desktop-login-status")).to_contain_text(phrase)
    expect(page.locator("#desktop-login-douyin-open")).to_be_disabled()
    expect(page.locator("#desktop-login-refresh")).to_be_enabled()
    assert "private-diagnostic-payload" not in page.locator("body").inner_text()
    assert code not in page.locator("body").inner_text()


def test_unconfirmed_success_cannot_reload_or_discard_drafts(login_page, login_site):
    page, site = login_page, login_site
    open_page(page, site)
    # A 200 response that does not confirm the requested mode is not a save.
    page.route("**/api/native/login/mode", lambda route: route.fulfill(status=200, content_type="application/json", body=json.dumps(site.state)))
    page.locator("#download-dir").fill("synthetic-unsaved-directory")
    page.locator("#desktop-login-mode").select_option("anonymous")
    page.locator("#desktop-login-save-mode").click()
    expect(page.locator("#desktop-login-status")).to_contain_text("保存未确认")
    expect(page.locator("#download-dir")).to_have_value("synthetic-unsaved-directory")
    expect(page.locator("#desktop-login-mode")).to_have_value("anonymous")
    assert site.calls == [("GET", "status", None)]


def test_general_settings_save_disables_authentication_changes(login_page, login_site):
    page, site = login_page, login_site
    open_page(page, site)
    page.locator("#desktop-login-mode").select_option("anonymous")
    page.evaluate("document.querySelector('#save-settings-button').disabled = true")
    expect(page.locator("#desktop-login-save-mode")).to_be_disabled()
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    page.evaluate("document.querySelector('#save-settings-button').disabled = false")
    expect(page.locator("#desktop-login-save-mode")).to_be_enabled()
    expect(page.locator("#desktop-login-mode")).to_have_value("anonymous")
    assert site.calls == [("GET", "status", None)]


def test_initial_request_timeout_can_be_retried_without_automatic_login(login_page, login_site):
    page, site = login_page, login_site
    page.clock.install()
    pending = open_with_held_login_request(page, site)
    assert len(pending) == 1
    page.clock.fast_forward(16000)
    expect(page.locator("#desktop-login-status")).to_contain_text("无法完成")
    expect(page.locator("#desktop-login-refresh")).to_be_enabled()
    expect(page.locator("#desktop-login-mode")).to_be_disabled()
    page.unroute("**/api/native/login")
    page.locator("#desktop-login-refresh").click()
    expect(page.locator("#desktop-login-mode")).to_be_enabled()
    assert site.calls == [("GET", "status", None)]
    assert site.jobs == []


def test_error_status_uses_fixed_message_and_does_not_poll_forever(login_page, login_site):
    page, site = login_page, login_site
    site.state["platforms"][0].update(status="error", error_code="login_window_closed")
    page.clock.install()
    open_page(page, site)
    expect(page.locator("#desktop-login-douyin-status")).to_contain_text("本次登录未保存")
    page.clock.fast_forward(10000)
    assert site.calls == [("GET", "status", None)]
    expect(page.locator("#desktop-login-douyin-open")).to_be_enabled()


def test_legacy_native_controls_and_main_form_survive_mode_roundtrip(login_page, login_site):
    page, site = login_page, login_site
    site.state["mode"] = "chrome"
    open_page(page, site)
    expect(page.locator("#desktop-chrome-profile")).to_be_enabled()
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Profile 4")
    expect(page.locator("#desktop-chrome-cookies")).to_be_visible()
    assert site.profile_scans == ["fixture-scan"]
    page.locator("#download-dir").fill("synthetic-legacy-directory")
    with page.expect_response(lambda response: response.url.endswith("/api/config") and response.request.method == "PUT"):
        page.locator("#save-settings-button").click()
    expect(page.locator("#desktop-chrome-profile-refresh")).to_be_enabled()
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已保存 Profile 4")
    assert site.config["download_dir"] == "synthetic-legacy-directory"
    assert site.config["chrome_profile"] == "Profile 4"
    assert site.config["use_chrome_cookies"] is True
    scans = len(site.profile_scans)
    page.locator("#desktop-login-mode").select_option("dedicated")
    with page.expect_navigation():
        page.locator("#desktop-login-save-mode").click()
    expect(page.locator("#desktop-login-mode")).to_be_enabled()
    expect(page.locator("#desktop-login-mode")).to_have_value("dedicated")
    expect(page.locator("#download-dir")).to_have_value("synthetic-legacy-directory")
    expect(page.locator("#chrome-profile")).to_have_value("Profile 4")
    expect(page.locator("#chrome-profile")).to_be_hidden()
    assert page.locator("#desktop-chrome-profile").count() == 0
    assert len(site.profile_scans) == scans
    with page.expect_response(lambda response: response.url.endswith("/api/config") and response.request.method == "PUT"):
        page.locator("#save-settings-button").click()
    assert site.saves[-1]["chrome_profile"] == "Profile 4"
    assert site.saves[-1]["use_chrome_cookies"] is True


def test_narrow_layout_has_visible_controls_without_horizontal_overflow(login_page, login_site, tmp_path):
    page, site = login_page, login_site
    page.set_viewport_size({"width": 540, "height": 900})
    open_page(page, site)
    panel = page.locator("#desktop-login-panel")
    panel.scroll_into_view_if_needed()
    width = panel.bounding_box()["width"]
    assert width > 250
    assert panel.evaluate("node => node.scrollWidth <= node.clientWidth + 1")
    for name in PLATFORMS:
        expect(page.locator(f"#desktop-login-{name}-open")).to_be_enabled()
        assert page.locator(f"#desktop-login-{name}-open").bounding_box()["width"] < width
    destination = tmp_path / "dedicated-login-ui.png"
    panel.screenshot(path=str(destination))
    assert destination.is_file()
    print(f"UI screenshot: {destination}")
