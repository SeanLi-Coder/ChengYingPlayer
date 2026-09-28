from __future__ import annotations

import hashlib
import json
import subprocess
from fractions import Fraction
from pathlib import Path

from dovi_fixtures import make_dovi_fixture

from media import ExportManager, VideoSource, probe_video


def _change_mastering_maximum(nal: bytes) -> bytes | None:
    """Change only the synthetic prefix SEI's 1000-nit mastering maximum."""
    if (nal[0] >> 1) & 63 != 39:
        return None
    rbsp = bytearray(nal[2:].replace(b"\x00\x00\x03", b"\x00\x00"))
    offset = 0
    changed = False
    while offset < len(rbsp) and rbsp[offset] != 0x80:
        payload_type = 0
        while rbsp[offset] == 255:
            payload_type += 255
            offset += 1
        payload_type += rbsp[offset]
        offset += 1
        payload_size = 0
        while rbsp[offset] == 255:
            payload_size += 255
            offset += 1
        payload_size += rbsp[offset]
        offset += 1
        assert offset + payload_size <= len(rbsp)
        if payload_type == 137:
            assert payload_size == 24
            maximum_offset = offset + 16
            assert (
                int.from_bytes(rbsp[maximum_offset : maximum_offset + 4], "big")
                == 10_000_000
            )
            rbsp[maximum_offset : maximum_offset + 4] = (9_000_000).to_bytes(4, "big")
            changed = True
        offset += payload_size
    if not changed:
        return None
    escaped = bytearray(nal[:2])
    zero_count = 0
    for value in rbsp:
        if zero_count >= 2 and value <= 3:
            escaped.append(3)
            zero_count = 0
        escaped.append(value)
        zero_count = zero_count + 1 if value == 0 else 0
    # Equal-size replacement keeps all MP4 sample tables valid and unchanged.
    assert len(escaped) == len(nal)
    return bytes(escaped)


def _probe_json(ffprobe: str, path: Path, *arguments: str) -> dict:
    completed = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            *arguments,
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return json.loads(completed.stdout)


def test_dolby_clip_rejects_real_midstream_static_hdr_change(
    tmp_path: Path, ffmpeg: str, ffprobe: str
) -> None:
    original = make_dovi_fixture(ffmpeg, tmp_path / "fixture", compatibility=1)
    original_digest = hashlib.sha256(original.read_bytes()).hexdigest()
    data = bytearray(original.read_bytes())
    packets = _probe_json(
        ffprobe, original, "-show_packets", "-show_entries", "packet=pos,size,pts_time"
    )["packets"]
    changes = 0
    for packet in packets:
        if float(packet["pts_time"]) < 2:
            continue
        offset = int(packet["pos"])
        end = offset + int(packet["size"])
        while offset < end:
            size = int.from_bytes(data[offset : offset + 4], "big")
            assert size >= 2 and offset + 4 + size <= end
            nal_start, nal_end = offset + 4, offset + 4 + size
            replacement = _change_mastering_maximum(bytes(data[nal_start:nal_end]))
            if replacement is not None:
                data[nal_start:nal_end] = replacement
                changes += 1
            offset = nal_end
    assert changes > 0
    source_path = tmp_path / "variable-static-hdr.mp4"
    source_path.write_bytes(data)
    source_digest = hashlib.sha256(data).hexdigest()
    frames = _probe_json(
        ffprobe,
        source_path,
        "-show_frames",
        "-show_entries",
        "frame=pts_time:frame_side_data",
    )["frames"]
    selected = [frame for frame in frames if 1.5 <= float(frame["pts_time"]) < 2.8]
    mastering_values = {
        Fraction(side_data["max_luminance"])
        for frame in selected
        for side_data in frame.get("side_data_list", [])
        if side_data.get("side_data_type") == "Mastering display metadata"
    }
    assert mastering_values == {Fraction(1000), Fraction(900)}
    assert all(
        any(
            side_data.get("side_data_type") == "Dolby Vision Metadata"
            for side_data in frame.get("side_data_list", [])
        )
        for frame in selected
    )
    destination = tmp_path / "exports"
    destination.mkdir()
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    source = VideoSource(
        "synthetic-variable-static",
        source_path,
        probe_video(source_path, ffprobe=ffprobe),
    )
    job = manager.create(source, start=1.5, end=2.8, output_directory=destination)
    try:
        job.worker.join(30)
        assert not job.worker.is_alive(), "Synthetic clip did not finish"
        assert job.status == "failed", job.snapshot()
        assert job.error == "Variable static HDR metadata cannot be preserved safely"
        assert not list(destination.iterdir())
        assert hashlib.sha256(source_path.read_bytes()).hexdigest() == source_digest
        assert hashlib.sha256(original.read_bytes()).hexdigest() == original_digest
    finally:
        manager.cancel_all()
