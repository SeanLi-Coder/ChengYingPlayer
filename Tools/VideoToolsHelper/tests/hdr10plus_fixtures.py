"""Generate legal test pictures and HDR10+ metadata without external media."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path


def hdr10plus_payload(index: int, *, advanced: bool = False) -> bytes:
    """Create a complete T.35 payload with independently changing field values."""
    fields: list[str] = []

    def put(value: int, width: int) -> None:
        assert 0 <= value < 1 << width
        fields.append(f"{value:0{width}b}")

    put(1, 8)
    windows = 2 if advanced else 1
    put(windows, 2)
    if advanced:
        for value in (10, 10, 120, 70, 60, 40):
            put(value, 16)
        put(0, 8)
        for value in (20, 30, 15):
            put(value, 16)
        put(0, 1)
    put(1000 + index, 27)
    put(int(advanced), 1)
    if advanced:
        put(2, 5)
        put(2, 5)
        for value in (1, 5, 10, 15):
            put(value, 4)
    for window in range(windows):
        for value in (10000 + index, 15000 + window + index, 20000 + index):
            put(value, 17)
        put(5000 + index, 17)
        put(3, 4)
        for percentage, value in ((1, 100), (50, 5000), (99, 10000)):
            put(percentage, 7)
            put(value + index, 17)
        put(index % 1000, 10)
    put(int(advanced), 1)
    if advanced:
        put(2, 5)
        put(2, 5)
        for value in (3, 6, 9, 12):
            put(value, 4)
    for window in range(windows):
        tone_mapping = not advanced or index % 3 != 0
        put(int(tone_mapping), 1)
        if tone_mapping:
            put(400 + index, 12)
            put(500 + window + index, 12)
            put(3, 4)
            for value in (100, 300, 800):
                put(value + index, 10)
        put(int(advanced), 1)
        if advanced:
            put(8 + index % 4, 6)
    bits = "".join(fields)
    bits += "0" * (-len(bits) % 8)
    return bytes.fromhex("b5003c000104") + int(bits, 2).to_bytes(len(bits) // 8, "big")


def escape_rbsp(data: bytes) -> bytes:
    escaped = bytearray()
    zeros = 0
    for value in data:
        if zeros >= 2 and value <= 3:
            escaped.append(3)
            zeros = 0
        escaped.append(value)
        zeros = zeros + 1 if value == 0 else 0
    return bytes(escaped)


def sei_nal(payload: bytes, *, extra_message: bytes = b"") -> bytes:
    size = bytes([255]) * (len(payload) // 255) + bytes([len(payload) % 255])
    return b"\x4e\x01" + escape_rbsp(extra_message + b"\x04" + size + payload + b"\x80")


def make_hdr10plus_fixture(
    ffmpeg: str,
    directory: Path,
    *,
    variable_rate: bool = False,
    static_metadata: bool = False,
    advanced: bool = False,
    reencode: bool = True,
    sparse_rate: bool = False,
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    base = directory / "base.hevc"
    injected = directory / "injected.hevc"
    remuxed = directory / "remuxed.mp4"
    result = directory / "synthetic-hdr10plus.mp4"
    static = (
        ":master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400"
        if static_metadata
        else ""
    )

    def run(*arguments: str) -> None:
        subprocess.run(
            [ffmpeg, "-nostdin", "-v", "error", *arguments],
            capture_output=True,
            text=True,
            check=True,
            timeout=90,
        )

    run(
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=160x96:rate=30:duration=3",
        "-pix_fmt",
        "yuv420p10le",
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-x265-params",
        "log-level=error:pools=1:frame-threads=1:bframes=0:aud=1:keyint=60:scenecut=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
        + static,
        "-color_primaries",
        "bt2020",
        "-color_trc",
        "smpte2084",
        "-colorspace",
        "bt2020nc",
        "-color_range",
        "tv",
        "-f",
        "hevc",
        str(base),
    )
    units = [
        nal
        for nal in re.split(b"\x00\x00\x00\x01|\x00\x00\x01", base.read_bytes())
        if nal
    ]
    output = bytearray()
    index = -1
    for nal in units:
        if (nal[0] >> 1) & 63 == 35:
            index += 1
            output.extend(b"\x00\x00\x00\x01" + nal)
            output.extend(
                b"\x00\x00\x00\x01"
                + sei_nal(hdr10plus_payload(index, advanced=advanced))
            )
        else:
            output.extend(b"\x00\x00\x00\x01" + nal)
    assert index == 89
    injected.write_bytes(output)
    run("-r", "30", "-i", str(injected), "-c", "copy", "-tag:v", "hvc1", str(remuxed))
    if not reencode:
        return remuxed
    filters = (
        ["-vf", "settb=1/90000,setpts=N*3000+mod(N\\,3)*300"] if variable_rate else []
    )
    if sparse_rate:
        filters = ["-vf", "settb=1/90000,setpts=N*1500+gte(N\\,57)*600000"]
    run(
        "-i",
        str(remuxed),
        "-f",
        "lavfi",
        "-i",
        "sine=sample_rate=48000:duration=8.2"
        if sparse_rate
        else "sine=sample_rate=48000:duration=3",
        *filters,
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-hdr10plus",
        "1",
        "-x265-params",
        "log-level=error:pools=1:frame-threads=1:keyint=60:min-keyint=60:scenecut=0:bframes=4"
        + static,
        "-pix_fmt",
        "yuv420p10le",
        "-fps_mode",
        "passthrough",
        "-enc_time_base:v",
        "1:90000",
        "-c:a",
        "aac",
        "-ac",
        "2",
        "-tag:v",
        "hvc1",
        str(result),
    )
    return result
