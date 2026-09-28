"""Synthetic Dolby Vision fixtures, using only the bundled FFmpeg at test time."""

from __future__ import annotations

import base64
import gzip
import hashlib
import json
import re
import subprocess
from pathlib import Path


def make_dovi_fixture(
    ffmpeg: str, directory: Path, *, compatibility: int = 4, variable_rate: bool = False
) -> Path:
    fixture = json.loads(
        (Path(__file__).parent / "fixtures/dovi/metadata.json").read_text()
    )[str(compatibility)]
    rpu = gzip.decompress(base64.b64decode(fixture["gzip_base64"]))
    assert hashlib.sha256(rpu).hexdigest() == fixture["sha256"]
    directory.mkdir(parents=True, exist_ok=True)
    base, injected = directory / "base.hevc", directory / "injected.hevc"
    remuxed, result = directory / "remuxed.mp4", directory / "synthetic-dovi.mp4"
    transfer = {1: "smpte2084", 4: "arib-std-b67"}[compatibility]
    hdr_params = (
        ":master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400"
        if compatibility == 1
        else ""
    )

    def run(*args: str) -> None:
        completed = subprocess.run(
            [ffmpeg, "-nostdin", "-v", "error", *args],
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        if completed.returncode:
            raise RuntimeError(completed.stderr)

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
        f"log-level=error:pools=1:frame-threads=1:bframes=0:aud=1:keyint=60:scenecut=0:colorprim=bt2020:transfer={transfer}:colormatrix=bt2020nc{hdr_params}",
        "-color_primaries",
        "bt2020",
        "-color_trc",
        transfer,
        "-colorspace",
        "bt2020nc",
        "-color_range",
        "tv",
        "-f",
        "hevc",
        str(base),
    )
    # The test-only base encoder deliberately has no B frames, so AUD access
    # units are in presentation order and can receive the matching synthetic RPU.
    units = [
        nal
        for nal in re.split(b"\x00\x00\x00\x01|\x00\x00\x01", base.read_bytes())
        if nal
    ]
    rpus = [nal for nal in re.split(b"\x00\x00\x00\x01|\x00\x00\x01", rpu) if nal]
    assert len(rpus) == fixture["frames"] == 90
    output = bytearray()
    index = -1
    for nal in units:
        if (nal[0] >> 1) & 0x3F == 35:
            if index >= 0:
                output.extend(b"\x00\x00\x00\x01\x7c\x01" + rpus[index])
            index += 1
        output.extend(b"\x00\x00\x00\x01" + nal)
    output.extend(b"\x00\x00\x00\x01\x7c\x01" + rpus[index])
    assert index == 89
    injected.write_bytes(output)
    run("-r", "30", "-i", str(injected), "-c", "copy", "-tag:v", "hvc1", str(remuxed))
    filters = (
        ["-vf", "settb=1/90000,setpts=N*3000+mod(N\\,3)*300"] if variable_rate else []
    )
    # Re-encode once to produce a realistic long-GOP/B-frame input with a real
    # Dolby Vision configuration record and valid MP4 timestamps.
    run(
        "-i",
        str(remuxed),
        "-f",
        "lavfi",
        "-i",
        "sine=sample_rate=48000:duration=3",
        *filters,
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-dolbyvision",
        "1",
        "-x265-params",
        f"log-level=error:pools=1:frame-threads=1:keyint=60:min-keyint=60:scenecut=0:bframes=4{hdr_params}",
        "-maxrate:v",
        "50M",
        "-bufsize:v",
        "100M",
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
        "-strict",
        "unofficial",
        "-tag:v",
        "hvc1",
        str(result),
    )
    return result
