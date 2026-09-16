#!/usr/bin/env python3
"""Isolated stdio/loopback fixture; never imports app state or browser cookies."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import parse_qs, urlsplit

TOKEN = "native-test-session-" + "a" * 40
MODE = os.environ.get("CHENGYING_TEST_MODE", "ready")
ROOT = Path(__file__).resolve().parents[2]
VENDORED_ASSETS = ROOT / "Tools/DownloaderHelper/vendor/rednote/app/static"
DESKTOP_ASSETS = ROOT / "Tools/DownloaderHelper/static"
STOP = threading.Event()
PAGE = b"""<!doctype html><html><body><h1>Native bridge fixture</h1>
<input id="download-dir"><p id="result">loaded</p>
<script>
window.chengyingDownloadCenter = {setDirectory: path => document.getElementById('download-dir').value = path};
function cancelTask() { document.getElementById('result').textContent = window.confirm('Cancel the fixture task?') ? 'yes' : 'no'; }
function playResult() { window.webkit.messageHandlers.downloadCenter.postMessage({action:'play',jobID:'job',itemID:'item',index:0}); }
</script></body></html>"""


def fixture_job():
    video = os.environ["CHENGYING_TEST_OUTPUT"]
    image = str(Path(video).with_suffix(".webp"))
    return {"id": "job", "source_url": "https://www.youtube.com/watch?v=fixture", "platform": "youtube",
            "source_kind": "item", "status": "completed", "author": "Native fixture", "revision": 1,
            "total_items": 2, "completed_items": 2, "failed_items": 0,
            "created_at": "2026-09-17T00:00:00Z", "updated_at": "2026-09-17T00:00:00Z",
            "items": [{"id": "video", "status": "completed", "title": "Fixture video", "media_type": "video",
                       "output_paths": [video], "resolution": "1920x1080", "progress": {"percent": 100}},
                      {"id": "image", "status": "completed", "title": "Fixture image", "media_type": "image",
                       "output_paths": [image], "progress": {"percent": 100}}]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.headers.get("Cookie") != "chengying_download_session=" + TOKEN:
            self.send_response(401)
            self.end_headers()
            return
        if self.path.startswith("/api/native/output?"):
            job = parse_qs(urlsplit(self.path).query).get("job_id", [""])[0]
            if job == "redirect":
                self.send_response(302)
                self.send_header("Location", "https://example.invalid/private")
                self.end_headers()
                return
            if job == "oversized_output":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "70000")
                self.end_headers()
                return
            if job == "missing":
                self.send_response(404)
                self.end_headers()
                return
            content = json.dumps({"path": os.environ["CHENGYING_TEST_OUTPUT"], "media_type": "video"}).encode()
            mime = "application/json"
        elif MODE == "frontend":
            path = urlsplit(self.path).path
            if path == "/":
                page = (VENDORED_ASSETS / "index.html").read_text()
                page = page.replace("__APP_ID__", "native-fixture").replace("__APP_VERSION__", "1").replace("__BUILD_ID__", "fixture-build")
                page = page.replace("<head>", "<head><script>window.fixtureErrors=[];addEventListener('error',e=>fixtureErrors.push(e.message));addEventListener('unhandledrejection',e=>fixtureErrors.push(String(e.reason)));</script>")
                page = page.replace("</head>", '<link rel="stylesheet" href="/native/desktop.css"><script src="/native/desktop.js" defer></script></head>')
                content, mime = page.encode(), "text/html"
            elif path in {"/static/app.js", "/static/styles.css", "/static/favicon.svg", "/native/desktop.js", "/native/desktop.css"}:
                asset = (DESKTOP_ASSETS if path.startswith("/native/") else VENDORED_ASSETS) / path.rsplit("/", 1)[1]
                content = asset.read_bytes()
                mime = "application/javascript" if path.endswith(".js") else "text/css" if path.endswith(".css") else "image/svg+xml"
            elif path == "/api/health":
                content = json.dumps({"status": "ok", "app_id": "native-fixture", "version": "1", "build_id": "fixture-build",
                                      "source_build_id": "fixture-build", "restart_required": False}).encode()
                mime = "application/json"
            elif path == "/api/config":
                content = json.dumps({"download_dir": "/tmp/fixture/downloads", "use_chrome_cookies": False, "chrome_profile": None}).encode()
                mime = "application/json"
            elif path in {"/api/jobs", "/api/jobs/job"}:
                content = json.dumps([fixture_job()] if path == "/api/jobs" else fixture_job()).encode()
                mime = "application/json"
            elif path == "/api/events":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                try:
                    self.wfile.write(("event: job\ndata: " + json.dumps(fixture_job()) + "\n\n").encode())
                    self.wfile.flush()
                    while not STOP.wait(1):
                        self.wfile.write(b": fixture heartbeat\n\n")
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            elif path == "/api/native/status":
                content, mime = b'{"chrome_installed": true}', "application/json"
            else:
                self.send_response(404)
                self.end_headers()
                return
        else:
            content, mime = PAGE, "text/html"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # The fixture has a fixed literal address; do not let HTTPServer perform
        # a system reverse-DNS lookup just to populate its display name.
        if self.server_address[0] != "127.0.0.1":
            raise ValueError("The native fixture must bind only to literal loopback")
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


if MODE == "timeout":
    sys.stdin.read()
    raise SystemExit(0)
if MODE in {"already_running", "startup_failed"}:
    print(json.dumps({"type": "failed", "code": MODE, "message": "Do not expose this raw detail"}), flush=True)
    sys.stdin.read()
    raise SystemExit(0)
server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ready = {"type": "ready", "protocol_version": 1, "url": f"http://127.0.0.1:{server.server_port}/",
         "token": TOKEN, "pid": os.getpid()}
if MODE == "wrong_pid":
    ready["pid"] += 10000
if MODE == "bad_origin":
    ready["url"] = "https://example.invalid/"
if MODE == "oversized":
    print("x" * 70000, flush=True)
else:
    print(json.dumps(ready), flush=True)
sys.stdin.read()
STOP.set()
server.shutdown()
server.server_close()
