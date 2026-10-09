"""Restore ordinary Chrome settings without reviving retired login windows."""

from __future__ import annotations

import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import chrome_profiles
from host import COOKIE_NAME, install_desktop_adapter
from login_auth import LoginPolicy
from proxy_config import ProxySettings

AUTH = "synthetic-login-api-" + "x" * 48
ORIGIN = "http://127.0.0.1:51923"
PLATFORMS = ("douyin", "xiaohongshu", "kuaishou", "instagram", "bilibili", "youtube")


class Config(BaseModel):
    download_dir: str
    use_chrome_cookies: bool = True
    chrome_profile: str | None = "Default"


class JobRequest(BaseModel):
    url: str = Field(min_length=8, max_length=4096)


@pytest.fixture
def native(tmp_path, monkeypatch, request):
    browser = tmp_path / "synthetic-chrome"
    for name in ("Default", "Profile 1"):
        (browser / name).mkdir(parents=True)
        (browser / name / "Cookies").touch()
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda _: browser)
    app = FastAPI()
    config = Config(download_dir=str(tmp_path / "media"))
    records = [
        {"id": "legacy", "cookie_browser": "chrome", "cookie_profile": "Default"},
        {"id": "snapshot", "cookie_browser": "chrome",
         "cookie_profile": "cy-session:douyin:" + "a" * 32},
    ]
    lock = threading.RLock()
    policy = LoginPolicy(tmp_path)
    initial = getattr(request, "param", None)
    if initial is not None:
        policy.save(initial)

    def get_config():
        with lock:
            return config.model_copy(deep=True)

    def update_config(value):
        nonlocal config
        with lock:
            config = value.model_copy(deep=True)
            return config

    def create_bound(url, *, output_root, cookie_browser, cookie_profile):
        record = {"id": str(len(records)), "cookie_browser": cookie_browser,
                  "cookie_profile": cookie_profile, "source_url": url, "output_root": output_root}
        records.append(record)
        return record

    def create_job(request):
        current = get_config()
        return create_bound(request.url, output_root=current.download_dir,
                            cookie_browser="chrome" if current.use_chrome_cookies else None,
                            cookie_profile=current.chrome_profile)

    def job(identifier):
        return SimpleNamespace(**next(record for record in records if record["id"] == identifier))

    def retry(identifier, *args):
        return next(record for record in records if record["id"] == identifier)

    manager = SimpleNamespace(_lock=threading.RLock(), _futures={}, create_job=create_bound,
                              start_job=retry, retry_item=retry, retry_failed=retry,
                              get_job=job, list_jobs=lambda: [SimpleNamespace(**record) for record in records])
    proxy = ProxySettings(tmp_path, manager)
    engine = SimpleNamespace(app=app, manager=manager, AppConfig=Config,
                             CreateJobRequest=JobRequest, _CONFIG_LOCK=lock,
                             get_config=get_config, update_config=update_config,
                             create_job=create_job, _public_job=lambda value: value,
                             _http_error=lambda error: HTTPException(422, "Synthetic request failed"),
                             open_verification=lambda identifier: {"status": "legacy", "job": identifier},
                             index=lambda: HTMLResponse("<html><head><title>原迹下载器</title></head></html>"))
    app.get("/api/config")(get_config)
    app.put("/api/config")(update_config)
    app.post("/api/jobs", status_code=201)(create_job)
    app.post("/api/jobs/{job_id}/retry")(lambda job_id: manager.retry_failed(job_id))
    app.post("/api/jobs/{job_id}/verify")(engine.open_verification)
    install_desktop_adapter(engine, token=AUTH, origin=ORIGIN, assets=tmp_path,
                            proxy_settings=proxy, login_policy=policy)
    client = TestClient(app, base_url=ORIGIN)
    client.cookies.set(COOKIE_NAME, AUTH)
    try:
        yield SimpleNamespace(client=client, engine=engine, policy=policy, initial=initial,
                              records=records, proxy=proxy, root=tmp_path, browser=browser)
    finally:
        client.close()


@pytest.mark.parametrize("native", [None, "dedicated", "chrome"], indirect=True)
def test_restored_page_always_contains_chrome_profile_controls(native):
    html = native.client.get("/").text
    assert "/native/chrome_profiles.js" in html
    assert "/native/login_sessions.js" not in html
    assert "/native/login_sessions.css" not in html
    response = native.client.get("/api/native/chrome-profiles")
    assert response.status_code == 200
    assert response.json()["selected_status"] == "available"
    assert response.json()["use_chrome_cookies"] is True
    assert not (native.root / "login-sessions").exists()


@pytest.mark.parametrize("path,method,payload", [
    ("/api/native/login", "get", None),
    ("/api/native/login/mode", "put", {"mode": "dedicated"}),
    ("/api/native/login/douyin/open", "post", {}),
    ("/api/native/login/douyin/save", "post", {}),
    ("/api/native/login/not-a-platform/open", "post", {}),
])
def test_retired_login_routes_cannot_open_or_save_a_browser(native, path, method, payload):
    assert native.client.request(method, path, json=payload).status_code == 404
    assert native.policy.mode() == "chrome"
    assert not (native.root / "login-sessions").exists()
    assert len(native.records) == 2


@pytest.mark.parametrize("platform", PLATFORMS)
def test_new_task_uses_configured_chrome_identity(native, platform):
    response = native.client.post("/api/jobs", json={"url": "https://www." + platform + ".com/item/synthetic"})
    assert response.status_code == 201
    assert response.json()["cookie_profile"] == "Default"
    assert response.json()["cookie_browser"] == "chrome"
    assert native.records[1]["cookie_profile"] == "cy-session:douyin:" + "a" * 32


@pytest.mark.parametrize("native", [None, "dedicated", "chrome", "anonymous"], indirect=True)
def test_checkbox_can_disable_and_enable_cookies_after_policy_retirement(native):
    initial = native.client.get("/api/config").json()
    assert initial["use_chrome_cookies"] is (native.initial != "anonymous")
    for enabled in (False, True, False):
        config = {**initial, "use_chrome_cookies": enabled, "chrome_profile": "Profile 1"}
        saved = native.client.put("/api/config", json=config)
        assert saved.status_code == 200
        assert saved.json()["use_chrome_cookies"] is enabled
        created = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
        assert created.status_code == 201
        assert created.json()["cookie_browser"] == ("chrome" if enabled else None)
        assert created.json()["cookie_profile"] == "Profile 1"
    assert native.policy.mode() == "chrome"


@pytest.mark.parametrize("native", ["anonymous"], indirect=True)
def test_saved_anonymous_policy_becomes_visible_cookie_off(native, monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Anonymous submission must not inspect Chrome")

    monkeypatch.setattr(chrome_profiles, "_profile_root", reject)
    config = native.client.get("/api/config").json()
    assert config["use_chrome_cookies"] is False
    assert config["chrome_profile"] == "Default"
    assert native.policy.mode() == "chrome"
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 201
    assert response.json()["cookie_browser"] is None


def test_missing_explicit_profile_blocks_before_creation(native):
    config = native.engine.get_config()
    config.chrome_profile = "Profile 17"
    native.engine.update_config(config)
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "chrome_profile_missing"
    assert len(native.records) == 2


@pytest.mark.parametrize("profile", ["cy-session:douyin:" + "a" * 32, "cy-session:invalid", "../Default"])
def test_snapshot_tokens_and_paths_cannot_become_new_chrome_config(native, profile):
    config = native.engine.get_config().model_dump()
    config["chrome_profile"] = profile
    response = native.client.put("/api/config", json=config)
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "chrome_profile_invalid"
    assert native.engine.get_config().chrome_profile == "Default"


def test_unrelated_save_preserves_unavailable_legacy_profile(native):
    config = native.engine.get_config()
    config.chrome_profile = "Profile 17"
    native.engine.update_config(config)
    payload = config.model_dump()
    payload["download_dir"] = str(native.root / "other-media")
    response = native.client.put("/api/config", json=payload)
    assert response.status_code == 200
    assert response.json()["chrome_profile"] == "Profile 17"


@pytest.mark.parametrize("identifier", ["legacy", "snapshot"])
def test_existing_task_retry_never_rebinds_after_checkbox_or_profile_change(native, identifier):
    previous = dict(next(record for record in native.records if record["id"] == identifier))
    payload = native.engine.get_config().model_dump()
    payload.update(use_chrome_cookies=False, chrome_profile="Profile 1")
    assert native.client.put("/api/config", json=payload).status_code == 200
    assert native.client.post("/api/jobs/" + identifier + "/retry").json() == previous


def test_legacy_snapshot_verification_never_opens_daily_chrome(native):
    response = native.client.post("/api/jobs/snapshot/verify")
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "login_refresh_new_task"
    assert "create a new task" in response.json()["detail"]["message"]
    assert native.records[1]["cookie_profile"] == "cy-session:douyin:" + "a" * 32
    assert native.client.post("/api/jobs/legacy/verify").json()["status"] == "legacy"


@pytest.mark.parametrize("path,method,payload", [
    ("/api/native/chrome-profiles", "get", None),
    ("/api/native/login/douyin/open", "post", {}),
    ("/api/config", "put", {}),
])
def test_active_and_removed_routes_retain_private_session_boundary(native, path, method, payload):
    assert native.client.request(method, path, json=payload,
                                 headers={"Origin": "https://untrusted.example"}).status_code == 403
    native.client.cookies.clear()
    assert native.client.request(method, path, json=payload).status_code == 403


def test_profile_save_cannot_change_identity_during_submission(native, monkeypatch):
    reading, release, saving = threading.Event(), threading.Event(), threading.Event()
    original = native.engine.create_job

    def held_create(request):
        reading.set()
        assert release.wait(5)
        return original(request)

    def change_profile():
        saving.set()
        return native.client.put("/api/config", json={
            "download_dir": str(native.root / "media"), "chrome_profile": "Profile 1",
            "use_chrome_cookies": True,
        })

    monkeypatch.setattr(native.engine, "create_job", held_create)
    with ThreadPoolExecutor(max_workers=2) as pool:
        submitted = pool.submit(native.client.post, "/api/jobs",
                                json={"url": "https://www.douyin.com/item/synthetic"})
        assert reading.wait(5)
        changed = pool.submit(change_profile)
        assert saving.wait(5)
        try:
            assert len(native.records) == 2
        finally:
            release.set()
        created = submitted.result(timeout=5)
        assert created.status_code == 201
        assert created.json()["cookie_profile"] == "Default"
        assert changed.result(timeout=5).status_code == 200
    assert native.engine.get_config().chrome_profile == "Profile 1"
