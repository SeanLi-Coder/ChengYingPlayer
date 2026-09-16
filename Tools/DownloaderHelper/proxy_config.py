"""Private, validated download proxy settings, separate from upstream state."""

from __future__ import annotations

import contextlib
import ipaddress
import json
import os
import re
import stat
import tempfile
import threading
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit, urlunsplit

from idna import encode as encode_idna


class ProxySettingsError(ValueError):
    def __init__(self, code: str, message: str, status: int = 422):
        super().__init__(message)
        self.code = code
        self.status = status


def invalid_proxy() -> ProxySettingsError:
    # Never include the submitted URL or a parser's exception in an error.
    return ProxySettingsError(
        "invalid_proxy", "Enter a valid HTTP, HTTPS, or SOCKS5 proxy address."
    )


def normalize_proxy_url(value: object) -> str | None:
    if not isinstance(value, str) or len(value) > 2048:
        raise invalid_proxy()
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise invalid_proxy()
    value = value.strip()
    if not value:
        return None
    if any(char.isspace() for char in value) or any(char in value for char in "\\?#"):
        raise invalid_proxy()
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https", "socks5", "socks5h"}:
            raise invalid_proxy()
        if not parsed.netloc or parsed.path not in {"", "/"}:
            raise invalid_proxy()
        host = parsed.hostname
        if not host or "%" in host:
            raise invalid_proxy()
        if ":" in host:
            host = f"[{ipaddress.IPv6Address(host).compressed}]"
        else:
            # Match the browser's modern IDNA rules instead of mapping e.g. ß to ss.
            host = encode_idna(host, uts46=True, std3_rules=True).decode("ascii").lower()
            labels = host.rstrip(".").split(".")
            if len(host) > 253 or any(
                not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                for label in labels
            ):
                raise invalid_proxy()
        authority = parsed.netloc.rsplit("@", 1)[-1]
        if authority.endswith(":"):
            raise invalid_proxy()
        port = parsed.port
        if port is None:
            port = {"http": 80, "https": 443, "socks5": 1080, "socks5h": 1080}[
                parsed.scheme
            ]
        if not 1 <= port <= 65535:
            raise invalid_proxy()
        credentials = ""
        if parsed.username is not None:
            if parsed.scheme.startswith("socks"):
                raise ProxySettingsError(
                    "socks_auth_unsupported",
                    "Authenticated SOCKS5 is not supported by the browser. Use an HTTP proxy endpoint instead.",
                )
            raw_user, raw_password = parsed.username, parsed.password or ""
            if any(
                re.search(r"%(?![0-9a-fA-F]{2})", part)
                for part in (raw_user, raw_password)
            ):
                raise invalid_proxy()
            username, password = (
                unquote(raw_user, errors="strict"),
                unquote(raw_password, errors="strict"),
            )
            if not username or any(
                ord(char) < 32 or ord(char) == 127 for char in username + password
            ):
                raise invalid_proxy()
            if ":" in username:
                raise invalid_proxy()
            if not username.isascii() or not password.isascii():
                raise ProxySettingsError(
                    "proxy_auth_unsupported",
                    "HTTP proxy credentials must use ASCII characters for consistent browser and media authentication.",
                )
            credentials = f"{quote(username, safe='')}:{quote(password, safe='')}@"
        scheme = "socks5" if parsed.scheme == "socks5h" else parsed.scheme
        return urlunsplit((scheme, f"{credentials}{host}:{port}", "", "", ""))
    except ProxySettingsError:
        raise
    except (ValueError, UnicodeError):
        raise invalid_proxy() from None


class ProxySettings:
    """Change a process-wide route only while the download manager is idle."""

    def __init__(self, data_dir: Path, manager):
        self.path = data_dir / "proxy.json"
        self.manager = manager
        self._lock = threading.RLock()
        self.test_lock = threading.Lock()
        self._enabled = False
        self._url: str | None = None
        self._unreadable = False
        self._load()

    def _load(self):
        try:
            descriptor = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            return
        except OSError:
            self._unreadable = True
            return
        try:
            with os.fdopen(descriptor, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 16_384:
                    raise ValueError("Invalid private settings file")
                payload = json.loads(handle.read(16_385))
            if not isinstance(payload, dict) or set(payload) != {
                "version",
                "enabled",
                "url",
            }:
                raise ValueError("Invalid settings schema")
            if (
                type(payload["version"]) is not int
                or payload["version"] != 1
                or type(payload["enabled"]) is not bool
            ):
                raise ValueError("Invalid settings version")
            url = normalize_proxy_url(payload["url"])
            if payload["enabled"] and not url:
                raise ValueError("Enabled proxy has no address")
            self._enabled, self._url = payload["enabled"], url
        except (OSError, ValueError, UnicodeError):
            # Do not silently leak downloads through a direct route on corruption.
            self._unreadable = True

    def _check_readable(self):
        if self._unreadable:
            raise ProxySettingsError(
                "proxy_settings_unreadable",
                "Saved proxy settings cannot be read. Clear the proxy settings explicitly before downloading.",
                503,
            )

    def proxy_url(self) -> str | None:
        with self._lock:
            self._check_readable()
            return self._url if self._enabled else None

    def status(self) -> dict:
        with self._lock:
            self._check_readable()
            parsed = urlsplit(self._url or "")
            return {
                "enabled": self._enabled,
                "configured": bool(self._url),
                "display_url": urlunsplit(
                    (parsed.scheme, parsed.netloc.rsplit("@", 1)[-1], "", "", "")
                )
                if self._url
                else "",
                "has_credentials": parsed.username is not None,
            }

    def _candidate(self, payload: object) -> tuple[bool, str | None]:
        if (
            not isinstance(payload, dict)
            or set(payload) - {"enabled", "url"}
            or type(payload.get("enabled")) is not bool
        ):
            raise invalid_proxy()
        explicit_clear = payload == {"enabled": False, "url": ""}
        if not explicit_clear:
            self._check_readable()
        url = normalize_proxy_url(payload["url"]) if "url" in payload else self._url
        if payload["enabled"] and not url:
            raise ProxySettingsError(
                "proxy_not_configured", "Enter a proxy address first."
            )
        return payload["enabled"], url

    def save(self, payload: object) -> dict:
        # The upstream manager uses this same lock when it queues or retries jobs.
        with self.manager._lock, self._lock:
            enabled, url = self._candidate(payload)
            if not self._unreadable and (enabled, url) == (self._enabled, self._url):
                return self.status()
            if any(not future.done() for future in self.manager._futures.values()):
                raise ProxySettingsError(
                    "proxy_busy",
                    "Wait for active downloads to finish or cancel them before changing the proxy.",
                    409,
                )
            temporary: Path | None = None
            try:
                descriptor, name = tempfile.mkstemp(
                    prefix=".proxy-", suffix=".tmp", dir=self.path.parent
                )
                temporary = Path(name)
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    os.fchmod(handle.fileno(), 0o600)
                    json.dump(
                        {"version": 1, "enabled": enabled, "url": url or ""}, handle
                    )
                    handle.write("\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                temporary.replace(self.path)
            except OSError:
                raise ProxySettingsError(
                    "proxy_save_failed",
                    "Could not save proxy settings. The previous settings are still in use.",
                    500,
                ) from None
            finally:
                if temporary is not None:
                    with contextlib.suppress(OSError):
                        temporary.unlink(missing_ok=True)
            self._enabled, self._url, self._unreadable = enabled, url, False
            return self.status()

    def proxy_for_test(self, payload: object) -> str:
        with self._lock:
            enabled, url = self._candidate(payload)
            if not enabled or not url:
                raise ProxySettingsError(
                    "proxy_not_configured",
                    "Enable a proxy and enter its address first.",
                )
            return url
