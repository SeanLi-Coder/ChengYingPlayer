"""Verify the shipped profile selector using only temporary synthetic metadata."""

from __future__ import annotations

import tempfile
from pathlib import Path


def _check_profile_runtime() -> str:
    from chrome_profiles import list_chrome_profiles, validate_chrome_profile

    with tempfile.TemporaryDirectory(prefix="chengying-profile-smoke-") as temporary:
        root = Path(temporary)
        (root / "Profile 1").mkdir()
        (root / "Profile 1" / "Cookies").touch()
        (root / "Profile 2" / "Network").mkdir(parents=True)
        (root / "Profile 2" / "Network" / "Cookies").touch()
        (root / "Profile 3").mkdir()
        (root / "Guest Profile").mkdir()
        (root / "Local State").touch()
        # Every check supplies its own synthetic root. No browser resolver,
        # SQLite connection, file-content read or keychain is needed here.
        expected = {"status": "ok", "profiles": [
            {"directory": "Profile 1", "has_cookie_database": True},
            {"directory": "Profile 2", "has_cookie_database": True},
            {"directory": "Profile 3", "has_cookie_database": False},
        ]}
        if list_chrome_profiles(root) != expected:
            raise RuntimeError("Synthetic Chrome profile choices were incorrect")
        if validate_chrome_profile("Default", root) != "chrome_profile_missing":
            raise RuntimeError("A missing explicit profile was silently replaced")
        if validate_chrome_profile("Profile 1", root) is not None:
            raise RuntimeError("A synthetic legacy database was not recognized")
        if validate_chrome_profile("Profile 2", root) is not None:
            raise RuntimeError("A synthetic network database was not recognized")
        if validate_chrome_profile("Profile 3", root) != "cookie_database_missing":
            raise RuntimeError("An empty profile was accepted as a cookie database")
        if validate_chrome_profile(None, root / "absent") is not None:
            raise RuntimeError("Automatic profile semantics were changed")
        if validate_chrome_profile("../Profile 1", root) != "chrome_profile_invalid":
            raise RuntimeError("An invalid profile selection was accepted")
        # Adding a real Default directory must update discovery rather than a
        # hard-coded example list; removing a choice never selects another one.
        (root / "Default").mkdir()
        (root / "Default" / "Cookies").touch()
        if list_chrome_profiles(root)["profiles"][0] != {
            "directory": "Default", "has_cookie_database": True,
        }:
            raise RuntimeError("The current synthetic default was not discovered")
        if validate_chrome_profile("Default", root) is not None:
            raise RuntimeError("The current explicit default was not accepted")
        (root / "Profile 1" / "Cookies").unlink()
        (root / "Profile 1").rmdir()
        if validate_chrome_profile("Profile 1", root) != "chrome_profile_missing":
            raise RuntimeError("A removed explicit profile was silently replaced")

    return "synthetic-directories-and-explicit-selection-verified-offline"


def verify_profile_runtime() -> str:
    try:
        return _check_profile_runtime()
    except Exception:  # noqa: BLE001 -- Build logs must not contain filesystem diagnostics.
        raise RuntimeError("The bundled Chrome-profile offline verification failed") from None
