"""Native-only, bounded Chrome-cookie extraction fixes for the pinned yt-dlp."""

from __future__ import annotations

import contextvars
import functools
import os
import sqlite3
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path

from diagnostic_log import record_cookie_event

SNAPSHOT_TIMEOUT_SECONDS = 5.0
SNAPSHOT_SLEEP_SECONDS = 0.025
_cancel_check = contextvars.ContextVar("chrome_cookie_cancel_check", default=None)
_session_guard = contextvars.ContextVar("chrome_cookie_session_guard", default=None)
_install_lock = threading.Lock()
_MALFORMED_COOKIE_WARNING = "Failed to decrypt malformed Chrome cookie data"


class CookieSnapshotError(RuntimeError):
    def __init__(self, diagnostic_code="cookie_storage_failed"):
        self.diagnostic_code = diagnostic_code
        super().__init__("Chrome cookie database snapshot failed")


@contextmanager
def cookie_read_scope(should_cancel=None, *, domain=None, required_cookie_names=()):
    """Carry one task's cancellation callback without changing process globals."""
    token = _cancel_check.set(should_cancel if should_cancel is not None else _cancel_check.get())
    guard_token = _session_guard.set((domain, tuple(required_cookie_names)) if domain else None)
    try:
        yield
    finally:
        _session_guard.reset(guard_token)
        _cancel_check.reset(token)


def _check_cancelled(process_cancel=None):
    task_cancel = _cancel_check.get()
    if (task_cancel and task_cancel()) or (process_cancel and process_cancel()):
        from app.errors import DownloadCancelledError

        raise DownloadCancelledError("Task cancelled")


def _open_database_snapshot(database_path, tmpdir, *, process_cancel=None):
    """Back up committed SQLite state, including WAL, into a private temporary file."""
    deadline = time.monotonic() + SNAPSHOT_TIMEOUT_SECONDS
    destination = None
    source = None
    snapshot = None
    succeeded = False
    last_status = sqlite3.SQLITE_OK
    record_cookie_event("snapshot_start")

    def progress(status, remaining, total):
        nonlocal last_status
        last_status = status
        _check_cancelled(process_cancel)
        if time.monotonic() >= deadline:
            code = (
                "cookie_database_locked"
                if status in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED}
                else "cookie_storage_failed"
            )
            error = CookieSnapshotError(code)
            record_cookie_event("snapshot_timeout", error=error, diagnostic_code=code)
            raise error

    try:
        progress(sqlite3.SQLITE_OK, 0, 0)
        # mkstemp provides exclusive creation and owner-only permissions. Each
        # concurrent extraction owns a different snapshot, even in one tmpdir.
        descriptor, snapshot = tempfile.mkstemp(prefix="cookie-snapshot-", suffix=".sqlite", dir=tmpdir)
        os.close(descriptor)
        destination = sqlite3.connect(snapshot, timeout=0)
        # Do not use immutable=1: it deliberately ignores committed WAL pages.
        uri = Path(database_path).absolute().as_uri() + "?mode=ro"
        source = sqlite3.connect(uri, uri=True, timeout=0)
        source.execute("PRAGMA query_only=ON")
        source.backup(destination, pages=128, progress=progress, sleep=SNAPSHOT_SLEEP_SECONDS)
        progress(last_status, 0, 0)
        source.close()
        source = None
        result = destination.cursor()
        destination = None
        succeeded = True
        record_cookie_event("snapshot_complete")
        return result
    except (sqlite3.Error, OSError) as error:
        from app.browser import _cookie_system_diagnostic

        diagnostic = _cookie_system_diagnostic(error) or "cookie_storage_failed"
        record_cookie_event("snapshot_failed", error=error, diagnostic_code=diagnostic)
        raise CookieSnapshotError(diagnostic) from None
    finally:
        if source is not None:
            source.close()
        if destination is not None:
            destination.close()
        # Successful cursors remain owned by yt-dlp; its temporary-directory
        # context removes the snapshot after closing that cursor's connection.
        if snapshot is not None and not succeeded:
            for suffix in ("", "-journal", "-wal", "-shm"):
                Path(snapshot + suffix).unlink(missing_ok=True)


def _cookie_processor(original, cookies):
    @functools.wraps(original)
    def process(decryptor, host_key, name, value, encrypted_value, path, expires_utc, is_secure):
        malformed_cbc = (
            isinstance(decryptor, cookies.MacChromeCookieDecryptor)
            and not value
            and isinstance(encrypted_value, bytes)
            and encrypted_value.startswith(b"v10")
            and (len(encrypted_value) <= 3 or (len(encrypted_value) - 3) % 16 != 0)
        )
        if not malformed_cbc:
            try:
                return original(
                    decryptor, host_key, name, value, encrypted_value, path, expires_utc, is_secure
                )
            except UnicodeDecodeError as error:
                # Chrome metadata and plaintext fields can contain invalid UTF-8.
                # Only this malformed-data error is recoverable here; backend,
                # cancellation, programming and native-library errors propagate.
                record_cookie_event("row_rejected", error=error, diagnostic_code="cookie_decryption_failed")
        else:
            record_cookie_event("row_rejected", diagnostic_code="cookie_decryption_failed")
        decryptor._logger.warning(_MALFORMED_COOKIE_WARNING, only_once=True)
        return bool(not value and encrypted_value), None

    process._chengying_cookie_runtime = True
    return process


def _chrome_extractor(original):
    @functools.wraps(original)
    def extract(browser_name, profile, keyring, logger):
        if browser_name != "chrome":
            return original(browser_name, profile, keyring, logger)
        record_cookie_event("extract_start")
        try:
            result = extract_guarded(browser_name, profile, keyring, logger)
        except BaseException as error:
            record_cookie_event("extract_failed", error=error)
            raise
        record_cookie_event("extract_complete")
        return result

    def extract_guarded(browser_name, profile, keyring, logger):
        guard = _session_guard.get()
        if browser_name != "chrome" or guard is None:
            return original(browser_name, profile, keyring, logger)
        from app.browser import extract_chrome_cookie_jar

        domain, required_cookie_names = guard

        def read_once(name, *, profile, logger):
            return original(name, profile, keyring, logger)

        # Validate the very same jar that YoutubeDL will consume. The native
        # caller opts in with its requested site; other browsers/sites keep the
        # existing behavior and no second extraction or profile choice occurs.
        return extract_chrome_cookie_jar(
            read_once, profile, domain=domain, required_cookie_names=required_cookie_names
        )

    extract._chengying_cookie_runtime = True
    return extract


def install_chrome_cookie_runtime(*, should_cancel=None):
    """Install immutable adapters once before the native service accepts work."""
    from yt_dlp import cookies

    with _install_lock:
        if getattr(cookies._open_database_copy, "_chengying_cookie_runtime", False):
            return

        def open_database(database_path, tmpdir):
            return _open_database_snapshot(database_path, tmpdir, process_cancel=should_cancel)

        open_database._chengying_cookie_runtime = True
        process = _cookie_processor(cookies._process_chrome_cookie, cookies)
        extract = _chrome_extractor(cookies._extract_chrome_cookies)
        cookies._open_database_copy = open_database
        cookies._process_chrome_cookie = process
        cookies._extract_chrome_cookies = extract
