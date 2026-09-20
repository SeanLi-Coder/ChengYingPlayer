from __future__ import annotations

import hashlib
import json
import struct
import subprocess
from pathlib import Path

import pytest

import media
from media import MediaError, RotationManager, VideoSource, probe_video

UNIT = 65_536
IDENTITY = (UNIT, 0, 0, 0, UNIT, 0, 0, 0, 1 << 30)
ORIENTATIONS = [
    ("identity", (1, 0, 0, 1)),
    ("left", (0, -1, 1, 0)),
    ("upside-down", (-1, 0, 0, -1)),
    ("right", (0, 1, -1, 0)),
    ("horizontal-mirror", (-1, 0, 0, 1)),
    ("vertical-mirror", (1, 0, 0, -1)),
    ("diagonal-mirror", (0, 1, 1, 0)),
    ("anti-diagonal-mirror", (0, -1, -1, 0)),
]


def run(ffmpeg: str, *arguments: str) -> bytes:
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", *arguments],
        check=False,
        capture_output=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    return result.stdout


def atoms(data: bytearray, start: int, end: int):
    while start < end:
        size, kind = struct.unpack_from(">I4s", data, start)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, start + 8)[0]
            header = 16
        elif size == 0:
            size = end - start
        assert size >= header and start + size <= end
        yield kind, start + header, start + size
        start += size


def with_matrix(original: Path, destination: Path, matrix: tuple[int, ...]) -> Path:
    """Patch only the video track's tkhd matrix in a generated MOV fixture."""
    data = bytearray(original.read_bytes())
    patched = 0
    for kind, start, end in atoms(data, 0, len(data)):
        if kind != b"moov":
            continue
        for track_kind, track_start, track_end in atoms(data, start, end):
            if track_kind != b"trak":
                continue
            children = list(atoms(data, track_start, track_end))
            is_video = any(
                nested_kind == b"hdlr"
                and data[nested_start + 8 : nested_start + 12] == b"vide"
                for child_kind, child_start, child_end in children
                if child_kind == b"mdia"
                for nested_kind, nested_start, _ in atoms(data, child_start, child_end)
            )
            if not is_video:
                continue
            for child_kind, child_start, _ in children:
                if child_kind == b"tkhd":
                    offset = child_start + (52 if data[child_start] == 1 else 40)
                    struct.pack_into(">9i", data, offset, *matrix)
                    patched += 1
    assert patched == 1
    destination.write_bytes(data)
    return destination


def transform_matrix(linear: tuple[int, int, int, int], *, translated: bool = True):
    a, b, c, d = linear
    return (
        a * UNIT,
        b * UNIT,
        0,
        c * UNIT,
        d * UNIT,
        0,
        96 * UNIT if translated else 0,
        -64 * UNIT if translated else 0,
        1 << 30,
    )


def transform_rgb(
    pixels: bytes, width: int, height: int, linear: tuple[int, int, int, int]
) -> tuple[bytes, int, int]:
    """An independent integer-coordinate oracle, not FFmpeg's orientation logic."""
    a, b, c, d = linear
    corners = [
        (a * x + c * y, b * x + d * y) for x in (0, width - 1) for y in (0, height - 1)
    ]
    left, right = min(x for x, _ in corners), max(x for x, _ in corners)
    top, bottom = min(y for _, y in corners), max(y for _, y in corners)
    out_width, out_height = right - left + 1, bottom - top + 1
    frame_size = width * height * 3
    assert len(pixels) % frame_size == 0
    result = bytearray(len(pixels))
    for offset in range(0, len(pixels), frame_size):
        for y in range(height):
            for x in range(width):
                source = offset + (y * width + x) * 3
                target = (
                    offset
                    + ((b * x + d * y - top) * out_width + a * x + c * y - left) * 3
                )
                result[target : target + 3] = pixels[source : source + 3]
    return bytes(result), out_width, out_height


def decode_rgb(ffmpeg: str, path: Path) -> bytes:
    return run(
        ffmpeg,
        "-noautorotate",
        "-i",
        str(path),
        "-map",
        "0:v:0",
        "-an",
        "-pix_fmt",
        "rgb24",
        "-f",
        "rawvideo",
        "pipe:1",
    )


def audio_hashes(ffprobe: str, path: Path) -> list[str]:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_packets",
            "-show_entries",
            "packet=data_hash",
            "-show_data_hash",
            "sha256",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return [packet["data_hash"] for packet in json.loads(result.stdout)["packets"]]


@pytest.fixture(scope="module")
def lossless_mov(tmp_path_factory, ffmpeg: str) -> Path:
    path = tmp_path_factory.mktemp("display-matrix") / "orientation.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=96x64:rate=4:duration=0.5",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=937:sample_rate=48000:duration=0.5",
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-c:v",
        "png",
        "-pix_fmt",
        "rgb24",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        str(path),
    )
    return path


def rotate(manager: RotationManager, path: Path, degrees: int, ffprobe: str):
    metadata = probe_video(path, ffprobe=ffprobe)
    job = manager.create(VideoSource("matrix-fixture", path, metadata), degrees=degrees)
    assert job.worker is not None
    job.worker.join(timeout=60)
    assert not job.worker.is_alive(), "Rotation worker exceeded its test deadline"
    assert job.snapshot()["status"] == "completed", job.snapshot()
    return job.output_path, probe_video(job.output_path, ffprobe=ffprobe)


@pytest.mark.parametrize("degrees", [90, 180, 270, 360])
@pytest.mark.parametrize(
    ("name", "linear"), ORIENTATIONS, ids=[item[0] for item in ORIENTATIONS]
)
def test_translated_and_mirrored_mov_rotates_every_pixel_without_losing_audio(
    degrees: int,
    name: str,
    linear: tuple[int, int, int, int],
    lossless_mov: Path,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    matrix = transform_matrix(linear)
    path = with_matrix(lossless_mov, tmp_path / f"{name}.mov", matrix)
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    metadata = probe_video(path, ffprobe=ffprobe)
    assert metadata["display_matrix"] == matrix
    expected, width, height = transform_rgb(
        decode_rgb(ffmpeg, lossless_mov), 96, 64, linear
    )
    assert (metadata["width"], metadata["height"]) == (width, height)
    turn = {
        90: (0, 1, -1, 0),
        180: (-1, 0, 0, -1),
        270: (0, -1, 1, 0),
        360: (1, 0, 0, 1),
    }[degrees]
    expected, width, height = transform_rgb(expected, width, height, turn)
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    output, result = rotate(manager, path, degrees, ffprobe)

    assert (result["width"], result["height"]) == (width, height)
    assert result["rotation"] == 0
    assert result["display_matrix"] is None
    assert result["video_bit_depth"] == metadata["video_bit_depth"]
    assert result["fps"] == metadata["fps"]
    assert result["audio_sample_rate"] == metadata["audio_sample_rate"] == 48_000
    assert result["audio_channels"] == metadata["audio_channels"]
    assert audio_hashes(ffprobe, output) == audio_hashes(ffprobe, path)
    assert decode_rgb(ffmpeg, output) == expected
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before


@pytest.mark.parametrize(
    ("name", "linear"), ORIENTATIONS, ids=[item[0] for item in ORIENTATIONS]
)
def test_origin_and_translated_matrices_have_identical_orientation(name, linear):
    assert media._display_transform_filters(
        transform_matrix(linear, translated=False)
    ) == (media._display_transform_filters(transform_matrix(linear)))


def test_consecutive_rotations_apply_to_the_current_displayed_picture(
    lossless_mov: Path,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    linear = (0, 1, 1, 0)
    path = with_matrix(
        lossless_mov, tmp_path / "mirrored-phone.mov", transform_matrix(linear)
    )
    expected, width, height = transform_rgb(
        decode_rgb(ffmpeg, lossless_mov), 96, 64, linear
    )
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    current = path
    for _ in range(4):
        current, result = rotate(manager, current, 90, ffprobe)
        expected, width, height = transform_rgb(expected, width, height, (0, 1, -1, 0))
        assert (result["width"], result["height"]) == (width, height)
        assert result["display_matrix"] is None
        assert decode_rgb(ffmpeg, current) == expected
        assert audio_hashes(ffprobe, current) == audio_hashes(ffprobe, path)


@pytest.mark.parametrize("degrees", [90, 180, 360])
def test_rotated_anamorphic_422_source_preserves_chroma_before_baking_matrix(
    degrees: int,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    original = tmp_path / "anamorphic-422.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=96x64:rate=4:duration=0.5",
        "-vf",
        "setsar=4/3",
        "-c:v",
        "libx264",
        "-crf",
        "0",
        "-pix_fmt",
        "yuv422p",
        str(original),
    )
    path = with_matrix(
        original, tmp_path / "rotated-422.mov", transform_matrix((0, 1, -1, 0))
    )
    before = probe_video(path, ffprobe=ffprobe)
    assert before["sample_aspect_ratio"] == "3:4"
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    output, result = rotate(manager, path, degrees, ffprobe)
    assert result["video_codec"] == "ffv1"
    assert result["pix_fmt"] == "yuv444p"
    assert result["sample_aspect_ratio"] == ("4:3" if degrees == 90 else "3:4")
    inverse_user = {90: "transpose=cclock", 180: "hflip,vflip", 360: "null"}[degrees]
    restored = run(
        ffmpeg,
        "-noautorotate",
        "-i",
        str(output),
        "-an",
        "-vf",
        f"{inverse_user},transpose=cclock",
        "-pix_fmt",
        "yuv444p",
        "-f",
        "rawvideo",
        "pipe:1",
    )
    expected = run(
        ffmpeg,
        "-noautorotate",
        "-i",
        str(original),
        "-an",
        "-vf",
        "format=yuv444p",
        "-pix_fmt",
        "yuv444p",
        "-f",
        "rawvideo",
        "pipe:1",
    )
    assert restored == expected


@pytest.mark.parametrize("mode", ["copy", "h264"])
def test_conversion_verifies_mirroring_not_just_rotation_angle(
    mode: str,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    monkeypatch,
) -> None:
    import conversion

    original = tmp_path / "source.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=96x64:rate=4:duration=0.5",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        str(original),
    )
    # A vertical mirror reports rotation=0, just like an untransformed video.
    mirrored = with_matrix(
        original, tmp_path / "mirrored.mov", transform_matrix((1, 0, 0, -1))
    )
    metadata = probe_video(mirrored, ffprobe=ffprobe)
    plain_metadata = probe_video(original, ffprobe=ffprobe)
    assert metadata["rotation"] == plain_metadata["rotation"] == 0
    manager = conversion.ConversionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = conversion.ConversionJob(
        id="lost-mirror",
        source=VideoSource("mirrored", mirrored, metadata),
        target_format="mov",
        mode=mode,
        output_path=tmp_path / "wrong.mov",
    )
    monkeypatch.setattr(
        conversion, "probe_video", lambda *args, **kwargs: plain_metadata
    )
    with pytest.raises(MediaError, match="display orientation change"):
        manager._verify_conversion(job, original, {})


def test_phone_metadata_tracks_choose_mov_and_copy_payloads(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    packet = tmp_path / "metadata.bin"
    packet.write_bytes(b"Generated phone metadata preservation fixture.")
    original = tmp_path / "phone.mp4"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=96x64:rate=4:duration=0.5",
        "-f",
        "data",
        "-i",
        str(packet),
        "-map",
        "0:v",
        "-map",
        "1:0",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:d",
        "copy",
        "-tag:d",
        "mebx",
        "-f",
        "mov",
        str(original),
    )
    path = with_matrix(
        original, tmp_path / "transformed-phone.mp4", transform_matrix((0, 1, -1, 0))
    )
    metadata = probe_video(path, ffprobe=ffprobe)
    assert metadata["has_data_streams"] is True
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    output, result = rotate(manager, path, 90, ffprobe)
    assert output.suffix == ".mov"
    assert result["has_data_streams"] is True
    assert run(
        ffmpeg, "-i", str(output), "-map", "0:d:0", "-c", "copy", "-f", "data", "pipe:1"
    ) == (packet.read_bytes())


def test_lossless_mkv_does_not_silently_drop_metadata_tracks(
    lossless_mov: Path,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    metadata = {**probe_video(lossless_mov, ffprobe=ffprobe), "has_data_streams": True}
    source = VideoSource("data-in-lossless", lossless_mov, metadata)
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    with pytest.raises(MediaError, match="Ancillary data tracks cannot be preserved"):
        manager.create(source, degrees=90)


def test_selected_video_after_audio_uses_its_own_matrix(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    path = tmp_path / "audio-first.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=96x64:rate=4:duration=0.5",
        "-f",
        "lavfi",
        "-i",
        "sine=sample_rate=48000:duration=0.5",
        "-map",
        "1:a",
        "-map",
        "0:v",
        "-c:v",
        "png",
        "-pix_fmt",
        "rgb24",
        "-c:a",
        "aac",
        str(path),
    )
    tagged = with_matrix(
        path, tmp_path / "audio-first-tagged.mov", transform_matrix((0, 1, 1, 0))
    )
    metadata = probe_video(tagged, ffprobe=ffprobe)
    assert metadata["video_stream_index"] == 1
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    output, _ = rotate(manager, tagged, 360, ffprobe)
    expected, _, _ = transform_rgb(decode_rgb(ffmpeg, path), 96, 64, (0, 1, 1, 0))
    assert decode_rgb(ffmpeg, output) == expected
    assert audio_hashes(ffprobe, output) == audio_hashes(ffprobe, path)


def test_variable_frame_timestamps_are_not_quantized_to_nominal_frame_rate(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    original = tmp_path / "variable-frame-rate.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=96x64:rate=60:duration=0.5",
        "-vf",
        "settb=1/600,setpts=N*10+floor(N/3)",
        "-fps_mode",
        "passthrough",
        "-enc_time_base",
        "1/600",
        "-video_track_timescale",
        "600",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        str(original),
    )
    before = probe_video(original, ffprobe=ffprobe)
    manager = RotationManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    output, after = rotate(manager, original, 90, ffprobe)
    assert before["average_frame_rate"] != before["nominal_frame_rate"]
    assert after["fps"] == before["fps"]
    assert after["video_frame_count"] == before["video_frame_count"]
    assert after["duration"] == before["duration"]
    timestamps = []
    for path in (original, output):
        result = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_packets",
                "-show_entries",
                "packet=pts_time",
                "-of",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
        timestamps.append(
            sorted(
                packet["pts_time"] for packet in json.loads(result.stdout)["packets"]
            )
        )
    assert timestamps[0] == timestamps[1]


@pytest.mark.parametrize(
    ("index", "value", "message"),
    [
        (0, 2 * UNIT, "scaled"),
        (1, UNIT // 4, "sheared"),
        (0, 0, "scaled"),
        (2, 1, "perspective"),
        (5, 1, "perspective"),
        (8, 0, "perspective"),
        (8, (1 << 30) // 2, "perspective"),
        (6, 1 << 31, "Invalid"),
    ],
)
def test_non_lossless_or_invalid_matrices_are_still_rejected(index, value, message):
    matrix = list(IDENTITY)
    matrix[index] = value
    with pytest.raises(MediaError, match=message):
        media._display_transform_filters(tuple(matrix))


@pytest.mark.parametrize(
    "text",
    [
        "00000000: 65536 0 0\n00000001: 0 65536 0",
        "00000000: 65536x 0 0\n00000001: 0 65536 0\n00000002: 0 0 1073741824",
        "00000000: 65536 0 0\n00000001: broken\n00000002: 0 0 1073741824",
    ],
)
def test_malformed_matrix_text_is_not_partially_accepted(text):
    assert media._parse_display_matrix(text) is None
