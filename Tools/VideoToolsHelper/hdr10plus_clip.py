"""Precise HDR10+ clipping with complete per-picture ITU-T T.35 verification.

FFprobe's readable HDR10+ JSON repeats field names and is not a complete,
lossless representation. Compare the full registered SEI payload instead, using
packet presentation timestamps and an independent decoded-frame correspondence.
"""

from __future__ import annotations

import contextlib
import hashlib
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
    _parse_aspect_ratio,
    _run_capture,
    probe_video,
)

HDR10PLUS_TYPE = "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"
T35_HEADER = bytes.fromhex("b5003c000104")
MAX_PROBE_LINE = 64 * 1024 * 1024
MAX_T35_PAYLOAD = 913
UNSUPPORTED_HDR10PLUS = "HDR10+ clipping requires progressive single-layer HEVC 10-bit limited-range BT.2020 PQ video"


def is_hdr10plus_source(metadata: dict[str, Any]) -> bool:
    return HDR10PLUS_TYPE in (metadata.get("dynamic_hdr_metadata_types") or ())


def validate_hdr10plus_clip_source(metadata: dict[str, Any]) -> None:
    if (
        metadata.get("video_codec") != "hevc"
        or metadata.get("pix_fmt") != "yuv420p10le"
        or metadata.get("color_range") != "tv"
        or metadata.get("color_space") != "bt2020nc"
        or metadata.get("color_primaries") != "bt2020"
        or metadata.get("color_transfer") != "smpte2084"
        or metadata.get("field_order") not in {"", "unknown", "progressive"}
        or metadata.get("is_dolby_vision")
        or metadata.get("dovi_configuration")
        or set(metadata.get("dynamic_hdr_metadata_types") or ()) != {HDR10PLUS_TYPE}
    ):
        raise MediaError(UNSUPPORTED_HDR10PLUS)
    if (
        metadata.get("video_stream_count") != 1
        or metadata.get("audio_stream_count") not in {0, 1}
        or metadata.get("ancillary_stream_count") != 0
    ):
        raise MediaError(
            "HDR10+ clipping currently supports one video track and at most one audio track without ancillary tracks"
        )


def require_hdr10plus_encoder(manager: Any) -> None:
    result = _run_capture(
        [manager.ffmpeg, "-hide_banner", "-h", "encoder=libx265"],
        timeout=30,
        cancel_event=manager.cancel_event,
    )
    if result.returncode or not re.search(
        r"(?m)^\s+-hdr10plus\s+<boolean>", result.stdout
    ):
        raise MediaError(
            "The bundled video encoder does not support HDR10+ preservation; update the application"
        )


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
        while True:
            line = process.stdout.readline(MAX_PROBE_LINE + 1)
            if job.cancel_event.is_set():
                raise InterruptedError
            if not line:
                break
            if len(line) > MAX_PROBE_LINE:
                raise MediaError(
                    "HDR10+ inspection exceeded the per-packet safety limit"
                )
            yield line.strip()
        if process.wait() != 0:
            raise MediaError(
                "HDR10+ metadata inspection failed; no output was published"
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


def _bounds(job: Any) -> tuple[Fraction, Fraction]:
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
    base = Fraction(metadata["video_time_base"])
    lower, upper = _bounds(job) if source else (None, None)
    command = [
        manager.ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(metadata["video_stream_index"]),
    ]
    # Start decoding at the beginning: a seek can lose leading open-GOP B frames
    # whose PTS is in range even when the chosen random-access picture is later.
    command.extend(
        [
            "-show_entries",
            (
                "frame=pts,width,height,pix_fmt,sample_aspect_ratio,interlaced_frame,"
                "color_range,color_space,color_transfer,color_primaries:"
                "frame_side_data=side_data_type,red_x,red_y,green_x,green_y,"
                "blue_x,blue_y,white_point_x,white_point_y,min_luminance,max_luminance,max_content,max_average"
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
                raise MediaError("HDR10+ frames have missing presentation timestamps")
            pts = int(match[1])
            if source and pts * base < lower:
                continue
            if source and pts * base >= upper:
                break
            if last is not None and pts <= last:
                raise MediaError("HDR10+ frames have ambiguous presentation timestamps")
            last = pts
            fields = dict(
                part.split("=", 1)
                for part in line.split("|")[1:]
                if "=" in part and not part.startswith("side_datum/")
            )
            expected = job.source.metadata
            if (
                fields.get("width") != str(expected["encoded_width"])
                or fields.get("height") != str(expected["encoded_height"])
                or fields.get("pix_fmt") != expected["pix_fmt"]
                or fields.get("interlaced_frame") != "0"
                or any(
                    fields.get(key) != expected.get(key)
                    for key in (
                        "color_range",
                        "color_space",
                        "color_transfer",
                        "color_primaries",
                    )
                )
                or (
                    _parse_aspect_ratio(fields.get("sample_aspect_ratio"))
                    or Fraction(1)
                )
                != (
                    _parse_aspect_ratio(expected.get("encoded_sample_aspect_ratio"))
                    or Fraction(1)
                )
            ):
                raise MediaError(
                    "HDR10+ frames contain changing or unsupported geometry, color, or scan properties"
                )
            types = set(re.findall(r"side_data_type=([^|]+)", line))
            if HDR10PLUS_TYPE not in types:
                raise MediaError("A selected frame is missing HDR10+ metadata")
            if any(
                _is_dynamic_hdr_side_data_type(value) and value != HDR10PLUS_TYPE
                for value in types
            ):
                raise MediaError(UNSUPPORTED_HDR10PLUS)
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


def inspect_hdr10plus_clip_frames(manager: Any, job: Any) -> None:
    if not sum(1 for _ in _selected_frames(manager, job, job.source.path, source=True)):
        raise MediaError("The selected range contains no HDR10+ video frames")


def inspect_static_hdr_clip_frames(manager: Any, job: Any) -> None:
    """Do not drop dynamic metadata that was absent from the initial probe frame."""
    lower, upper = _bounds(job)
    base = Fraction(job.source.metadata["video_time_base"])
    command = [
        manager.ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(job.source.metadata["video_stream_index"]),
        "-show_entries",
        "frame=pts:frame_side_data=side_data_type",
        "-of",
        "compact",
        str(job.source.path),
    ]
    previous = None
    with contextlib.closing(_lines(manager, job, command)) as lines:
        for line in lines:
            if not line.startswith("frame|"):
                continue
            match = re.search(r"(?:^|\|)pts=(-?\d+)(?:\||$)", line)
            if not match:
                raise MediaError("HDR frame timestamps could not be inspected safely")
            pts = int(match[1])
            if previous is not None and pts <= previous:
                raise MediaError("HDR frame timestamps could not be inspected safely")
            previous = pts
            if pts * base < lower:
                continue
            if pts * base >= upper:
                break
            types = re.findall(r"side_data_type=([^|]+)", line)
            if any(_is_dynamic_hdr_side_data_type(value) for value in types):
                raise MediaError(
                    "The selected HDR range contains dynamic metadata not detected in the initial frame; no output was published"
                )


def _hex_bytes(text: str, *, escaped: bool = False) -> bytes:
    result = bytearray()
    if escaped:
        # Compact output escapes both line separators and printable backslashes.
        # A literal backslash followed by 'n' in the ASCII column is not a row.
        escapes = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f"}
        text = re.sub(r"\\(.)", lambda match: escapes.get(match[1], match[1]), text)
    for line in text.splitlines():
        if not line:
            continue
        address, separator, body = line.partition(": ")
        if not separator or not re.fullmatch(r"[0-9a-fA-F]{8,16}", address):
            raise MediaError("Invalid HDR10+ packet data")
        if int(address, 16) != len(result):
            raise MediaError("Non-contiguous HDR10+ packet data")
        try:
            data = bytes.fromhex(body[:39])
        except ValueError as exc:
            raise MediaError("Invalid HDR10+ packet data") from exc
        if not 0 < len(data) <= 16:
            raise MediaError("Invalid HDR10+ packet data")
        result.extend(data)
    return bytes(result)


def _length_size(manager: Any, job: Any, path: Path, index: int) -> int | None:
    command = [
        manager.ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(index),
        "-show_entries",
        "stream=extradata:stream_side_data=",
        "-show_data",
        "-of",
        "compact",
        str(path),
    ]
    raw = None
    with contextlib.closing(_lines(manager, job, command)) as lines:
        for line in lines:
            if not line.startswith("stream|extradata="):
                continue
            if raw is not None or len(line) > 1024 * 1024:
                raise MediaError("HDR10+ HEVC packet framing exceeded the safety limit")
            # Empty requested side-data sections may add a final unescaped '|'.
            # Keep escaped bars/backslashes in FFprobe's printable ASCII column.
            value = re.match(r"(?:\\.|[^\\|])*", line.partition("|extradata=")[2])
            raw = _hex_bytes(value[0], escaped=True)
    if raw is None:
        raise MediaError("HDR10+ HEVC packet framing could not be inspected")
    if len(raw) >= 23 and raw[0] == 1:
        return (raw[21] & 3) + 1
    if raw.startswith((b"\x00\x00\x01", b"\x00\x00\x00\x01")):
        return None
    raise MediaError("HDR10+ HEVC packet framing is unsupported")


def _nals(data: bytes, length_size: int | None) -> Iterator[bytes]:
    if length_size is None:
        markers = re.finditer(b"\x00\x00\x00\x01|\x00\x00\x01", data)
        previous = next(markers, None)
        if previous is None or previous.start() != 0:
            raise MediaError("Invalid HDR10+ Annex B packet")
        for marker in markers:
            yield data[previous.end() : marker.start()]
            previous = marker
        yield data[previous.end() :].rstrip(b"\x00")
        return
    offset = 0
    while offset < len(data):
        if offset + length_size > len(data):
            raise MediaError("Truncated HDR10+ HEVC packet")
        size = int.from_bytes(data[offset : offset + length_size], "big")
        offset += length_size
        if size < 2 or offset + size > len(data):
            raise MediaError("Truncated HDR10+ HEVC packet")
        yield data[offset : offset + size]
        offset += size


def _unescape(data: bytes) -> bytes:
    result = bytearray()
    zeros = 0
    index = 0
    while index < len(data):
        value = data[index]
        if zeros >= 2 and value == 3:
            if index + 1 >= len(data) or data[index + 1] > 3:
                raise MediaError("Invalid HDR10+ emulation-prevention bytes")
            zeros = 0
            index += 1
            continue
        result.append(value)
        zeros = zeros + 1 if value == 0 else 0
        index += 1
    return bytes(result)


def _sei_number(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value += byte
        if byte != 255:
            return value, offset
    raise MediaError("Truncated HDR10+ SEI header")


def _payload(data: bytes, length_size: int | None) -> bytes:
    payload = None
    for nal in _nals(data, length_size):
        if len(nal) < 2 or nal[0] & 128 or not (nal[1] & 7):
            raise MediaError("Invalid HDR10+ HEVC NAL header")
        if ((nal[0] & 1) << 5) | (nal[1] >> 3):
            raise MediaError(UNSUPPORTED_HDR10PLUS)
        if ((nal[0] >> 1) & 63) not in {39, 40}:
            continue
        rbsp = _unescape(nal[2:])
        offset = 0
        while offset < len(rbsp):
            if rbsp[offset:] == b"\x80":
                break
            kind, offset = _sei_number(rbsp, offset)
            size, offset = _sei_number(rbsp, offset)
            if offset + size > len(rbsp):
                raise MediaError("Truncated HDR10+ SEI payload")
            item = rbsp[offset : offset + size]
            offset += size
            if kind == 4 and item.startswith(T35_HEADER):
                if (
                    payload is not None
                    or not 8 <= len(item) <= MAX_T35_PAYLOAD
                    or item[6] != 1
                ):
                    raise MediaError("Unsupported or ambiguous HDR10+ SEI payload")
                payload = item
        else:
            raise MediaError("Missing HDR10+ SEI trailing bits")
    if payload is None:
        raise MediaError("A selected packet is missing HDR10+ metadata")
    return payload


def _fingerprints(
    manager: Any,
    job: Any,
    path: Path,
    connection: sqlite3.Connection,
    table: str,
    *,
    source: bool,
) -> Fraction:
    assert table in {"original", "exported"}
    connection.execute(
        f"CREATE TABLE {table} (pts INTEGER PRIMARY KEY, size INTEGER, digest TEXT)"
    )
    metadata = (
        job.source.metadata
        if source
        else probe_video(path, ffprobe=manager.ffprobe, cancel_event=job.cancel_event)
    )
    index = metadata["video_stream_index"]
    base = Fraction(metadata["video_time_base"])
    length_size = _length_size(manager, job, path, index)
    lower, upper = _bounds(job) if source else (None, None)
    command = [
        manager.ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(index),
        "-show_packets",
        "-show_data",
        "-show_entries",
        "packet=pts,data",
        "-of",
        "compact",
        str(path),
    ]
    with contextlib.closing(_lines(manager, job, command)) as lines:
        for line in lines:
            if not line.startswith("packet|"):
                continue
            match = re.search(r"(?:^|\|)pts=(-?\d+)(?:\||$)", line)
            if not match:
                raise MediaError("HDR10+ packets have missing presentation timestamps")
            pts = int(match[1])
            if source and not lower <= pts * base < upper:
                continue
            _, separator, data = line.partition("|data=")
            if not separator:
                raise MediaError("HDR10+ packet data is unavailable")
            payload = _payload(_hex_bytes(data, escaped=True), length_size)
            try:
                connection.execute(
                    f"INSERT INTO {table} VALUES (?, ?, ?)",
                    (pts, len(payload), hashlib.sha256(payload).hexdigest()),
                )
            except sqlite3.IntegrityError as exc:
                raise MediaError(
                    "HDR10+ packets have ambiguous presentation timestamps"
                ) from exc
    return base


def verify_hdr10plus_clip(manager: Any, job: Any, output: Path) -> None:
    metadata = probe_video(
        output, ffprobe=manager.ffprobe, cancel_event=job.cancel_event
    )
    validate_hdr10plus_clip_source(metadata)
    if metadata.get("display_matrix") != job.source.metadata.get("display_matrix"):
        raise MediaError("Output verification detected a changed HDR10+ display matrix")
    lower, _ = _bounds(job)
    with (
        tempfile.TemporaryDirectory(
            prefix=".hdr10plus-verify-", dir=output.parent
        ) as directory,
        contextlib.closing(
            sqlite3.connect(str(Path(directory) / "frames.sqlite"))
        ) as connection,
    ):
        # Keep the frame index on disk, with bounded cache and no journal copy.
        connection.execute("PRAGMA cache_size = -2048")
        connection.execute("PRAGMA temp_store = FILE")
        before_base = _fingerprints(
            manager, job, job.source.path, connection, "original", source=True
        )
        after_base = _fingerprints(
            manager, job, output, connection, "exported", source=False
        )
        before = connection.execute(
            "SELECT pts, size, digest FROM original ORDER BY pts"
        )
        after = connection.execute(
            "SELECT pts, size, digest FROM exported ORDER BY pts"
        )
        count = 0
        tolerance = max(before_base, after_base) * 2
        for original, exported in zip_longest(before, after):
            if job.cancel_event.is_set():
                raise InterruptedError
            if original is None or exported is None:
                raise MediaError(
                    "Output verification detected a changed HDR10+ frame count"
                )
            if (
                abs(original[0] * before_base - lower - exported[0] * after_base)
                > tolerance
            ):
                raise MediaError(
                    "Output verification detected changed HDR10+ frame timestamps"
                )
            if original[1:] != exported[1:]:
                raise MediaError("Output verification detected changed HDR10+ metadata")
            count += 1
        if not count:
            raise MediaError("Output verification found no HDR10+ frames")
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
                            "Output verification detected missing or hidden HDR10+ frames"
                        )
            finally:
                frames.close()
