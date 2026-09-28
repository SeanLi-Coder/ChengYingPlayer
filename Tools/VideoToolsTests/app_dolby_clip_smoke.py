"""Exercise precise Dolby Vision clipping through the actual frozen app helper."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import queue
import subprocess
import tempfile
import threading
import time
from fractions import Fraction
from pathlib import Path
from typing import Any


def run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {result.stderr[-4000:]}")
    return result.stdout


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def metadata(ffprobe: Path, path: Path) -> dict[str, Any]:
    return json.loads(run([
        str(ffprobe), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path),
    ]))


def rpu_packets(ffmpeg: Path, path: Path) -> list[tuple[Fraction, int, str]]:
    # Deliberately independent of the production verifier. Normalization expands
    # inter-frame RPU references and includes extension blocks hidden by ffprobe.
    report = run([
        str(ffmpeg), "-v", "error", "-nostdin", "-copyts", "-i", str(path),
        "-map", "0:v:0", "-c:v", "copy", "-bsf:v",
        "hevc_mp4toannexb,dovi_rpu=compression=none,filter_units=pass_types=62",
        "-f", "framehash", "-",
    ])
    time_base = None
    packets = []
    for line in report.splitlines():
        if line.startswith("#tb 0:"):
            time_base = Fraction(line.partition(":")[2].strip())
        elif line and not line.startswith("#"):
            fields = [field.strip() for field in line.split(",")]
            assert time_base is not None and len(fields) == 6 and fields[0] == "0", line
            assert int(fields[4]) >= 8 and len(fields[5]) == 64, line
            packets.append((int(fields[2]) * time_base, int(fields[4]), fields[5]))
    assert packets and len({packet[0] for packet in packets}) == len(packets)
    return sorted(packets)


def decoded_frames(ffprobe: Path, path: Path) -> list[dict[str, Any]]:
    return json.loads(run([
        str(ffprobe), "-v", "error", "-select_streams", "v:0", "-show_frames",
        "-show_entries", "frame=pts_time:frame_side_data=side_data_type", "-of", "json", str(path),
    ]))["frames"]


def fixture_factory():
    path = Path(__file__).resolve().parents[1] / "VideoToolsHelper/tests/dovi_fixtures.py"
    spec = importlib.util.spec_from_file_location("clip_smoke_fixture", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.make_dovi_fixture


def check_clip(ffmpeg: Path, ffprobe: Path, source: Path, output: Path,
               start: Fraction, end: Fraction, compatibility: int) -> None:
    source_meta, output_meta = metadata(ffprobe, source), metadata(ffprobe, output)
    before = next(stream for stream in source_meta["streams"] if stream["codec_type"] == "video")
    after = next(stream for stream in output_meta["streams"] if stream["codec_type"] == "video")
    for key in ("codec_name", "width", "height", "pix_fmt", "color_range", "color_space",
                "color_transfer", "color_primaries", "sample_aspect_ratio"):
        assert after.get(key) == before.get(key), (key, before.get(key), after.get(key))
    configurations = [item for item in after.get("side_data_list", [])
                      if item.get("side_data_type") == "DOVI configuration record"]
    assert len(configurations) == 1, after
    config = configurations[0]
    assert config["dv_profile"] == 8 and config["dv_bl_signal_compatibility_id"] == compatibility
    assert (config["rpu_present_flag"], config["el_present_flag"], config["bl_present_flag"]) == (1, 0, 1)
    origin = Fraction(source_meta["format"].get("start_time", "0"))
    selected = [packet for packet in rpu_packets(ffmpeg, source) if origin + start <= packet[0] < origin + end]
    actual = rpu_packets(ffmpeg, output)
    assert len(selected) == len(actual) and len(actual) > 10, (len(selected), len(actual))
    tolerance = max(Fraction(before["time_base"]), Fraction(after["time_base"])) * 2
    for old, new in zip(selected, actual, strict=True):
        assert old[1:] == new[1:], "The complete normalized RPU changed"
        assert abs(old[0] - origin - start - new[0]) <= tolerance, (old[0], new[0])
    frames = decoded_frames(ffprobe, output)
    assert len(frames) == len(actual), "Decoded and RPU packet frame counts differ"
    for frame, packet in zip(frames, actual, strict=True):
        assert abs(Fraction(frame["pts_time"]) - packet[0]) <= tolerance
        assert any(item.get("side_data_type") == "Dolby Vision Metadata"
                   for item in frame.get("side_data_list", [])), "A decoded frame lost Dolby Vision"
    before_audio = [stream for stream in source_meta["streams"] if stream["codec_type"] == "audio"]
    after_audio = [stream for stream in output_meta["streams"] if stream["codec_type"] == "audio"]
    assert len(before_audio) == len(after_audio)
    for old, new in zip(before_audio, after_audio, strict=True):
        assert new["codec_name"] == "alac", new
        for key in ("sample_rate", "channels", "channel_layout"):
            assert old.get(key) == new.get(key), (key, old.get(key), new.get(key))
        assert abs(float(new["duration"]) - float(end - start)) < 0.06, new
    run([str(ffmpeg), "-v", "error", "-xerror", "-nostdin", "-i", str(output), "-f", "null", "-"])


def smoke(tools_directory: Path) -> None:
    ffmpeg, ffprobe, helper = (tools_directory / name for name in (
        "ffmpeg", "ffprobe", "chengying-video-tools-helper",
    ))
    for executable in (ffmpeg, ffprobe, helper):
        if not executable.is_file():
            raise RuntimeError(f"Missing bundled executable: {executable}")
    make_fixture = fixture_factory()
    with tempfile.TemporaryDirectory(prefix="chengying-dolby-clip-smoke-") as directory:
        root = Path(directory).resolve()
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
                except Exception as exc:  # noqa: BLE001 - propagate reader errors
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
                assert ready["type"] == "ready" and "clip" in ready["operations"], ready
                outputs: set[Path] = set()
                for case, (compatibility, variable_rate) in enumerate(((1, False), (4, False), (4, True))):
                    source_dir = root / f"source-{case}"
                    source_dir.mkdir()
                    source = make_fixture(str(ffmpeg), source_dir, compatibility=compatibility,
                                          variable_rate=variable_rate)
                    source_digest = digest(source)
                    start, end = Fraction("0.417"), Fraction("1.863")
                    # Repeat the first clip to check collision-safe publication.
                    for repeat in range(2 if case == 0 else 1):
                        task_id = f"dolby-clip-smoke-{case}-{repeat}"
                        send({
                            "id": task_id, "command": "start", "operation": "clip",
                            "input_path": str(source), "start": float(start), "end": float(end),
                            "output_directory": str(root),
                        })
                        deadline = time.monotonic() + 120
                        accepted = False
                        while True:
                            remaining = deadline - time.monotonic()
                            if remaining <= 0:
                                raise TimeoutError("Frozen Dolby Vision clip did not finish")
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
                        assert output.is_absolute() and output.is_file() and output.suffix == ".mp4"
                        assert output.parent == root and output != source and output not in outputs
                        outputs.add(output)
                        check_clip(ffmpeg, ffprobe, source, output, start, end, compatibility)
                        assert digest(source) == source_digest, "The source file changed"
                        print(f"PASS: frozen precise DV 8.{compatibility} clip, VFR={variable_rate}, repeat={repeat}",
                              flush=True)
                assert len(outputs) == 4
                assert not [path for path in root.iterdir() if path.name.startswith(".")], "Partial output remains"
                send({"id": "smoke-shutdown", "command": "shutdown"})
                assert process.wait(timeout=15) == 0
                print("PASS: frozen clips retain complete RPU data, exact frame ranges, audio and source files",
                      flush=True)
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
