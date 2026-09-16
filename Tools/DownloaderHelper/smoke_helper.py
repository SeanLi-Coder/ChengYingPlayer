"""Offline protocol/security/lifecycle smoke test for source or frozen helpers."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

COOKIE_NAME = "chengying_download_session"


def read_event(child, timeout=30):
    buffer = getattr(child, "_chengying_protocol_buffer", bytearray())
    child._chengying_protocol_buffer = buffer
    deadline = time.monotonic() + timeout
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        while b"\n" not in buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AssertionError("Helper did not return a protocol event in time")
            chunk = os.read(child.stdout.fileno(), 4096)
            if not chunk:
                raise AssertionError(
                    f"Helper closed its protocol pipe (exit={child.poll()})"
                )
            buffer.extend(chunk)
            if len(buffer) > 65_536:
                raise AssertionError("Helper exceeded the protocol message limit")
        newline = buffer.index(b"\n")
        data = bytes(buffer[:newline])
        del buffer[: newline + 1]
    return json.loads(data)


def request(url, *, token=None, origin=None):
    headers = {}
    if token:
        headers["Cookie"] = f"{COOKIE_NAME}={token}"
    if origin:
        headers["Origin"] = origin
    try:
        with build_opener(ProxyHandler({})).open(
            Request(url, headers=headers), timeout=5
        ) as response:
            return response.status, response.read(), response.headers
    except HTTPError as exc:
        return exc.code, exc.read(), exc.headers


def run_smoke(command, ffmpeg, ffprobe):
    with tempfile.TemporaryDirectory(prefix="chengying-download-smoke-") as temporary:
        root = Path(temporary).resolve()
        arguments = [
            *command,
            "--stdio",
            "--data-dir",
            str(root / "data"),
            "--download-dir",
            str(root / "downloads"),
            "--ffmpeg",
            str(ffmpeg),
            "--ffprobe",
            str(ffprobe),
        ]
        children = []
        with (root / "stderr.log").open("wb") as diagnostic:

            def launch():
                child = subprocess.Popen(
                    arguments,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=diagnostic,
                )
                children.append(child)
                return child

            try:
                child = launch()
                event = read_event(child)
                assert event["type"] == "ready", event.get("code")
                assert event["protocol_version"] == 1
                assert event["pid"] == child.pid
                url, token = event["url"], event["token"]
                assert url.startswith("http://127.0.0.1:")
                assert len(token) >= 48
                assert request(url)[0] == 403
                assert request(url, token="wrong")[0] == 403
                assert (
                    request(url, token=token, origin="https://example.invalid")[0]
                    == 403
                )
                status, body, headers = request(url, token=token)
                assert status == 200 and b"/native/desktop.js" in body
                assert token.encode() not in body
                assert "frame-ancestors 'none'" in headers["content-security-policy"]
                status, body, _ = request(url + "api/health", token=token)
                health = json.loads(body)
                assert status == 200 and health["status"] == "ok"
                assert health["build_id"] == health["source_build_id"]
                assert health["restart_required"] is False
                assert request(url + "static/app.js", token=token)[0] == 200
                assert request(url + "native/desktop.js", token=token)[0] == 200
                assert request(url + "api/jobs", token=token)[1] == b"[]"
                config = json.loads(request(url + "api/config", token=token)[1])
                assert config["download_dir"] == str(root / "downloads")
                assert config["use_chrome_cookies"] is True
                duplicate = launch()
                rejected = read_event(duplicate)
                assert (
                    rejected["type"] == "failed"
                    and rejected["code"] == "already_running"
                )
                assert duplicate.wait(timeout=10) != 0
                child.stdin.write(b'{"command":"ping"}\n')
                child.stdin.flush()
                assert read_event(child)["type"] == "pong"
                child.stdin.write(b'{"command":"shutdown"}\n')
                child.stdin.flush()
                assert read_event(child)["type"] == "stopped"
                assert child.wait(timeout=15) == 0
                # The same data directory is reusable, but the previous launch token is not.
                restarted = launch()
                fresh = read_event(restarted)
                assert fresh["type"] == "ready" and fresh["token"] != token
                assert request(fresh["url"], token=token)[0] == 403
                restarted.stdin.close()
                assert read_event(restarted)["type"] == "stopped"
                assert restarted.wait(timeout=15) == 0
                assert (root / "data").stat().st_mode & 0o077 == 0
            finally:
                for child in children:
                    if child.stdin and not child.stdin.closed:
                        child.stdin.close()
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            if os.getpgid(child.pid) == child.pid:
                                os.killpg(child.pid, signal.SIGKILL)
                            else:
                                child.kill()
                            child.wait(timeout=5)
        print(
            "Download center protocol, authentication, isolation, lock, restart, and EOF smoke checks passed."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    arguments = parser.parse_args()
    command = [str(arguments.helper.resolve())]
    if arguments.helper.suffix == ".py":
        command.insert(0, sys.executable)
    start = time.monotonic()
    run_smoke(command, arguments.ffmpeg.resolve(), arguments.ffprobe.resolve())
    print(f"Offline smoke checks completed in {time.monotonic() - start:.1f}s.")


if __name__ == "__main__":
    main()
