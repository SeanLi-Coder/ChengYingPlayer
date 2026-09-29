"""Check native profile preflight with isolated metadata and no real browser."""
from __future__ import annotations

import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chrome_profiles
from host import COOKIE_NAME, install_desktop_adapter

TOKEN = "synthetic-profile-session-" + "x" * 48
ORIGIN = "http://127.0.0.1:51923"


class Config(BaseModel):
    download_dir: str
    use_chrome_cookies: bool = True
    chrome_profile: str | None = "Default"


class JobRequest(BaseModel):
    url: str = Field(min_length=8, max_length=4096)


@pytest.fixture
def native(tmp_path, monkeypatch):
    browser = tmp_path / "browser"
    (browser / "Profile 1").mkdir(parents=True)
    (browser / "Profile 1/Cookies").touch()
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda root: browser)
    app = FastAPI()
    config = Config(download_dir=str(tmp_path / "media"))
    records = [{"id": "old", "cookie_profile": "Default"}]
    saved = []
    lock = threading.RLock()

    def get_config():
        with lock:
            return config.model_copy(deep=True)

    def update_config(value):
        nonlocal config
        with lock:
            config = value.model_copy(deep=True)
            saved.append(value.model_dump())
            return config

    def create_job(request):
        snapshot = get_config()
        job = {"id": "new", "cookie_profile": snapshot.chrome_profile,
               "cookie_browser": "chrome" if snapshot.use_chrome_cookies else None}
        records.append(job)
        return job

    app.post("/api/jobs", status_code=201)(create_job)
    app.put("/api/config")(update_config)
    app.post("/api/jobs/{job_id}/retry")(lambda job_id: records[0])
    engine = SimpleNamespace(app=app, manager=SimpleNamespace(list_jobs=list),
                             AppConfig=Config, CreateJobRequest=JobRequest,
                             _CONFIG_LOCK=lock, get_config=get_config,
                             update_config=update_config, create_job=create_job)
    install_desktop_adapter(engine, token=TOKEN, origin=ORIGIN, assets=tmp_path)
    client = TestClient(app, base_url=ORIGIN)
    client.cookies.set(COOKIE_NAME, TOKEN)
    return SimpleNamespace(client=client, engine=engine, records=records, saved=saved, browser=browser)


def test_profile_choices_report_missing_saved_default_without_changing_it(native):
    response = native.client.get("/api/native/chrome-profiles")
    assert response.status_code == 200
    assert response.json() == {"schema_version": 1, "status": "ok",
        "profiles": [{"directory": "Profile 1", "has_cookie_database": True}],
        "selected_profile": "Default", "selected_status": "missing", "use_chrome_cookies": True}
    assert "no-store" in response.headers["cache-control"]
    assert native.engine.get_config().chrome_profile == "Default"
    assert not native.saved and len(native.records) == 1


def test_missing_profile_is_rejected_before_task_creation(native):
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "chrome_profile_missing"
    assert len(native.records) == 1


def test_explicit_saved_real_profile_applies_only_to_new_tasks(native):
    config = native.engine.get_config().model_dump()
    config["chrome_profile"] = "Profile 1"
    assert native.client.put("/api/config", json=config).status_code == 200
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    assert response.status_code == 201
    assert response.json()["cookie_profile"] == "Profile 1"
    assert native.client.post("/api/jobs/old/retry").json()["cookie_profile"] == "Default"
    assert native.client.get("/api/native/chrome-profiles").json()["selected_status"] == "available"


@pytest.mark.parametrize("profile,code", [("Profile 2", "chrome_profile_missing"),
    ("../private-account", "chrome_profile_invalid"), ("Profile 0", "chrome_profile_invalid")])
def test_unavailable_new_settings_not_saved(native, profile, code):
    config = native.engine.get_config().model_dump()
    config["chrome_profile"] = profile
    response = native.client.put("/api/config", json=config)
    assert response.status_code == 422 and response.json()["detail"]["code"] == code
    assert "private-account" not in response.text
    assert not native.saved


@pytest.mark.parametrize("mode", ["off", "automatic"])
def test_explicit_cookie_off_and_automatic_keep_existing_semantics(native, mode, monkeypatch):
    config = native.engine.get_config().model_dump()
    if mode == "off":
        config["use_chrome_cookies"] = False
    else:
        config["chrome_profile"] = None
    def reject(*args):
        raise AssertionError("No directory scan is needed")
    monkeypatch.setattr(chrome_profiles, "_profile_root", reject)
    assert native.client.put("/api/config", json=config).status_code == 200
    assert native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"}).status_code == 201


def test_unedited_legacy_configuration_preserved_but_not_rebound(native):
    legacy = native.engine.get_config()
    legacy.chrome_profile = "/private/legacy-account"
    native.engine.update_config(legacy)
    assert native.client.put("/api/config", json=legacy.model_dump()).status_code == 200
    report = native.client.get("/api/native/chrome-profiles")
    assert report.json()["selected_status"] == "invalid"
    assert "legacy-account" not in report.text
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    assert response.status_code == 422
    assert native.engine.get_config().chrome_profile == legacy.chrome_profile


def test_profile_removed_after_save_is_rechecked_at_submission(native):
    config = native.engine.get_config().model_dump()
    config["chrome_profile"] = "Profile 1"
    assert native.client.put("/api/config", json=config).status_code == 200
    (native.browser / "Profile 1/Cookies").unlink()
    response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    assert response.status_code == 422 and response.json()["detail"]["code"] == "cookie_database_missing"
    assert len(native.records) == 1


def test_scan_failure_never_claims_profile_was_deleted(native, monkeypatch):
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda _: (_ for _ in ()).throw(PermissionError(13, "private path")))
    response = native.client.get("/api/native/chrome-profiles")
    assert response.json()["status"] == "cookie_permission_denied"
    assert response.json()["selected_status"] == "unverified"
    assert "private path" not in response.text


def test_settings_lock_covers_profile_check_and_original_submission(native, monkeypatch):
    held = []
    def validate(profile):
        def attempt():
            acquired = native.engine._CONFIG_LOCK.acquire(blocking=False)
            held.append(not acquired)
            if acquired:
                native.engine._CONFIG_LOCK.release()
        worker = threading.Thread(target=attempt)
        worker.start()
        worker.join(timeout=2)
    # The adapter resolves the function at installation time. Its existing
    # imported function still uses this patched metadata root while holding the lock.
    original = chrome_profiles._profile_root
    def root(value):
        validate("Default")
        return original(value)
    monkeypatch.setattr(chrome_profiles, "_profile_root", root)
    native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    assert held == [True]


def test_concurrent_save_cannot_replace_the_preflighted_submission_identity(native):
    selected = native.engine.get_config()
    selected.chrome_profile = "Profile 1"
    native.engine.update_config(selected)
    next_config = selected.model_copy(deep=True)
    next_config.chrome_profile = "Profile 2"
    original_create = native.engine.create_job
    attempted = threading.Event()
    saved = threading.Event()
    lock_held = []
    workers = []

    def change_configuration():
        acquired = native.engine._CONFIG_LOCK.acquire(blocking=False)
        lock_held.append(not acquired)
        if acquired:
            native.engine._CONFIG_LOCK.release()
        attempted.set()
        native.engine.update_config(next_config)
        saved.set()

    def create_while_save_waits(request):
        worker = threading.Thread(target=change_configuration)
        workers.append(worker)
        worker.start()
        assert attempted.wait(timeout=2)
        assert not saved.is_set()
        return original_create(request)

    native.engine.create_job = create_while_save_waits
    try:
        response = native.client.post("/api/jobs", json={"url": "https://www.douyin.com/video/123456"})
    finally:
        for worker in workers:
            worker.join(timeout=2)
            assert not worker.is_alive()
    assert response.status_code == 201
    assert response.json()["cookie_profile"] == "Profile 1"
    assert lock_held == [True] and saved.is_set()
    assert native.engine.get_config().chrome_profile == "Profile 2"
    assert native.records[0]["cookie_profile"] == "Default"


@pytest.mark.parametrize("path", ["/api/native/chrome-profiles", "/api/jobs", "/api/config"])
def test_preflight_routes_require_session_and_same_origin(native, path):
    assert native.client.get(path, headers={"Origin": "https://foreign.invalid"}).status_code == 403
    native.client.cookies.clear()
    assert native.client.get(path).status_code == 403


@pytest.mark.parametrize("body,status", [(b"private-token", 422), (b"x" * 16385, 413), (b"[]", 422)])
def test_submission_errors_never_echo_input(native, body, status):
    response = native.client.post("/api/jobs", content=body)
    assert response.status_code == status
    assert "private-token" not in response.text
