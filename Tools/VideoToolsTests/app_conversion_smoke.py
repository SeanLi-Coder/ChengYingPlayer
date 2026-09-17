"""Verify conversion using the frozen helper and FFmpeg shipped inside the app."""

from __future__ import annotations

import argparse
import hashlib
import json
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


def run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {result.stderr[-4000:]}")
    return result.stdout


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def smoke(tools_directory: Path) -> None:
    ffmpeg = tools_directory / "ffmpeg"
    ffprobe = tools_directory / "ffprobe"
    helper = tools_directory / "chengying-video-tools-helper"
    for executable in (ffmpeg, ffprobe, helper):
        if not executable.is_file():
            raise RuntimeError(f"Missing bundled executable: {executable}")

    with tempfile.TemporaryDirectory(prefix="chengying-conversion-smoke-") as directory:
        root = Path(directory).resolve()
        source = root / "camera sample 'original'.mp4"
        run([
            str(ffmpeg), "-v", "error", "-nostdin", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=24:duration=1.5", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=1.5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", str(source),
        ])
        source_digest = digest(source)
        events: queue.Queue[dict[str, Any] | BaseException] = queue.Queue()
        with (root / "helper.stderr").open("wb") as error_log:
            process = subprocess.Popen(
                [str(helper), "--ffmpeg", str(ffmpeg), "--ffprobe", str(ffprobe), "--stdio"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_log,
                text=True, encoding="utf-8", bufsize=1,
            )
            assert process.stdout is not None and process.stdin is not None

            def read_events() -> None:
                try:
                    assert process.stdout is not None
                    for line in process.stdout:
                        event = json.loads(line)
                        if not isinstance(event, dict):
                            raise TypeError("Helper emitted a non-object event")
                        events.put(event)
                    events.put(EOFError("Helper closed its event stream"))
                except Exception as exc:  # noqa: BLE001 - forward reader failures to the main thread
                    events.put(exc)

            reader = threading.Thread(target=read_events, daemon=True)
            reader.start()

            def receive(timeout: float = 60) -> dict[str, Any]:
                event = events.get(timeout=timeout)
                if isinstance(event, BaseException):
                    detail = (root / "helper.stderr").read_text(encoding="utf-8", errors="replace")[-6000:]
                    event.add_note(f"Frozen helper stderr: {detail}")
                    raise event
                return event

            def send(request: dict[str, Any]) -> None:
                assert process.stdin is not None
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()

            try:
                ready = receive()
                assert ready["type"] == "ready" and "convert" in ready["operations"], ready
                outputs: set[Path] = set()
                for index, (target_format, mode) in enumerate([
                    (None, None), ("mkv", "copy"), ("mov", "h264"),
                    ("mp4", "hevc"), (None, None),
                ]):
                    task_id = f"conversion-smoke-{index}"
                    request = {
                        "id": task_id, "command": "start", "operation": "convert",
                        "input_path": str(source),
                    }
                    if target_format is not None:
                        request["target_format"] = target_format
                    if mode is not None:
                        request["conversion_mode"] = mode
                    send(request)
                    deadline = time.monotonic() + 90
                    accepted = False
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError("Frozen conversion did not finish")
                        event = receive(remaining)
                        assert event.get("id") == task_id, event
                        if event["type"] == "accepted":
                            accepted = True
                        elif event["type"] == "progress":
                            assert 0 <= event["progress"] < 100, event
                        else:
                            assert accepted and event["type"] == "completed", event
                            break
                    output = Path(event["output_path"])
                    assert output.is_absolute() and output.is_file()
                    assert output.parent == root and output != source and output not in outputs
                    assert output.suffix == f".{target_format or 'mp4'}"
                    outputs.add(output)
                    metadata = json.loads(run([
                        str(ffprobe), "-v", "error", "-show_streams", "-show_format",
                        "-of", "json", str(output),
                    ]))
                    video, audio = metadata["streams"]
                    assert video["codec_name"] == ("hevc" if mode == "hevc" else "h264")
                    assert (video["width"], video["height"]) == (160, 90)
                    assert video["pix_fmt"] == "yuv420p" and audio["codec_name"] == "aac"
                    assert abs(float(metadata["format"]["duration"]) - 1.5) < 0.12
                    assert digest(source) == source_digest
                    print(f"PASS: frozen {target_format or 'mp4'} / {mode or 'copy'} conversion")
                assert len(outputs) == 5
                assert not list(root.glob(".conversion-*")), "Partial outputs were left behind"
                send({"id": "smoke-shutdown", "command": "shutdown"})
                assert process.wait(timeout=15) == 0
                print("PASS: frozen conversion preserves the source and never overwrites outputs")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                process.stdin.close()
                reader.join(timeout=5)
                process.stdout.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--app", type=Path)
    group.add_argument("--tools-directory", type=Path)
    args = parser.parse_args()
    directory = args.app / "Contents" / "MacOS" if args.app else args.tools_directory
    smoke(directory.resolve(strict=True))


if __name__ == "__main__":
    main()
