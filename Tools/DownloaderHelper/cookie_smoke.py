"""Exercise the shipped Chrome-cookie reader using only synthetic local data."""

from __future__ import annotations

import hashlib
import sqlite3
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def _replace_attributes(replacements):
    originals = []
    try:
        for owner, name, value in replacements:
            originals.append((owner, name, getattr(owner, name)))
            setattr(owner, name, value)
        yield
    finally:
        for owner, name, value in reversed(originals):
            setattr(owner, name, value)


def _encrypted_cookie(domain: str, value: bytes, password: bytes) -> bytes:
    from Cryptodome.Cipher import AES

    key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)
    plaintext = hashlib.sha256(domain.encode()).digest() + value
    padding = 16 - len(plaintext) % 16
    return b"v10" + AES.new(key, AES.MODE_CBC, b" " * 16).encrypt(
        plaintext + bytes([padding]) * padding
    )


def _check_cookie_runtime() -> str:
    from app import browser, douyin_signing
    from yt_dlp import cookies

    password = b"chengying-synthetic-cookie-password"
    expected_value = "chengying-synthetic-cookie-value"
    keychain_available = True
    keychain_calls = 0

    class SyntheticKeychain:
        @staticmethod
        def run(arguments, **kwargs):
            nonlocal keychain_calls
            if arguments != [
                "security", "find-generic-password", "-w", "-a", "Chrome",
                "-s", "Chrome Safe Storage",
            ] or kwargs != {
                "stdout": subprocess.PIPE,
                "stderr": subprocess.DEVNULL,
            }:
                raise RuntimeError("Unexpected synthetic keychain request")
            keychain_calls += 1
            return (password + b"\n", b"", 0) if keychain_available else (b"", b"", 1)

    with tempfile.TemporaryDirectory(prefix="chengying-cookie-smoke-") as temporary:
        root = Path(temporary)
        profile = root / "Default"
        profile.mkdir()
        database = profile / "Cookies"
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE meta (key TEXT, value TEXT)")
            connection.execute("INSERT INTO meta VALUES ('version', '24')")
            connection.execute(
                "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
                "encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER)"
            )
            connection.execute(
                "INSERT INTO cookies VALUES (?, ?, '', ?, '/', 0, 1)",
                (
                    ".douyin.com", "sessionid",
                    _encrypted_cookie(".douyin.com", expected_value.encode(), password),
                ),
            )

        def browser_settings(name):
            if name != "chrome":
                raise RuntimeError("Unexpected synthetic browser request")
            return {
                "browser_dir": str(root),
                "keyring_name": "Chrome",
                "supports_profiles": True,
            }

        # Replace every entry into the real browser directory or keychain before
        # invoking the production wrapper. This runs only in offline self-test.
        with _replace_attributes([
            (cookies, "Popen", SyntheticKeychain),
            (cookies, "_get_chromium_based_browser_settings", browser_settings),
            (browser, "chrome_user_data_directory", lambda: root),
        ]):
            def check_valid_cookie():
                jar = douyin_signing._load_chrome_cookie_jar("Default")
                if [(item.domain, item.name, item.value) for item in jar] != [
                    (".douyin.com", "sessionid", expected_value),
                ]:
                    raise RuntimeError("Synthetic Chrome-cookie extraction failed")

            check_valid_cookie()
            with sqlite3.connect(database) as connection:
                connection.execute(
                    "INSERT INTO cookies VALUES (?, ?, '', ?, '/', 0, 1)",
                    (
                        ".unrelated.example", "broken",
                        _encrypted_cookie(".unrelated.example", b"\xff", password),
                    ),
                )
            check_valid_cookie()

            keychain_available = False
            try:
                douyin_signing._load_chrome_cookie_jar("Default")
            except douyin_signing._CookieAccessSigningFailure as error:
                if error.cookie_diagnostic_code != "cookie_decryption_failed":
                    raise RuntimeError("Synthetic keychain failure was misclassified") from None
            else:
                raise RuntimeError("Synthetic keychain failure was not reported")

            if keychain_calls != 3:
                raise RuntimeError("Synthetic cookie verification missed the keychain path")

    return "macos-v10-aes-and-fixed-diagnostics-verified-offline"


def verify_cookie_runtime() -> str:
    try:
        return _check_cookie_runtime()
    except Exception:  # noqa: BLE001 -- Keep private backend diagnostics out of build logs.
        # Build logs need a fixed failure message, never fixture values, paths,
        # backend exception text, or a traceback containing an underlying error.
        raise RuntimeError("The bundled Chrome-cookie offline verification failed") from None
