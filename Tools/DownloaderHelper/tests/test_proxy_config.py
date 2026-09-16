"""Proxy configuration and API regressions using only temporary private state."""

from __future__ import annotations

import json
import os
import stat
import sys
import threading
from concurrent.futures import Future
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import COOKIE_NAME, install_desktop_adapter
from proxy_config import ProxySettings, ProxySettingsError, normalize_proxy_url


def manager():
    return SimpleNamespace(_lock=threading.RLock(), _futures={})


@pytest.mark.parametrize(
    "value,expected",
    [
        ("", None),
        ("  ", None),
        ("http://127.0.0.1:7897/", "http://127.0.0.1:7897"),
        (" HTTPS://Example.COM ", "https://example.com:443"),
        ("socks5://localhost", "socks5://localhost:1080"),
        ("socks5h://localhost:1081", "socks5://localhost:1081"),
        ("http://[::1]:7897/", "http://[::1]:7897"),
        ("http://代理.example", "http://xn--mnq481g.example:80"),
        ("https://faß.de", "https://xn--fa-hia.de:443"),
        (
            "https://test%40user:p%40ss%3Aword@example.test:444/",
            "https://test%40user:p%40ss%3Aword@example.test:444",
        ),
    ],
)
def test_normalization(value, expected):
    assert normalize_proxy_url(value) == expected


@pytest.mark.parametrize(
    "value",
    [
        None,
        123,
        {},
        "127.0.0.1:7897",
        "file:///tmp/a",
        "ftp://host:21",
        "http://",
        "http://:80",
        "http://host:0",
        "http://host:65536",
        "http://host:",
        "http://host:bad",
        "http://host/path",
        "http://host/?a",
        "http://host/#a",
        "http://host\\evil",
        "http://host name",
        "http://-host:80",
        "http://host\n",
        "http://user:pa%0Ass@host:80",
        "http://user:bad%QX@host:80",
        "http://[broken]:80",
        "http://[fe80::1%en0]:80",
        "https://%75ser%3Aname:password@host:443",
        "x" * 2049,
    ],
)
def test_invalid_values_do_not_leak_input(value):
    with pytest.raises(ProxySettingsError) as error:
        normalize_proxy_url(value)
    assert error.value.code == "invalid_proxy"
    assert "password" not in str(error.value)
    assert "pa%0Ass" not in str(error.value)


@pytest.mark.parametrize(
    "url", ["socks5://user:secret@localhost:1080", "socks5h://user@localhost:1080"]
)
def test_browser_incompatible_socks_auth_is_rejected(url):
    with pytest.raises(ProxySettingsError) as error:
        normalize_proxy_url(url)
    assert error.value.code == "socks_auth_unsupported"
    assert "secret" not in str(error.value)


def test_ambiguous_proxy_credential_encoding_is_rejected():
    with pytest.raises(ProxySettingsError) as error:
        normalize_proxy_url("http://user:%E5%AF%86%E7%A0%81@localhost:7897")
    assert error.value.code == "proxy_auth_unsupported"
    assert "%E5" not in str(error.value)


def test_private_atomic_persistence_and_nonreflecting_status(tmp_path):
    settings = ProxySettings(tmp_path, manager())
    assert settings.proxy_url() is None
    assert settings.status() == {
        "enabled": False,
        "configured": False,
        "display_url": "",
        "has_credentials": False,
    }
    result = settings.save(
        {"enabled": True, "url": "http://test-user:test-secret@127.0.0.1:7897/"}
    )
    assert result == {
        "enabled": True,
        "configured": True,
        "display_url": "http://127.0.0.1:7897",
        "has_credentials": True,
    }
    assert "test-secret" not in json.dumps(result)
    assert stat.S_IMODE(settings.path.stat().st_mode) == 0o600
    restored = ProxySettings(tmp_path, manager())
    assert restored.proxy_url() == "http://test-user:test-secret@127.0.0.1:7897"
    restored.save({"enabled": False})
    assert restored.proxy_url() is None
    assert restored.status()["has_credentials"]
    restored.save({"enabled": True})
    assert "test-secret" in restored.proxy_url()
    restored.save({"enabled": False, "url": ""})
    assert not restored.status()["configured"]
    assert "test-secret" not in restored.path.read_text()
    assert not list(tmp_path.glob(".proxy-*.tmp"))


def test_failed_save_preserves_current_route_and_file(tmp_path):
    settings = ProxySettings(tmp_path, manager())
    settings.save({"enabled": True, "url": "http://first.test:80"})
    previous = settings.path.read_bytes()
    with patch.object(
        Path, "replace", side_effect=OSError("synthetic private details")
    ), pytest.raises(ProxySettingsError) as error:
        settings.save({"enabled": True, "url": "https://second.test:443"})
    assert error.value.code == "proxy_save_failed"
    assert "synthetic private" not in str(error.value)
    assert settings.path.read_bytes() == previous
    assert settings.proxy_url() == "http://first.test:80"
    assert not list(tmp_path.glob(".proxy-*.tmp"))


@pytest.mark.parametrize(
    "payload",
    [
        [],
        None,
        {},
        {"enabled": "yes"},
        {"enabled": 1},
        {"enabled": True},
        {"enabled": False, "extra": 1},
        {"enabled": False, "url": None},
    ],
)
def test_malformed_updates_cannot_change_settings(tmp_path, payload):
    settings = ProxySettings(tmp_path, manager())
    with pytest.raises(ProxySettingsError):
        settings.save(payload)
    assert settings.proxy_url() is None
    assert not settings.path.exists()


def test_running_or_queued_tasks_prevent_route_change(tmp_path):
    active = manager()
    settings = ProxySettings(tmp_path, active)
    settings.save({"enabled": True, "url": "http://first.test:80"})
    future = Future()
    active._futures["job"] = future
    for payload in (
        {"enabled": False},
        {"enabled": False, "url": ""},
        {"enabled": True, "url": "socks5://second.test:1080"},
    ):
        with pytest.raises(ProxySettingsError) as error:
            settings.save(payload)
        assert error.value.code == "proxy_busy" and error.value.status == 409
    assert settings.save({"enabled": True})["enabled"]
    assert settings.proxy_url() == "http://first.test:80"
    future.set_result(None)
    assert settings.save({"enabled": False})["enabled"] is False


@pytest.mark.parametrize(
    "raw",
    [
        b"broken",
        b"[]",
        b'{"version":1,"enabled":true,"url":""}',
        b'{"version":true,"enabled":false,"url":""}',
        b'{"version":1,"enabled":true,"url":"file:///tmp/private"}',
        b"x" * 16_385,
    ],
)
def test_corrupt_settings_block_network_until_explicit_clear(tmp_path, raw):
    path = tmp_path / "proxy.json"
    path.write_bytes(raw)
    settings = ProxySettings(tmp_path, manager())
    for operation in (
        settings.status,
        settings.proxy_url,
        lambda: settings.save({"enabled": False}),
    ):
        with pytest.raises(ProxySettingsError) as error:
            operation()
        assert error.value.code == "proxy_settings_unreadable"
    assert path.read_bytes() == raw
    assert settings.save({"enabled": False, "url": ""})["configured"] is False
    assert ProxySettings(tmp_path, manager()).proxy_url() is None


def test_symlink_and_fifo_settings_are_never_read(tmp_path):
    private = tmp_path / "private"
    private.write_bytes(b"private-data")
    link = tmp_path / "proxy.json"
    link.symlink_to(private)
    settings = ProxySettings(tmp_path, manager())
    with pytest.raises(ProxySettingsError):
        settings.proxy_url()
    settings.save({"enabled": False, "url": ""})
    assert private.read_bytes() == b"private-data" and not link.is_symlink()
    link.unlink()
    os.mkfifo(link)
    with pytest.raises(ProxySettingsError):
        ProxySettings(tmp_path, manager()).status()


@pytest.fixture
def proxy_api(tmp_path):
    settings = ProxySettings(tmp_path, manager())
    app = FastAPI()
    engine = SimpleNamespace(app=app, manager=settings.manager)
    install_desktop_adapter(
        engine,
        token="private-test-token",
        origin="http://127.0.0.1:51237",
        assets=tmp_path,
        proxy_settings=settings,
    )
    client = TestClient(app, base_url="http://127.0.0.1:51237")
    client.cookies.set(COOKIE_NAME, "private-test-token")
    return client, settings


def test_authenticated_api_does_not_echo_credentials(proxy_api):
    client, settings = proxy_api
    assert client.get("/api/native/proxy").json()["enabled"] is False
    response = client.put(
        "/api/native/proxy",
        json={
            "enabled": True,
            "url": "https://test-user:private-password@example.test:443",
        },
    )
    assert response.status_code == 200 and "private-password" not in response.text
    assert response.headers["cache-control"] == "no-store"
    assert client.get("/api/native/proxy").json() == response.json()
    assert "private-password" in settings.proxy_url()
    assert client.put("/api/native/proxy", json={"enabled": False}).status_code == 200


@pytest.mark.parametrize(
    "method,path",
    [
        ("get", "/api/native/proxy"),
        ("put", "/api/native/proxy"),
        ("post", "/api/native/proxy/test"),
    ],
)
def test_proxy_api_rejects_missing_session_and_cross_origin(proxy_api, method, path):
    client, _ = proxy_api
    call = getattr(client, method)
    assert call(path, headers={"Origin": "https://example.invalid"}).status_code == 403
    client.cookies.clear()
    assert call(path).status_code == 403


def test_api_validation_is_bounded_and_private(proxy_api):
    client, _ = proxy_api
    for body in (
        b"broken",
        b"[]",
        b'{"enabled":true,"url":"http://secret\npassword@host"}',
    ):
        response = client.put("/api/native/proxy", content=body)
        assert response.status_code == 422 and "password" not in response.text
    assert client.put("/api/native/proxy", content=b"x" * 4097).status_code == 413


def test_connection_probe_does_not_save_or_expose_network_exceptions(proxy_api):
    client, settings = proxy_api
    with patch("proxy_transport.probe_proxy", return_value=25) as probe:
        response = client.post(
            "/api/native/proxy/test",
            json={"enabled": True, "url": "http://127.0.0.1:7897"},
        )
        assert response.json()["ok"] and response.json()["elapsed_ms"] == 25
        probe.assert_called_once_with("http://127.0.0.1:7897", timeout=10)
    assert settings.proxy_url() is None and not settings.path.exists()
    with patch(
        "proxy_transport.probe_proxy",
        side_effect=RuntimeError("http://private-user:private-password@secret.test"),
    ):
        response = client.post(
            "/api/native/proxy/test",
            json={"enabled": True, "url": "http://127.0.0.1:7897"},
        )
    assert (
        response.json()["code"] == "proxy_test_failed"
        and "private-password" not in response.text
    )
    with settings.test_lock:
        response = client.post(
            "/api/native/proxy/test",
            json={"enabled": True, "url": "http://127.0.0.1:7897"},
        )
        assert (
            response.status_code == 409
            and response.json()["detail"]["code"] == "proxy_test_busy"
        )
