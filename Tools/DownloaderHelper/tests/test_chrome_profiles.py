"""Exercise profile choices with synthetic metadata and no browser contents."""

from __future__ import annotations

import builtins
import errno
import json
import socket
import sqlite3
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chrome_profiles as profiles


@pytest.fixture(autouse=True)
def reject_external_access(monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Browser contents and external access are forbidden")

    monkeypatch.setattr(sqlite3, "connect", reject)
    monkeypatch.setattr(subprocess, "Popen", reject)
    monkeypatch.setattr(socket.socket, "connect", reject)
    monkeypatch.setattr(socket.socket, "connect_ex", reject)


def create_profile(root, name, *, database=None):
    profile = root / name
    profile.mkdir(parents=True)
    if database is not None:
        path = profile / database
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"not a real cookie database")
    return profile


def test_only_actual_standard_directories_are_listed_in_numeric_order(tmp_path):
    create_profile(tmp_path, "Profile 10", database="Network/Cookies")
    create_profile(tmp_path, "Profile 2", database="Cookies")
    create_profile(tmp_path, "Profile 1")
    for name in ("Guest Profile", "System Profile", "Profile 0", "Profile 01", "PRIVATE_ACCOUNT"):
        create_profile(tmp_path, name, database="Cookies")
    (tmp_path / "Default").write_bytes(b"not a directory")
    result = profiles.list_chrome_profiles(tmp_path)
    assert result == {"status": "ok", "profiles": [
        {"directory": "Profile 1", "has_cookie_database": False},
        {"directory": "Profile 2", "has_cookie_database": True},
        {"directory": "Profile 10", "has_cookie_database": True},
    ]}
    assert str(tmp_path) not in json.dumps(result)
    assert "PRIVATE_ACCOUNT" not in json.dumps(result)
    assert profiles.validate_chrome_profile("Default", tmp_path) == "chrome_profile_missing"


def test_default_is_first_only_when_it_actually_exists(tmp_path):
    create_profile(tmp_path, "Profile 1", database="Cookies")
    create_profile(tmp_path, "Default", database="Network/Cookies")
    assert [entry["directory"] for entry in profiles.list_chrome_profiles(tmp_path)["profiles"]] == [
        "Default", "Profile 1",
    ]
    assert profiles.validate_chrome_profile("Default", tmp_path) is None


@pytest.mark.parametrize("database", ["Cookies", "Network/Cookies"])
def test_valid_store_is_detected_without_opening_or_mutating_any_file(tmp_path, monkeypatch, database):
    profile = create_profile(tmp_path, "Profile 3", database=database)
    (tmp_path / "Local State").write_bytes(b"private account metadata must not be opened")
    before = {str(path.relative_to(tmp_path)): path.read_bytes() for path in tmp_path.rglob("*") if path.is_file()}

    def reject(*args, **kwargs):
        raise AssertionError("Profile discovery must not open file contents")

    with monkeypatch.context() as context:
        context.setattr(builtins, "open", reject)
        context.setattr(Path, "open", reject)
        assert profiles.list_chrome_profiles(tmp_path) == {"status": "ok", "profiles": [
            {"directory": "Profile 3", "has_cookie_database": True},
        ]}
        assert profiles.validate_chrome_profile("Profile 3", tmp_path) is None
    after = {str(path.relative_to(tmp_path)): path.read_bytes() for path in tmp_path.rglob("*") if path.is_file()}
    assert before == after
    assert (profile / database).is_file()


def test_missing_database_is_distinct_from_missing_profile(tmp_path):
    create_profile(tmp_path, "Profile 4")
    assert profiles.validate_chrome_profile("Profile 4", tmp_path) == "cookie_database_missing"
    assert profiles.validate_chrome_profile("Default", tmp_path) == "chrome_profile_missing"


def test_missing_root_and_empty_root_are_distinct(tmp_path):
    missing = tmp_path / "missing"
    assert profiles.list_chrome_profiles(missing) == {"status": "chrome_data_directory_missing", "profiles": []}
    assert profiles.validate_chrome_profile("Default", missing) == "chrome_data_directory_missing"
    assert profiles.list_chrome_profiles(tmp_path) == {"status": "ok", "profiles": []}


@pytest.mark.parametrize("value", ["", "../Default", "/private/Legacy", "Default\n", " Default", "Profile 0", "Profile 01", "Profile -1", "Profile " + "9" * 300, True, 7, [], {}])
def test_invalid_selection_never_probes_the_filesystem(value, monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Invalid choices must not inspect any root")

    monkeypatch.setattr(profiles, "_profile_root", reject)
    assert profiles.validate_chrome_profile(value) == "chrome_profile_invalid"


def test_automatic_selection_retains_existing_behavior_without_probing(monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Automatic selection must not scan a profile")

    monkeypatch.setattr(profiles, "_profile_root", reject)
    assert profiles.validate_chrome_profile(None) is None


def test_lazy_default_root_is_resolved_from_browser_module_without_reading_state(tmp_path, monkeypatch):
    create_profile(tmp_path, "Profile 4", database="Cookies")
    monkeypatch.setitem(sys.modules, "app.browser", SimpleNamespace(chrome_user_data_directory=lambda: tmp_path))
    assert profiles.validate_chrome_profile("Profile 4") is None
    assert profiles.list_chrome_profiles()["profiles"] == [
        {"directory": "Profile 4", "has_cookie_database": True},
    ]


def test_unsupported_platform_root_is_reported_without_guessing(monkeypatch):
    monkeypatch.setattr(profiles, "_profile_root", lambda _: None)
    assert profiles.list_chrome_profiles() == {"status": "chrome_data_directory_missing", "profiles": []}
    assert profiles.validate_chrome_profile("Default") == "chrome_data_directory_missing"


@pytest.mark.parametrize("number,expected", [(errno.EACCES, "cookie_permission_denied"), (errno.EPERM, "cookie_permission_denied"), (errno.EIO, "cookie_storage_failed")])
def test_scan_failure_does_not_expose_exception_or_return_partial_choices(tmp_path, monkeypatch, number, expected):
    create_profile(tmp_path, "Default", database="Cookies")

    def reject(*args, **kwargs):
        raise OSError(number, "PRIVATE_COOKIE_VALUE /Users/private/browser")

    monkeypatch.setattr(profiles.os, "scandir", reject)
    assert profiles.list_chrome_profiles(tmp_path) == {"status": expected, "profiles": []}


@pytest.mark.parametrize("number,expected", [(errno.EACCES, "cookie_permission_denied"), (errno.EIO, "cookie_storage_failed")])
def test_database_metadata_failure_is_reported_safely(tmp_path, monkeypatch, number, expected):
    create_profile(tmp_path, "Default", database="Cookies")
    original = Path.lstat

    def lstat(path, *args, **kwargs):
        if path.name == "Cookies":
            raise OSError(number, "PRIVATE_COOKIE_VALUE /Users/private/browser")
        return original(path, *args, **kwargs)

    monkeypatch.setattr(Path, "lstat", lstat)
    assert profiles.list_chrome_profiles(tmp_path) == {"status": expected, "profiles": []}
    assert profiles.validate_chrome_profile("Default", tmp_path) == expected


def test_symlinked_root_is_not_scanned(tmp_path, monkeypatch):
    real = tmp_path / "real"
    create_profile(real, "Default", database="Cookies")
    linked = tmp_path / "linked"
    linked.symlink_to(real, target_is_directory=True)

    def reject(*args, **kwargs):
        raise AssertionError("Linked roots must not be traversed")

    monkeypatch.setattr(profiles.os, "scandir", reject)
    assert profiles.list_chrome_profiles(linked) == {"status": "cookie_storage_failed", "profiles": []}
    assert profiles.validate_chrome_profile("Default", linked) == "cookie_storage_failed"


def test_linked_profile_is_never_offered_or_accepted(tmp_path):
    root = tmp_path / "chrome"
    root.mkdir()
    real = create_profile(tmp_path, "private-profile", database="Cookies")
    (root / "Default").symlink_to(real, target_is_directory=True)
    assert profiles.list_chrome_profiles(root) == {"status": "ok", "profiles": []}
    assert profiles.validate_chrome_profile("Default", root) == "chrome_profile_missing"


@pytest.mark.parametrize("kind", ["legacy", "network", "modern"])
def test_linked_database_or_network_directory_is_not_accepted(tmp_path, kind):
    root = tmp_path / "chrome"
    profile = create_profile(root, "Profile 2")
    target = tmp_path / "private-target"
    if kind == "network":
        target.mkdir()
        (target / "Cookies").write_bytes(b"not a cookie database")
        (profile / "Network").symlink_to(target, target_is_directory=True)
    else:
        target.write_bytes(b"not a cookie database")
        link = profile / ("Cookies" if kind == "legacy" else "Network/Cookies")
        link.parent.mkdir(exist_ok=True)
        link.symlink_to(target)
    assert profiles.list_chrome_profiles(root) == {"status": "ok", "profiles": [
        {"directory": "Profile 2", "has_cookie_database": False},
    ]}
    assert profiles.validate_chrome_profile("Profile 2", root) == "cookie_database_missing"


def test_scan_limit_reports_incomplete_instead_of_partial_success(tmp_path, monkeypatch):
    monkeypatch.setattr(profiles, "MAX_SCAN_ENTRIES", 3)
    for name in ("Default", "Profile 1", "Profile 2", "Profile 3"):
        create_profile(tmp_path, name, database="Cookies")
    assert profiles.list_chrome_profiles(tmp_path) == {"status": "profile_scan_limit", "profiles": []}


def test_scan_limit_counts_unknown_entries_too_and_allows_exact_boundary(tmp_path, monkeypatch):
    monkeypatch.setattr(profiles, "MAX_SCAN_ENTRIES", 3)
    create_profile(tmp_path, "Default", database="Cookies")
    (tmp_path / "Unknown 1").touch()
    (tmp_path / "Unknown 2").touch()
    assert profiles.list_chrome_profiles(tmp_path)["status"] == "ok"
    (tmp_path / "Unknown 3").touch()
    assert profiles.list_chrome_profiles(tmp_path) == {"status": "profile_scan_limit", "profiles": []}


@pytest.mark.parametrize("error", [KeyboardInterrupt(), SystemExit(), RuntimeError("programming failure")])
def test_control_and_unexpected_errors_are_not_swallowed(tmp_path, monkeypatch, error):
    def reject(*args, **kwargs):
        raise error

    monkeypatch.setattr(profiles.os, "scandir", reject)
    with pytest.raises(type(error)):
        profiles.list_chrome_profiles(tmp_path)
