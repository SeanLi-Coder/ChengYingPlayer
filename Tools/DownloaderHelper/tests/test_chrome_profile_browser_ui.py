"""Real Chrome UI checks using only loopback fixtures and synthetic metadata."""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
import uvicorn
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from playwright.sync_api import expect, sync_playwright
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import chrome_profiles
from host import COOKIE_NAME, install_desktop_adapter

CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
TOKEN = "synthetic-browser-profile-session-" + "x" * 48
VERSION = "1.0.0"
BUILD = "synthetic-browser-build"
APP_ID = "synthetic-profile-ui"


class Configuration(BaseModel):
    download_dir: str
    use_chrome_cookies: bool = True
    chrome_profile: str | None = "Default"


class JobRequest(BaseModel):
    url: str = Field(min_length=8, max_length=4096)


@pytest.fixture
def fixture_site(tmp_path, monkeypatch):
    browser_root = tmp_path / "synthetic-chrome-directories"
    (browser_root / "Profile 1").mkdir(parents=True)
    (browser_root / "Profile 1/Cookies").touch()
    (browser_root / "Profile 4").mkdir()
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda _: browser_root)
    config = Configuration(download_dir=str(tmp_path / "fixture-output"))
    submissions = []
    saves = []
    lock = threading.RLock()
    app = FastAPI()
    static = ROOT / "vendor/rednote/app/static"
    page_errors = []
    forbidden_requests = []

    def get_config():
        with lock:
            return config.model_copy(deep=True)

    def update_config(value):
        nonlocal config
        with lock:
            config = value.model_copy(deep=True)
            saves.append(config.model_dump())
            return get_config()

    def create_job(request):
        # Capture the original submission boundary without starting media
        # discovery, a browser cookie reader, or an external network request.
        with lock:
            submissions.append({"url": request.url, **get_config().model_dump()})
        return {"accepted": True}

    def index():
        content = static.joinpath("index.html").read_text(encoding="utf-8")
        for source, replacement in (("__APP_ID__", APP_ID), ("__APP_VERSION__", VERSION), ("__BUILD_ID__", BUILD)):
            content = content.replace(source, replacement)
        return HTMLResponse(content)

    @app.get("/api/health")
    def health():
        return {"status": "ok", "app_id": APP_ID, "version": VERSION,
                "build_id": BUILD, "source_build_id": BUILD, "restart_required": False}

    @app.get("/api/events")
    def events():
        return Response(": local fixture\n\n", media_type="text/event-stream")

    app.get("/api/config")(get_config)
    @app.get("/api/jobs")
    def list_jobs():
        return []

    app.mount("/static", StaticFiles(directory=static), name="fixture-static")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    origin = f"http://127.0.0.1:{listener.getsockname()[1]}"
    engine = SimpleNamespace(app=app, manager=SimpleNamespace(list_jobs=list),
                             AppConfig=Configuration, CreateJobRequest=JobRequest,
                             _CONFIG_LOCK=lock, get_config=get_config,
                             update_config=update_config, create_job=create_job, index=index)
    install_desktop_adapter(engine, token=TOKEN, origin=origin, assets=ROOT / "static")
    server = uvicorn.Server(uvicorn.Config(app, log_level="error", access_log=False, lifespan="off"))
    worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    worker.start()
    deadline = time.monotonic() + 5
    try:
        while not server.started and worker.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started, "The loopback fixture server failed to start"
        yield SimpleNamespace(origin=origin, root=browser_root, get_config=get_config,
                              submissions=submissions, saves=saves,
                              page_errors=page_errors, forbidden_requests=forbidden_requests)
    finally:
        server.should_exit = True
        worker.join(timeout=5)
        if worker.is_alive():
            server.force_exit = True
            worker.join(timeout=5)
        listener.close()
        assert not worker.is_alive(), "The loopback fixture server did not stop"


@pytest.fixture
def browser_page(fixture_site):
    if not CHROME.is_file():
        if os.environ.get("CHENGYING_REQUIRE_CHROME_UI") == "1":
            pytest.fail("The required real Chrome UI runtime is not installed")
        pytest.skip("The optional real Chrome UI runtime is not installed")
    with sync_playwright() as playwright:
        # launch(), not launch_persistent_context(): Playwright owns a fresh
        # temporary browser directory and never opens the user's Chrome data.
        browser = playwright.chromium.launch(channel="chrome", headless=True,
                                             args=["--no-proxy-server"], timeout=15000)
        try:
            context = browser.new_context(service_workers="block", viewport={"width": 1280, "height": 1200})
            context.add_cookies([{"name": COOKIE_NAME, "value": TOKEN, "url": fixture_site.origin}])

            def only_fixture(route):
                if route.request.url.startswith(fixture_site.origin + "/"):
                    route.continue_()
                else:
                    fixture_site.forbidden_requests.append("non-fixture request")
                    route.abort()

            context.route("**/*", only_fixture)
            page = context.new_page()
            page.set_default_timeout(5000)
            page.on("pageerror", lambda error: fixture_site.page_errors.append(type(error).__name__))
            yield page
            assert not fixture_site.page_errors
            assert not fixture_site.forbidden_requests
        finally:
            browser.close()


def open_fixture(page, site):
    with page.expect_response(lambda response: response.url == site.origin + "/api/config" and response.request.method == "GET"):
        page.goto(site.origin + "/")
    expect(page.locator("#desktop-chrome-profile")).to_be_visible()
    expect(page.locator("#desktop-chrome-profile")).to_be_enabled()
    expect(page.locator("#desktop-chrome-cookies")).to_be_checked()
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已不存在")
    expect(page.locator("body")).not_to_have_class("version-blocked")


def attempt_new_task(page):
    page.locator("#url-input").fill("https://www.douyin.com/video/123456")
    page.locator("#download-button").click()


def save_settings(page, site):
    with page.expect_response(lambda response: response.url == site.origin + "/api/config" and response.request.method == "PUT") as saved:
        page.locator("#save-settings-button").click()
    assert saved.value.status == 200
    expect(page.locator("#desktop-chrome-profile-refresh")).to_be_enabled()
    expect(page.locator("#desktop-chrome-profile-status")).not_to_contain_text("正在")


def test_real_chrome_missing_profile_explicit_save_and_unsaved_guard(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    select = page.locator("#desktop-chrome-profile")
    expect(select).to_have_value("Default")
    assert select.bounding_box()["width"] > 100
    assert select.evaluate("node => getComputedStyle(node).backgroundColor") != "rgba(0, 0, 0, 0)"
    assert select.locator("option").evaluate_all("nodes => nodes.map(node => node.value)") == ["", "Profile 1", "Profile 4", "Default"]
    attempt_new_task(page)
    expect(page.locator("#form-error")).to_contain_text("已不存在")
    assert site.submissions == [] and site.saves == []
    select.select_option("Profile 1")
    expect(page.locator("#chrome-profile")).to_have_value("Profile 1")
    attempt_new_task(page)
    expect(page.locator("#form-error")).to_contain_text("先保存")
    assert site.submissions == []
    save_settings(page, site)
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已保存 Profile 1")
    with page.expect_response(lambda response: response.url == site.origin + "/api/jobs" and response.request.method == "POST") as created:
        attempt_new_task(page)
    assert created.value.status == 201
    assert len(site.submissions) == 1 and site.submissions[0]["chrome_profile"] == "Profile 1"


def test_real_chrome_refresh_preserves_identity_and_reports_metadata(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    assert "尚无 Cookie" in page.locator('#desktop-chrome-profile option[value="Profile 4"]').inner_text()
    (site.root / "Profile 4/Cookies").touch()
    page.locator("#desktop-chrome-profile-refresh").click()
    expect(page.locator('#desktop-chrome-profile option[value="Profile 4"]')).to_have_text("Profile 4")
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Default")
    assert site.get_config().chrome_profile == "Default" and site.saves == []
    page.locator("#desktop-chrome-profile").select_option("Profile 1")
    (site.root / "Profile 1").rename(site.root / "Retired Synthetic Profile")
    page.locator("#desktop-chrome-profile-refresh").click()
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已不存在")
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Profile 1")
    attempt_new_task(page)
    assert site.submissions == [] and site.saves == []


@pytest.mark.parametrize("mode", ["automatic", "cookie-off"])
def test_real_chrome_explicit_automatic_and_cookie_off(browser_page, fixture_site, mode):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    if mode == "automatic":
        page.locator("#desktop-chrome-profile").select_option("")
    else:
        page.locator("#desktop-chrome-cookies").uncheck()
    attempt_new_task(page)
    expect(page.locator("#form-error")).to_contain_text("先保存")
    assert site.submissions == []
    save_settings(page, site)
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("自动选择" if mode == "automatic" else "已保存关闭 Cookie")
    with page.expect_response(lambda response: response.url == site.origin + "/api/jobs" and response.request.method == "POST"):
        attempt_new_task(page)
    assert len(site.submissions) == 1
    if mode == "automatic":
        assert site.submissions[0]["chrome_profile"] is None
        assert site.submissions[0]["use_chrome_cookies"] is True
    else:
        assert site.submissions[0]["chrome_profile"] == "Default"
        assert site.submissions[0]["use_chrome_cookies"] is False


def test_real_chrome_inventory_failure_can_refresh_without_mutation(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    endpoint = site.origin + "/api/native/chrome-profiles"
    page.route(endpoint, lambda route: route.fulfill(status=503, content_type="application/json", body="{}"))
    page.goto(site.origin + "/")
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("无法核实")
    expect(page.locator("#desktop-chrome-profile")).to_be_disabled()
    attempt_new_task(page)
    expect(page.locator("#form-error")).to_contain_text("尚未完成")
    assert site.submissions == [] and site.saves == []
    page.unroute(endpoint)
    page.locator("#desktop-chrome-profile-refresh").click()
    expect(page.locator("#desktop-chrome-profile")).to_be_enabled()
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Default")
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已不存在")


def test_real_chrome_late_engine_config_load_cannot_replace_visible_drafts(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    pending = []

    def delay_initial_config(route):
        if route.request.method == "GET":
            pending.append(route)
        else:
            route.continue_()

    page.route(site.origin + "/api/config", delay_initial_config)
    page.goto(site.origin + "/")
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("已不存在")
    expect(page.locator("#desktop-chrome-cookies")).to_be_checked()
    page.locator("#desktop-chrome-profile").select_option("Profile 1")
    page.locator("#desktop-chrome-cookies").uncheck()
    assert len(pending) == 1
    pending[0].fulfill(status=200, content_type="application/json",
                       body=json.dumps(site.get_config().model_dump()))
    # Prove the late original handler ran, not merely that the request finished.
    expect(page.locator("#chrome-profile")).to_have_value("Default")
    assert page.locator("#chrome-cookies").evaluate("node => node.checked") is True
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Profile 1")
    expect(page.locator("#desktop-chrome-cookies")).not_to_be_checked()
    save_settings(page, site)
    assert site.get_config().chrome_profile == "Profile 1"
    assert site.get_config().use_chrome_cookies is False
    expect(page.locator("#desktop-chrome-profile")).to_have_value("Profile 1")
    expect(page.locator("#desktop-chrome-cookies")).not_to_be_checked()


def test_real_chrome_cookie_label_track_and_keyboard_toggle_the_visible_draft(browser_page, fixture_site):
    page, site = browser_page, fixture_site
    open_fixture(page, site)
    label = page.locator('label[for="desktop-chrome-cookies"]')
    toggle = page.locator("#desktop-chrome-cookies")
    assert label.evaluate("node => node.control.id") == "desktop-chrome-cookies"
    label.locator("strong").click()
    expect(toggle).not_to_be_checked()
    expect(page.locator("#desktop-chrome-profile-status")).to_contain_text("尚未保存")
    assert page.locator("#chrome-cookies").evaluate("node => node.checked") is False
    label.locator(".switch-track").click()
    expect(toggle).to_be_checked()
    label.click(position={"x": 8, "y": 8})
    expect(toggle).not_to_be_checked()
    toggle.focus()
    page.keyboard.press("Space")
    expect(toggle).to_be_checked()
    page.keyboard.press("Space")
    expect(toggle).not_to_be_checked()
    assert site.saves == []
    save_settings(page, site)
    assert site.get_config().use_chrome_cookies is False
    assert site.get_config().chrome_profile == "Default"
