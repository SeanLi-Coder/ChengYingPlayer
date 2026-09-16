"""Exercise the built App's loop event handlers through real mpv JSON IPC.

Run on the disposable macOS CI desktop, after signing the application bundle.
This is an integration test of decoder events, not a synthetic keyboard test.
"""

from __future__ import annotations

import argparse
import json
import math
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque
from pathlib import Path


class IPC:
    def __init__(self, connection: socket.socket, process: subprocess.Popen):
        self.connection = connection
        self.process = process
        self.buffer = b""
        self.request_id = 0
        self.events: deque[dict] = deque(maxlen=24)
        self.trace: deque[dict] = deque(maxlen=32)

    def request(self, command: list, *, timeout: float = 5.0, optional: bool = False):
        self.request_id += 1
        request_id = self.request_id
        packet = {"command": command, "request_id": request_id}
        self.connection.sendall(json.dumps(packet).encode("utf-8") + b"\n")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                self.connection.settimeout(max(0.01, min(0.2, deadline - time.monotonic())))
                try:
                    data = self.connection.recv(65536)
                except TimeoutError:
                    if self.process.poll() is not None:
                        raise RuntimeError(f"App exited with status {self.process.returncode}")
                    continue
                if not data:
                    raise RuntimeError("App closed its IPC socket")
                self.buffer += data
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            if not line:
                continue
            message = json.loads(line)
            if message.get("request_id") != request_id:
                if "event" in message:
                    self.events.append(message)
                continue
            if message.get("error") != "success":
                if optional:
                    return None
                raise RuntimeError(f"IPC command {command!r} failed: {message}")
            return message.get("data")
        raise TimeoutError(f"Timed out waiting for IPC command {command!r}")

    def get(self, name: str, *, optional: bool = False):
        return self.request(["get_property", name], optional=optional)

    def set(self, name: str, value):
        return self.request(["set_property", name, value])

    def snapshot(self) -> dict:
        state = {
            "time": self.get("time-pos", optional=True),
            "seeking": self.get("seeking", optional=True),
            "pause": self.get("pause", optional=True),
            "path": self.get("path", optional=True),
            "a": self.get("ab-loop-a", optional=True),
            "b": self.get("ab-loop-b", optional=True),
            "count": self.get("ab-loop-count", optional=True),
            "remaining_loops": self.get("remaining-ab-loops", optional=True),
            "idle": self.get("idle-active", optional=True),
        }
        self.trace.append(state)
        return state


def wait_until(predicate, description: str, *, timeout: float = 8.0):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.02)
    raise AssertionError(f"Timed out: {description}; last result={last!r}")


def same_path(actual, expected: Path) -> bool:
    return isinstance(actual, str) and Path(actual).resolve() == expected.resolve()


def inside(position, start: float, end: float) -> bool:
    return isinstance(position, (int, float)) and math.isfinite(position) and start <= position < end


def settled_in_range(ipc: IPC, media: Path, start: float, end: float) -> dict:
    def ready():
        state = ipc.snapshot()
        if state["path"] is not None and not same_path(state["path"], media):
            raise AssertionError(f"Loop changed media unexpectedly: {state}")
        return state if inside(state["time"], start, end) and state["seeking"] is False else None

    return wait_until(ready, f"playback to settle within [{start}, {end})")


def monitor_range(
    ipc: IPC,
    media: Path,
    start: float,
    end: float,
    *,
    duration: float = 1.2,
    playing: bool = False,
    require_progress: bool = False,
):
    settled_in_range(ipc, media, start, end)
    deadline = time.monotonic() + duration
    outside_since = None
    valid_positions = []
    while time.monotonic() < deadline:
        state = ipc.snapshot()
        now = time.monotonic()
        if not same_path(state["path"], media):
            raise AssertionError(f"Playback unloaded or switched media during the loop: {state}")
        if playing and state["pause"] is not False:
            raise AssertionError(f"Loop unexpectedly paused during ordinary playback: {state}")
        if inside(state["time"], start, end):
            outside_since = None
            valid_positions.append(state["time"])
        else:
            if outside_since is None:
                outside_since = now
            # IPC deliberately bypasses the UI's pre-seek clamp. Allow a bounded
            # asynchronous decoder correction, never persistent out-of-range playback.
            if now - outside_since > 0.75:
                raise AssertionError(f"Playback remained outside [{start}, {end}): {state}")
        time.sleep(0.012)
    settled_in_range(ipc, media, start, end)
    if len(valid_positions) < 3:
        raise AssertionError("Too few in-range samples to verify actual decoder playback")
    if require_progress and max(valid_positions) - min(valid_positions) < 1 / 30:
        raise AssertionError(f"Decoder did not visibly progress while playing: {valid_positions}")


def configure_loop(ipc: IPC, start: float, end: float):
    ipc.set("ab-loop-count", 0)
    ipc.set("ab-loop-a", start)
    ipc.set("ab-loop-b", end)
    ipc.set("ab-loop-count", "inf")


def clear_loop(ipc: IPC):
    ipc.set("ab-loop-count", 0)
    ipc.set("ab-loop-a", "no")
    ipc.set("ab-loop-b", "no")


def check_paused(ipc: IPC):
    if ipc.get("pause") is not True:
        raise AssertionError("Paused navigation unexpectedly resumed playback")


def exercise(ipc: IPC, first: Path, second: Path):
    wait_until(lambda: same_path(ipc.get("path", optional=True), first), "first test media to load")
    wait_until(lambda: ipc.get("time-pos", optional=True) is not None, "first video timestamp")
    ipc.set("pause", True)
    # IPC can see libmpv's first timestamp before AppKit processes fileStarted
    # and fileLoaded. Native keyboard actions remain disabled during this phase.
    # Let queued startup/UI callbacks settle before bypassing them through IPC.
    monitor_range(ipc, first, 0, 3, duration=2.0)
    check_paused(ipc)
    ipc.request(["seek", 0, "absolute+exact"])
    configure_loop(ipc, 0, 1)
    settled_in_range(ipc, first, 0, 1)
    if float(ipc.get("ab-loop-a")) != 0:
        raise AssertionError("A=0 was not retained by mpv")
    if float(ipc.get("ab-loop-b")) != 1 or str(ipc.get("ab-loop-count")) != "inf":
        raise AssertionError(f"Loop configuration was not retained: {ipc.snapshot()}")
    print("PASS: Zero-start loop is active in the real App", flush=True)

    for speed in (16.0, 0.1):
        ipc.set("pause", True)
        ipc.request(["seek", 0.2, "absolute+exact"])
        settled_in_range(ipc, first, 0, 1)
        ipc.set("speed", speed)
        ipc.set("pause", False)
        monitor_range(ipc, first, 0, 1, duration=1.6, playing=True, require_progress=True)
        print(f"PASS: {speed:g}x playback remains inside the loop and continues decoding", flush=True)

    ipc.set("pause", True)
    ipc.set("speed", 1.0)
    ipc.request(["seek", 2.5, "absolute+exact"])
    monitor_range(ipc, first, 0, 1, duration=0.35)
    check_paused(ipc)
    print("PASS: A paused seek beyond B is corrected without resuming", flush=True)

    configure_loop(ipc, 0.5, 1.5)
    ipc.request(["seek", 0.8, "absolute+exact"])
    settled_in_range(ipc, first, 0.5, 1.5)
    ipc.request(["seek", -5, "relative+exact"])
    monitor_range(ipc, first, 0.5, 1.5, duration=0.35)
    check_paused(ipc)
    print("PASS: A negative relative seek returns to the nonzero A boundary", flush=True)

    ipc.request(["seek", 0.5, "absolute+exact"])
    settled_in_range(ipc, first, 0.5, 1.5)
    ipc.request(["frame-back-step"])
    monitor_range(ipc, first, 0.5, 1.5, duration=0.35)
    check_paused(ipc)
    ipc.request(["seek", 1.5 - 1 / 30, "absolute+exact"])
    settled_in_range(ipc, first, 0.5, 1.5)
    ipc.request(["frame-step"])
    monitor_range(ipc, first, 0.5, 1.5, duration=0.35)
    check_paused(ipc)
    print("PASS: Forward and backward frame stepping cannot remain outside A/B", flush=True)

    clear_loop(ipc)
    ipc.request(["seek", 2.4, "absolute+exact"])
    monitor_range(ipc, first, 2.35, 2.5, duration=0.35)
    print("PASS: Clearing the loop restores unrestricted file navigation", flush=True)

    configure_loop(ipc, 0, 1)
    ipc.request(["seek", 3.5, "absolute+exact"])
    monitor_range(ipc, first, 0, 1, duration=0.4)
    check_paused(ipc)
    if ipc.get("eof-reached") is not False:
        raise AssertionError("Loop did not recover from the EOF seek")
    ipc.set("pause", False)
    monitor_range(ipc, first, 0, 1, duration=1.5, playing=True, require_progress=True)
    print("PASS: EOF seek recovers into the same file and looping resumes", flush=True)

    ipc.set("pause", True)
    ipc.request(["loadfile", str(second), "replace"])
    wait_until(lambda: same_path(ipc.get("path", optional=True), second), "replacement media to load")
    wait_until(lambda: ipc.get("time-pos", optional=True) is not None, "replacement video timestamp")
    wait_until(
        lambda: ipc.get("ab-loop-a") == "no" and ipc.get("ab-loop-b") == "no"
        and str(ipc.get("ab-loop-count")) == "0",
        "old loop markers to be cleared for replacement media",
    )
    ipc.set("pause", True)
    ipc.request(["seek", 2.4, "absolute+exact"])
    monitor_range(ipc, second, 2.35, 2.5, duration=0.35)
    print("PASS: Media replacement clears the previous loop and recovery state", flush=True)


def make_video(ffmpeg: Path, output: Path):
    command = [
        str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=3",
        "-an", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-g", "90", "-keyint_min", "90", "-sc_threshold", "0", "-bf", "3",
        "-movflags", "+faststart", str(output),
    ]
    subprocess.run(command, check=True, timeout=45, capture_output=True)


def connect(path: Path, process: subprocess.Popen) -> IPC:
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"App exited before opening IPC: status {process.returncode}")
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.connect(str(path))
            return IPC(connection, process)
        except (FileNotFoundError, ConnectionRefusedError):
            connection.close()
            time.sleep(0.05)
    raise TimeoutError("App did not open its IPC socket within 25 seconds")


def stop_app(process: subprocess.Popen | None, ipc: IPC | None):
    if ipc is not None:
        try:
            ipc.request(["quit"], timeout=2)
        except (OSError, RuntimeError, TimeoutError):
            pass
        finally:
            ipc.connection.close()
    if process is None or process.poll() is not None:
        return
    try:
        process.wait(timeout=6)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=4)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Signed, built ChengYing.app bundle")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    executable = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
    ffmpeg = app / "Contents/MacOS/ffmpeg"
    if not executable.is_file() or not ffmpeg.is_file():
        parser.error("The App must contain its executable and bundled FFmpeg")

    # Keep the socket path below macOS's sockaddr_un limit; RUNNER_TEMP can be long.
    with tempfile.TemporaryDirectory(prefix="chengying-loop-", dir="/tmp") as temporary:
        directory = Path(temporary)
        first, second = directory / "sample.mp4", directory / "replacement.mp4"
        app_log = directory / "app.log"
        ipc = None
        process = None
        failed = False
        try:
            make_video(ffmpeg, first)
            make_video(ffmpeg, second)
            command = [
                str(executable),
                "--no-stdin", f"--mpv-input-ipc-server={directory / 'ipc.sock'}",
                "--mpv-pause=yes", "--mpv-config=no", "--mpv-hwdec=no",
                "-enableAdvancedSettings", "YES", "-enableLogging", "YES", "-logLevel", "0",
                # Foundation's argument domain overrides preferences for this
                # process only. Do not use defaults write or change the user's HOME.
                "-recordPlaybackHistory", "NO", "-recordRecentFiles", "NO",
                "-resumeLastPosition", "NO", "-enableRecentDocumentsWorkaround", "NO",
                "-playlistAutoAdd", "NO", "-enableThumbnailPreview", "NO",
                "-SUEnableAutomaticChecks", "NO", str(first),
            ]
            with app_log.open("wb") as log:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                ipc = connect(directory / "ipc.sock", process)
                exercise(ipc, first, second)
            print("PASS: Real App loop integration smoke completed", flush=True)
        except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            failed = True
            print(f"FAIL: Real App loop integration smoke: {error}", file=sys.stderr, flush=True)
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                print(error.stderr.decode("utf-8", errors="replace"), file=sys.stderr)
            if ipc is not None:
                print(f"Recent playback samples: {list(ipc.trace)!r}", file=sys.stderr)
                print(f"Recent mpv events: {list(ipc.events)!r}", file=sys.stderr)
        finally:
            stop_app(process, ipc)
            if failed and app_log.is_file():
                print("App output (last 24 KB):", file=sys.stderr)
                print(app_log.read_bytes()[-24576:].decode("utf-8", errors="replace"), file=sys.stderr)
        return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
