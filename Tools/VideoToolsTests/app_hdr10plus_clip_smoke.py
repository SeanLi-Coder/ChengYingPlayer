"""Verify HDR10+ clipping through the shipped helper and codec, without user media."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import queue
import re
import subprocess
import tempfile
import threading
import time
from fractions import Fraction
from pathlib import Path

from app_dolby_clip_smoke import decoded_frames, digest, metadata, run


def packet_metadata(ffprobe: Path, path: Path) -> list[tuple[Fraction, str]]:
    """Independently inspect complete registered T.35 messages, not readable fields."""
    report = json.loads(run([
        str(ffprobe), "-v", "error", "-select_streams", "v:0", "-show_packets",
        "-show_streams", "-show_data", "-show_entries",
        "stream=time_base,extradata:packet=pts,data", "-of", "json", str(path),
    ]))

    def unhex(dump: str) -> bytes:
        result = bytearray()
        for line in dump.splitlines():
            if not line:
                continue
            address, separator, rest = line.partition(": ")
            assert separator and int(address, 16) == len(result), "Invalid packet dump offset"
            result.extend(bytes.fromhex(rest.split("  ", 1)[0]))
        return bytes(result)

    stream = report["streams"][0]
    extra = unhex(stream["extradata"])
    assert len(extra) >= 23 and extra[0] == 1, "Expected an HEVC configuration record"
    length_size = (extra[21] & 3) + 1
    time_base = Fraction(stream["time_base"])
    result = []
    for packet in report["packets"]:
        data = unhex(packet["data"])
        offset = 0
        messages = []
        while offset < len(data):
            assert offset + length_size <= len(data)
            size = int.from_bytes(data[offset:offset + length_size], "big")
            offset += length_size
            assert size >= 2 and offset + size <= len(data)
            nal = data[offset:offset + size]
            offset += size
            if (nal[0] >> 1) & 63 not in (39, 40):
                continue
            rbsp = re.sub(b"\x00\x00\x03(?=[\x00-\x03])", b"\x00\x00", nal[2:])
            cursor = 0
            while cursor < len(rbsp) and rbsp[cursor:] != b"\x80":
                values = []
                for _ in range(2):
                    value = 0
                    while True:
                        assert cursor < len(rbsp), "Truncated SEI header"
                        byte = rbsp[cursor]
                        cursor += 1
                        value += byte
                        if byte != 255:
                            break
                    values.append(value)
                payload_type, payload_size = values
                assert cursor + payload_size <= len(rbsp), "Truncated SEI message"
                payload = rbsp[cursor:cursor + payload_size]
                cursor += payload_size
                if payload_type == 4 and payload.startswith(b"\xb5\x00\x3c\x00\x01\x04"):
                    messages.append(hashlib.sha256(payload).hexdigest())
        assert len(messages) == 1, "Each video packet must retain one complete HDR10+ payload"
        result.append((int(packet["pts"]) * time_base, messages[0]))
    assert result and len({pts for pts, _ in result}) == len(result)
    return sorted(result)


def check_clip(ffmpeg: Path, ffprobe: Path, source: Path, output: Path,
               start: Fraction, end: Fraction, *, require_varying_metadata: bool = True) -> None:
    before, after = metadata(ffprobe, source), metadata(ffprobe, output)
    video = next(item for item in before["streams"] if item["codec_type"] == "video")
    encoded = next(item for item in after["streams"] if item["codec_type"] == "video")
    for key in ("codec_name", "width", "height", "pix_fmt", "color_range", "color_space",
                "color_transfer", "color_primaries", "sample_aspect_ratio"):
        assert video.get(key) == encoded.get(key), (key, video.get(key), encoded.get(key))
    origin = Fraction(before["format"].get("start_time", "0"))
    selected = [(pts, value) for pts, value in packet_metadata(ffprobe, source)
                if origin + start <= pts < origin + end]
    actual = packet_metadata(ffprobe, output)
    assert len(selected) == len(actual) > 10
    if require_varying_metadata:
        assert len({value for _, value in selected}) > 10, "Fixture metadata must vary between frames"
    tolerance = 2 * max(Fraction(video["time_base"]), Fraction(encoded["time_base"]))
    for (old_pts, old_value), (new_pts, new_value) in zip(selected, actual, strict=True):
        assert old_value == new_value, "Full HDR10+ payload changed or shifted to another frame"
        assert abs(old_pts - origin - start - new_pts) <= tolerance
    frames = decoded_frames(ffprobe, output)
    assert len(frames) == len(actual)
    for frame, (pts, _) in zip(frames, actual, strict=True):
        assert abs(Fraction(frame["pts_time"]) - pts) <= tolerance
        kinds = [item.get("side_data_type") for item in frame.get("side_data_list", [])]
        assert kinds.count("HDR Dynamic Metadata SMPTE2094-40 (HDR10+)") == 1
    old_audio = [item for item in before["streams"] if item["codec_type"] == "audio"]
    new_audio = [item for item in after["streams"] if item["codec_type"] == "audio"]
    assert len(old_audio) == len(new_audio)
    for old, new in zip(old_audio, new_audio, strict=True):
        assert new["codec_name"] == "alac"
        for key in ("sample_rate", "channels", "channel_layout"):
            assert old.get(key) == new.get(key), key
        assert abs(float(new["duration"]) - float(end - start)) < 0.06
    run([str(ffmpeg), "-v", "error", "-xerror", "-nostdin", "-i", str(output), "-f", "null", "-"])


def smoke(directory: Path) -> None:
    ffmpeg, ffprobe, helper = (directory / name for name in (
        "ffmpeg", "ffprobe", "chengying-video-tools-helper",
    ))
    assert all(path.is_file() for path in (ffmpeg, ffprobe, helper))
    fixture_path = Path(__file__).resolve().parents[1] / "VideoToolsHelper/tests/hdr10plus_fixtures.py"
    spec = importlib.util.spec_from_file_location("hdr10plus_smoke_fixture", fixture_path)
    assert spec and spec.loader
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    with tempfile.TemporaryDirectory(prefix="chengying-hdr10plus-smoke-") as temporary:
        root = Path(temporary).resolve()
        events: queue.Queue[dict | BaseException] = queue.Queue()
        with (root / "helper.stderr").open("wb") as stderr:
            process = subprocess.Popen(
                [str(helper), "--ffmpeg", str(ffmpeg), "--ffprobe", str(ffprobe), "--stdio"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                text=True, encoding="utf-8", bufsize=1,
            )
            assert process.stdin is not None and process.stdout is not None

            def read() -> None:
                try:
                    assert process.stdout is not None
                    for line in process.stdout:
                        events.put(json.loads(line))
                    events.put(EOFError("Frozen helper closed its event stream"))
                except Exception as error:  # noqa: BLE001 - propagate reader errors
                    events.put(error)

            def receive(timeout: float = 60) -> dict:
                event = events.get(timeout=timeout)
                if isinstance(event, BaseException):
                    raise event
                return event

            def send(request: dict) -> None:
                assert process.stdin is not None
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()

            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            try:
                assert receive()["type"] == "ready"
                outputs = set()
                cases = ((False, False, False, False), (True, True, False, False),
                         (True, False, True, False), (False, False, False, True))
                for case, (variable_rate, static_metadata, advanced, sparse) in enumerate(cases):
                    source = fixture.make_hdr10plus_fixture(
                        str(ffmpeg), root / f"source-{case}",
                        variable_rate=variable_rate, static_metadata=static_metadata,
                        advanced=advanced, sparse_rate=sparse,
                    )
                    original = digest(source)
                    start, end = Fraction("0.417"), Fraction("1.863")
                    if sparse:
                        video = next(item for item in metadata(ffprobe, source)["streams"]
                                     if item["codec_type"] == "video")
                        start, end = Fraction("6.417"), Fraction(video["duration"])
                    for repeat in range(2 if case == 0 else 1):
                        task_id = f"hdr10plus-smoke-{case}-{repeat}"
                        send({"id": task_id, "command": "start", "operation": "clip",
                              "input_path": str(source), "output_directory": str(root),
                              "start": float(start), "end": float(end)})
                        deadline, accepted = time.monotonic() + 120, False
                        while True:
                            remaining = deadline - time.monotonic()
                            assert remaining > 0, "Frozen HDR10+ clip timed out"
                            event = receive(remaining)
                            assert event.get("id") == task_id, event
                            if event["type"] == "accepted":
                                accepted = True
                            elif event["type"] == "progress":
                                assert 0 <= event["progress"] < 100
                            else:
                                assert accepted and event["type"] == "completed", event
                                break
                        output = Path(event["output_path"])
                        assert output.is_file() and output.parent == root and output not in outputs
                        assert output.suffix == ".mp4" and output != source
                        check_clip(ffmpeg, ffprobe, source, output, start, end)
                        assert digest(source) == original, "Source media was modified"
                        outputs.add(output)
                        print(f"PASS: frozen HDR10+ clip, VFR={variable_rate}, static={static_metadata}, advanced={advanced}, sparse={sparse}, repeat={repeat}",
                              flush=True)
                assert len(outputs) == 5
                assert not [path for path in root.iterdir() if path.name.startswith(".")]
                send({"id": "hdr10plus-shutdown", "command": "shutdown"})
                assert process.wait(timeout=15) == 0
                print("PASS: frozen clips retain complete HDR10+ payloads, exact frame ranges and audio", flush=True)
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
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--app", type=Path)
    selection.add_argument("--tools-directory", type=Path)
    args = parser.parse_args()
    directory = args.app / "Contents/MacOS" if args.app else args.tools_directory
    smoke(directory.resolve(strict=True))


if __name__ == "__main__":
    main()
