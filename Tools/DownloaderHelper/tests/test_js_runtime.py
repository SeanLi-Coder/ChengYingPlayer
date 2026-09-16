from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import js_runtime
from ejs_smoke import verify_ejs_runtime


def test_real_node_ejs_solves_n_and_signature_without_network():
    assert verify_ejs_runtime() == js_runtime.NODE_VERSION


@pytest.mark.parametrize("proxy_first", [False, True])
def test_native_runtime_preserves_upstream_options_and_proxy_transport(
    proxy_first, tmp_path
):
    from proxy_transport import install_proxy_transports

    engine = importlib.import_module("app.downloader")
    original = engine.MediaDownloader._base_options
    instance = SimpleNamespace(
        config=SimpleNamespace(
            socket_timeout_seconds=30, retries=8, fragment_retries=9
        ),
        _cookie_options=lambda enabled: (
            {"cookiefile": str(tmp_path / "fixture.txt")} if enabled else {}
        ),
    )
    before = original(instance, False)
    assert before["js_runtimes"] == {"deno": {}}
    restores = []
    try:
        first = lambda: install_proxy_transports(lambda: "socks5://127.0.0.1:7897")
        actions = (
            [first, js_runtime.install_js_runtime]
            if proxy_first
            else [js_runtime.install_js_runtime, first]
        )
        restores.extend(action() for action in actions)
        for cookies in (False, True):
            options = engine.MediaDownloader._base_options(instance, cookies)
            assert options["js_runtimes"] == {
                "node": {"path": str(js_runtime.node_path())}
            }
            assert options["remote_components"] == []
            for key, value in original(instance, cookies).items():
                if key != "js_runtimes":
                    assert options[key] == value
            with engine.YoutubeDL(options, auto_init=False) as downloader:
                assert downloader.params["proxy"] == "socks5h://127.0.0.1:7897"
                assert downloader._js_runtimes["node"].info.supported
                assert set(downloader.params["js_runtimes"]) == {"node"}
    finally:
        for restore in reversed(restores):
            restore()
            restore()
    assert engine.MediaDownloader._base_options is original


def test_runtime_installation_is_idempotent():
    restore = js_runtime.install_js_runtime()
    try:
        assert js_runtime.install_js_runtime() is restore
    finally:
        restore()


def test_runtime_does_not_search_the_users_path(monkeypatch):
    monkeypatch.setenv("PATH", "/nonexistent")
    assert js_runtime.node_path().is_absolute()
    assert os.access(js_runtime.node_path(), os.X_OK)


def test_frozen_runtime_cannot_escape_the_helper(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", "/tmp/Unrelated.app/Contents/MacOS/helper")
    with pytest.raises(RuntimeError, match="sealed helper"):
        js_runtime.node_path()
