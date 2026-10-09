"""Summary requests share restored Chrome settings without private login UI."""

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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import chrome_profiles
import login_sessions
from login_auth import LoginPolicy
from test_summary_source import (
    ROOT,
    URL,
    Downloader,
    Response,
    Session,
    caption_blob,
    metadata,
    source,
)


@pytest.fixture(autouse=True)
def reject_real_access(monkeypatch, request):
    if request.node.name == "test_production_login_self_test_in_isolated_subprocess":
        return

    def reject(*args, **kwargs):
        raise AssertionError("Real browser, keychain and external transport are forbidden")

    monkeypatch.setattr(socket.socket, "connect", reject)
    monkeypatch.setattr(socket.socket, "connect_ex", reject)
    monkeypatch.setattr(subprocess, "Popen", reject)
    monkeypatch.setattr("yt_dlp.cookies.extract_cookies_from_browser", reject)
    monkeypatch.setattr(login_sessions, "LoginSessions", reject)
    monkeypatch.setattr(login_sessions, "LegacyLoginSnapshots", reject)


@pytest.fixture
def fixture(tmp_path, monkeypatch):
    data, job = tmp_path / "data", tmp_path / "job"
    data.mkdir(mode=0o700)
    job.mkdir(mode=0o700)
    (data / "config.json").write_text(json.dumps({"use_chrome_cookies": True, "chrome_profile": "Profile 1"}))
    browser = tmp_path / "synthetic-chrome"
    (browser / "Profile 1").mkdir(parents=True)
    (browser / "Profile 1/Cookies").touch()
    monkeypatch.setattr(chrome_profiles, "_profile_root", lambda _: browser)
    return SimpleNamespace(data_dir=data, download_dir=job, ffmpeg=tmp_path / "ffmpeg", ffprobe=tmp_path / "ffprobe")


def policy(fixture, mode):
    LoginPolicy(fixture.data_dir).save(mode)


def acquire(fixture, downloader=None):
    downloader = downloader or Downloader(metadata(), fixture.download_dir)
    events = []
    path = source.acquire(fixture, URL, "youtube", events.append, source.Cancellation(),
                          ydl_factory=downloader,
                          session_factory=lambda: Session([Response(caption_blob())]),
                          node=fixture.data_dir / "node")
    return path, downloader, events


@pytest.mark.parametrize("mode", [None, "dedicated", "chrome"])
def test_restored_modes_use_saved_chrome_profile_and_never_read_session_store(fixture, mode):
    if mode:
        policy(fixture, mode)
    path, downloader, events = acquire(fixture)
    assert downloader.options["cookiesfrombrowser"] == ("chrome", "Profile 1")
    assert json.loads(path.read_text())["segments"]
    assert not (fixture.data_dir / "login-sessions").exists()
    assert "Profile 1" not in json.dumps(events)


@pytest.mark.parametrize("mode", [None, "dedicated", "chrome", "anonymous"])
def test_explicit_cookie_off_remains_off_in_every_policy(fixture, monkeypatch, mode):
    if mode:
        policy(fixture, mode)
    (fixture.data_dir / "config.json").write_text(json.dumps({"use_chrome_cookies": False, "chrome_profile": "Profile 1"}))

    def reject(*args, **kwargs):
        raise AssertionError("Cookie-off must not inspect a Chrome directory")

    monkeypatch.setattr(chrome_profiles, "_profile_root", reject)
    _, downloader, _ = acquire(fixture)
    assert "cookiesfrombrowser" not in downloader.options


def test_unmigrated_anonymous_policy_overrides_old_cookie_on(fixture, monkeypatch):
    policy(fixture, "anonymous")

    def reject(*args, **kwargs):
        raise AssertionError("Anonymous mode must not inspect Chrome")

    monkeypatch.setattr(chrome_profiles, "_profile_root", reject)
    _, downloader, _ = acquire(fixture)
    assert "cookiesfrombrowser" not in downloader.options


@pytest.mark.parametrize("profile", ["cy-session:youtube:" + "a" * 32, "cy-session:invalid", "Profile 99", "../Default"])
def test_invalid_or_missing_profile_blocks_before_any_transport(fixture, profile):
    (fixture.data_dir / "config.json").write_text(json.dumps({"use_chrome_cookies": True, "chrome_profile": profile}))
    downloader = Downloader(metadata(), fixture.download_dir)
    with pytest.raises(source.SourceError) as raised:
        acquire(fixture, downloader)
    assert raised.value.code == "cookies_unavailable"
    assert downloader.options is None


def test_invalid_policy_blocks_before_any_transport(fixture):
    (fixture.data_dir / "login-policy.json").write_text('{"version":1,"mode":"unexpected"}')
    downloader = Downloader(metadata(), fixture.download_dir)
    with pytest.raises(source.SourceError) as raised:
        acquire(fixture, downloader)
    assert raised.value.code == "configuration_unavailable"
    assert downloader.options is None


@pytest.mark.parametrize("finish_during", ["policy", "config"])
def test_summary_cannot_mix_old_cookie_on_with_retired_anonymous_policy(fixture, monkeypatch, finish_during):
    policy(fixture, "anonymous")
    original_mode = LoginPolicy.mode
    original_read = source.read_private_json

    def commit_migration():
        (fixture.data_dir / "config.json").write_text(json.dumps({"use_chrome_cookies": False, "chrome_profile": "Profile 1"}))
        policy(fixture, "chrome")

    def changing_mode(instance):
        if finish_during == "policy":
            commit_migration()
        return original_mode(instance)

    def changing_config(path):
        if path.name == "config.json" and finish_during == "config":
            old = original_read(path)
            commit_migration()
            return old
        return original_read(path)

    def reject(*args, **kwargs):
        raise AssertionError("Anonymous migration must not authorize Chrome access")

    monkeypatch.setattr(LoginPolicy, "mode", changing_mode)
    monkeypatch.setattr(source, "read_private_json", changing_config)
    monkeypatch.setattr(chrome_profiles, "_profile_root", reject)
    _, downloader, _ = acquire(fixture)
    assert "cookiesfrombrowser" not in downloader.options
    assert original_mode(LoginPolicy(fixture.data_dir)) == "chrome"


def test_production_login_self_test_in_isolated_subprocess(tmp_path):
    vendor = tmp_path / "vendor"
    shutil.copytree(ROOT / "vendor/rednote/app", vendor / "app", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    code = r"""
import socket, subprocess, sys
sys.path[:0] = [sys.argv[1], sys.argv[2]]
def reject(*args, **kwargs):
    raise AssertionError("Browser, keychain and network access are forbidden")
socket.socket.connect = reject
socket.socket.connect_ex = reject
import yt_dlp.cookies
subprocess.Popen = reject
yt_dlp.cookies.Popen = reject
from app import browser
browser.chrome_user_data_directory = reject
from login_smoke import verify_login_runtime
print(verify_login_runtime())
assert "app.main" not in sys.modules
"""
    environment = {key: value for key, value in os.environ.items() if not key.startswith("CHENGYING_")}
    result = subprocess.run([sys.executable, "-I", "-c", code, str(vendor), str(ROOT)],
                            capture_output=True, text=True, timeout=30,
                            cwd=tmp_path, env=environment, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "removed-entry-and-legacy-identity-verified-offline"
    assert result.stderr == ""
