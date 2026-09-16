"""Offline checks for the actual frozen download-center dependencies."""

from __future__ import annotations

import importlib.metadata
import json
import os
import subprocess
import sys
from pathlib import Path


def _check() -> dict[str, object]:
    import certifi
    import playwright
    import requests
    import yt_dlp
    from playwright.sync_api import sync_playwright
    from yt_dlp.extractor import gen_extractor_classes
    from yt_dlp.utils._jsruntime import DenoJsRuntime

    root = Path(__file__).resolve().parent
    runtime_root = Path(getattr(sys, "_MEIPASS", root))
    vendor_root = runtime_root / "vendor" / "rednote"
    executable_root = Path(sys.executable).resolve().parent
    manifest_path = runtime_root / "runtime-artifacts.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    versions = {}
    for package in manifest["artifacts"]:
        actual = importlib.metadata.version(package["name"])
        if actual != package["version"]:
            raise RuntimeError(f"Unexpected bundled version: {package['name']}")
        versions[package["name"]] = actual

    for relative in (
        "run.py",
        "launcher.py",
        "LICENSE",
        "app/main.py",
        "app/static/index.html",
    ):
        if not (vendor_root / relative).is_file():
            raise RuntimeError(f"Missing preserved downloader resource: {relative}")
    for relative in (
        "static/desktop.js",
        "static/desktop.css",
        "upstream-manifest.json",
    ):
        if not (runtime_root / relative).is_file():
            raise RuntimeError(f"Missing desktop adapter resource: {relative}")
    if not Path(certifi.where()).is_file():
        raise RuntimeError("The bundled HTTPS certificate bundle is unavailable")
    if requests.Session is None or yt_dlp.YoutubeDL is None:
        raise RuntimeError("The bundled downloader imports are incomplete")
    from proxy_config import normalize_proxy_url
    from proxy_transport import RequestsRH, _browser_proxy, _download_proxy

    proxy = normalize_proxy_url("socks5://127.0.0.1:7897/")
    if _download_proxy(proxy) != "socks5h://127.0.0.1:7897":
        raise RuntimeError("The bundled proxy transport has inconsistent SOCKS DNS routing")
    if _browser_proxy(proxy) != {"server": "socks5://127.0.0.1:7897", "bypass": "<-loopback>"}:
        raise RuntimeError("The bundled browser proxy configuration is unavailable")
    if not {"http", "https", "socks5", "socks5h"}.issubset(RequestsRH._SUPPORTED_PROXY_SCHEMES):
        raise RuntimeError("The bundled downloader lacks a required proxy protocol")
    extractors = gen_extractor_classes()
    names = {extractor.__name__ for extractor in extractors}
    if not {"YoutubeIE", "BiliBiliIE", "DouyinIE"}.issubset(names):
        raise RuntimeError("The original yt-dlp extractor set is incomplete")
    from importlib.resources import files

    solver = files("yt_dlp_ejs").joinpath("yt", "solver", "core.min.js")
    if not solver.is_file() or len(solver.read_bytes()) < 100:
        raise RuntimeError("The bundled YouTube JavaScript solver is unavailable")

    deno = executable_root / "deno"
    if not os.access(deno, os.X_OK):
        raise RuntimeError("The bundled Deno executable is unavailable")
    deno_result = subprocess.run(
        [str(deno), "eval", "console.log(6 * 7)"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
        env={**os.environ, "DENO_NO_UPDATE_CHECK": "1"},
    )
    if deno_result.stdout.strip() != "42":
        raise RuntimeError("The bundled Deno JavaScript runtime failed")
    runtime = DenoJsRuntime(str(deno)).info
    if runtime is None or not runtime.supported:
        raise RuntimeError("yt-dlp cannot use the bundled Deno runtime")

    driver = Path(playwright.__file__).resolve().parent / "driver"
    if not (driver / "node").is_file() or not (driver / "package" / "cli.js").is_file():
        raise RuntimeError("The bundled Playwright driver is incomplete")
    # Starting the driver verifies Node and its JS package; it never opens a site or a Chrome profile.
    with sync_playwright() as browser_driver:
        if browser_driver.chromium.name != "chromium":
            raise RuntimeError("The Playwright Node driver did not start")
        request_context = browser_driver.request.new_context()
        request_context.dispose()

    return {
        "status": "ok",
        "dependencies": versions,
        "extractor_count": len(names),
        "deno_version": runtime.version,
        "playwright_driver": "ready",
        "browser": "external-google-chrome",
        "minimum_macos": manifest["minimum_macos"],
    }


def run() -> int:
    result = _check()
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0
