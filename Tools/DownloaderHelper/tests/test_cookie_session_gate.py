"""Verify repaired sessions through real extractors using synthetic SQLite stores."""

from __future__ import annotations

import socket
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path

import pytest
from yt_dlp import YoutubeDL, cookies
from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import DownloadCancelled, DownloadError

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import chrome_cookie_runtime as runtime
from app import browser, douyin, downloader
from app import douyin_signing as signing
from app.errors import (
    AuthenticationRequiredError,
    DownloadCancelledError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import DownloadJob, Platform, SourceKind
from app.task_manager import DownloadManager
from cookie_smoke import _encrypted_cookie

VIDEO_URL = "https://www.douyin.com/video/1234567890123456789"
PROFILE_URL = "https://www.douyin.com/user/synthetic-owner"
PASSWORD = b"synthetic-session-gate-password"


class BrowserReached(BaseException):
    """Stop before starting a real browser, after the production cookie checks."""


def reject_external(*args, **kwargs):
    raise AssertionError("Unexpected external access")


@pytest.fixture
def store(tmp_path, monkeypatch):
    root = tmp_path / "synthetic-browser"
    profile = root / "Profile 2"
    profile.mkdir(parents=True)
    database = profile / "Cookies"
    monkeypatch.setattr(socket.socket, "connect", reject_external)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_external)
    monkeypatch.setattr(subprocess, "Popen", reject_external)
    monkeypatch.setattr(cookies.Popen, "run", reject_external)
    monkeypatch.setattr(cookies, "_get_mac_keyring_password", lambda *args: PASSWORD)
    monkeypatch.setattr(cookies, "_get_chromium_based_browser_settings", lambda name: {
        "browser_dir": str(root), "keyring_name": "Chrome", "supports_profiles": True,
    })
    monkeypatch.setattr(cookies, "get_cookie_decryptor", lambda directory, name, logger, **kwargs:
        cookies.MacChromeCookieDecryptor(name, logger, kwargs["meta_version"]))
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: root)
    for name in ("_open_database_copy", "_process_chrome_cookie", "_extract_chrome_cookies"):
        monkeypatch.setattr(cookies, name, getattr(cookies, name))
    runtime.install_chrome_cookie_runtime()
    snapshot = cookies._open_database_copy
    state = {"snapshots": 0, "reading": False}

    def counted_snapshot(*args, **kwargs):
        state["snapshots"] += 1
        state["reading"] = True
        try:
            return snapshot(*args, **kwargs)
        finally:
            state["reading"] = False

    monkeypatch.setattr(cookies, "_open_database_copy", counted_snapshot)

    def browser_reached():
        raise BrowserReached()

    def signed_auth_failure(*args, **kwargs):
        raise AuthenticationRequiredError("Synthetic authentication confirmation")

    monkeypatch.setattr("playwright.sync_api.sync_playwright", browser_reached)
    monkeypatch.setattr(douyin, "fetch_signed_profile_awemes", signed_auth_failure)
    monkeypatch.setattr(downloader, "fetch_signed_aweme_detail", reject_external)
    with closing(sqlite3.connect(database)) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.executescript(
            "CREATE TABLE meta (key TEXT, value TEXT);"
            "INSERT INTO meta VALUES ('version', '24');"
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
            "encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER);"
        )
        state["writer"] = writer
        yield state


def cookie_row(domain=".douyin.com", name="sessionid", *, value=b"synthetic-session",
               path="/", expires=0, malformed=None):
    payload = _encrypted_cookie(domain, value, PASSWORD) if malformed is None else malformed
    return domain, name, "", payload, path, expires, 1


def write_rows(store, rows):
    with store["writer"] as writer:
        writer.executemany("INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)", rows)


def generic_extract(*, config=None, should_cancel=None, before_result=None, url=VIDEO_URL):
    engine = downloader.MediaDownloader(config or downloader.DownloaderConfig(cookie_profile="Profile 2"))
    calls = []

    class SyntheticIE(InfoExtractor):
        _VALID_URL = r"https://www\.douyin\.com/video/(?P<id>\d+)"

        def _real_extract(self, url):
            jar = self._downloader.cookiejar
            session = next((cookie.value for cookie in jar if cookie.name == "sessionid"), None)
            if before_result:
                before_result()
            assert self._downloader.cookiejar is jar
            return {
                "id": self._match_id(url), "title": "Synthetic video",
                "url": "https://media.invalid/synthetic.mp4",
                "height": 1080 if session else 480,
            }

    def operation(use_cookies):
        calls.append(use_cookies)
        with YoutubeDL({
            **engine._base_options(use_cookies), "logger": downloader._YdlLogger(),
        }, auto_init=False) as ydl:
            ydl.add_info_extractor(SyntheticIE(ydl))
            return ydl.extract_info(VIDEO_URL, download=False, process=False)

    result, fallback = engine._run_with_cookie_fallback(
        operation, url=url, should_cancel=should_cancel,
    )
    return result, fallback, calls


def enter(entry, *, should_cancel=None, allow_fallback=False):
    if entry == "generic":
        return generic_extract(should_cancel=should_cancel)
    if entry == "signing":
        return signing._run_with_signing_page(
            VIDEO_URL, cookie_profile="Profile 2", should_cancel=should_cancel,
            navigation_timeout_ms=100, signer_timeout_ms=100, signer_settle_ms=0,
            budget=signing.new_signed_discovery_budget(), status_callback=None,
            operation=reject_external,
        )
    return douyin.discover_profile(
        PROFILE_URL, cookie_profile="Profile 2", should_cancel=should_cancel,
        allow_cookie_fallback=allow_fallback,
    )


@pytest.mark.parametrize("entry", ["generic", "signing", "browser"])
@pytest.mark.parametrize("bad_record", ["aes-length", "encrypted-utf8", "plain-utf8"])
def test_unrelated_bad_record_preserves_current_session(store, entry, bad_record):
    rows = [cookie_row()]
    if bad_record == "aes-length":
        rows.append(cookie_row(".unrelated.invalid", malformed=b"v10truncated"))
    elif bad_record == "encrypted-utf8":
        rows.append(cookie_row(".unrelated.invalid", value=b"\xff"))
    else:
        with store["writer"] as writer:
            writer.execute(
                "INSERT INTO cookies VALUES ('.unrelated.invalid', 'broken', "
                "CAST(X'FF' AS TEXT), X'', '/', 0, 1)"
            )
    write_rows(store, rows)
    if entry == "generic":
        result, fallback, calls = enter(entry)
        assert result["height"] == 1080
        assert fallback is False
        assert calls == [True]
    else:
        with pytest.raises(BrowserReached):
            enter(entry)
    assert store["snapshots"] == 1


@pytest.mark.parametrize("entry", ["generic", "signing", "browser"])
@pytest.mark.parametrize("remaining", ["none", "ttwid", "expired", "subdomain", "path", "lookalike"])
def test_broken_requested_session_never_silently_becomes_anonymous(store, entry, remaining):
    rows = [cookie_row(malformed=b"v10truncated")]
    if remaining == "ttwid":
        rows.append(cookie_row(name="ttwid"))
    elif remaining == "expired":
        rows.append(cookie_row(name="sessionid_ss", expires=int((time.time() - 60 + 11_644_473_600) * 1_000_000)))
    elif remaining == "subdomain":
        rows.append(cookie_row(".live.douyin.com", name="sessionid_ss"))
    elif remaining == "path":
        rows.append(cookie_row(name="sessionid_ss", path="/unrelated/"))
    elif remaining == "lookalike":
        rows.append(cookie_row(".douyin.com.attacker.invalid", name="sessionid_ss"))
    write_rows(store, rows)
    expected = signing._CookieAccessSigningFailure if entry == "signing" else TemporaryAccessError
    with pytest.raises(expected) as failure:
        enter(entry)
    diagnostic = getattr(failure.value, "cookie_diagnostic_code", None) or failure.value.diagnostic_code
    assert diagnostic == "cookie_decryption_failed"
    if entry != "signing":
        assert failure.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert store["snapshots"] == 1


def test_generic_guard_consumes_one_cached_jar_even_if_database_changes(store):
    write_rows(store, [cookie_row(), cookie_row(".unrelated.invalid", malformed=b"v10broken")])

    def delete_session():
        with store["writer"] as writer:
            writer.execute("DELETE FROM cookies WHERE host_key = '.douyin.com'")

    result, fallback, _ = generic_extract(before_result=delete_session)
    assert result["height"] == 1080 and not fallback
    assert store["snapshots"] == 1
    with pytest.raises(TemporaryAccessError):
        generic_extract()
    assert store["snapshots"] == 2


@pytest.mark.parametrize("mode", ["disabled", "explicit-fallback"])
def test_explicit_anonymous_modes_keep_existing_behavior(store, mode):
    write_rows(store, [cookie_row(malformed=b"v10broken")])
    config = downloader.DownloaderConfig(
        cookie_browser=None if mode == "disabled" else "chrome", cookie_profile="Profile 2",
        allow_cookie_fallback=mode == "explicit-fallback",
    )
    result, fallback, calls = generic_extract(config=config)
    assert result["height"] == 480
    assert fallback is (mode == "explicit-fallback")
    assert calls == ([False] if mode == "disabled" else [True, False])
    assert store["snapshots"] == (0 if mode == "disabled" else 1)


@pytest.mark.parametrize("entry", ["generic", "signing", "browser"])
def test_cancel_during_real_snapshot_uses_the_task_callback(store, entry):
    write_rows(store, [cookie_row()])
    with pytest.raises(DownloadCancelledError):
        enter(entry, should_cancel=lambda: store["reading"])
    assert store["snapshots"] == 1


@pytest.mark.parametrize("entry", ["generic", "signing", "browser"])
@pytest.mark.parametrize("signal", [DownloadCancelled, DownloadCancelledError, KeyboardInterrupt, SystemExit])
@pytest.mark.parametrize("wrapped", [False, True])
def test_control_signals_survive_real_cookie_extractor_wrappers(store, monkeypatch, entry, signal, wrapped):
    write_rows(store, [cookie_row()])
    interruption = signal("Synthetic interruption")

    def interrupted_snapshot(*args, **kwargs):
        if wrapped:
            error = DownloadError("Synthetic cookie reader failure")
            error.exc_info = (signal, interruption, None)
            error.__context__ = error
            raise error
        raise interruption

    monkeypatch.setattr(cookies, "_open_database_copy", interrupted_snapshot)
    expected = DownloadCancelledError if signal is DownloadCancelled else signal
    with pytest.raises(expected):
        enter(entry)


@pytest.mark.parametrize("allow_fallback", [False, True])
def test_browser_fallback_keeps_existing_partial_session_rejection(store, allow_fallback):
    write_rows(store, [cookie_row(malformed=b"v10broken")])
    with pytest.raises(TemporaryAccessError) as failure:
        enter("browser", allow_fallback=allow_fallback)
    assert failure.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE


def test_native_scope_is_optional_for_standalone_engine(monkeypatch):
    monkeypatch.setitem(sys.modules, "chrome_cookie_runtime", None)
    with signing.chrome_cookie_read_scope(lambda: False, domain="douyin.com"):
        pass


def test_existing_job_keeps_its_profile_when_current_settings_change(store):
    write_rows(store, [cookie_row(), cookie_row(".unrelated.invalid", malformed=b"v10broken")])
    manager = object.__new__(DownloadManager)
    manager.downloader_config = downloader.DownloaderConfig(cookie_browser=None, cookie_profile="Profile 7")
    job = DownloadJob(
        id="synthetic-job", source_url=VIDEO_URL, platform=Platform.DOUYIN,
        source_kind=SourceKind.ITEM, output_root="/synthetic-output",
        cookie_browser="chrome", cookie_profile="Profile 2",
    )
    config = manager._engine_for_job(job).config
    result, fallback, calls = generic_extract(config=config)
    assert config.cookie_profile == job.cookie_profile == "Profile 2"
    assert config.cookie_browser == job.cookie_browser == "chrome"
    assert result["height"] == 1080 and not fallback
    assert calls == [True]
