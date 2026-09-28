from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import cookie_smoke


def test_real_cookie_extraction_uses_only_synthetic_database_and_keychain(monkeypatch, capsys):
    from app import browser
    from yt_dlp import cookies

    original_directory = browser.chrome_user_data_directory
    original_settings = cookies._get_chromium_based_browser_settings
    original_process = cookies.Popen

    def reject_process(*args, **kwargs):
        raise AssertionError("Offline cookie verification attempted an external process")

    monkeypatch.setattr(subprocess, "Popen", reject_process)
    assert cookie_smoke.verify_cookie_runtime() == (
        "macos-v10-aes-and-fixed-diagnostics-verified-offline"
    )
    assert browser.chrome_user_data_directory is original_directory
    assert cookies._get_chromium_based_browser_settings is original_settings
    assert cookies.Popen is original_process
    assert capsys.readouterr() == ("", "")


def test_cookie_verification_restores_hooks_and_redacts_backend_failure(monkeypatch, capsys):
    from app import browser, douyin_signing
    from yt_dlp import cookies

    original_directory = browser.chrome_user_data_directory
    original_settings = cookies._get_chromium_based_browser_settings
    original_process = cookies.Popen

    def reject_extraction(*args, **kwargs):
        assert browser.chrome_user_data_directory is not original_directory
        assert cookies.Popen is not original_process
        raise RuntimeError("sensitive-cookie=/private/synthetic-profile")

    monkeypatch.setattr(douyin_signing, "_load_chrome_cookie_jar", reject_extraction)
    with pytest.raises(RuntimeError) as failure:
        cookie_smoke.verify_cookie_runtime()
    assert str(failure.value) == "The bundled Chrome-cookie offline verification failed"
    assert failure.value.__suppress_context__
    assert browser.chrome_user_data_directory is original_directory
    assert cookies._get_chromium_based_browser_settings is original_settings
    assert cookies.Popen is original_process
    assert capsys.readouterr() == ("", "")


def test_cookie_verification_requires_working_native_aes(monkeypatch):
    from Cryptodome.Cipher import AES

    def broken_aes(*args, **kwargs):
        raise OSError("synthetic missing AES library")

    monkeypatch.setattr(AES, "new", broken_aes)
    with pytest.raises(RuntimeError, match="Chrome-cookie offline verification failed"):
        cookie_smoke.verify_cookie_runtime()
