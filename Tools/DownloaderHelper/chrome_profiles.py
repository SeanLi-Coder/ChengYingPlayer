"""Enumerate Chrome profile directories without reading browser contents."""

from __future__ import annotations

import errno
import os
import re
import stat
from pathlib import Path

PROFILE_DIRECTORY_RE = re.compile(r"(?:Default|Profile [1-9][0-9]{0,9})")
MAX_SCAN_ENTRIES = 256


def _profile_root(root: Path | None) -> Path | None:
    if root is not None:
        return Path(root)
    # Keep imports lazy: callers can inspect this module without importing the
    # application, opening its persisted task state, or probing a real browser.
    from app.browser import chrome_user_data_directory

    return chrome_user_data_directory()


def _error_code(error: OSError) -> str:
    if error.errno in {errno.EACCES, errno.EPERM}:
        return "cookie_permission_denied"
    return "cookie_storage_failed"


def _kind(path: Path) -> int | None:
    try:
        return stat.S_IFMT(path.lstat().st_mode)
    except FileNotFoundError:
        return None


def _root_status(root: Path | None) -> str | None:
    kind = _kind(root) if root is not None else None
    if kind is None:
        return "chrome_data_directory_missing"
    if kind != stat.S_IFDIR:
        return "cookie_storage_failed"
    return None


def _has_cookie_database(profile: Path) -> bool:
    # Metadata only. Never connect to SQLite, open the cookie file, read Local
    # State, follow a linked database/directory, or infer which account is used.
    legacy = _kind(profile / "Cookies")
    network = _kind(profile / "Network")
    if legacy == stat.S_IFLNK or network == stat.S_IFLNK:
        return False
    modern = _kind(profile / "Network" / "Cookies") if network == stat.S_IFDIR else None
    if modern == stat.S_IFLNK:
        return False
    return legacy == stat.S_IFREG or modern == stat.S_IFREG


def list_chrome_profiles(root: Path | None = None) -> dict[str, object]:
    """Return bounded directory-name choices, never paths, identities or cookies."""
    profiles: list[dict[str, object]] = []
    try:
        root = _profile_root(root)
        status = _root_status(root)
        if status is not None:
            return {"status": status, "profiles": []}
        with os.scandir(root) as entries:
            for index, entry in enumerate(entries):
                if index >= MAX_SCAN_ENTRIES:
                    # A partial list must not masquerade as a complete scan.
                    return {"status": "profile_scan_limit", "profiles": []}
                if not PROFILE_DIRECTORY_RE.fullmatch(entry.name):
                    continue
                if not entry.is_dir(follow_symlinks=False):
                    continue
                path = root / entry.name
                # Recheck metadata rather than relying only on a directory
                # entry's cached type, including after a concurrent rename.
                if _kind(path) != stat.S_IFDIR:
                    continue
                profiles.append({
                    "directory": entry.name,
                    "has_cookie_database": _has_cookie_database(path),
                })
    except OSError as error:
        return {"status": _error_code(error), "profiles": []}
    profiles.sort(key=lambda profile: (
        0 if profile["directory"] == "Default" else 1,
        0 if profile["directory"] == "Default" else int(profile["directory"][8:]),
    ))
    return {"status": "ok", "profiles": profiles}


def validate_chrome_profile(profile: str | None, root: Path | None = None) -> str | None:
    """Preflight an explicit selection without selecting another browser identity."""
    if profile is None:
        # Automatic selection retains the upstream semantics and does not cause
        # a new background directory scan as a side effect of settings display.
        return None
    if not isinstance(profile, str) or not PROFILE_DIRECTORY_RE.fullmatch(profile):
        return "chrome_profile_invalid"
    try:
        root = _profile_root(root)
        status = _root_status(root)
        if status is not None:
            return status
        directory = root / profile
        if _kind(directory) != stat.S_IFDIR:
            return "chrome_profile_missing"
        if not _has_cookie_database(directory):
            return "cookie_database_missing"
    except OSError as error:
        return _error_code(error)
    return None
