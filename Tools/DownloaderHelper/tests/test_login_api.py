"""Exercise native login APIs using synthetic sessions and temporary settings."""

from __future__ import annotations

import json
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlsplit

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
from login_sessions import LoginSessionError
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


class FakeSessions:
    def __init__(self):
        self.busy = False
        self.calls = []
        self.revision = "a" * 32
        self.failure = None

    def active(self):
        return self.busy

    def status(self):
        return {"schema_version": 1, "busy": self.busy, "platforms": [
            {"platform": platform, "state": "saved", "saved_at": None}
            for platform in PLATFORMS]}

    def current_token(self, platform):
        self.calls.append(("current", platform))
        if self.failure:
            raise self.failure
        return "cy-session:" + platform + ":" + self.revision

    def cookie_jar(self, token):
        self.calls.append(("read", token))
        if self.failure:
            raise self.failure
        return []

    def start(self, platform):
        if platform not in PLATFORMS:
            raise LoginSessionError("login_platform_invalid", 422)
        if self.busy:
            raise LoginSessionError("login_busy", 409)
        self.calls.append(("start", platform))
        self.busy = True

    def finish(self, platform):
        if platform not in PLATFORMS:
            raise LoginSessionError("login_platform_invalid", 422)
        self.calls.append(("finish", platform))
        self.busy = False
        self.revision = "b" * 32


@pytest.fixture
def native(tmp_path, monkeypatch):
    def reject_chrome(*args, **kwargs):
        raise AssertionError("Daily Chrome inventory must not be accessed")

    monkeypatch.setattr(chrome_profiles, "_profile_root", reject_chrome)
    app = FastAPI()
    config = Config(download_dir=str(tmp_path / "media"))
    records = [{"id": "legacy", "cookie_browser": "chrome", "cookie_profile": "Default"}]
    lock = threading.RLock()
    sessions = FakeSessions()
    policy = LoginPolicy(tmp_path)

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

    def identify_url(url):
        hostname = (urlsplit(url).hostname or "").removeprefix("www.")
        platform = hostname.split(".")[0]
        if platform not in PLATFORMS:
            raise ValueError("Unsupported synthetic source")
        return SimpleNamespace(platform=SimpleNamespace(value=platform))

    def job(identifier):
        return SimpleNamespace(**next(record for record in records if record["id"] == identifier))

    def retry(identifier, *args):
        return next(record for record in records if record["id"] == identifier)

    manager = SimpleNamespace(_lock=threading.RLock(), _futures={}, create_job=create_bound,
                              start_job=retry, retry_item=retry, retry_failed=retry,
                              get_job=job, list_jobs=lambda: [SimpleNamespace(**record) for record in records])
    proxy = ProxySettings(tmp_path, manager)
    proxy.additional_activity = sessions.active
    engine = SimpleNamespace(app=app, manager=manager, AppConfig=Config,
                             CreateJobRequest=JobRequest, _CONFIG_LOCK=lock,
                             get_config=get_config, update_config=update_config,
                             create_job=create_job, identify_url=identify_url,
                             _public_job=lambda value: value,
                             _http_error=lambda error: HTTPException(422, "Synthetic request failed"),
                             open_verification=lambda identifier: {"status": "legacy", "job": identifier},
                             index=lambda: HTMLResponse("<html><head><title>原迹下载器</title></head></html>"))
    app.get("/api/config")(get_config)
    app.put("/api/config")(update_config)
    app.post("/api/jobs", status_code=201)(create_job)
    app.post("/api/jobs/{job_id}/retry")(lambda job_id: manager.retry_failed(job_id))
    app.post("/api/jobs/{job_id}/verify")(engine.open_verification)
    install_desktop_adapter(engine, token=AUTH, origin=ORIGIN, assets=tmp_path,
                            proxy_settings=proxy, login_sessions=sessions, login_policy=policy)
    client = TestClient(app, base_url=ORIGIN)
    client.cookies.set(COOKIE_NAME, AUTH)
    try:
        yield SimpleNamespace(client=client, engine=engine, sessions=sessions,
                              policy=policy, records=records, proxy=proxy, root=tmp_path)
    finally:
        client.close()


def test_fresh_login_status_and_inventory_do_not_read_daily_chrome(native):
    assert native.client.get("/api/native/login").json()["mode"] == "dedicated"
    inventory = native.client.get("/api/native/chrome-profiles")
    assert inventory.status_code == 200
    assert inventory.json()["status"] == "disabled"
    assert inventory.json()["profiles"] == []
    html = native.client.get("/").text
    assert "/native/login_sessions.js" in html
    assert "/native/chrome_profiles.js" not in html
    assert native.engine.get_config().chrome_profile == "Default"
    assert native.sessions.calls == []


@pytest.mark.parametrize("platform", PLATFORMS)
def test_new_task_binds_exact_platform_revision_without_chrome_preflight(native, platform):
    response = native.client.post("/api/jobs", json={"url": "https://www." + platform + ".com/item/synthetic"})
    assert response.status_code == 201
    profile = "cy-session:" + platform + ":" + "a" * 32
    assert response.json()["cookie_profile"] == profile
    assert response.json()["cookie_browser"] == "chrome"
    assert native.sessions.calls == [("current", platform), ("read", profile)]
    assert native.records[0]["cookie_profile"] == "Default"


def test_new_dedicated_tasks_do_not_inherit_old_chrome_off_setting(native):
    config = native.engine.get_config()
    config.use_chrome_cookies = False
    native.engine.update_config(config)
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 201
    assert response.json()["cookie_browser"] == "chrome"
    assert native.engine.get_config().use_chrome_cookies is False


def test_unrelated_settings_save_does_not_scan_or_rewrite_old_profile(native):
    config = native.engine.get_config().model_dump()
    config["download_dir"] = str(native.root / "another-media-folder")
    response = native.client.put("/api/config", json=config)
    assert response.status_code == 200
    assert response.json()["chrome_profile"] == "Default"
    assert native.policy.mode() == "dedicated"


def test_legacy_retry_retains_exact_identity_after_new_login_saved(native):
    assert native.client.post("/api/native/login/douyin/open", json={}).status_code == 200
    assert native.client.post("/api/native/login/douyin/save", json={}).status_code == 200
    response = native.client.post("/api/jobs/legacy/retry")
    assert response.status_code == 200
    assert response.json() == native.records[0]
    assert response.json()["cookie_profile"] == "Default"


def test_dedicated_retry_keeps_immutable_old_revision(native):
    first = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"}).json()
    assert native.client.post("/api/native/login/douyin/open", json={}).status_code == 200
    assert native.client.post("/api/native/login/douyin/save", json={}).status_code == 200
    retried = native.client.post("/api/jobs/" + first["id"] + "/retry").json()
    second = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"}).json()
    assert retried["cookie_profile"] == first["cookie_profile"]
    assert second["cookie_profile"] != first["cookie_profile"]


def test_missing_session_rejects_before_task_creation(native):
    native.sessions.failure = LoginSessionError("login_session_missing", 409)
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 409
    assert response.json() == {"detail": {"code": "login_session_missing",
        "message": "请先在“下载登录”中打开对应平台的专用窗口，手动登录并保存，再创建下载任务。"}}
    assert len(native.records) == 1


def test_explicit_anonymous_mode_does_not_load_snapshot_or_daily_chrome(native):
    response = native.client.put("/api/native/login/mode", json={"mode": "anonymous"})
    assert response.status_code == 200
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 201
    assert response.json()["cookie_browser"] is None
    assert response.json()["cookie_profile"] is None
    assert native.sessions.calls == []
    assert native.records[0]["cookie_profile"] == "Default"


def test_explicit_legacy_mode_uses_original_profile_preflight(native, monkeypatch):
    browser = native.root / "synthetic-chrome"
    (browser / "Default").mkdir(parents=True)
    (browser / "Default/Cookies").touch()
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda root: browser)
    assert native.client.put("/api/native/login/mode", json={"mode": "chrome"}).status_code == 200
    assert native.client.get("/api/native/chrome-profiles").json()["selected_status"] == "available"
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"})
    assert response.status_code == 201
    assert response.json()["cookie_profile"] == "Default"
    assert native.sessions.calls == []


@pytest.mark.parametrize("path,method,payload", [
    ("/api/native/login", "get", None),
    ("/api/native/login/mode", "put", {"mode": "anonymous"}),
    ("/api/native/login/douyin/open", "post", {}),
    ("/api/native/login/douyin/save", "post", {}),
])
def test_login_routes_require_private_launch_session(native, path, method, payload):
    response = native.client.request(method, path, json=payload,
                                     headers={"Origin": "https://untrusted.example"})
    assert response.status_code == 403
    native.client.cookies.clear()
    response = native.client.request(method, path, json=payload)
    assert response.status_code == 403
    assert native.sessions.calls == []


@pytest.mark.parametrize("payload", [{}, {"mode": "unknown"}, {"mode": []},
    {"mode": "dedicated", "extra": "private-fixture"}, []])
def test_invalid_mode_payload_is_private_and_does_not_change_policy(native, payload):
    response = native.client.put("/api/native/login/mode", json=payload)
    assert response.status_code == 422
    assert "private-fixture" not in response.text
    assert native.policy.mode() == "dedicated"


def test_oversized_login_payload_is_rejected_without_echo(native):
    response = native.client.put("/api/native/login/mode", content=json.dumps({"mode": "private-fixture" * 100}),
                                 headers={"Content-Type": "application/json"})
    assert response.status_code == 413
    assert "private-fixture" not in response.text


def test_dedicated_verification_never_opens_daily_chrome_or_rebinds(native):
    job = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"}).json()
    response = native.client.post("/api/jobs/" + job["id"] + "/verify")
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "login_refresh_new_task"
    assert native.records[-1]["cookie_profile"] == job["cookie_profile"]
    assert native.client.post("/api/jobs/legacy/verify").json()["status"] == "legacy"


def test_login_window_blocks_mode_changes_new_jobs_proxy_and_updates(native):
    assert native.client.post("/api/native/login/douyin/open", json={}).status_code == 200
    assert native.client.get("/api/native/activity").json() == {"known": True, "busy": True}
    assert native.client.put("/api/native/login/mode", json={"mode": "anonymous"}).status_code == 409
    assert native.client.post("/api/jobs", json={"url": "https://www.douyin.com/item/synthetic"}).status_code == 409
    response = native.client.put("/api/native/proxy", json={"enabled": True, "url": "http://127.0.0.1:9123"})
    assert response.status_code == 409
    assert native.proxy.proxy_url() is None
    response = native.client.put("/api/native/maintenance/12345678-1234-1234-1234-123456789abc")
    assert response.json() == {"acquired": False}
    assert native.client.post("/api/native/login/douyin/save", json={}).status_code == 200
    assert native.client.get("/api/native/activity").json() == {"known": True, "busy": False}


def test_acquired_update_lease_blocks_login_browser_launch(native):
    identifier = "12345678-1234-1234-1234-123456789abc"
    assert native.client.put("/api/native/maintenance/" + identifier).json() == {"acquired": True}
    response = native.client.post("/api/native/login/douyin/open", json={})
    assert response.status_code == 409
    assert native.sessions.calls == []


@pytest.mark.parametrize("mode", ["chrome", "anonymous"])
def test_dedicated_browser_cannot_launch_in_another_mode(native, mode):
    native.policy.save(mode)
    response = native.client.post("/api/native/login/douyin/open", json={})
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "login_mode_required"
    assert native.sessions.calls == []


@pytest.mark.parametrize("path", ["/api/native/login/not-a-platform/open", "/api/native/login/douyin/not-an-action"])
def test_unknown_login_actions_cannot_launch_arbitrary_browser_target(native, path):
    response = native.client.post(path, json={})
    assert response.status_code == 422
    assert native.sessions.calls == []


def test_mode_save_cannot_change_identity_halfway_through_submission(native, monkeypatch):
    reading = threading.Event()
    release = threading.Event()
    saving = threading.Event()
    original_read = native.sessions.cookie_jar

    def held_read(profile):
        reading.set()
        assert release.wait(5)
        return original_read(profile)

    def change_mode():
        saving.set()
        return native.client.put("/api/native/login/mode", json={"mode": "anonymous"})

    monkeypatch.setattr(native.sessions, "cookie_jar", held_read)
    with ThreadPoolExecutor(max_workers=2) as pool:
        submitted = pool.submit(native.client.post, "/api/jobs",
                                json={"url": "https://www.douyin.com/item/synthetic"})
        assert reading.wait(5)
        changed = pool.submit(change_mode)
        assert saving.wait(5)
        try:
            assert native.policy.mode() == "dedicated"
            assert len(native.records) == 1
        finally:
            release.set()
        created = submitted.result(timeout=5)
        assert created.status_code == 201
        assert created.json()["cookie_profile"] == "cy-session:douyin:" + "a" * 32
        assert changed.result(timeout=5).status_code == 200
    assert native.policy.mode() == "anonymous"
