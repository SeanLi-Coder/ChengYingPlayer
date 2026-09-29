"""Keep the frozen profile self-test isolated from real browser data."""

from __future__ import annotations

import builtins
import socket
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import chrome_profiles
import profile_smoke


@pytest.fixture(autouse=True)
def reject_private_access(monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Browser, database, keychain, network and file reads are forbidden")

    monkeypatch.setattr(builtins, "open", reject)
    monkeypatch.setattr(Path, "open", reject)
    monkeypatch.setattr(sqlite3, "connect", reject)
    monkeypatch.setattr(subprocess, "Popen", reject)
    monkeypatch.setattr(socket.socket, "connect", reject)
    monkeypatch.setattr(socket.socket, "connect_ex", reject)


def test_smoke_uses_only_explicit_temporary_roots_and_cleans_them(monkeypatch):
    original = chrome_profiles._profile_root
    roots = set()

    def resolve(root):
        assert isinstance(root, Path) and root.name.startswith("chengying-profile-smoke-")
        assert root.is_dir()
        roots.add(root)
        return original(root)

    monkeypatch.setattr(chrome_profiles, "_profile_root", resolve)
    assert profile_smoke.verify_profile_runtime() == (
        "synthetic-directories-and-explicit-selection-verified-offline"
    )
    assert len(roots) == 1
    assert not next(iter(roots)).exists()


def test_smoke_failure_is_fixed_and_does_not_expose_private_exception(monkeypatch):
    def broken(root):
        raise OSError("PRIVATE_COOKIE_VALUE /Users/private/browser")

    monkeypatch.setattr(chrome_profiles, "list_chrome_profiles", broken)
    with pytest.raises(RuntimeError) as caught:
        profile_smoke.verify_profile_runtime()
    assert str(caught.value) == "The bundled Chrome-profile offline verification failed"
    assert caught.value.__suppress_context__ is True


@pytest.mark.parametrize("error", [KeyboardInterrupt(), SystemExit()])
def test_smoke_does_not_swallow_control_signals(monkeypatch, error):
    def interrupted(root):
        raise error

    monkeypatch.setattr(chrome_profiles, "list_chrome_profiles", interrupted)
    with pytest.raises(type(error)):
        profile_smoke.verify_profile_runtime()


def test_smoke_rejects_silent_explicit_profile_fallback(monkeypatch):
    original = chrome_profiles.validate_chrome_profile

    def fallback(profile, root):
        if profile == "Default":
            return None
        return original(profile, root)

    monkeypatch.setattr(chrome_profiles, "validate_chrome_profile", fallback)
    with pytest.raises(RuntimeError, match="bundled Chrome-profile offline verification failed"):
        profile_smoke.verify_profile_runtime()
