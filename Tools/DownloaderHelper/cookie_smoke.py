"""Exercise the shipped Chrome-cookie reader using only synthetic local data."""

from __future__ import annotations

import hashlib
import sqlite3
import subprocess
import tempfile
from contextlib import closing, contextmanager
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
    from chrome_cookie_runtime import cookie_read_scope, install_chrome_cookie_runtime
    from yt_dlp import YoutubeDL, cookies
    from yt_dlp.utils import DownloadError

    install_chrome_cookie_runtime()

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
        with closing(sqlite3.connect(database)) as connection, _replace_attributes([
            (cookies, "Popen", SyntheticKeychain),
            (cookies, "_get_chromium_based_browser_settings", browser_settings),
            (browser, "chrome_user_data_directory", lambda: root),
        ]):
            # Keep this writer open so committed schema, cookie inserts, and
            # deletions stay in the WAL throughout the production extraction.
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
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
            connection.commit()

            def check_valid_cookie():
                jar = douyin_signing._load_chrome_cookie_jar("Default")
                if [(item.domain, item.name, item.value) for item in jar] != [
                    (".douyin.com", "sessionid", expected_value),
                ]:
                    raise RuntimeError("Synthetic Chrome-cookie extraction failed")

            def check_ytdlp_cookie_session(*, expect_failure=False):
                try:
                    with cookie_read_scope(
                        domain="douyin.com", required_cookie_names=("sessionid", "sessionid_ss")
                    ), YoutubeDL({
                        "quiet": True, "no_warnings": True, "cachedir": False,
                        "logger": browser.ChromeCookieLogger(),
                        "cookiesfrombrowser": ("chrome", "Default"),
                    }, auto_init=False) as downloader:
                        names = [cookie.name for cookie in downloader.cookiejar]
                except DownloadError as error:
                    if not expect_failure or browser.chrome_cookie_diagnostic(
                        "Default", error
                    ) != "cookie_decryption_failed":
                        raise RuntimeError("Synthetic YoutubeDL cookie failure was misclassified") from None
                else:
                    if expect_failure or names != ["sessionid"]:
                        raise RuntimeError("Synthetic YoutubeDL cookie session was not protected")

            check_valid_cookie()
            with connection:
                connection.executemany(
                    "INSERT INTO cookies VALUES (?, ?, '', ?, '/', 0, 1)",
                    [
                        (
                            ".unrelated.example", "broken-utf8",
                            _encrypted_cookie(".unrelated.example", b"\xff", password),
                        ),
                        (".unrelated.example", "broken-length", b"v10truncated"),
                    ],
                )
                connection.execute(
                    "INSERT INTO cookies VALUES ('.unrelated.example', 'broken-plain', "
                    "CAST(X'FF' AS TEXT), X'', '/', 0, 1)"
                )
            check_valid_cookie()
            check_ytdlp_cookie_session()

            def check_unavailable_session():
                try:
                    douyin_signing._load_chrome_cookie_jar("Default")
                except douyin_signing._CookieAccessSigningFailure as error:
                    if error.cookie_diagnostic_code != "cookie_decryption_failed":
                        raise RuntimeError("Synthetic cookie failure was misclassified") from None
                else:
                    raise RuntimeError("Synthetic cookie failure was not reported")

            keychain_available = False
            check_unavailable_session()
            keychain_available = True
            with connection:
                connection.execute(
                    "UPDATE cookies SET encrypted_value = ? WHERE name = 'sessionid'",
                    (b"v10truncated",),
                )
            check_unavailable_session()
            check_ytdlp_cookie_session(expect_failure=True)
            with connection:
                connection.execute("DELETE FROM cookies")
            if list(douyin_signing._load_chrome_cookie_jar("Default")):
                raise RuntimeError("Synthetic cookie snapshot retained a deleted session")

            if keychain_calls != 7:
                raise RuntimeError("Synthetic cookie verification missed the keychain path")

    return "macos-v10-aes-and-fixed-diagnostics-verified-offline"


def verify_cookie_runtime() -> str:
    try:
        return _check_cookie_runtime()
    except Exception:  # noqa: BLE001 -- Keep private backend diagnostics out of build logs.
        # Build logs need a fixed failure message, never fixture values, paths,
        # backend exception text, or a traceback containing an underlying error.
        raise RuntimeError("The bundled Chrome-cookie offline verification failed") from None
