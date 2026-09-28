"""Exercise pinned cookie extraction with synthetic stores and no user access."""

from __future__ import annotations

import hashlib
import os
import socket
import sqlite3
import sys
import time
from pathlib import Path

import pytest

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT / "vendor" / "rednote"))

from app import browser, douyin
from app import douyin_signing as signing
from app.errors import (
    AuthenticationRequiredError,
    DownloadCancelledError,
    SiteIssueCode,
    TemporaryAccessError,
)
from yt_dlp import cookies
from yt_dlp.aes import aes_cbc_encrypt_bytes

PROFILE_URL = "https://www.douyin.com/user/fixture-owner"
PASSWORD = b"synthetic-keychain-password"
PRIVATE_MARKER = "DO_NOT_DISCLOSE_FIXTURE_SECRET"
ORIGINAL_MAC_KEYRING_PASSWORD = cookies._get_mac_keyring_password


def reject_external_access(*args, **kwargs):
    raise AssertionError("Unexpected network, browser, or keychain access")


@pytest.fixture(autouse=True)
def isolated_cookie_environment(monkeypatch, tmp_path):
    root = tmp_path / "chrome"
    root.mkdir()
    monkeypatch.setattr(socket.socket, "connect", reject_external_access)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_external_access)
    monkeypatch.setattr(cookies.Popen, "run", reject_external_access)
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: root)
    monkeypatch.setattr(
        cookies, "_get_chromium_based_browser_settings",
        lambda name: {
            "browser_dir": str(root), "keyring_name": "Chrome",
            "supports_profiles": True,
        },
    )
    monkeypatch.setattr(cookies, "_get_mac_keyring_password", lambda *args: PASSWORD)
    monkeypatch.setattr(
        cookies, "get_cookie_decryptor",
        lambda directory, name, logger, *, keyring, meta_version:
            cookies.MacChromeCookieDecryptor(name, logger, meta_version),
    )
    monkeypatch.setattr(
        "playwright.sync_api.sync_playwright", reject_external_access,
    )
    return root


def cookie_row(
    domain=".douyin.com", *, name="sessionid", value="fixture-value",
    encrypted=False, corrupt=False, expires=0, path="/",
):
    payload = b""
    if encrypted:
        plaintext = hashlib.sha256(domain.encode()).digest()
        plaintext += b"\xff" if corrupt else value.encode()
        key = cookies.MacChromeCookieDecryptor.derive_key(PASSWORD)
        payload = b"v10" + aes_cbc_encrypt_bytes(plaintext, key, b" " * 16)
        value = ""
    return domain, name, value, payload, path, expires, 1


def write_store(root, rows, profile="Profile 2"):
    database = root / profile / "Network" / "Cookies"
    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE meta (key TEXT, value TEXT)")
        connection.execute("INSERT INTO meta VALUES ('version', '24')")
        connection.execute(
            "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
            "encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER)"
        )
        connection.executemany("INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
    return database


@pytest.mark.parametrize("loader", [signing._load_chrome_cookie_jar, douyin._extract_cookies])
def test_real_extractor_reads_meta24_encrypted_douyin_cookie(isolated_cookie_environment, loader):
    write_store(isolated_cookie_environment, [cookie_row(encrypted=True)])
    result = list(loader("Profile 2"))
    assert len(result) == 1
    assert result[0].value == "fixture-value"


@pytest.mark.parametrize("loader", [signing._load_chrome_cookie_jar, douyin._extract_cookies])
@pytest.mark.parametrize("missing_key", [False, True])
def test_bad_unrelated_cookie_does_not_discard_valid_douyin_session(
    isolated_cookie_environment, monkeypatch, loader, missing_key,
):
    write_store(isolated_cookie_environment, [
        cookie_row(),
        cookie_row(".unrelated.example", encrypted=True, corrupt=True),
    ])
    if missing_key:
        monkeypatch.setattr(cookies, "_get_mac_keyring_password", lambda *args: None)
    assert [cookie.value for cookie in loader("Profile 2")] == ["fixture-value"]


@pytest.mark.parametrize("remaining", ["none", "unrelated", "lookalike", "expired", "ttwid"])
@pytest.mark.parametrize("missing_key", [False, True])
def test_failed_requested_cookies_are_reported_as_cookie_access(
    isolated_cookie_environment, monkeypatch, remaining, missing_key,
):
    rows = [cookie_row(encrypted=True, corrupt=True)]
    if remaining == "unrelated":
        rows.append(cookie_row(".other.example"))
    elif remaining == "lookalike":
        rows.append(cookie_row(".douyin.com.attacker.example"))
    elif remaining == "expired":
        expired = int((time.time() - 60 + 11_644_473_600) * 1_000_000)
        rows.append(cookie_row(name="sessionid_ss", expires=expired))
    elif remaining == "ttwid":
        rows.append(cookie_row(name="ttwid"))
    write_store(isolated_cookie_environment, rows)
    if missing_key:
        monkeypatch.setattr(cookies, "_get_mac_keyring_password", lambda *args: None)
    with pytest.raises(signing._CookieAccessSigningFailure) as failure:
        signing._load_chrome_cookie_jar("Profile 2")
    assert failure.value.cookie_diagnostic_code == "cookie_decryption_failed"
    with pytest.raises(TemporaryAccessError) as public:
        signing._raise_signing_error(PROFILE_URL, failure.value)
    assert public.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert public.value.diagnostic_code == "cookie_decryption_failed"
    assert "Profile 2" not in str(public.value)


def test_missing_keychain_entry_keeps_safe_decryption_category(
    isolated_cookie_environment, monkeypatch, capsys,
):
    write_store(isolated_cookie_environment, [cookie_row(encrypted=True)])
    monkeypatch.setattr(cookies, "_get_mac_keyring_password", ORIGINAL_MAC_KEYRING_PASSWORD)
    calls = []

    def failed_keychain(command, **kwargs):
        calls.append(command)
        return b"", PRIVATE_MARKER.encode(), 1

    monkeypatch.setattr(cookies.Popen, "run", failed_keychain)
    with pytest.raises(signing._CookieAccessSigningFailure) as failure:
        signing._load_chrome_cookie_jar("Profile 2")
    assert len(calls) == 1
    assert calls[0][:2] == ["security", "find-generic-password"]
    assert failure.value.cookie_diagnostic_code == "cookie_decryption_failed"
    assert PRIVATE_MARKER not in str(failure.value)
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize(
    ("domain", "path"), [(".live.douyin.com", "/"), (".douyin.com", "/unrelated/")],
)
def test_auth_cookie_must_cover_actual_douyin_page_and_api_after_warning(
    isolated_cookie_environment, domain, path,
):
    write_store(isolated_cookie_environment, [
        cookie_row(encrypted=True, corrupt=True),
        cookie_row(domain, name="sessionid_ss", path=path),
    ])
    with pytest.raises(signing._CookieAccessSigningFailure) as failure:
        signing._load_chrome_cookie_jar("Profile 2")
    assert failure.value.cookie_diagnostic_code == "cookie_decryption_failed"


def test_logger_accepts_warning_keywords_without_retaining_private_details(capsys):
    logger = browser.ChromeCookieLogger()
    logger.debug(PRIVATE_MARKER)
    logger.info(PRIVATE_MARKER)
    logger.warning(f"failed to decrypt {PRIVATE_MARKER}", only_once=True)
    logger.warning(PRIVATE_MARKER, once=True)
    logger.error(PRIVATE_MARKER)
    assert vars(logger) == {"diagnostic_code": "cookie_decryption_failed"}
    assert capsys.readouterr() == ("", "")


def test_empty_store_without_decryption_failure_remains_an_authentication_case(
    isolated_cookie_environment,
):
    write_store(isolated_cookie_environment, [])
    jar = signing._load_chrome_cookie_jar("Profile 2")
    assert not list(jar)
    with pytest.raises(signing._AuthenticationSigningFailure):
        signing._cookie_jar_to_playwright(jar)


def enter_browser_fallback(monkeypatch):
    def signed_auth_failure(*args, **kwargs):
        raise AuthenticationRequiredError("Synthetic authentication confirmation")
    monkeypatch.setattr(douyin, "fetch_signed_profile_awemes", signed_auth_failure)


@pytest.mark.parametrize("allow_fallback", [False, True])
def test_browser_fallback_preserves_cookie_failure_without_anonymous_demotion(
    isolated_cookie_environment, monkeypatch, allow_fallback,
):
    write_store(isolated_cookie_environment, [cookie_row(encrypted=True, corrupt=True)])
    enter_browser_fallback(monkeypatch)
    with pytest.raises(TemporaryAccessError) as failure:
        douyin.discover_profile(
            PROFILE_URL, cookie_profile="Profile 2", allow_cookie_fallback=allow_fallback,
        )
    assert failure.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert failure.value.diagnostic_code == "cookie_decryption_failed"


@pytest.mark.parametrize("signal", [KeyboardInterrupt, SystemExit, DownloadCancelledError])
@pytest.mark.parametrize("entry", ["signing", "browser"])
def test_control_signals_escape_cookie_extraction(monkeypatch, signal, entry):
    def interrupted(*args, **kwargs):
        raise signal("Synthetic interruption")
    module = signing if entry == "signing" else douyin
    monkeypatch.setattr(module, "extract_cookies_from_browser", interrupted)
    if entry == "browser":
        enter_browser_fallback(monkeypatch)
    with pytest.raises(signal):
        if entry == "signing":
            signing._load_chrome_cookie_jar("Profile 2")
        else:
            douyin.discover_profile(PROFILE_URL, cookie_profile="Profile 2")


def test_automatic_profile_diagnostic_does_not_assume_default(isolated_cookie_environment):
    database = write_store(isolated_cookie_environment, [cookie_row()], profile="Profile 7")
    assert not (isolated_cookie_environment / "Default").exists()
    assert browser.chrome_cookie_diagnostic(None, RuntimeError("Synthetic failure")) == (
        "cookie_access_unknown"
    )
    assert len(list(signing._load_chrome_cookie_jar(None))) == 1
    assert database.is_file()


def test_automatic_profile_keeps_pinned_extractor_selection(isolated_cookie_environment):
    older = write_store(isolated_cookie_environment, [cookie_row(value="older")], "Default")
    newer = write_store(isolated_cookie_environment, [cookie_row(value="newer")], "Profile 7")
    os.utime(older, (10, 10))
    os.utime(newer, (20, 20))
    assert [cookie.value for cookie in signing._load_chrome_cookie_jar(None)] == ["newer"]
    assert [cookie.value for cookie in signing._load_chrome_cookie_jar("Default")] == ["older"]
