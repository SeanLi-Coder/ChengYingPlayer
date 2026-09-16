from __future__ import annotations

import base64
import hashlib
import importlib
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import traceback
from contextlib import contextmanager
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.error import HTTPError, URLError
from urllib.request import HTTPCookieProcessor, Request

import pytest

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT))
sys.path.insert(0, str(HELPER_ROOT / "vendor" / "rednote"))
import proxy_transport as transport
from yt_dlp import YoutubeDL
from yt_dlp.networking import Request as MediaRequest
from yt_dlp.networking.exceptions import ProxyError


class HTTPFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.path, dict(self.headers)))
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Set-Cookie", "fixture=yes; Path=/")
            self.end_headers()
            return
        status = 403 if self.path == "/denied" else 200
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "7")
        self.end_headers()
        self.wfile.write(b"fixture")

    def do_CONNECT(self):
        self.server.requests.append((self.path, dict(self.headers)))
        expected = getattr(self.server, "required_auth", None)
        if expected and self.headers.get("Proxy-Authorization") != expected:
            self.send_response(407)
            self.send_header("Proxy-Authenticate", 'Basic realm="fixture"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with socket.create_connection(
            self.server.tunnel_address, timeout=3
        ) as upstream:
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            sockets = (self.connection, upstream)
            while True:
                readable, _, _ = select.select(sockets, (), (), 3)
                if not readable:
                    break
                for connection in readable:
                    body = connection.recv(65536)
                    if not body:
                        return
                    other = (
                        upstream if connection is self.connection else self.connection
                    )
                    other.sendall(body)

    def log_message(self, *_):
        pass


class SOCKSFixture(socketserver.StreamRequestHandler):
    def handle(self):
        version, count = self.rfile.read(2)
        assert version == 5
        self.rfile.read(count)
        self.wfile.write(b"\x05\x00")
        version, command, _, kind = self.rfile.read(4)
        assert version == 5 and command == 1
        if kind == 3:
            address = self.rfile.read(self.rfile.read(1)[0]).decode()
        elif kind == 1:
            address = ".".join(str(byte) for byte in self.rfile.read(4))
        else:
            address = self.rfile.read(16).hex()
        port = struct.unpack("!H", self.rfile.read(2))[0]
        self.server.destinations.append((kind, address, port))
        self.wfile.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
        lines = []
        while line := self.rfile.readline():
            lines.append(line)
            if line == b"\r\n":
                break
        self.server.requests.append(b"".join(lines))
        self.wfile.write(
            b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture"
        )


@contextmanager
def server(handler=HTTPFixture, *, tls_context=None):
    kind = (
        ThreadingHTTPServer
        if handler is HTTPFixture
        else socketserver.ThreadingTCPServer
    )
    instance = kind(("127.0.0.1", 0), handler)
    instance.requests = []
    instance.destinations = []
    instance.tunnel_address = instance.server_address
    instance.daemon_threads = True
    if tls_context is not None:
        instance.socket = tls_context.wrap_socket(instance.socket, server_side=True)
    worker = threading.Thread(
        target=instance.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
    )
    worker.start()
    try:
        yield instance
    finally:
        instance.shutdown()
        instance.server_close()
        worker.join(timeout=2)


def address(instance, scheme="http"):
    return f"{scheme}://127.0.0.1:{instance.server_address[1]}"


@pytest.fixture
def installed():
    state = SimpleNamespace(proxy=None)
    get_proxy = lambda: state.proxy
    cleanup = transport.install_proxy_transports(get_proxy)
    state.cleanup = cleanup
    state.get_proxy = get_proxy
    state.downloader = importlib.import_module("app.downloader")
    state.xiaohongshu = importlib.import_module("app.xiaohongshu")
    state.signing = importlib.import_module("app.douyin_signing")
    try:
        yield state
    finally:
        cleanup()


def test_ytdlp_preserves_class_options_and_snapshots(installed):
    options = {"quiet": True, "socket_timeout": 4, "proxy": "http://ignored.invalid"}
    installed.proxy = "socks5://127.0.0.1:7897"
    with installed.downloader.YoutubeDL(options, auto_init=False) as downloader:
        assert isinstance(downloader, YoutubeDL)
        assert downloader.params["socket_timeout"] == 4
        assert downloader.proxies == {"all": "socks5h://127.0.0.1:7897"}
        installed.proxy = None
        assert downloader.proxies["all"].startswith("socks5h:")
    assert options["proxy"] == "http://ignored.invalid"
    assert installed.xiaohongshu.YoutubeDL is installed.downloader.YoutubeDL


def test_install_and_cleanup_are_idempotent(installed):
    assert transport.install_proxy_transports(installed.get_proxy) is installed.cleanup
    with pytest.raises(RuntimeError):
        transport.install_proxy_transports(lambda: None)
    installed.cleanup()
    installed.cleanup()
    assert installed.downloader.YoutubeDL is YoutubeDL


@pytest.mark.parametrize("module", ["downloader", "xiaohongshu"])
def test_explicit_http_proxy_overrides_environment_no_proxy(
    installed, monkeypatch, module
):
    with server() as proxy:
        installed.proxy = address(proxy)
        monkeypatch.setenv("no_proxy", "*")
        monkeypatch.setenv("NO_PROXY", "*")
        with (
            getattr(installed, module).YoutubeDL(
                {"quiet": True}, auto_init=False
            ) as downloader,
            downloader.urlopen(
                MediaRequest(
                    "http://fixture.invalid/media", headers={"Range": "bytes=3-"}
                )
            ) as response,
        ):
            assert response.read() == b"fixture"
        assert proxy.requests[0][0] == "http://fixture.invalid/media"
        assert proxy.requests[0][1]["Range"] == "bytes=3-"


def test_disabled_proxy_forces_direct_for_media_and_signing(installed, monkeypatch):
    for name in (
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "all_proxy",
        "ALL_PROXY",
    ):
        monkeypatch.setenv(name, "http://127.0.0.1:1")
    monkeypatch.setenv("no_proxy", "")
    monkeypatch.setenv("NO_PROXY", "")
    with server() as origin:
        url = address(origin) + "/ok"
        with installed.downloader.YoutubeDL(
            {"quiet": True}, auto_init=False
        ) as downloader:
            assert downloader.proxies == {"all": "__noproxy__"}
            with downloader.urlopen(url) as response:
                assert response.read() == b"fixture"
        with installed.signing.build_opener().open(url) as response:
            assert response.read() == b"fixture"
    assert len(origin.requests) == 2


@pytest.mark.parametrize("transport_name", ["media", "signing"])
def test_socks5_uses_proxy_dns_and_preserves_http(transport_name, installed):
    with server(SOCKSFixture) as proxy:
        installed.proxy = address(proxy, "socks5")
        url = "http://must-not-resolve.invalid/media"
        if transport_name == "media":
            with (
                installed.downloader.YoutubeDL(
                    {"quiet": True}, auto_init=False
                ) as downloader,
                downloader.urlopen(url) as response,
            ):
                assert response.read() == b"fixture"
        else:
            with installed.signing.build_opener().open(url) as response:
                assert response.read() == b"fixture"
        assert proxy.destinations == [(3, "must-not-resolve.invalid", 80)]


def test_signing_preserves_cookies_charset_redirects_and_errors(installed):
    jar = CookieJar()
    opener = installed.signing.build_opener(HTTPCookieProcessor(jar))
    with server() as origin:
        root = address(origin)
        with opener.open(Request(root + "/redirect"), timeout=2) as response:
            assert response.status == 200
            assert response.geturl() == root + "/ok"
            assert response.headers.get_content_charset() == "utf-8"
            assert response.read(3) == b"fix"
            assert response.read() == b"fixture"[3:]
            wrapped = response
        assert wrapped.closed
        assert any(cookie.name == "fixture" and cookie.value == "yes" for cookie in jar)
        assert origin.requests[-1][1]["Cookie"] == "fixture=yes"
        with pytest.raises(HTTPError) as failure:
            opener.open(root + "/denied")
        assert failure.value.code == 403
        assert failure.value.geturl() == root + "/denied"
        assert failure.value.read() == b"fixture"
        owned_response = failure.value.fp
        failure.value.close()
        assert owned_response.closed


def test_signing_connection_failure_is_urlerror(installed):
    installed.proxy = "http://127.0.0.1:1"
    with pytest.raises(URLError):
        installed.signing.build_opener().open("http://fixture.invalid/", timeout=0.1)


@pytest.mark.parametrize(
    "value,expected",
    [
        (
            "http://alice:pa%40ss@127.0.0.1:7897",
            {
                "server": "http://127.0.0.1:7897",
                "username": "alice",
                "password": "pa@ss",
            },
        ),
        ("https://proxy.example:443", {"server": "https://proxy.example:443"}),
        ("socks5://127.0.0.1:7897", {"server": "socks5://127.0.0.1:7897"}),
        ("socks5h://[::1]:7897", {"server": "socks5://[::1]:7897"}),
    ],
)
def test_browser_configuration_separates_credentials(value, expected):
    assert transport._browser_proxy(value) == {**expected, "bypass": "<-loopback>"}


def test_playwright_launch_uses_explicit_proxy_or_direct(monkeypatch):
    from playwright.sync_api import BrowserType

    launches = []
    monkeypatch.setattr(
        BrowserType, "launch", lambda self, *args, **kwargs: launches.append(kwargs)
    )
    state = SimpleNamespace(proxy=None)
    cleanup = transport.install_proxy_transports(lambda: state.proxy)
    try:
        BrowserType.launch(None, channel="chrome", headless=True)
        assert launches[-1]["proxy"] is None
        assert "--no-proxy-server" in launches[-1]["args"]
        state.proxy = "https://alice:pa%40ss@proxy.example:443"
        BrowserType.launch(None, channel="chrome", headless=True)
        assert launches[-1]["proxy"] == transport._browser_proxy(state.proxy)
        assert "--no-proxy-server" not in launches[-1]["args"]
        assert launches[-1]["channel"] == "chrome"
    finally:
        cleanup()


def test_probe_uses_transport_without_cookies(monkeypatch):
    with server() as proxy:
        monkeypatch.setattr(
            transport, "_PROBE_URL", "http://fixture.invalid/robots.txt"
        )
        assert transport.probe_proxy(address(proxy), timeout=2) >= 0
        assert len(proxy.requests) == 1
        assert not any(
            name.lower() in {"cookie", "authorization"} for name in proxy.requests[0][1]
        )


def test_proxy_credentials_are_removed_without_losing_error_type():
    proxy = "https://alice:pa%40ss@proxy.example:443"
    cause = ValueError(
        "Connection failed via https://alice:pa%40ss@proxy.example:443; password pa@ss"
    )
    error = ProxyError(cause=cause)
    error.__cause__ = cause
    transport._sanitize_exception(error, proxy)
    detail = "".join(traceback.format_exception(error))
    assert isinstance(error, ProxyError)
    for secret in ("alice", "pa@ss", "pa%40ss"):
        assert secret not in detail
    assert "Connection failed" in detail and "proxy.example" in detail


def test_ytdlp_logger_and_errors_are_redacted(installed):
    installed.proxy = "http://alice:pa%40ss@proxy.example:7897"
    log = []
    logger = SimpleNamespace(debug=log.append, warning=log.append, error=log.append)
    with installed.downloader.YoutubeDL(
        {"logger": logger, "quiet": True}, auto_init=False
    ) as downloader:
        downloader.report_warning("Proxy password pa@ss for alice")
        downloader.to_screen(installed.proxy)
        with pytest.raises(Exception) as failure:
            downloader.report_error("Proxy password pa%40ss for alice")
    assert all(
        "alice" not in entry and "pa@ss" not in entry and "pa%40ss" not in entry
        for entry in log
    )
    assert "alice" not in str(failure.value)


@pytest.fixture
def tls_contexts(tmp_path):
    certificate = tmp_path / "certificate.pem"
    private_key = tmp_path / "private-key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-keyout",
            str(private_key),
            "-out",
            str(certificate),
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:must-not-resolve.invalid",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certificate, private_key)
    trusted_context = ssl.create_default_context(cafile=str(certificate))
    return server_context, trusted_context, certificate


@pytest.mark.parametrize("mode", ["media", "signing", "probe"])
def test_authenticated_https_proxy_tunnels_https_with_certificate_verification(
    installed, monkeypatch, tls_contexts, mode
):
    server_context, trusted_context, _ = tls_contexts
    monkeypatch.setattr(
        transport.RequestsRH,
        "_make_sslcontext",
        lambda *_args, **_kwargs: trusted_context,
    )
    with (
        server(tls_context=server_context) as origin,
        server(tls_context=server_context) as proxy,
    ):
        proxy.tunnel_address = origin.server_address
        installed.proxy = address(proxy, "https").replace("//", "//alice:pa%40ss@")
        destination = address(origin, "https") + "/ok"
        if mode == "media":
            with (
                installed.downloader.YoutubeDL(
                    {"quiet": True}, auto_init=False
                ) as downloader,
                downloader.urlopen(destination) as response,
            ):
                assert response.read() == b"fixture"
        elif mode == "signing":
            with installed.signing.build_opener().open(
                destination, timeout=2
            ) as response:
                assert response.read() == b"fixture"
        else:
            monkeypatch.setattr(transport, "_PROBE_URL", destination)
            assert transport.probe_proxy(installed.proxy, timeout=2) >= 0
        assert len(proxy.requests) == 1 and len(origin.requests) == 1
        expected = "Basic " + base64.b64encode(b"alice:pa@ss").decode()
        assert proxy.requests[0][1]["Proxy-Authorization"] == expected
        assert "Proxy-Authorization" not in origin.requests[0][1]


def test_untrusted_https_proxy_is_rejected(installed, tls_contexts):
    server_context, _, _ = tls_contexts
    with server(tls_context=server_context) as proxy:
        installed.proxy = address(proxy, "https")
        with (
            installed.downloader.YoutubeDL(
                {"quiet": True}, auto_init=False
            ) as downloader,
            pytest.raises(ProxyError, match="CERTIFICATE_VERIFY_FAILED"),
        ):
            downloader.urlopen("https://fixture.invalid/media")
        assert not proxy.requests


def test_proxy_connection_failure_does_not_retry_direct(installed):
    with server() as origin:
        installed.proxy = "http://127.0.0.1:1"
        with (
            installed.downloader.YoutubeDL(
                {"quiet": True, "socket_timeout": 0.1}, auto_init=False
            ) as downloader,
            pytest.raises(ProxyError),
        ):
            downloader.urlopen(address(origin) + "/ok")
        assert not origin.requests


def test_invalid_saved_settings_block_all_network_entry_points(monkeypatch):
    from playwright.sync_api import BrowserType

    launches = []
    monkeypatch.setattr(
        BrowserType, "launch", lambda *_args, **kwargs: launches.append(kwargs)
    )

    def broken_settings():
        raise ValueError("Invalid saved proxy settings")

    cleanup = transport.install_proxy_transports(broken_settings)
    try:
        for action in (
            lambda: importlib.import_module("app.downloader").YoutubeDL(),
            lambda: importlib.import_module("app.xiaohongshu").YoutubeDL(),
            lambda: importlib.import_module("app.douyin_signing").build_opener(),
            lambda: BrowserType.launch(None, channel="chrome"),
        ):
            with pytest.raises(ValueError, match="Invalid saved"):
                action()
        assert not launches
    finally:
        cleanup()


@pytest.mark.skipif(
    not Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").is_file(),
    reason="The optional local Chrome runtime is not installed",
)
@pytest.mark.parametrize("mode", ["http", "socks5", "direct"])
def test_actual_chrome_page_and_context_request_use_same_proxy(
    installed, monkeypatch, mode
):
    from playwright.sync_api import sync_playwright

    for name in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ):
        monkeypatch.setenv(name, "http://127.0.0.1:1")
    handler = SOCKSFixture if mode == "socks5" else HTTPFixture
    with server(handler) as proxy:
        if mode == "direct":
            target = address(proxy) + "/ok"
        else:
            installed.proxy = address(proxy, mode)
            target = "http://must-not-resolve.invalid/media"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                channel="chrome", headless=True, timeout=15000
            )
            try:
                context = browser.new_context()
                page = context.new_page()
                response = page.goto(
                    target, wait_until="domcontentloaded", timeout=5000
                )
                assert response is not None and response.status == 200
                assert "fixture" in page.content()
                response = context.request.get(target, timeout=5000)
                assert response.status == 200 and response.body() == b"fixture"
                response.dispose()
            finally:
                browser.close()
        assert len(proxy.requests) >= 2
        if mode == "socks5":
            assert (
                sum(
                    entry == (3, "must-not-resolve.invalid", 80)
                    for entry in proxy.destinations
                )
                >= 2
            )


@pytest.mark.skipif(
    not Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").is_file(),
    reason="The optional local Chrome runtime is not installed",
)
def test_actual_chrome_https_proxy_with_pinned_fixture_trust(
    installed, monkeypatch, tls_contexts
):
    from playwright.sync_api import sync_playwright

    server_context, _, certificate = tls_contexts
    public_key = subprocess.run(
        ["openssl", "x509", "-in", str(certificate), "-pubkey", "-noout"],
        check=True,
        capture_output=True,
    ).stdout
    der_key = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"],
        input=public_key,
        check=True,
        capture_output=True,
    ).stdout
    pin = base64.b64encode(hashlib.sha256(der_key).digest()).decode()
    # Scope test trust to one ephemeral key and the child Node driver. Neither
    # the macOS keychain nor any production TLS verification setting is changed.
    monkeypatch.setenv("NODE_EXTRA_CA_CERTS", str(certificate))
    with (
        server(tls_context=server_context) as origin,
        server(tls_context=server_context) as proxy,
    ):
        proxy.tunnel_address = origin.server_address
        proxy.required_auth = "Basic " + base64.b64encode(b"alice:pa@ss").decode()
        installed.proxy = address(proxy, "https").replace("//", "//alice:pa%40ss@")
        target = f"https://must-not-resolve.invalid:{origin.server_address[1]}/ok"
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                channel="chrome",
                headless=True,
                timeout=15000,
                args=[f"--ignore-certificate-errors-spki-list={pin}"],
            )
            try:
                context = browser.new_context()
                page = context.new_page()
                response = page.goto(
                    target, wait_until="domcontentloaded", timeout=5000
                )
                assert response is not None and response.status == 200
                assert "fixture" in page.content()
                response = context.request.get(target, timeout=5000)
                assert response.status == 200 and response.body() == b"fixture"
                response.dispose()
            finally:
                browser.close()
        assert len(origin.requests) >= 2
        assert any(
            headers.get("Proxy-Authorization") == proxy.required_auth
            for _, headers in proxy.requests
        )
        assert all(
            "Proxy-Authorization" not in headers for _, headers in origin.requests
        )


@pytest.mark.skipif(
    not Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome").is_file(),
    reason="The optional local Chrome runtime is not installed",
)
def test_actual_chrome_dead_proxy_does_not_fall_back_to_direct(installed):
    from playwright.sync_api import Error, sync_playwright

    installed.proxy = "http://127.0.0.1:1"
    with server() as origin, sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            channel="chrome", headless=True, timeout=15000
        )
        try:
            context = browser.new_context()
            page = context.new_page()
            target = address(origin) + "/ok"
            with pytest.raises(Error):
                page.goto(target, wait_until="domcontentloaded", timeout=3000)
            with pytest.raises(Error):
                context.request.get(target, timeout=3000)
        finally:
            browser.close()
        assert not origin.requests
