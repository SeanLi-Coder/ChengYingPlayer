"""Summary authentication uses explicit policy and app-owned cookie snapshots."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import login_sessions
from test_summary_source import (
    ROOT,
    URL,
    Downloader,
    Response,
    caption_blob,
    metadata,
    source,
)


def records(value="SYNTHETIC_FIRST"):
    return [
        {
            "name": "SAPISID",
            "value": value,
            "domain": "www.youtube.com",
            "path": "/",
            "expires": -1,
            "httpOnly": True,
            "secure": True,
            "sameSite": "Lax",
        }
    ]


@pytest.fixture(autouse=True)
def reject_real_access(monkeypatch, request):
    if request.node.name == "test_production_login_self_test_in_isolated_subprocess":
        return

    def reject(*args, **kwargs):
        raise AssertionError(
            "Real browser, keychain and external transport are forbidden"
        )

    monkeypatch.setattr(socket.socket, "connect", reject)
    monkeypatch.setattr(socket.socket, "connect_ex", reject)
    monkeypatch.setattr(subprocess, "Popen", reject)
    monkeypatch.setattr("yt_dlp.cookies.extract_cookies_from_browser", reject)


@pytest.fixture
def fixture(tmp_path):
    data, job = tmp_path / "data", tmp_path / "job"
    data.mkdir(mode=0o700)
    job.mkdir(mode=0o700)
    (data / "config.json").write_text(
        json.dumps({"use_chrome_cookies": True, "chrome_profile": "Profile 1"})
    )
    return SimpleNamespace(
        data_dir=data,
        download_dir=job,
        ffmpeg=tmp_path / "ffmpeg",
        ffprobe=tmp_path / "ffprobe",
    )


def seed(fixture):
    manager = login_sessions.LoginSessions(fixture.data_dir, lambda: None)
    try:
        manager._store("youtube", records())
        return manager.current_token("youtube")
    finally:
        assert manager.close()


def policy(fixture, mode):
    (fixture.data_dir / "login-policy.json").write_text(
        json.dumps({"version": 1, "mode": mode})
    )


def acquire(fixture, downloader=None):
    from yt_dlp.networking._requests import RequestsRH

    downloader = downloader or Downloader(metadata(), fixture.download_dir)
    handler = RequestsRH(logger=source.QuietLogger())
    downloader._request_director = SimpleNamespace(handlers={"Requests": handler})

    class CaptionSession(requests.Session):
        def __init__(self):
            super().__init__()
            self.prepared = []

        def get(self, url, **kwargs):
            self.prepared.append(
                self.prepare_request(
                    requests.Request("GET", url, headers=kwargs.get("headers"))
                )
            )
            return Response(caption_blob())

    session = CaptionSession()
    events = []
    try:
        path = source.acquire(
            fixture,
            URL,
            "youtube",
            events.append,
            source.Cancellation(),
            ydl_factory=downloader,
            session_factory=lambda: session,
            node=fixture.data_dir / "node",
        )
    finally:
        handler.close()
    return path, downloader, session, events


def tracking_sessions(monkeypatch, *, fail=False, change=False):
    original = login_sessions.LoginSessions
    created = []

    class TrackedSessions(original):
        def __init__(self, *args, **kwargs):
            self.ready = False
            self.was_closed = False
            super().__init__(*args, **kwargs)
            self.ready = True
            created.append(self)

        def current_token(self, platform):
            if self.ready and fail:
                raise login_sessions.LoginSessionError("login_session_expired")
            token = super().current_token(platform)
            if self.ready and change:
                self._store(platform, records("SYNTHETIC_SECOND"))
            return token

        def close(self, *args, **kwargs):
            self.was_closed = True
            return super().close(*args, **kwargs)

    monkeypatch.setattr(login_sessions, "LoginSessions", TrackedSessions)
    return created


def test_dedicated_default_ignores_daily_chrome_setting_and_closes_store(
    fixture, monkeypatch
):
    first = seed(fixture)
    created = tracking_sessions(monkeypatch)

    class NoChromeReader(Downloader):
        @property
        def cookiejar(self):
            if getattr(self.private_jar, "_chengying_dedicated_session", False):
                return self.private_jar
            raise AssertionError("Dedicated mode must not read the browser cookie jar")

        @cookiejar.setter
        def cookiejar(self, value):
            self.private_jar = value

    downloader = NoChromeReader(metadata(), fixture.download_dir)
    path, result, session, events = acquire(fixture, downloader)
    assert json.loads(path.read_text())["segments"]
    assert "cookiesfrombrowser" not in result.options
    assert next(iter(result.private_jar)).value == "SYNTHETIC_FIRST"
    assert getattr(
        result._request_director.handlers["Requests"]._create_instance,
        "_chengying_dedicated_session",
        False,
    )
    assert session.prepared[0].headers["Cookie"] == "SAPISID=SYNTHETIC_FIRST"
    child = session.prepare_request(
        requests.Request("GET", "https://child.www.youtube.com/")
    )
    assert "Cookie" not in child.headers
    assert created[0].was_closed
    assert created[0]._root_fd == -1
    public = json.dumps(events)
    assert (
        first not in public
        and "SYNTHETIC_FIRST" not in public
        and "Profile 1" not in public
    )


def test_summary_holds_exact_snapshot_when_current_login_changes(fixture, monkeypatch):
    first = seed(fixture)
    created = tracking_sessions(monkeypatch, change=True)
    _, downloader, _, _ = acquire(fixture)
    assert next(iter(downloader.cookiejar)).value == "SYNTHETIC_FIRST"
    assert created[0].was_closed
    restored = login_sessions.LoginSessions(fixture.data_dir, lambda: None)
    try:
        assert restored.current_token("youtube") != first
    finally:
        restored.close()


@pytest.mark.parametrize("mode", ["anonymous", "chrome"])
def test_non_dedicated_modes_never_read_session_store(fixture, monkeypatch, mode):
    policy(fixture, mode)

    def reject(*args, **kwargs):
        raise AssertionError("This policy must not inspect app-owned sessions")

    monkeypatch.setattr(login_sessions, "LoginSessions", reject)
    _, downloader, _, _ = acquire(fixture)
    if mode == "chrome":
        assert downloader.options["cookiesfrombrowser"] == ("chrome", "Profile 1")
    else:
        assert "cookiesfrombrowser" not in downloader.options


def test_legacy_explicit_cookie_off_remains_off(fixture):
    policy(fixture, "chrome")
    (fixture.data_dir / "config.json").write_text(
        json.dumps({"use_chrome_cookies": False, "chrome_profile": "Profile 1"})
    )
    _, downloader, _, _ = acquire(fixture)
    assert "cookiesfrombrowser" not in downloader.options


def test_missing_snapshot_blocks_before_any_transport(fixture, monkeypatch):
    created = tracking_sessions(monkeypatch)
    downloader = Downloader(metadata(), fixture.download_dir)
    with pytest.raises(source.SourceError) as raised:
        acquire(fixture, downloader)
    assert raised.value.code == "cookies_unavailable"
    assert downloader.options is None
    assert created[0].was_closed
    assert not list(fixture.download_dir.iterdir())


def test_expired_snapshot_closes_store_and_never_falls_back_to_chrome(
    fixture, monkeypatch
):
    seed(fixture)
    created = tracking_sessions(monkeypatch, fail=True)
    downloader = Downloader(metadata(), fixture.download_dir)
    with pytest.raises(source.SourceError) as raised:
        acquire(fixture, downloader)
    assert raised.value.code == "cookies_unavailable"
    assert downloader.options is None
    assert created[0].was_closed


def test_invalid_policy_blocks_before_any_transport(fixture):
    policy(fixture, "unexpected")
    downloader = Downloader(metadata(), fixture.download_dir)
    with pytest.raises(source.SourceError) as raised:
        acquire(fixture, downloader)
    assert raised.value.code == "configuration_unavailable"
    assert downloader.options is None


def test_owned_store_closed_before_metadata_failure(fixture, monkeypatch):
    seed(fixture)
    created = tracking_sessions(monkeypatch)

    class FailedDownloader(Downloader):
        def extract_info(self, *args, **kwargs):
            assert created[0].was_closed
            raise source.SourceError("source_unavailable")

    with pytest.raises(source.SourceError, match="website source"):
        acquire(fixture, FailedDownloader(metadata(), fixture.download_dir))
    assert created[0]._root_fd == -1


def test_production_login_self_test_in_isolated_subprocess(tmp_path):
    vendor = tmp_path / "vendor"
    shutil.copytree(
        ROOT / "vendor/rednote/app",
        vendor / "app",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
    code = r"""
import socket, subprocess, sys
sys.path[:0] = [sys.argv[1], sys.argv[2]]
def reject(*args, **kwargs):
    raise AssertionError("Browser, keychain and network access are forbidden")
socket.socket.connect = reject
socket.socket.connect_ex = reject
# Native crypto initialization may call the system's file(1) before our guard.
import yt_dlp.cookies
subprocess.Popen = reject
yt_dlp.cookies.Popen = reject
from app import browser
browser.chrome_user_data_directory = reject
from login_smoke import verify_login_runtime
print(verify_login_runtime())
assert "app.main" not in sys.modules
"""
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("CHENGYING_")
    }
    result = subprocess.run(
        [sys.executable, "-I", "-c", code, str(vendor), str(ROOT)],
        capture_output=True,
        text=True,
        timeout=30,
        cwd=tmp_path,
        env=environment,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "isolated-revisions-and-restart-verified-offline"
    assert result.stderr == ""
