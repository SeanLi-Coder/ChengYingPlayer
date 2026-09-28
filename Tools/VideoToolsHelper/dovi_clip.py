"""Precise single-layer Dolby Vision clipping with complete RPU verification.

The bundled FFmpeg regenerates RPU data from decoded frame metadata. Verification
normalizes the *whole* RPU using its bitstream filter, including extension blocks
which FFprobe's human-readable frame metadata does not expose. It does not compare
compressed video pixels: the existing CRF 14 clip encoder remains lossy.
"""

from __future__ import annotations

import contextlib
import re
import sqlite3
import subprocess
import tempfile
from collections.abc import Iterator
from fractions import Fraction
from itertools import zip_longest
from pathlib import Path
from typing import Any

from media import (
    MediaError,
    _compact_hdr_side_data_values,
    _is_dynamic_hdr_side_data_type,
    probe_video,
)

SUPPORTED_DOVI_TYPES = {"Dolby Vision RPU Data", "Dolby Vision Metadata"}
UNSUPPORTED_DOVI = "Dynamic HDR clipping currently supports only single-layer Dolby Vision profile 8.1 or 8.4"


def validate_dovi_clip_source(metadata: dict[str, Any]) -> None:
    cfg = metadata.get("dovi_configuration") or {}
    compatibility = cfg.get("dv_bl_signal_compatibility_id")
    expected_transfer = {1: "smpte2084", 4: "arib-std-b67"}.get(compatibility)
    if (
        metadata.get("video_codec") != "hevc"
        or metadata.get("pix_fmt") != "yuv420p10le"
        or cfg.get("dv_version_major") != 1
        or cfg.get("dv_version_minor") != 0
        or cfg.get("dv_profile") != 8
        or cfg.get("rpu_present_flag") != 1
        or cfg.get("el_present_flag") != 0
        or cfg.get("bl_present_flag") != 1
        or cfg.get("dv_md_compression") not in {None, "none", "limited"}
        or not expected_transfer
        or metadata.get("color_transfer") != expected_transfer
        or metadata.get("color_primaries") != "bt2020"
        or metadata.get("color_space") != "bt2020nc"
        or metadata.get("color_range") != "tv"
        or set(metadata.get("dynamic_hdr_metadata_types") or ()) - SUPPORTED_DOVI_TYPES
    ):
        raise MediaError(UNSUPPORTED_DOVI)
    if metadata.get("field_order") not in {"", "unknown", "progressive"}:
        raise MediaError("Dolby Vision clipping requires progressive video")
    if compatibility == 1 and not (metadata.get("static_hdr_metadata") or {}).get(
        "Mastering display metadata"
    ):
        raise MediaError(
            "Dolby Vision profile 8.1 clipping requires verified static HDR metadata"
        )


def dovi_encoding_options(metadata: dict[str, Any]) -> list[str]:
    # These are the Dolby Vision high-tier limits for the inferred picture level,
    # not target bitrates. CRF remains 14. x265 requires VBV/HRD for DV profiles.
    width = int(metadata["encoded_width"])
    pixels_per_second = (
        width * int(metadata["encoded_height"]) * float(metadata.get("max_fps") or 30)
    )
    limits = (
        (1280, 1280 * 720 * 30, 50),
        (2560, 1920 * 1080 * 30, 70),
        (3840, 1920 * 1080 * 60, 70),
        (3840, 3840 * 2160 * 24, 130),
        (3840, 3840 * 2160 * 120, 240),
        (7680, 7680 * 4320 * 120, 450),
    )
    maximum = next(
        (
            rate
            for bound, pps, rate in limits
            if width <= bound and pixels_per_second <= pps
        ),
        None,
    )
    if maximum is None:
        raise MediaError(
            "Dolby Vision clipping exceeds the supported picture size or frame rate"
        )
    return [
        "-dolbyvision",
        "1",
        "-maxrate:v",
        f"{maximum}M",
        "-bufsize:v",
        f"{maximum * 2}M",
        "-enc_time_base:v",
        "demux",
        "-strict",
        "unofficial",
    ]


def _lines(manager: Any, job: Any, command: list[str]) -> Iterator[str]:
    process = None
    try:
        with job.lock:
            if job.cancel_event.is_set():
                raise InterruptedError
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            job.process = process
        assert process.stdout is not None
        for line in process.stdout:
            if job.cancel_event.is_set():
                raise InterruptedError
            yield line.strip()
        if job.cancel_event.is_set():
            raise InterruptedError
        if process.wait() != 0:
            raise MediaError(
                "Dolby Vision metadata inspection failed; no output was published"
            )
    finally:
        with job.lock:
            if job.process is process:
                job.process = None
        if process is not None:
            if process.poll() is None:
                manager._escalate_process_stop(process)
            if process.stdout is not None:
                process.stdout.close()


def _source_bounds(job: Any) -> tuple[Fraction, Fraction]:
    origin = Fraction(str(job.source.metadata.get("format_start_time") or 0))
    return origin + Fraction(str(job.start)), origin + Fraction(str(job.end))


def _selected_frames(
    manager: Any, job: Any, path: Path, *, source: bool
) -> Iterator[int]:
    metadata = (
        job.source.metadata
        if source
        else probe_video(path, ffprobe=manager.ffprobe, cancel_event=job.cancel_event)
    )
    time_base = Fraction(metadata["video_time_base"])
    lower, upper = _source_bounds(job) if source else (None, None)
    command = [
        manager.ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(metadata["video_stream_index"]),
    ]
    if source:
        command.extend(["-read_intervals", f"{float(lower):.6f}%"])
    command.extend(
        [
            "-show_entries",
            (
                "frame=pts:frame_side_data=side_data_type,red_x,red_y,green_x,green_y,"
                "blue_x,blue_y,white_point_x,white_point_y,min_luminance,max_luminance,"
                "max_content,max_average"
            ),
            "-of",
            "compact",
            str(path),
        ]
    )
    iterator = _lines(manager, job, command)
    last = None
    try:
        for line in iterator:
            if not line.startswith("frame|"):
                continue
            match = re.search(r"(?:^|\|)pts=(-?\d+)(?:\||$)", line)
            if not match:
                raise MediaError(
                    "Dolby Vision frames have missing presentation timestamps"
                )
            pts = int(match.group(1))
            timestamp = pts * time_base
            if source and timestamp < lower:
                continue
            if source and timestamp >= upper:
                break
            if last is not None and pts <= last:
                raise MediaError(
                    "Dolby Vision frames have ambiguous presentation timestamps"
                )
            last = pts
            types = set(re.findall(r"side_data_type=([^|]+)", line))
            if "Dolby Vision Metadata" not in types:
                raise MediaError("A selected frame is missing Dolby Vision metadata")
            if any(
                _is_dynamic_hdr_side_data_type(value)
                and value not in SUPPORTED_DOVI_TYPES
                for value in types
            ):
                raise MediaError(UNSUPPORTED_DOVI)
            baseline = job.source.metadata.get("static_hdr_metadata") or {}
            for kind, section in (
                ("Mastering display metadata", "mastering_display_metadata"),
                ("Content light level metadata", "content_light_level_metadata"),
            ):
                values = _compact_hdr_side_data_values(line, section)
                if (values or {}) != baseline.get(kind, {}):
                    raise MediaError(
                        "Variable static HDR metadata cannot be preserved safely"
                    )
            yield pts
    finally:
        iterator.close()


def inspect_dovi_clip_frames(manager: Any, job: Any) -> None:
    count = sum(1 for _ in _selected_frames(manager, job, job.source.path, source=True))
    if not count:
        raise MediaError("The selected range contains no Dolby Vision video frames")


def _fingerprints(
    manager: Any,
    job: Any,
    path: Path,
    connection: sqlite3.Connection,
    table: str,
    *,
    source: bool,
) -> Fraction:
    # Table names are fixed by this module, never supplied by requests.
    assert table in {"original", "exported"}
    connection.execute(
        f"CREATE TABLE {table} (pts INTEGER PRIMARY KEY, size INTEGER, digest TEXT)"
    )
    index = job.source.metadata["video_stream_index"] if source else 0
    command = [
        manager.ffmpeg,
        "-v",
        "error",
        "-nostdin",
        "-copyts",
        "-i",
        str(path),
        "-map",
        f"0:{index}",
        "-c",
        "copy",
        "-bsf:v",
        "hevc_mp4toannexb,dovi_rpu=compression=none,filter_units=pass_types=62",
        "-f",
        "framehash",
        "-",
    ]
    time_base = None
    lower, upper = _source_bounds(job) if source else (None, None)
    for line in _lines(manager, job, command):
        if line.startswith("#tb 0:"):
            time_base = Fraction(line.partition(":")[2].strip())
        elif line and not line.startswith("#"):
            fields = [field.strip() for field in line.split(",")]
            if len(fields) < 6 or fields[0] != "0" or time_base is None:
                raise MediaError("Invalid Dolby Vision metadata fingerprint")
            try:
                pts, size = int(fields[2]), int(fields[4])
            except ValueError as exc:
                raise MediaError("Invalid Dolby Vision metadata fingerprint") from exc
            if source and not lower <= pts * time_base < upper:
                continue
            if size < 8 or not re.fullmatch(r"[0-9a-f]{64}", fields[5]):
                raise MediaError("A selected packet is missing Dolby Vision RPU data")
            try:
                connection.execute(
                    f"INSERT INTO {table} VALUES (?, ?, ?)", (pts, size, fields[5])
                )
            except sqlite3.IntegrityError as exc:
                raise MediaError(
                    "Dolby Vision packets have ambiguous presentation timestamps"
                ) from exc
    if time_base is None:
        raise MediaError("Dolby Vision metadata fingerprints are unavailable")
    return time_base


def verify_dovi_clip(manager: Any, job: Any, output: Path) -> None:
    metadata = probe_video(
        output, ffprobe=manager.ffprobe, cancel_event=job.cancel_event
    )
    validate_dovi_clip_source(metadata)
    if (
        metadata["dovi_configuration"]["dv_bl_signal_compatibility_id"]
        != job.source.metadata["dovi_configuration"]["dv_bl_signal_compatibility_id"]
    ):
        raise MediaError("Output verification detected a changed Dolby Vision profile")
    if metadata.get("display_matrix") != job.source.metadata.get("display_matrix"):
        raise MediaError(
            "Output verification detected a changed Dolby Vision display matrix"
        )
    lower, _ = _source_bounds(job)
    # A private disk-backed index keeps memory bounded for long clips and orders
    # different source/output B-frame packet orders by presentation timestamp.
    with (
        tempfile.TemporaryDirectory(
            prefix=".dovi-verify-", dir=output.parent
        ) as directory,
        contextlib.closing(
            sqlite3.connect(str(Path(directory) / "frames.sqlite"))
        ) as connection,
    ):
        original_base = _fingerprints(
            manager, job, job.source.path, connection, "original", source=True
        )
        exported_base = _fingerprints(
            manager, job, output, connection, "exported", source=False
        )
        original = connection.execute(
            "SELECT pts, size, digest FROM original ORDER BY pts"
        )
        exported = connection.execute(
            "SELECT pts, size, digest FROM exported ORDER BY pts"
        )
        tolerance = max(original_base, exported_base) * 2
        count = 0
        for before, after in zip_longest(original, exported):
            if job.cancel_event.is_set():
                raise InterruptedError
            if before is None or after is None:
                raise MediaError(
                    "Output verification detected a changed Dolby Vision frame count"
                )
            if (
                abs(before[0] * original_base - lower - after[0] * exported_base)
                > tolerance
            ):
                raise MediaError(
                    "Output verification detected changed Dolby Vision frame timestamps"
                )
            if before[1:] != after[1:]:
                raise MediaError(
                    "Output verification detected changed Dolby Vision RPU metadata"
                )
            count += 1
        if not count:
            raise MediaError("Output verification found no Dolby Vision frames")
        for table, path, source in (
            ("original", job.source.path, True),
            ("exported", output, False),
        ):
            packets = connection.execute(f"SELECT pts FROM {table} ORDER BY pts")
            frames = _selected_frames(manager, job, path, source=source)
            try:
                for packet, frame in zip_longest(packets, frames):
                    if packet is None or frame is None or packet[0] != frame:
                        raise MediaError(
                            "Output verification detected missing or hidden Dolby Vision frames"
                        )
            finally:
                frames.close()
