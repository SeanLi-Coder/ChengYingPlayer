"""Check generic yt-dlp cookie failures without real profiles or network access."""

from __future__ import annotations

import socket
import sys
from pathlib import Path

import pytest
from yt_dlp.utils import DownloadCancelled, DownloadError

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT / "vendor" / "rednote"))

from app import browser, downloader
from app.errors import DownloadCancelledError, SiteIssueCode, TemporaryAccessError
from app.models import DownloadItem, DownloadJob, Platform, SourceKind
from app.storage import JsonJobStore
from app.task_manager import DownloadManager

VIDEO_URL = "https://www.douyin.com/video/1234567890123456789"
PRIVATE_MARKER = "DO_NOT_DISCLOSE_COOKIE_FIXTURE"


def reject_external_access(*args, **kwargs):
    raise AssertionError("Unexpected network, browser, or extractor access")


@pytest.fixture(autouse=True)
def isolated_cookie_environment(monkeypatch, tmp_path):
    root = tmp_path / "chrome"
    database = root / "Default" / "Network" / "Cookies"
    database.parent.mkdir(parents=True)
    database.touch()
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: root)
    monkeypatch.setattr(socket.socket, "connect", reject_external_access)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_external_access)
    monkeypatch.setattr(downloader, "YoutubeDL", reject_external_access)
    monkeypatch.setattr(downloader, "fetch_signed_aweme_detail", reject_external_access)
    return root


def run_failure(error, *, config=None):
    engine = downloader.MediaDownloader(config or downloader.DownloaderConfig(cookie_profile="Default"))
    calls = []

    def operation(use_cookies):
        calls.append(use_cookies)
        raise error

    with pytest.raises(TemporaryAccessError) as failure:
        engine._run_with_cookie_fallback(operation, url=VIDEO_URL)
    assert calls == [True]
    assert failure.value.__cause__ is error
    assert str(failure.value).startswith(downloader.COOKIE_ACCESS_MESSAGE)
    assert failure.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert PRIVATE_MARKER not in str(failure.value)
    assert "Default" not in str(failure.value)
    return failure.value


@pytest.mark.parametrize(("message", "expected"), [
    ("Failed to decrypt cookie", "cookie_decryption_failed"),
    ("Could not copy Chrome cookie database: Permission denied", "cookie_permission_denied"),
    ("Cookie database is locked", "cookie_database_locked"),
    ("Failed to load cookies", "cookie_access_unknown"),
])
def test_generic_cookie_failure_has_fixed_diagnostic(message, expected):
    failure = run_failure(DownloadError(f"{message}: {PRIVATE_MARKER}"))
    assert failure.diagnostic_code == expected
    assert str(failure).endswith(f"Diagnostic code: {expected}.")


@pytest.mark.parametrize("cause_type", [PermissionError, RuntimeError])
def test_wrapped_cookie_failure_uses_safe_cause_without_leaking_it(cause_type):
    error = DownloadError("Failed to load cookies")
    error.__cause__ = cause_type(
        f"Permission denied: {PRIVATE_MARKER}" if cause_type is PermissionError else PRIVATE_MARKER
    )
    failure = run_failure(error)
    assert failure.diagnostic_code == (
        "cookie_permission_denied" if cause_type is PermissionError else "cookie_access_unknown"
    )


@pytest.mark.parametrize(("profile", "expected"), [
    ("Profile 7", "chrome_profile_missing"),
    ("../private", "chrome_profile_invalid"),
    (None, "cookie_access_unknown"),
])
def test_profile_probe_is_confined_to_synthetic_root(profile, expected):
    failure = run_failure(
        DownloadError("Failed to load cookies"),
        config=downloader.DownloaderConfig(cookie_profile=profile),
    )
    assert failure.diagnostic_code == expected


def test_probe_filesystem_failure_falls_back_to_unknown(monkeypatch):
    def unavailable_root():
        raise OSError(PRIVATE_MARKER)

    monkeypatch.setattr(browser, "chrome_user_data_directory", unavailable_root)
    failure = run_failure(DownloadError("Failed to load cookies"))
    assert failure.diagnostic_code == "cookie_access_unknown"


def test_untrusted_diagnostic_is_never_exposed(monkeypatch):
    monkeypatch.setattr(downloader, "chrome_cookie_diagnostic", lambda *args: PRIVATE_MARKER)
    failure = run_failure(DownloadError("Failed to load cookies"))
    assert failure.diagnostic_code == "cookie_access_unknown"


def test_other_browser_does_not_probe_chrome(monkeypatch):
    monkeypatch.setattr(downloader, "chrome_cookie_diagnostic", reject_external_access)
    failure = run_failure(
        DownloadError("Failed to load cookies"),
        config=downloader.DownloaderConfig(cookie_browser="firefox"),
    )
    assert failure.diagnostic_code == "cookie_access_unknown"


def test_douyin_yt_dlp_failure_is_classified_before_signing(monkeypatch):
    class CookieFailureYoutubeDL:
        def __init__(self, options):
            assert options["cookiesfrombrowser"] == ("chrome", "Default")

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def extract_info(self, *args, **kwargs):
            raise DownloadError(f"Cookie database is locked: {PRIVATE_MARKER}")

    monkeypatch.setattr(downloader, "YoutubeDL", CookieFailureYoutubeDL)
    engine = downloader.MediaDownloader(downloader.DownloaderConfig(cookie_profile="Default"))
    with pytest.raises(TemporaryAccessError) as failure:
        engine._discover_douyin_item(VIDEO_URL, lambda: False)
    assert failure.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert failure.value.diagnostic_code == "cookie_database_locked"
    assert PRIVATE_MARKER not in str(failure.value)


def test_generic_diagnostic_survives_job_item_persistence(tmp_path):
    failure = run_failure(DownloadError(f"Failed to decrypt cookie: {PRIVATE_MARKER}"))
    item = DownloadItem(id="fixture-item", source_url=VIDEO_URL)
    job = DownloadJob(
        id="fixture-job", source_url=VIDEO_URL, platform=Platform.DOUYIN,
        source_kind=SourceKind.ITEM, output_root=str(tmp_path / "output"), items=[item],
    )
    DownloadManager._record_issue_locked(job, str(failure), item=item, cause=failure)
    store = JsonJobStore(tmp_path / "state")
    store.save(job)
    restored = store.get(job.id)
    assert restored.issue_code == restored.items[0].issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert restored.diagnostic_code == restored.items[0].diagnostic_code == "cookie_decryption_failed"
    assert PRIVATE_MARKER not in restored.model_dump_json()


def test_explicit_anonymous_fallback_keeps_existing_behavior(monkeypatch):
    monkeypatch.setattr(downloader, "chrome_cookie_diagnostic", reject_external_access)
    engine = downloader.MediaDownloader(downloader.DownloaderConfig(allow_cookie_fallback=True))
    calls = []

    def operation(use_cookies):
        calls.append(use_cookies)
        if use_cookies:
            raise DownloadError("Failed to load cookies")
        return "synthetic anonymous result"

    assert engine._run_with_cookie_fallback(operation, url=VIDEO_URL) == (
        "synthetic anonymous result", True,
    )
    assert calls == [True, False]


@pytest.mark.parametrize("signal", [DownloadCancelled, DownloadCancelledError, KeyboardInterrupt, SystemExit])
@pytest.mark.parametrize("during_fallback", [False, True])
def test_control_signals_keep_existing_cancellation_semantics(monkeypatch, signal, during_fallback):
    monkeypatch.setattr(downloader, "chrome_cookie_diagnostic", reject_external_access)
    engine = downloader.MediaDownloader(downloader.DownloaderConfig(allow_cookie_fallback=during_fallback))
    calls = []

    def operation(use_cookies):
        calls.append(use_cookies)
        if during_fallback and use_cookies:
            raise DownloadError("Failed to load cookies")
        raise signal("Synthetic interruption")

    expected = DownloadCancelledError if signal is DownloadCancelled else signal
    with pytest.raises(expected):
        engine._run_with_cookie_fallback(operation, url=VIDEO_URL)
    assert calls == ([True, False] if during_fallback else [True])


@pytest.mark.parametrize("signal", [DownloadCancelledError, KeyboardInterrupt, SystemExit])
def test_diagnostic_probe_never_swallows_control_signals(monkeypatch, signal):
    def interrupted_probe(*args):
        raise signal("Synthetic interruption")

    monkeypatch.setattr(downloader, "chrome_cookie_diagnostic", interrupted_probe)
    engine = downloader.MediaDownloader()

    def operation(use_cookies):
        raise DownloadError("Failed to load cookies")

    with pytest.raises(signal):
        engine._run_with_cookie_fallback(operation, url=VIDEO_URL)
