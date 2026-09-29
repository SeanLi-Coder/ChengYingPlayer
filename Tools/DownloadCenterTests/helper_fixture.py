#!/usr/bin/env python3
"""Isolated stdio/loopback fixture; never imports app state or browser cookies."""
import fcntl
import hashlib
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import parse_qs, urlsplit

# Hold a shared lock until this process exits, including failure/timeout modes.
# The runner can await only its own fixtures without querying or signaling PIDs.
PROCESS_GUARD = open(os.environ["CHENGYING_WK_PROCESS_GUARD"], encoding="ascii")  # noqa: SIM115 -- Hold the lock until process exit.
fcntl.flock(PROCESS_GUARD, fcntl.LOCK_SH)
if PROCESS_GUARD.read(16) != "open\n":
    raise SystemExit("Native fixture workspace has closed.")

TOKEN = "native-test-session-" + "a" * 40
MODE = os.environ.get("CHENGYING_TEST_MODE", "ready")
ROOT = Path(__file__).resolve().parents[2]
VENDORED_ASSETS = ROOT / "Tools/DownloaderHelper/vendor/rednote/app/static"
DESKTOP_ASSETS = ROOT / "Tools/DownloaderHelper/static"
STOP = threading.Event()
DRAIN_OBSERVED = threading.Event()
UPDATE_LEASE = None
PROXY_LOCK = threading.RLock()
PROXY = {"enabled": False, "url": "", "read_error": "", "busy": False,
         "reads": 0, "writes": 0, "tests": 0, "config_writes": 0}
CONFIG = {"download_dir": "/tmp/fixture/downloads", "use_chrome_cookies": True, "chrome_profile": "Default"}
PROFILE_STATE = {"reads": 0, "jobs": [], "status": "ok"}
PROFILE_OPTIONS = [{"directory": "Profile 1", "has_cookie_database": True},
                   {"directory": "Profile 2", "has_cookie_database": True},
                   {"directory": "Profile 4", "has_cookie_database": False}]
DIAGNOSTICS = {"reads": 0, "mutations": 0, "error": "", "revision": 1}
FRONTEND_SAFETY_PROBES = """<script>
window.fixtureErrors = [];
addEventListener('error', event => fixtureErrors.push(event.message));
addEventListener('unhandledrejection', event => fixtureErrors.push(String(event.reason)));
window.fixtureClipboard = {mode: 'success', legacyResult: true, writes: [], legacyCopies: 0, selected: ''};
Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
  writeText(value) {
    fixtureClipboard.writes.push(String(value));
    return fixtureClipboard.mode === 'success' ? Promise.resolve() : Promise.reject(new Error('raw-clipboard-secret'));
  }
}});
const fixtureOriginalCommand = document.execCommand.bind(document);
document.execCommand = function(command, ...args) {
  if (String(command).toLowerCase() !== 'copy') return fixtureOriginalCommand(command, ...args);
  fixtureClipboard.legacyCopies++;
  const field = document.activeElement;
  fixtureClipboard.selected = field && typeof field.value === 'string'
    ? field.value.slice(field.selectionStart, field.selectionEnd) : String(getSelection());
  return fixtureClipboard.legacyResult;
};
window.fixtureRequests = [];
const fixtureOriginalFetch = window.fetch.bind(window);
window.fetch = function(input, options) {
  const url = new URL(typeof input === 'string' ? input : input.url, location.href);
  const method = options?.method || input?.method || 'GET';
  fixtureRequests.push({path: url.pathname, method: String(method).toUpperCase(), external: url.origin !== location.origin});
  if (url.origin !== location.origin) return Promise.reject(new Error('External fixture request blocked'));
  return fixtureOriginalFetch(input, options);
};
window.fixtureBeaconCalls = 0;
Object.defineProperty(navigator, 'sendBeacon', {configurable: true, value: () => {
  fixtureBeaconCalls++;
  return false;
}});
</script>"""
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


def proxy_status():
    parsed = urlsplit(PROXY["url"])
    return {"enabled": PROXY["enabled"], "configured": bool(PROXY["url"]),
            "display_url": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}" if PROXY["url"] else "",
            "has_credentials": bool(parsed.username or parsed.password)}


def proxy_snapshot():
    parsed = urlsplit(PROXY["url"])
    credentials = f"{parsed.username or ''}:{parsed.password or ''}".encode()
    return {**proxy_status(), "credential_digest": hashlib.sha256(credentials).hexdigest(),
            "reads": PROXY["reads"], "writes": PROXY["writes"], "tests": PROXY["tests"],
            "config_writes": PROXY["config_writes"], "download_dir": CONFIG["download_dir"]}


def profile_inventory():
    selected = CONFIG["chrome_profile"]
    choice = next((entry for entry in PROFILE_OPTIONS if entry["directory"] == selected), None)
    if selected is None:
        state = "automatic"
    elif PROFILE_STATE["status"] != "ok":
        state = "unverified"
    elif choice is None:
        state = "missing"
    else:
        state = "available" if choice["has_cookie_database"] else "cookie_database_missing"
    return {"schema_version": 1, "status": PROFILE_STATE["status"], "profiles": PROFILE_OPTIONS,
            "selected_profile": selected, "selected_status": state,
            "use_chrome_cookies": CONFIG["use_chrome_cookies"]}


def profile_snapshot():
    return {**profile_inventory(), "reads": PROFILE_STATE["reads"], "jobs": PROFILE_STATE["jobs"],
            "config_writes": PROXY["config_writes"]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def json_response(self, data, status=200):
        content = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)

    def proxy_error(self, code, status=503):
        self.json_response({"detail": {"code": code, "message": "Never expose raw fixture-secret details"}}, status)

    def do_PUT(self):
        self.fixture_mutation()

    def do_DELETE(self):
        self.fixture_mutation()

    def do_POST(self):
        self.fixture_mutation()

    def fixture_mutation(self):
        global UPDATE_LEASE
        if self.headers.get("Cookie") != "chengying_download_session=" + TOKEN:
            self.json_response({}, 401)
            return
        if self.path.startswith("/api/native/maintenance/"):
            parts = self.path.split("/")
            identifier = parts[4]
            if self.path.endswith("/commit"):
                DRAIN_OBSERVED.clear()
                self.json_response({"acquired": UPDATE_LEASE == identifier})
            elif self.command == "DELETE":
                if UPDATE_LEASE == identifier:
                    UPDATE_LEASE = None
                self.json_response({"released": True})
            else:
                acquired = UPDATE_LEASE in (None, identifier)
                if acquired:
                    UPDATE_LEASE = identifier
                self.json_response({"acquired": acquired})
            return
        if MODE != "frontend":
            self.json_response({}, 404)
            return
        if urlsplit(self.path).path == "/api/native/diagnostics":
            with PROXY_LOCK:
                DIAGNOSTICS["mutations"] += 1
            self.json_response({}, 405)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise ValueError("Invalid fixture payload length")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise TypeError("Invalid fixture payload")
        except (ValueError, TypeError):
            self.json_response({}, 400)
            return
        path = urlsplit(self.path).path
        with PROXY_LOCK:
            if path == "/api/fixture/profile-mode" and self.command == "POST":
                if payload.get("status") in {"ok", "cookie_permission_denied"}:
                    PROFILE_STATE["status"] = payload["status"]
                self.json_response(profile_snapshot())
            elif path == "/api/jobs" and self.command == "POST":
                # Record the synthetic saved identity only; never resolve or download the URL.
                PROFILE_STATE["jobs"].append({"chrome_profile": CONFIG["chrome_profile"],
                                              "use_chrome_cookies": CONFIG["use_chrome_cookies"]})
                self.json_response(fixture_job())
            elif path == "/api/fixture/diagnostics-mode" and self.command == "POST":
                if payload.get("error") in {"", "unavailable", "schema", "oversized"}:
                    DIAGNOSTICS["error"] = payload["error"]
                if payload.get("refresh") is True:
                    DIAGNOSTICS["revision"] += 1
                self.json_response(dict(DIAGNOSTICS))
            elif path == "/api/fixture/proxy-mode" and self.command == "POST":
                if "read_error" in payload:
                    PROXY["read_error"] = payload["read_error"]
                if "busy" in payload:
                    PROXY["busy"] = payload["busy"] is True
                self.json_response(proxy_snapshot())
            elif path == "/api/native/proxy" and self.command == "PUT":
                if PROXY["busy"]:
                    self.proxy_error("proxy_busy", 409)
                    return
                if "url" in payload:
                    PROXY["url"] = payload["url"]
                PROXY["enabled"] = payload["enabled"]
                PROXY["writes"] += 1
                if payload.get("url") == "" and payload["enabled"] is False:
                    PROXY["read_error"] = ""
                self.json_response(proxy_status())
            elif path == "/api/native/proxy/test" and self.command == "POST":
                PROXY["tests"] += 1
                # No actual outbound request or browser state is used by this fixture.
                self.json_response({"ok": True, "elapsed_ms": 125})
            elif path == "/api/config" and self.command == "PUT":
                CONFIG.update(payload)
                PROXY["config_writes"] += 1
                self.json_response(CONFIG)
            else:
                self.json_response({}, 404)

    def do_GET(self):
        if self.headers.get("Cookie") != "chengying_download_session=" + TOKEN:
            self.send_response(401)
            self.end_headers()
            return
        if self.path == "/api/native/activity":
            self.json_response({"known": MODE != "activity_unknown", "busy": UPDATE_LEASE is not None})
            if MODE == "update_drain" and UPDATE_LEASE is not None:
                DRAIN_OBSERVED.set()
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
            item = parse_qs(urlsplit(self.path).query).get("item_id", [""])[0]
            output = Path(os.environ["CHENGYING_TEST_OUTPUT"])
            if item == "image":
                output = output.with_suffix(".webp")
            content = json.dumps({"path": str(output), "media_type": "image" if item == "image" else "video"}).encode()
            mime = "application/json"
        elif MODE == "frontend":
            path = urlsplit(self.path).path
            if path == "/api/native/chrome-profiles":
                with PROXY_LOCK:
                    PROFILE_STATE["reads"] += 1
                    self.json_response(profile_inventory())
                return
            elif path == "/api/fixture/profile-mode":
                with PROXY_LOCK:
                    self.json_response(profile_snapshot())
                return
            elif path == "/api/native/diagnostics":
                with PROXY_LOCK:
                    DIAGNOSTICS["reads"] += 1
                    state = dict(DIAGNOSTICS)
                if state["error"] == "unavailable":
                    self.json_response({"detail": {"code": "diagnostics_unavailable", "message": "raw-diagnostic-secret"}}, 503)
                elif state["error"] == "schema":
                    self.json_response({"schema_version": 99, "text": "raw-diagnostic-secret"})
                elif state["error"] == "oversized":
                    self.json_response({"schema_version": 1, "text": "raw-diagnostic-secret" * 4000})
                else:
                    self.json_response({"schema_version": 1, "text": (
                        "ChengYing Download Center Diagnostics\n"
                        "schema_version=1\n"
                        f"fixture_revision={state['revision']}\n"
                        "job.1.platform=douyin\n"
                        "job.1.diagnostic_code=cookie_access_unknown\n"
                        "Privacy: no cookies, credentials, URLs or local paths.\n"
                    )})
                return
            elif path == "/api/fixture/diagnostics-mode":
                with PROXY_LOCK:
                    self.json_response(dict(DIAGNOSTICS))
                return
            elif path == "/api/native/proxy":
                with PROXY_LOCK:
                    PROXY["reads"] += 1
                    error = PROXY["read_error"]
                    first_read = PROXY["reads"] == 1
                    snapshot = proxy_status()
                if first_read:
                    STOP.wait(1)
                if error:
                    self.proxy_error("proxy_settings_unreadable" if error == "corrupt" else "proxy_unavailable")
                else:
                    self.json_response(snapshot)
                return
            elif path == "/api/fixture/proxy-mode":
                with PROXY_LOCK:
                    self.json_response(proxy_snapshot())
                return
            elif path == "/":
                page = (VENDORED_ASSETS / "index.html").read_text()
                page = page.replace("__APP_ID__", "native-fixture").replace("__APP_VERSION__", "1").replace("__BUILD_ID__", "fixture-build")
                page = page.replace("<head>", "<head>" + FRONTEND_SAFETY_PROBES)
                page = page.replace("</head>", "<script>new MutationObserver((records,observer)=>{const control=document.querySelector('#desktop-proxy-save');if(control){window.fixtureProxyInitiallyDisabled=control.disabled&&document.querySelector('#desktop-proxy-test').disabled&&document.querySelector('#desktop-proxy-url').disabled;observer.disconnect();}}).observe(document.documentElement,{childList:true,subtree:true});</script></head>")
                page = page.replace("</head>", '<link rel="stylesheet" href="/native/desktop.css"><script src="/native/desktop.js" defer></script></head>')
                page = page.replace("</head>", '<link rel="stylesheet" href="/native/chrome_profiles.css"><script src="/native/chrome_profiles.js" defer></script></head>')
                page = page.replace("</head>", '<link rel="stylesheet" href="/native/diagnostics.css"><script src="/native/diagnostics.js" defer></script></head>')
                content, mime = page.encode(), "text/html"
            elif path in {"/static/app.js", "/static/styles.css", "/static/favicon.svg", "/native/desktop.js", "/native/desktop.css", "/native/chrome_profiles.js", "/native/chrome_profiles.css", "/native/diagnostics.js", "/native/diagnostics.css"}:
                asset = (DESKTOP_ASSETS if path.startswith("/native/") else VENDORED_ASSETS) / path.rsplit("/", 1)[1]
                content = asset.read_bytes()
                mime = "application/javascript" if path.endswith(".js") else "text/css" if path.endswith(".css") else "image/svg+xml"
            elif path == "/api/health":
                content = json.dumps({"status": "ok", "app_id": "native-fixture", "version": "1", "build_id": "fixture-build",
                                      "source_build_id": "fixture-build", "restart_required": False}).encode()
                mime = "application/json"
            elif path == "/api/config":
                with PROXY_LOCK:
                    content = json.dumps(CONFIG).encode()
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
if MODE == "update_drain":
    DRAIN_OBSERVED.wait(timeout=10)
server.shutdown()
server.server_close()
