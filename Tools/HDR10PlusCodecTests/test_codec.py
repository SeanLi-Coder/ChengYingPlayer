"""Production FFmpeg HDR10+ round-trips with independently generated SEI syntax."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FFMPEG = Path(os.environ.get("CHENGYING_FFMPEG", ROOT / "deps/executable/ffmpeg"))
FFPROBE = Path(os.environ.get("CHENGYING_FFPROBE", ROOT / "deps/executable/ffprobe"))
HEADER = bytes.fromhex("b5003c000104")
UUID = bytes.fromhex("4368656e6759696e674844523130506c75")
FRAME_COUNT = 18


def run(*args):
    return subprocess.run(
        [str(arg) for arg in args], capture_output=True, check=True, timeout=120
    )


def hdr_payload(index, version=1):
    """Write T.35 independently of FFmpeg's serializer, with all optional branches."""
    bits = []

    def put(value, width):
        assert 0 <= value < (1 << width)
        bits.extend(f"{value:0{width}b}")

    windows = 1 + index % 3
    put(version, 8)
    put(windows, 2)
    for window in range(1, windows):
        for coordinate in (window, window + 1, 60 - window, 61 - window, 32, 32):
            put(coordinate, 16)
        put(15 * window, 8)
        for axis in (10, 20, 15):
            put(axis, 16)
        put(window % 2, 1)
    put(1000 + index, 27)
    put(index % 2, 1)
    if index % 2:
        put(2, 5)
        put(2, 5)
        for luminance in (0, 5, 10, 15):
            put(luminance, 4)
    for window in range(windows):
        for channel in range(4):
            put(10000 + index * 137 + channel * 13 + window, 17)
        put(2, 4)
        for percentage, percentile in ((10, 1000), (90, 9000)):
            put(percentage, 7)
            put(percentile + index + window, 17)
        put(7 + index, 10)
    put(int(index % 3 == 0), 1)
    if index % 3 == 0:
        put(2, 5)
        put(2, 5)
        for luminance in (15, 10, 5, 0):
            put(luminance, 4)
    for window in range(windows):
        tone_mapping = (index + window) % 2
        put(tone_mapping, 1)
        if tone_mapping:
            put(1000 + index, 12)
            put(2000 + index, 12)
            put(2, 4)
            put(100 + index, 10)
            put(800 + index, 10)
        saturation = int((index + window) % 4 != 0)
        put(saturation, 1)
        if saturation:
            put(10 + index, 6)
    bits.extend("0" * (-len(bits) % 8))
    return HEADER + int("".join(bits), 2).to_bytes(len(bits) // 8, "big")


def escape_rbsp(data):
    output = bytearray()
    zeros = 0
    for value in data:
        if zeros == 2 and value <= 3:
            output.append(3)
            zeros = 0
        output.append(value)
        zeros = zeros + 1 if value == 0 else 0
    return bytes(output)


def unescape_rbsp(data):
    output = bytearray()
    zeros = 0
    for value in data:
        if zeros == 2 and value == 3:
            zeros = 0
            continue
        output.append(value)
        zeros = zeros + 1 if value == 0 else 0
    return bytes(output)


def sei_size(value):
    return b"\xff" * (value // 255) + bytes([value % 255])


def sei_nal(entries):
    rbsp = b"".join(
        sei_size(kind) + sei_size(len(payload)) + payload for kind, payload in entries
    )
    return b"\x4e\x01" + escape_rbsp(rbsp + b"\x80")


def inject_metadata(source, payloads):
    nals = re.split(b"\x00\x00\x00?\x01", source)
    output = bytearray()
    index = -1
    for nal in nals:
        if not nal:
            continue
        kind = (nal[0] >> 1) & 63
        if kind in (39, 40):
            continue
        output.extend(b"\x00\x00\x00\x01" + nal)
        if kind == 35:
            index += 1
            if payloads[index] is not None:
                entries = [
                    (4, payloads[index]),
                    (5, UUID + f"frame-{index:02d}".encode() + b"\0"),
                ]
                output.extend(b"\x00\x00\x00\x01" + sei_nal(entries))
    assert index + 1 == len(payloads)
    return bytes(output)


def packet_sei(packet):
    binary = bytes.fromhex(
        "".join(
            line.split(":", 1)[1].split("  ", 1)[0].replace(" ", "")
            for line in packet["data"].splitlines()
            if ":" in line
        )
    )
    entries = []
    offset = 0
    while offset < len(binary):
        length = int.from_bytes(binary[offset : offset + 4], "big")
        offset += 4
        nal = binary[offset : offset + length]
        assert length and len(nal) == length
        offset += length
        if ((nal[0] >> 1) & 63) not in (39, 40):
            continue
        rbsp = unescape_rbsp(nal[2:])
        cursor = 0
        while cursor < len(rbsp) and rbsp[cursor:] != b"\x80":
            kind = 0
            while rbsp[cursor] == 255:
                kind += 255
                cursor += 1
            kind += rbsp[cursor]
            cursor += 1
            size = 0
            while rbsp[cursor] == 255:
                size += 255
                cursor += 1
            size += rbsp[cursor]
            cursor += 1
            value = rbsp[cursor : cursor + size]
            assert len(value) == size
            entries.append((kind, value))
            cursor += size
    return entries


class CodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        help_text = run(FFMPEG, "-hide_banner", "-h", "encoder=libx265").stdout.decode()
        if not re.search(r"^\s+-hdr10plus\s+<boolean>", help_text, re.MULTILINE):
            raise AssertionError(
                "Production FFmpeg is missing the required HDR10+ patch"
            )
        cls.workspace = tempfile.TemporaryDirectory(prefix="chengying-hdr10plus-codec-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.base = cls.root / "base.hevc"
        run(
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=64x64:rate=24",
            "-frames:v",
            FRAME_COUNT,
            "-an",
            "-c:v",
            "libx265",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p10le",
            "-color_primaries",
            "bt2020",
            "-color_trc",
            "smpte2084",
            "-colorspace",
            "bt2020nc",
            "-color_range",
            "tv",
            "-x265-params",
            "aud=1:bframes=0:colorprim=9:transfer=16:colormatrix=9:log-level=error",
            cls.base,
        )
        cls.payloads = [hdr_payload(index) for index in range(FRAME_COUNT)]
        cls.source = cls.root / "hdr.hevc"
        cls.source.write_bytes(inject_metadata(cls.base.read_bytes(), cls.payloads))

    def encode(self, source, name, enabled=True, bframes=4, filters=()):
        destination = self.root / name
        run(
            FFMPEG,
            "-hide_banner",
            "-loglevel",
            "error",
            "-r",
            "24",
            "-i",
            source,
            "-map",
            "0:v:0",
            *filters,
            "-c:v",
            "libx265",
            "-preset",
            "ultrafast",
            "-hdr10plus",
            int(enabled),
            "-udu_sei",
            "1",
            "-pix_fmt",
            "yuv420p10le",
            "-x265-params",
            f"bframes={bframes}:b-adapt=0:keyint=48:log-level=error",
            "-tag:v",
            "hvc1",
            destination,
        )
        return destination

    def packets(self, path):
        data = json.loads(
            run(
                FFPROBE,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_packets",
                "-show_data",
                "-show_entries",
                "packet=pts,dts,data",
                "-of",
                "json",
                path,
            ).stdout
        )
        return data["packets"]

    def test_payload_bytes_follow_display_order_through_bframes_and_flush(self):
        destination = self.encode(self.source, "roundtrip.mp4")
        packets = self.packets(destination)
        self.assertEqual(len(packets), FRAME_COUNT)
        self.assertNotEqual(
            [p["pts"] for p in packets], sorted(p["pts"] for p in packets)
        )
        for index, packet in enumerate(sorted(packets, key=lambda p: p["pts"])):
            entries = packet_sei(packet)
            hdr = [
                value
                for kind, value in entries
                if kind == 4 and value.startswith(HEADER)
            ]
            self.assertEqual(
                hdr, [self.payloads[index]], f"HDR10+ payload changed at frame {index}"
            )
            user_data = UUID + f"frame-{index:02d}".encode() + b"\0"
            self.assertTrue(
                any(kind == 5 and value.endswith(user_data) for kind, value in entries)
            )
        frames = json.loads(
            run(
                FFPROBE,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_frames",
                "-of",
                "json",
                destination,
            ).stdout
        )["frames"]
        self.assertEqual(len(frames), FRAME_COUNT)
        self.assertIn("B", {frame["pict_type"] for frame in frames})
        for frame in frames:
            self.assertEqual(frame["pix_fmt"], "yuv420p10le")
            self.assertEqual(frame["color_primaries"], "bt2020")
            self.assertEqual(frame["color_transfer"], "smpte2084")
            self.assertEqual(frame["color_space"], "bt2020nc")
            self.assertEqual(frame["color_range"], "tv")
            hdr = [
                side
                for side in frame.get("side_data_list", [])
                if side["side_data_type"]
                == "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"
            ]
            self.assertEqual(len(hdr), 1)

    def test_hdr10plus_remains_opt_in(self):
        destination = self.encode(self.source, "disabled.mp4", enabled=False)
        self.assertFalse(
            any(
                kind == 4 and value.startswith(HEADER)
                for packet in self.packets(destination)
                for kind, value in packet_sei(packet)
            )
        )

    def test_missing_middle_frame_is_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError) as result:
            self.encode(
                self.source,
                "missing.mp4",
                filters=(
                    "-vf",
                    "sidedata=delete:type=DYNAMIC_HDR_PLUS:enable='eq(n,7)'",
                ),
            )
        self.assertIn(
            b"HDR10+ enabled, but frame metadata is missing or invalid",
            result.exception.stderr,
        )

    def test_no_metadata_is_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.encode(self.base, "absent.mp4")

    def test_unsupported_application_version_is_rejected(self):
        source = self.root / "future.hevc"
        source.write_bytes(
            inject_metadata(
                self.base.read_bytes(),
                [hdr_payload(index, version=2) for index in range(FRAME_COUNT)],
            )
        )
        with self.assertRaises(subprocess.CalledProcessError):
            self.encode(source, "future.mp4")


if __name__ == "__main__":
    unittest.main()
