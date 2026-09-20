"""Stress rotation in the real App using a temporary copy of the source video.

Keyboard mode covers the native permanent-rotation shortcut and frozen helper.
IPC mode covers preview rotation and real rendering only, not permanent export.
Auto mode uses keyboard events only when posting is already authorized. It never
requests Accessibility access, changes defaults, or edits the supplied source.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from app_loop_smoke import IPC, connect, make_video, same_path, stop_app, wait_until


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
        return value.hexdigest()


def rotation_outputs(source: Path, degrees: int) -> set[Path]:
    """The helper may change containers to preserve the original tracks."""
    stem = f"{source.stem}_rotated_{degrees or 360}"
    return {
        path for path in source.parent.glob(stem + "*")
        if path.is_file() and path.suffix.lower() in {".mp4", ".m4v", ".mov", ".mkv"}
        and (path.stem == stem
             or path.stem.startswith(stem + "_") and path.stem[len(stem) + 1:].isdigit())
    }


def new_rotation_outputs(source: Path, degrees: int, previous: set[Path]) -> list[Path]:
    return sorted(rotation_outputs(source, degrees) - previous)


def probe_video(ffprobe: Path, source: Path) -> dict:
    result = subprocess.run(
        [str(ffprobe), "-v", "error", "-show_streams", "-of", "json", str(source)],
        check=True, capture_output=True, text=True, timeout=30,
    )
    videos = [stream for stream in json.loads(result.stdout)["streams"]
              if stream.get("codec_type") == "video"]
    if not videos:
        raise AssertionError(f"No video stream in {source.name}")
    return videos[0]


def expected_dimensions(video: dict, degrees: int) -> tuple[int, int]:
    rotation = next((item["rotation"] for item in video.get("side_data_list", [])
                     if "rotation" in item), video.get("tags", {}).get("rotate", 0))
    rotation = float(rotation)
    if not math.isfinite(rotation) or abs(rotation / 90 - round(rotation / 90)) > 0.001:
        raise AssertionError("The smoke input must use a right-angle display rotation")
    width, height = int(video["width"]), int(video["height"])
    if (round(rotation / 90) + degrees // 90) % 2:
        width, height = height, width
    return width, height


def check_export_metadata(video: dict, dimensions: tuple[int, int]) -> None:
    actual = int(video["width"]), int(video["height"])
    if actual != dimensions:
        raise AssertionError(f"Unexpected rotated dimensions: {actual}, expected {dimensions}")
    if float(video.get("tags", {}).get("rotate", 0)) % 360:
        raise AssertionError("Export retained rotation metadata instead of baking the transform")
    if any(item.get("side_data_type") == "Display Matrix" or float(item.get("rotation", 0)) % 360
           for item in video.get("side_data_list", [])):
        raise AssertionError("Export retained a display transform instead of baking the transform")


def check_playback(ipc: IPC, source: Path) -> None:
    if not same_path(ipc.get("path", optional=True), source):
        raise AssertionError("Rotation changed or unloaded the original playback source")
    if ipc.get("time-pos", optional=True) is None:
        raise AssertionError("Rotation lost the decoder timestamp")


def wait_rotation(ipc: IPC, degrees: int) -> None:
    wait_until(lambda: ipc.get("video-rotate") == degrees,
               f"native rotation to reach {degrees} degrees", timeout=8)


def post_keys(driver: Path, process: subprocess.Popen, sequence: str, interval: float) -> None:
    result = subprocess.run(
        [str(driver), str(process.pid), sequence, str(interval)],
        capture_output=True, text=True, timeout=15 + len(sequence) * interval, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Native key driver failed: {result.stderr.strip()}")
    print(result.stdout.strip(), flush=True)


def exercise(
    ipc: IPC, process: subprocess.Popen, source: Path, *, driver: Path | None,
    rounds: int, interval: float, export_timeout: float, ffprobe: Path, ffmpeg: Path,
) -> None:
    wait_until(lambda: same_path(ipc.get("path", optional=True), source), "test media to load")
    wait_until(lambda: ipc.get("time-pos", optional=True) is not None, "first decoded timestamp")
    wait_until(lambda: ipc.get("pause") is False, "AppKit to finish opening media", timeout=15)
    print(f"DECODER: hwdec-current={ipc.get('hwdec-current', optional=True)!r}", flush=True)
    ipc.set("loop-file", "inf")
    original_digest = digest(source)
    degrees = int(ipc.get("video-rotate")) % 360
    if driver is not None and degrees:
        raise AssertionError("A fresh shortcut test must start without preview rotation")
    for index in range(rounds):
        # Exercise both paused rendering and active decoder reconfiguration.
        ipc.set("pause", index % 2 == 0)
        sequence = ("RRRRRLLLLRR" if index % 2 == 0 else "LLLLLRRRRLL")
        if driver is not None:
            post_keys(driver, process, sequence, interval)
            degrees = (degrees + 90 * (sequence.count("R") - sequence.count("L"))) % 360
        else:
            for direction in sequence:
                degrees = (degrees + (90 if direction == "R" else -90)) % 360
                ipc.set("video-rotate", degrees)
                if interval:
                    time.sleep(interval)
        wait_rotation(ipc, degrees)
        check_playback(ipc, source)
        print(f"PASS: Rotation burst {index + 1}/{rounds}, final angle {degrees}", flush=True)
        # Let the shortcut's first export begin before the next burst queues work.
        time.sleep(0.3)
    if driver is not None:
        # Finish at an asymmetric angle and require the corresponding final export.
        previous_outputs = rotation_outputs(source, 90)
        final_keys = "R" * (((90 - degrees) % 360) // 90 or 4)
        post_keys(driver, process, final_keys, interval)
        degrees = 90
        wait_rotation(ipc, degrees)
        suffix = degrees or 360

        def exported():
            check_playback(ipc, source)
            return new_rotation_outputs(source, suffix, previous_outputs)

        outputs = wait_until(exported, f"permanent {suffix}-degree output", timeout=export_timeout)
        dimensions = expected_dimensions(probe_video(ffprobe, source), degrees)
        for output in outputs:
            check_export_metadata(probe_video(ffprobe, output), dimensions)
            subprocess.run(
                [str(ffmpeg), "-v", "error", "-xerror", "-nostdin", "-i", str(output),
                 "-map", "0:v:0", "-t", "1", "-f", "null", "-"],
                check=True, capture_output=True, timeout=30,
            )
        print(f"PASS: Native permanent rotation published {len(outputs)} final-angle output(s)", flush=True)
    ipc.set("pause", False)
    first_time = ipc.get("time-pos")
    wait_until(lambda: ipc.get("time-pos") != first_time, "decoder playback to continue after rotation")
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        check_playback(ipc, source)
        time.sleep(0.05)
    if digest(source) != original_digest:
        raise AssertionError("Rotation modified the copied source video")
    print("PASS: Original playback source is unchanged and decoding continues", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="Read-only input; playback uses a temporary copy")
    parser.add_argument("--mode", choices=("auto", "keyboard", "ipc"), default="auto")
    parser.add_argument("--hwdec", default="auto", help="mpv hardware decoder option")
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--interval", type=float, default=0.012)
    parser.add_argument("--export-timeout", type=float, default=120)
    parser.add_argument("--keep-artifacts", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.rounds <= 100:
        parser.error("rounds must be between 1 and 100")
    if not math.isfinite(args.interval) or not 0 <= args.interval <= 0.25:
        parser.error("interval must be finite and between 0 and 0.25 seconds")
    if not math.isfinite(args.export_timeout) or not 1 <= args.export_timeout <= 600:
        parser.error("export timeout must be finite and between 1 and 600 seconds")
    app = args.app.resolve(strict=True)
    source_input = args.source.resolve(strict=True) if args.source else None
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    binaries = app / "Contents/MacOS"
    executable = binaries / metadata["CFBundleExecutable"]
    for path in (executable, binaries / "ffmpeg", binaries / "ffprobe"):
        if not path.is_file():
            parser.error(f"The App is missing {path.name}")
    directory = Path(tempfile.mkdtemp(prefix="chengying-rotation-", dir="/tmp"))
    app_log = directory / "app.log"
    source = directory / ("sample" + source_input.suffix if source_input else "sample.mp4")
    ipc = None
    process = None
    failed = False
    input_digest = digest(source_input) if source_input else None
    try:
        driver = None
        if args.mode != "ipc":
            candidate = directory / "RotationKeyDriver"
            subprocess.run(
                ["xcrun", "swiftc", str(Path(__file__).with_name("RotationKeyDriver.swift")),
                 "-o", str(candidate)], check=True, capture_output=True, timeout=60,
            )
            permission = subprocess.run([str(candidate), "--preflight"], capture_output=True,
                                        text=True, timeout=5, check=False)
            if permission.returncode == 0:
                driver = candidate
            elif permission.returncode != 77 or args.mode == "keyboard":
                raise RuntimeError(permission.stderr.strip())
            else:
                print("SKIP: Native shortcuts require existing event-post permission; using IPC preview only",
                      flush=True)
        print(f"MODE: {'native permanent-rotation shortcuts' if driver else 'IPC preview rotation only'}; "
              f"hwdec={args.hwdec}; artifacts={directory}", flush=True)
        if source_input:
            shutil.copyfile(source_input, source)
        else:
            make_video(binaries / "ffmpeg", source)
        command = [
            str(executable), "--no-stdin", f"--mpv-input-ipc-server={directory / 'ipc.sock'}",
            "--mpv-pause=yes", "--mpv-config=no", f"--mpv-hwdec={args.hwdec}",
            "-enableAdvancedSettings", "YES", "-enableLogging", "YES", "-logLevel", "0",
            # Foundation's argument domain overrides this process only.
            "-recordPlaybackHistory", "NO", "-recordRecentFiles", "NO",
            "-pauseWhenOpen", "NO", "-resumeLastPosition", "NO",
            "-enableRecentDocumentsWorkaround", "NO", "-playlistAutoAdd", "NO",
            "-enableThumbnailPreview", "NO", "-SUEnableAutomaticChecks", "NO", str(source),
        ]
        with app_log.open("wb") as log:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT)
            print(f"APP: PID {process.pid}, version {metadata.get('CFBundleShortVersionString')}, "
                  f"build {metadata.get('CFBundleVersion')}", flush=True)
            ipc = connect(directory / "ipc.sock", process)
            exercise(ipc, process, source, driver=driver, rounds=args.rounds,
                     interval=args.interval, export_timeout=args.export_timeout,
                     ffprobe=binaries / "ffprobe", ffmpeg=binaries / "ffmpeg")
        print("PASS: Real App rotation smoke completed", flush=True)
    except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        failed = True
        print(f"FAIL: Real App rotation smoke: {error}", file=sys.stderr, flush=True)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode("utf-8", errors="replace") if isinstance(error.stderr, bytes)
                  else error.stderr, file=sys.stderr)
        if ipc is not None:
            print(f"Recent mpv events: {list(ipc.events)!r}", file=sys.stderr)
    finally:
        if process is not None:
            print(f"APP: Exit status before cleanup: {process.poll()}", flush=True)
        stop_app(process, ipc)
        if source_input and digest(source_input) != input_digest:
            failed = True
            print("FAIL: Supplied source changed during the smoke test", file=sys.stderr)
        if failed and app_log.is_file():
            print("App output (last 24 KB):", file=sys.stderr)
            print(app_log.read_bytes()[-24576:].decode("utf-8", errors="replace"), file=sys.stderr)
        if args.keep_artifacts:
            print(f"ARTIFACTS: {directory}", flush=True)
        else:
            shutil.rmtree(directory)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
