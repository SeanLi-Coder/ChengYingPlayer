"""Exercise native cookie adapters with real SQLite and exclusively synthetic data."""

from __future__ import annotations

import errno
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import chrome_cookie_runtime as runtime
from cookie_smoke import _encrypted_cookie


@pytest.fixture
def cookie_database(tmp_path, monkeypatch):
    from app import browser
    from yt_dlp import cookies

    def reject_process(*args, **kwargs):
        raise AssertionError("External processes are forbidden in cookie tests")

    monkeypatch.setattr(subprocess, "Popen", reject_process)
    password = b"synthetic-runtime-password"

    class Keychain:
        @staticmethod
        def run(arguments, **kwargs):
            assert arguments == [
                "security", "find-generic-password", "-w", "-a", "Chrome",
                "-s", "Chrome Safe Storage",
            ]
            return password + b"\n", b"", 0

    root = tmp_path / "synthetic-browser"
    profile = root / "Default"
    profile.mkdir(parents=True)
    database = profile / "Cookies"
    monkeypatch.setattr(cookies, "Popen", Keychain)
    monkeypatch.setattr(cookies, "_get_chromium_based_browser_settings", lambda name: {
        "browser_dir": str(root), "keyring_name": "Chrome", "supports_profiles": True,
    })
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: root)
    # Restore exact original function references when the test ends, including
    # when another native-only test already installed these adapters.
    monkeypatch.setattr(cookies, "_open_database_copy", cookies._open_database_copy)
    monkeypatch.setattr(cookies, "_process_chrome_cookie", cookies._process_chrome_cookie)
    monkeypatch.setattr(cookies, "_extract_chrome_cookies", cookies._extract_chrome_cookies)
    runtime.install_chrome_cookie_runtime()
    with closing(sqlite3.connect(database)) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.executescript(
            "CREATE TABLE meta (key TEXT, value TEXT);"
            "INSERT INTO meta VALUES ('version', '24');"
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
            "encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER);"
        )
        writer.execute(
            "INSERT INTO cookies VALUES ('.douyin.com', 'sessionid', '', ?, '/', 0, 1)",
            (_encrypted_cookie(".douyin.com", b"synthetic-session", password),),
        )
        writer.commit()
        yield writer, database, password


def _load_session():
    from app import douyin_signing

    return douyin_signing._load_chrome_cookie_jar("Default")


def test_snapshot_reads_committed_wal_schema_insert_and_delete(cookie_database, tmp_path):
    writer, database, _ = cookie_database
    before = {path.name: path.read_bytes() for path in database.parent.iterdir()}
    assert [cookie.name for cookie in _load_session()] == ["sessionid"]
    assert database.read_bytes() == before["Cookies"]
    assert Path(str(database) + "-wal").read_bytes() == before["Cookies-wal"]
    assert {path.name for path in database.parent.iterdir()} == set(before)
    with writer:
        writer.execute("UPDATE meta SET value = '25'")
        writer.execute("DELETE FROM cookies")
    with closing(runtime._open_database_snapshot(database, tmp_path).connection) as snapshot:
        assert snapshot.execute("SELECT value FROM meta").fetchone() == ("25",)
        assert snapshot.execute("SELECT count(*) FROM cookies").fetchone() == (0,)
    assert list(_load_session()) == []


@pytest.mark.parametrize("malformed", [b"v10", b"v10truncated", b"v10" + bytes(17)])
def test_unrelated_malformed_ciphertext_preserves_valid_session(cookie_database, malformed, capsys):
    writer, _, _ = cookie_database
    with writer:
        writer.execute(
            "INSERT INTO cookies VALUES ('.unrelated.example', 'unrelated', '', ?, '/', 0, 1)",
            (malformed,),
        )
    assert [cookie.name for cookie in _load_session()] == ["sessionid"]
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("field", ["host_key", "name", "value", "path"])
def test_unrelated_non_utf8_field_preserves_valid_session(cookie_database, field):
    writer, _, _ = cookie_database
    with writer:
        writer.execute(
            "INSERT INTO cookies VALUES ('.unrelated.example', 'unrelated', 'value', X'', '/', 0, 1)"
        )
        writer.execute(f"UPDATE cookies SET {field} = CAST(X'FF' AS TEXT) WHERE name = 'unrelated'")
    assert [cookie.name for cookie in _load_session()] == ["sessionid"]


@pytest.mark.parametrize("corruption", ["ciphertext", "plaintext"])
def test_malformed_target_session_is_not_anonymous(cookie_database, corruption):
    from app import douyin_signing

    writer, _, _ = cookie_database
    with writer:
        if corruption == "ciphertext":
            writer.execute("UPDATE cookies SET encrypted_value = ?", (b"v10truncated",))
        else:
            writer.execute("UPDATE cookies SET value = CAST(X'FF' AS TEXT)")
    with pytest.raises(douyin_signing._CookieAccessSigningFailure) as failure:
        _load_session()
    assert failure.value.cookie_diagnostic_code == "cookie_decryption_failed"


def test_native_backend_failure_and_control_signals_propagate(cookie_database):
    from app.errors import DownloadCancelledError
    from yt_dlp import cookies

    class Decryptor:
        pass

    for error in (
        OSError("synthetic backend failure"), ValueError("synthetic programming failure"),
        DownloadCancelledError("Task cancelled"), KeyboardInterrupt(), SystemExit(),
    ):
        def fail(*args, error=error):
            raise error

        process = runtime._cookie_processor(fail, cookies)
        with pytest.raises(type(error)) as actual:
            process(Decryptor(), b"host", b"name", b"value", b"", b"/", 0, 1)
        assert actual.value is error


def test_malformed_warning_is_fixed_and_private(cookie_database):
    from app import browser
    from yt_dlp import cookies

    messages = []

    class Logger(browser.ChromeCookieLogger):
        def warning(self, message, **kwargs):
            messages.append(message)
            super().warning(message, **kwargs)

    decryptor = cookies.MacChromeCookieDecryptor("Chrome", Logger(), meta_version=24)
    assert cookies._process_chrome_cookie(
        decryptor, b"private-host", b"private-name", b"", b"v10private", b"/private", 0, 1,
    ) == (True, None)
    assert messages == ["Failed to decrypt malformed Chrome cookie data"]


@pytest.fixture
def locked_database(tmp_path):
    database = tmp_path / "locked.sqlite"
    with closing(sqlite3.connect(database)) as writer:
        writer.execute("CREATE TABLE fixture (value TEXT)")
        writer.commit()
        writer.execute("BEGIN EXCLUSIVE")
        writer.execute("INSERT INTO fixture VALUES ('pending')")
        yield database
        writer.rollback()


def test_locked_snapshot_has_bounded_timeout_and_cleans_partial_file(locked_database, tmp_path, monkeypatch):
    output = tmp_path / "snapshot-output"
    output.mkdir()
    monkeypatch.setattr(runtime, "SNAPSHOT_TIMEOUT_SECONDS", 0.1)
    started = time.monotonic()
    with pytest.raises(runtime.CookieSnapshotError) as failure:
        runtime._open_database_snapshot(locked_database, output)
    assert failure.value.diagnostic_code == "cookie_database_locked"
    assert time.monotonic() - started < 1.0
    assert list(output.iterdir()) == []
    assert str(failure.value) == "Chrome cookie database snapshot failed"


def test_locked_snapshot_honors_task_cancellation_and_cleans(locked_database, tmp_path):
    from app.errors import DownloadCancelledError

    output = tmp_path / "snapshot-output"
    output.mkdir()
    cancelled = threading.Event()
    timer = threading.Timer(0.05, cancelled.set)
    timer.start()
    try:
        with runtime.cookie_read_scope(cancelled.is_set), pytest.raises(DownloadCancelledError):
            runtime._open_database_snapshot(locked_database, output)
    finally:
        timer.cancel()
        timer.join()
    assert list(output.iterdir()) == []


@pytest.mark.parametrize("mode", ["missing", "invalid"])
def test_snapshot_failure_cleans_files_and_does_not_create_source(tmp_path, mode):
    database = tmp_path / "private-source.sqlite"
    if mode == "invalid":
        database.write_bytes(b"synthetic-invalid-sqlite")
    output = tmp_path / "snapshot-output"
    output.mkdir()
    with pytest.raises(runtime.CookieSnapshotError) as failure:
        runtime._open_database_snapshot(database, output)
    assert failure.value.diagnostic_code == (
        "cookie_storage_failed" if mode == "missing" else "cookie_database_invalid"
    )
    assert list(output.iterdir()) == []
    if mode == "missing":
        assert not database.exists()
    else:
        assert database.read_bytes() == b"synthetic-invalid-sqlite"


def test_concurrent_snapshots_and_cancellation_scopes_are_independent(cookie_database, tmp_path):
    from app.errors import DownloadCancelledError

    _, database, _ = cookie_database
    output = tmp_path / "snapshot-output"
    output.mkdir()
    gate = threading.Barrier(8)

    def read(index):
        gate.wait()
        with runtime.cookie_read_scope(lambda: index == 0):
            try:
                with closing(runtime._open_database_snapshot(database, output).connection) as copied:
                    return copied.execute("SELECT count(*) FROM cookies").fetchone()[0]
            except DownloadCancelledError:
                return "cancelled"

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(read, range(8)))
    assert results == ["cancelled", *([1] * 7)]
    snapshots = list(output.iterdir())
    assert len(snapshots) == 7
    assert all(os.stat(path).st_mode & 0o777 == 0o600 for path in snapshots)


def test_runtime_installation_is_idempotent_under_concurrency(cookie_database):
    from yt_dlp import cookies

    before = cookies._open_database_copy, cookies._process_chrome_cookie, cookies._extract_chrome_cookies
    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(lambda _: runtime.install_chrome_cookie_runtime(), range(20)))
    assert (cookies._open_database_copy, cookies._process_chrome_cookie, cookies._extract_chrome_cookies) == before


def test_process_shutdown_cancellation_prevents_snapshot_creation(tmp_path):
    from app.errors import DownloadCancelledError

    with pytest.raises(DownloadCancelledError):
        runtime._open_database_snapshot(tmp_path / "missing", tmp_path, process_cancel=lambda: True)
    assert list(tmp_path.iterdir()) == []


def test_nested_scope_inherits_task_cancellation_and_resets_guard(tmp_path):
    from app.errors import DownloadCancelledError

    with runtime.cookie_read_scope(
        lambda: True, domain="douyin.com", required_cookie_names=("sessionid",)
    ):
        with runtime.cookie_read_scope():
            assert runtime._session_guard.get() is None
            with pytest.raises(DownloadCancelledError):
                runtime._open_database_snapshot(tmp_path / "missing", tmp_path)
        assert runtime._session_guard.get() == ("douyin.com", ("sessionid",))
    assert runtime._cancel_check.get() is None
    assert runtime._session_guard.get() is None


def test_snapshot_reads_wal_without_existing_shm_and_preserves_committed_bytes(cookie_database, tmp_path):
    _, original, _ = cookie_database
    private = tmp_path / "synthetic-clone"
    private.mkdir()
    database = private / "Cookies"
    shutil.copyfile(original, database)
    wal = Path(str(database) + "-wal")
    shutil.copyfile(str(original) + "-wal", wal)
    expected = database.read_bytes(), wal.read_bytes()
    assert not Path(str(database) + "-shm").exists()
    with closing(runtime._open_database_snapshot(database, tmp_path).connection) as snapshot:
        assert snapshot.execute("SELECT count(*) FROM cookies").fetchone() == (1,)
    # SQLite can create coordination sidecars for a read-only WAL connection;
    # the committed database and WAL bytes must not be checkpointed or changed.
    assert (database.read_bytes(), wal.read_bytes()) == expected


def test_snapshot_reads_clean_closed_wal_database_without_changing_main_file(tmp_path):
    database = tmp_path / "closed.sqlite"
    with closing(sqlite3.connect(database)) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("CREATE TABLE fixture (value TEXT)")
        writer.execute("INSERT INTO fixture VALUES ('committed')")
        writer.commit()
    expected = database.read_bytes()
    assert not Path(str(database) + "-wal").exists()
    with closing(runtime._open_database_snapshot(database, tmp_path).connection) as snapshot:
        assert snapshot.execute("SELECT value FROM fixture").fetchone() == ("committed",)
    assert database.read_bytes() == expected


def test_snapshot_connect_failure_cleans_exclusive_temporary_file(tmp_path, monkeypatch):
    def fail(*args, **kwargs):
        raise sqlite3.OperationalError("synthetic destination connection failure")

    monkeypatch.setattr(runtime.sqlite3, "connect", fail)
    with pytest.raises(runtime.CookieSnapshotError):
        runtime._open_database_snapshot(tmp_path / "missing", tmp_path)
    assert list(tmp_path.iterdir()) == []


def test_nonlocked_backup_timeout_is_a_storage_failure(cookie_database, tmp_path, monkeypatch):
    _, database, _ = cookie_database
    ticks = iter((0.0, 0.0, 10.0))
    monkeypatch.setattr(runtime, "time", SimpleNamespace(monotonic=lambda: next(ticks)))
    output = tmp_path / "snapshot-output"
    output.mkdir()
    with pytest.raises(runtime.CookieSnapshotError) as failure:
        runtime._open_database_snapshot(database, output)
    assert failure.value.diagnostic_code == "cookie_storage_failed"
    assert list(output.iterdir()) == []


def test_full_temporary_volume_has_fixed_storage_diagnostic(tmp_path, monkeypatch):
    def full(*args, **kwargs):
        raise OSError(errno.ENOSPC, "synthetic private storage details")

    monkeypatch.setattr(runtime.tempfile, "mkstemp", full)
    with pytest.raises(runtime.CookieSnapshotError) as failure:
        runtime._open_database_snapshot(tmp_path / "unused", tmp_path)
    assert failure.value.diagnostic_code == "cookie_storage_failed"
    assert str(failure.value) == "Chrome cookie database snapshot failed"
    assert list(tmp_path.iterdir()) == []
