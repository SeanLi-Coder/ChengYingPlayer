"""Exercise fixed cookie diagnostics without user profiles or external access."""

from __future__ import annotations

import errno
import socket
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest
from yt_dlp.utils import DownloadError

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT / "vendor" / "rednote"))

from app import browser
from app import douyin_signing as signing
from app.errors import DownloadCancelledError, SiteIssueCode, TemporaryAccessError

PRIVATE_MARKER = "DO_NOT_DISCLOSE_COOKIE_DETAIL"
PRIVATE_PATH = f"/private/{PRIVATE_MARKER}/Cookies"


def reject_external_access(*args, **kwargs):
    raise AssertionError("Unexpected network, process, or real browser access")


@pytest.fixture(autouse=True)
def isolated_environment(monkeypatch, tmp_path):
    root = tmp_path / "chrome"
    database = root / "Default" / "Cookies"
    database.parent.mkdir(parents=True)
    database.touch()
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: root)
    monkeypatch.setattr(socket.socket, "connect", reject_external_access)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_external_access)
    monkeypatch.setattr(subprocess, "Popen", reject_external_access)
    monkeypatch.setattr(signing, "extract_cookies_from_browser", reject_external_access)


def public_failure(monkeypatch, cause):
    def failed_extractor(*args, **kwargs):
        raise cause

    monkeypatch.setattr(signing, "extract_cookies_from_browser", failed_extractor)
    with pytest.raises(signing._CookieAccessSigningFailure) as internal:
        signing._load_chrome_cookie_jar("Default")
    with pytest.raises(TemporaryAccessError) as public:
        signing._raise_signing_error("https://www.douyin.com/user/fixture", internal.value)
    assert public.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert PRIVATE_MARKER not in str(public.value)
    assert PRIVATE_PATH not in str(public.value)
    assert "Default" not in str(public.value)
    return public.value


@pytest.mark.parametrize("number", [errno.EACCES, errno.EPERM])
def test_permission_uses_errno_without_requiring_english_message(number, monkeypatch):
    error = OSError(number, PRIVATE_MARKER, PRIVATE_PATH)
    assert public_failure(monkeypatch, error).diagnostic_code == "cookie_permission_denied"


def test_permission_type_is_evidence_even_without_errno_or_english_message(monkeypatch):
    assert public_failure(monkeypatch, PermissionError(PRIVATE_PATH)).diagnostic_code == (
        "cookie_permission_denied"
    )


@pytest.mark.parametrize(
    "number", [errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS,
               errno.EMFILE, errno.ENFILE, errno.ENOMEM],
)
def test_storage_errors_have_fixed_non_authentication_category(number, monkeypatch):
    error = OSError(number, PRIVATE_MARKER, PRIVATE_PATH)
    assert public_failure(monkeypatch, error).diagnostic_code == "cookie_storage_failed"


@pytest.mark.parametrize("kind", [ImportError, ModuleNotFoundError, AttributeError, TypeError])
def test_reader_errors_keep_type_without_exposing_details(kind, monkeypatch):
    assert public_failure(monkeypatch, kind(PRIVATE_PATH)).diagnostic_code == "cookie_reader_failed"


@pytest.mark.parametrize("kind", [RuntimeError, ValueError, OSError])
def test_unrecognized_errors_do_not_guess_permission_or_login(kind, monkeypatch):
    assert public_failure(monkeypatch, kind(PRIVATE_PATH)).diagnostic_code == "cookie_access_unknown"


@pytest.mark.parametrize("mode", ["missing_schema", "not_a_database", "locked"])
def test_actual_sqlite_exception_chains_are_classified(mode, tmp_path, monkeypatch):
    database = tmp_path / "synthetic.sqlite"
    if mode == "not_a_database":
        database.write_bytes(b"synthetic non-database bytes")
    with sqlite3.connect(database, timeout=0) as connection:
        if mode == "locked":
            connection.execute("CREATE TABLE meta (value TEXT)")
            connection.commit()
            connection.execute("BEGIN EXCLUSIVE")
        with sqlite3.connect(database, timeout=0) as reader:
            try:
                reader.execute("SELECT value FROM meta")
            except sqlite3.DatabaseError as original:
                try:
                    raise RuntimeError(PRIVATE_MARKER) from original
                except RuntimeError as wrapped:
                    error = wrapped
            else:
                pytest.fail("Synthetic SQLite operation unexpectedly succeeded")
        connection.rollback()
    expected = "cookie_database_locked" if mode == "locked" else "cookie_database_invalid"
    assert isinstance(error.__cause__, sqlite3.DatabaseError)
    assert isinstance(error.__cause__.sqlite_errorcode, int)
    assert public_failure(monkeypatch, error).diagnostic_code == expected


@pytest.mark.parametrize(("number", "expected"), [
    (sqlite3.SQLITE_BUSY, "cookie_database_locked"),
    (sqlite3.SQLITE_LOCKED, "cookie_database_locked"),
    (sqlite3.SQLITE_CORRUPT, "cookie_database_invalid"),
    (sqlite3.SQLITE_SCHEMA, "cookie_database_invalid"),
    (sqlite3.SQLITE_FULL, "cookie_storage_failed"),
    (sqlite3.SQLITE_IOERR | (3 << 8), "cookie_storage_failed"),
    (sqlite3.SQLITE_CANTOPEN, "cookie_storage_failed"),
    (sqlite3.SQLITE_PERM, "cookie_permission_denied"),
])
def test_sqlite_numeric_codes_win_over_untrusted_message_words(number, expected):
    error = sqlite3.DatabaseError(f"{PRIVATE_MARKER}: permission denied decrypt locked")
    error.sqlite_errorcode = number
    assert browser.chrome_cookie_diagnostic("Default", error) == expected


def test_yt_dlp_retained_exception_tuple_is_followed(monkeypatch):
    try:
        raise OSError(errno.ENOSPC, PRIVATE_MARKER, PRIVATE_PATH)
    except OSError:
        retained = sys.exc_info()
    error = DownloadError("Failed to load cookies", exc_info=retained)
    assert error.__context__ is None
    assert public_failure(monkeypatch, error).diagnostic_code == "cookie_storage_failed"


def test_both_explicit_cause_and_implicit_context_are_followed():
    try:
        raise PermissionError(errno.EACCES, PRIVATE_MARKER)
    except PermissionError:
        try:
            raise RuntimeError(PRIVATE_MARKER) from ValueError("Synthetic wrapper")
        except RuntimeError as wrapped:
            error = wrapped
    assert browser.chrome_cookie_diagnostic("Default", error) == "cookie_permission_denied"


def test_cycle_is_bounded_and_does_not_hide_known_cause():
    first = RuntimeError(PRIVATE_MARKER)
    second = OSError(errno.ENOSPC, PRIVATE_MARKER)
    first.__cause__ = second
    second.__cause__ = first
    assert browser.chrome_cookie_diagnostic("Default", first) == "cookie_storage_failed"
    first.__cause__ = first
    assert browser.chrome_cookie_diagnostic("Default", first) == "cookie_access_unknown"


def test_chain_depth_is_bounded_without_formatting_every_error():
    formatted = []

    class CountedError(RuntimeError):
        def __str__(self):
            formatted.append(True)
            return PRIVATE_MARKER

    error = OSError(errno.ENOSPC, PRIVATE_MARKER)
    for _ in range(40):
        wrapper = CountedError()
        wrapper.__cause__ = error
        error = wrapper
    assert browser.chrome_cookie_diagnostic("Default", error) == "cookie_access_unknown"
    assert len(formatted) == 16


@pytest.mark.parametrize("diagnostic", [PRIVATE_PATH, f"cookie_reader_failed {PRIVATE_MARKER}",
                                        "cookie_access_unknown", None])
def test_untrusted_or_unknown_structured_diagnostic_does_not_hide_cause(diagnostic):
    error = RuntimeError(PRIVATE_MARKER)
    error.diagnostic_code = diagnostic
    error.__cause__ = OSError(errno.ENOSPC, PRIVATE_MARKER)
    assert browser.chrome_cookie_diagnostic("Default", error) == "cookie_storage_failed"


def test_arbitrary_diagnostic_objects_are_not_stringified():
    class UntrustedValue:
        def __str__(self):
            raise AssertionError("Untrusted diagnostic was formatted")

        def __bool__(self):
            raise AssertionError("Untrusted diagnostic was evaluated")

    value = UntrustedValue()
    assert browser.public_cookie_diagnostic_code(value) == "cookie_access_unknown"
    error = RuntimeError(PRIVATE_MARKER)
    error.diagnostic_code = value
    assert browser.chrome_cookie_diagnostic("Default", error) == "cookie_access_unknown"


def test_structured_class_attribute_is_preserved():
    class DatabaseError(RuntimeError):
        diagnostic_code = "cookie_database_invalid"

    assert browser.chrome_cookie_diagnostic("Default", DatabaseError(PRIVATE_MARKER)) == (
        "cookie_database_invalid"
    )


def test_broken_diagnostic_property_does_not_escape():
    class UntrustedError(RuntimeError):
        @property
        def diagnostic_code(self):
            raise ValueError(PRIVATE_PATH)

    assert browser.chrome_cookie_diagnostic("Default", UntrustedError(PRIVATE_MARKER)) == (
        "cookie_access_unknown"
    )


def test_diagnostic_string_subclass_cannot_execute_custom_normalization():
    class UntrustedString(str):
        def strip(self):
            raise AssertionError("Untrusted normalization was called")

    assert browser.public_cookie_diagnostic_code(UntrustedString(PRIVATE_PATH)) == (
        "cookie_access_unknown"
    )


def test_exception_formatting_failure_is_not_a_new_diagnostic_failure():
    class UnformattableError(RuntimeError):
        def __str__(self):
            raise ValueError(PRIVATE_PATH)

    assert browser.chrome_cookie_diagnostic("Default", UnformattableError()) == "cookie_access_unknown"


@pytest.mark.parametrize("signal", [DownloadCancelledError, KeyboardInterrupt, SystemExit])
@pytest.mark.parametrize("entry", ["extractor", "exception_chain", "exception_formatter"])
def test_control_signals_escape_even_after_a_decryption_warning(signal, entry, monkeypatch):
    interrupted = signal("Synthetic interruption")
    if entry == "extractor":
        def extractor(*args, logger, **kwargs):
            logger.warning(f"failed to decrypt: {PRIVATE_MARKER}", only_once=True)
            raise interrupted

        monkeypatch.setattr(signing, "extract_cookies_from_browser", extractor)
        with pytest.raises(signal) as caught:
            signing._load_chrome_cookie_jar("Default")
    elif entry == "exception_chain":
        error = RuntimeError(PRIVATE_MARKER)
        error.__cause__ = interrupted
        with pytest.raises(signal) as caught:
            browser.chrome_cookie_diagnostic("Default", error)
    else:
        class InterruptedFormatter(RuntimeError):
            def __str__(self):
                raise interrupted

        with pytest.raises(signal) as caught:
            browser.chrome_cookie_diagnostic("Default", InterruptedFormatter())
    assert caught.value is interrupted


def test_extractor_exception_preserves_already_diagnosed_warning(monkeypatch, capsys):
    original = TypeError(PRIVATE_PATH)

    def extractor(*args, logger, **kwargs):
        logger.warning(f"failed to decrypt {PRIVATE_MARKER}", only_once=True)
        logger.warning(PRIVATE_MARKER, once=True)
        raise original

    monkeypatch.setattr(signing, "extract_cookies_from_browser", extractor)
    with pytest.raises(signing._CookieAccessSigningFailure) as caught:
        signing._load_chrome_cookie_jar("Default")
    assert caught.value.cookie_diagnostic_code == "cookie_decryption_failed"
    assert caught.value.__cause__.__cause__ is original
    assert PRIVATE_MARKER not in str(caught.value)
    assert PRIVATE_MARKER not in str(caught.value.__cause__)
    assert capsys.readouterr() == ("", "")


def test_unknown_warning_does_not_mask_reader_exception(monkeypatch):
    def extractor(*args, logger, **kwargs):
        logger.warning(PRIVATE_MARKER)
        raise ImportError(PRIVATE_PATH)

    monkeypatch.setattr(signing, "extract_cookies_from_browser", extractor)
    with pytest.raises(signing._CookieAccessSigningFailure) as caught:
        signing._load_chrome_cookie_jar("Default")
    assert caught.value.cookie_diagnostic_code == "cookie_reader_failed"


def test_logger_accepts_yt_dlp_keywords_without_storing_messages(capsys):
    logger = browser.ChromeCookieLogger()
    logger.debug(PRIVATE_MARKER, marker=PRIVATE_PATH)
    logger.info(f"could not be decrypted {PRIVATE_MARKER}", marker=PRIVATE_PATH)
    logger.warning(PRIVATE_MARKER, True, once=True, marker=PRIVATE_PATH)
    logger.error(PRIVATE_MARKER, marker=PRIVATE_PATH)
    assert vars(logger) == {"diagnostic_code": "cookie_decryption_failed"}
    assert capsys.readouterr() == ("", "")
