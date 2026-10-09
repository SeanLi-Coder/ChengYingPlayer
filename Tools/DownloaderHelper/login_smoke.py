"""Exercise private login persistence without Chrome, user data or a network."""

from __future__ import annotations

import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


def verify_login_runtime():
    from login_auth import LoginPolicy, install_session_cookies, restore_chrome_settings
    from login_sessions import LegacyLoginSnapshots, LoginSessions
    from yt_dlp.cookies import extract_cookies_from_browser

    with tempfile.TemporaryDirectory(prefix="chengying-login-self-test-") as folder:
        data = Path(folder).resolve()
        data.chmod(0o700)
        policy = LoginPolicy(data)
        if policy.mode() != "chrome":
            raise RuntimeError("The Chrome login default is unavailable")
        policy.save("dedicated")
        if policy.mode() != "chrome":
            raise RuntimeError("The retired login policy is still active")
        policy.save("anonymous")
        if policy.mode() != "anonymous":
            raise RuntimeError("The explicit anonymous preference was lost")
        from pydantic import BaseModel

        class Config(BaseModel):
            use_chrome_cookies: bool = True

        config = Config()

        def persist(value):
            nonlocal config
            config = value.model_copy(deep=True)

        engine = SimpleNamespace(_CONFIG_LOCK=threading.RLock(),
                                 get_config=lambda: config, update_config=persist)
        restore_chrome_settings(engine, policy)
        if config.use_chrome_cookies or policy.mode() != "chrome":
            raise RuntimeError("The anonymous preference migration failed")
        reader = LegacyLoginSnapshots(data)
        if any(hasattr(reader, name) for name in ("start", "finish", "current_token", "_store")):
            raise RuntimeError("The compatibility reader exposes a login action")
        sessions = LoginSessions(data, lambda: None)
        records = [{"name": "sessionid", "value": "synthetic-first", "domain": ".douyin.com",
                    "path": "/", "expires": time.time() + 3600, "httpOnly": True,
                    "secure": True, "sameSite": "Lax"}]
        try:
            sessions._store("douyin", records)
            first = sessions.current_token("douyin")
            records[0]["value"] = "synthetic-second"
            sessions._store("douyin", records)
            second = sessions.current_token("douyin")
            restore = install_session_cookies(LegacyLoginSnapshots(data))
            try:
                if [cookie.value for cookie in extract_cookies_from_browser("chrome", first)] != ["synthetic-first"]:
                    raise RuntimeError("A task's private login identity changed")
                if [cookie.value for cookie in extract_cookies_from_browser("chrome", second)] != ["synthetic-second"]:
                    raise RuntimeError("The new private login identity is unavailable")
            finally:
                restore()
        finally:
            sessions.close()
        reopened = LoginSessions(data, lambda: None)
        try:
            if reopened.current_token("douyin") != second or first == second:
                raise RuntimeError("Private login persistence failed")
            report = reopened.status()
            if first in str(report) or second in str(report) or "synthetic-" in str(report):
                raise RuntimeError("Private login status exposed credential data")
        finally:
            reopened.close()
    return "removed-entry-and-legacy-identity-verified-offline"
