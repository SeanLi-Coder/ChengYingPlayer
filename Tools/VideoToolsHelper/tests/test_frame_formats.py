from __future__ import annotations

import json
import struct
import subprocess
import time
from pathlib import Path

import pytest

from media import (
    FrameExtractionJob,
    FrameExtractionManager,
    MediaError,
    VideoSource,
    probe_video,
)


def _video(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    *,
    pixel_format: str = "yuv420p",
    codec: str = "ffv1",
    color_options: tuple[str, ...] = (),
) -> VideoSource:
    path = tmp_path / ("synthetic.nut" if codec == "rawvideo" else "synthetic.mkv")
    alpha = "ap" in pixel_format or pixel_format == "bgra"
    pattern = (
        "color=c=0xD73575@0.5:size=64x36:rate=10:duration=1,format=rgba"
        if alpha
        else "color=c=0xD73575:size=64x36:rate=10:duration=1"
    )
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            pattern,
            "-c:v",
            codec,
            "-pix_fmt",
            pixel_format,
            *color_options,
            str(path),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return VideoSource("synthetic", path, probe_video(path, ffprobe=ffprobe))


def _completed(job: FrameExtractionJob) -> dict:
    deadline = time.monotonic() + 60
    while (
        job.snapshot()["status"] in {"queued", "running"}
        and time.monotonic() < deadline
    ):
        time.sleep(0.02)
    snapshot = job.snapshot()
    assert snapshot["status"] == "completed", snapshot
    return snapshot


@pytest.mark.parametrize(
    "pixel_format,codec,extension,depth,alpha",
    [
        ("yuv420p10le", "ffv1", ".png", 16, False),
        ("gbrp16le", "ffv1", ".png", 16, False),
        ("bgra", "ffv1", ".png", 8, True),
        ("gbrap16le", "ffv1", ".png", 16, True),
        ("gbrpf32le", "rawvideo", ".exr", 32, False),
        ("gbrapf32le", "rawvideo", ".exr", 32, True),
    ],
)
def test_lossless_mode_keeps_high_depth_alpha_and_float(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    pixel_format: str,
    codec: str,
    extension: str,
    depth: int,
    alpha: bool,
) -> None:
    source = _video(tmp_path, ffmpeg, ffprobe, pixel_format=pixel_format, codec=codec)
    assert source.metadata["video_bit_depth"] > 8 or alpha
    assert source.metadata["has_alpha"] == alpha
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(
        source, start=0.2, end=0.5, output_directory=tmp_path, frame_format="png"
    )
    snapshot = _completed(job)
    assert job.frame_format == "png"
    assert job.frame_extension == extension
    assert snapshot["frame_count"] == 3
    frames = sorted(job.output_path.iterdir())
    assert len(frames) == 3
    for frame in frames:
        assert frame.suffix == extension
        if extension == ".png":
            width, height, bit_depth, color_type = manager._png_header(frame)
            assert (width, height, bit_depth) == (64, 36, depth)
            assert (color_type in {4, 6}) == alpha
        else:
            stream = manager._probe_still(frame)
            assert stream["codec_name"] == "exr"
            assert stream["pix_fmt"] == pixel_format
            assert (stream["width"], stream["height"]) == (64, 36)
        if pixel_format != "yuv420p10le":
            actual = _raw(ffmpeg, frame, pixel_format)
            original = _raw(ffmpeg, source.path, pixel_format)
            if extension == ".exr" and alpha:
                # OpenEXR uses associated alpha; compare the represented colors,
                # not straight RGB bytes against correctly premultiplied samples.
                # https://openexr.com/en/latest/TechnicalIntroduction.html
                decoded = subprocess.run(
                    [
                        ffprobe,
                        "-v",
                        "error",
                        "-select_streams",
                        "v:0",
                        "-show_entries",
                        "frame=alpha_mode",
                        "-of",
                        "json",
                        str(frame),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                assert (
                    json.loads(decoded.stdout)["frames"][0]["alpha_mode"]
                    == "premultiplied"
                )
                count = 64 * 36
                assert len(original) == len(actual) == count * 4 * 4
                assert actual[-count * 4 :] == original[-count * 4 :]
                samples = [value[0] for value in struct.iter_unpack("<f", original)]
                expected_rgb = b"".join(
                    struct.pack("<f", value * samples[3 * count + index % count])
                    for index, value in enumerate(samples[: 3 * count])
                )
                assert actual[: 3 * count * 4] == expected_rgb
            else:
                assert actual == original


@pytest.mark.parametrize(
    "pixel_format,codec",
    [
        ("bgra", "ffv1"),
        ("gbrap16le", "ffv1"),
        ("gbrpf32le", "rawvideo"),
        ("gbrapf32le", "rawvideo"),
    ],
)
def test_default_jpg_rejects_transparency_and_float_before_creating_output(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    pixel_format: str,
    codec: str,
) -> None:
    source = _video(tmp_path, ffmpeg, ffprobe, pixel_format=pixel_format, codec=codec)
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    with pytest.raises(MediaError, match="select lossless PNG/EXR"):
        manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    assert list(tmp_path.iterdir()) == [source.path]


def test_default_jpg_explicitly_reports_high_depth_sdr_quantization(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    source = _video(tmp_path, ffmpeg, ffprobe, pixel_format="yuv420p10le")
    assert source.metadata["video_bit_depth"] == 10
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    snapshot = _completed(job)
    assert "lossy 8-bit JPG" in snapshot["message"]
    assert (
        manager._probe_still(job.output_path / "frame_000001.jpg")["pix_fmt"]
        == "yuvj444p"
    )


def test_real_hdr_source_requires_explicit_lossless_mode(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    source = _video(
        tmp_path,
        ffmpeg,
        ffprobe,
        pixel_format="yuv420p10le",
        color_options=(
            "-vf",
            "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084",
            "-colorspace",
            "bt2020nc",
            "-color_primaries",
            "bt2020",
            "-color_trc",
            "smpte2084",
        ),
    )
    assert source.metadata["is_hdr"] is True
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    with pytest.raises(MediaError, match="select lossless PNG/EXR"):
        manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    job = manager.create(
        source, start=0, end=0.1, output_directory=tmp_path, frame_format="png"
    )
    _completed(job)
    assert manager._png_header(job.output_path / "frame_000001.png")[2] == 16


@pytest.mark.parametrize(
    "metadata",
    [
        {"is_hdr": True},
        {"is_dolby_vision": True},
        {"color_transfer": "smpte2084"},
        {"color_transfer": "arib-std-b67"},
        {"color_primaries": "bt2020"},
        {"color_primaries": "smpte432"},
        {"color_space": "bt2020nc"},
        {"is_palette": True},
        {"static_hdr_metadata": {"mastering": "fixture"}},
        {"dynamic_hdr_metadata_types": ["HDR10+ Dynamic Metadata"]},
    ],
)
def test_jpg_color_and_representation_guards(metadata: dict, tmp_path: Path) -> None:
    source = VideoSource(
        "guard", tmp_path / "unopened.nut", {"pix_fmt": "yuv420p", **metadata}
    )
    with pytest.raises(MediaError, match="select lossless PNG/EXR"):
        FrameExtractionManager._image_profile(source)
    assert FrameExtractionManager._image_profile(source, "png")[0] == ".png"


@pytest.mark.parametrize(
    "frame_format", [None, True, 1, [], {}, "jpeg", "JPG", "../jpg", ""]
)
def test_manager_rejects_invalid_format_before_accessing_source(
    frame_format, tmp_path: Path
) -> None:
    source = VideoSource("guard", tmp_path / "unopened.nut", {})
    manager = FrameExtractionManager(
        ffmpeg="unused", ffprobe="unused", encoders={"png", "mjpeg"}
    )
    with pytest.raises(MediaError, match="frame_format must be jpg or png"):
        manager.create(
            source,
            start=0,
            end=0.1,
            output_directory=tmp_path,
            frame_format=frame_format,
        )


def _raw(ffmpeg: str, path: Path, pixel_format: str = "rgb24") -> bytes:
    return subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-frames:v",
            "1",
            "-f",
            "rawvideo",
            "-pix_fmt",
            pixel_format,
            "-",
        ],
        check=True,
        capture_output=True,
        timeout=30,
    ).stdout


@pytest.mark.parametrize("color_range", ["tv", "pc"])
def test_jpg_color_matches_decoded_bt709_source(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    color_range: str,
) -> None:
    source = _video(
        tmp_path,
        ffmpeg,
        ffprobe,
        color_options=(
            "-vf",
            f"scale=in_color_matrix=bt601:out_color_matrix=bt709:out_range={color_range}",
            "-colorspace",
            "bt709",
            "-color_primaries",
            "bt709",
            "-color_trc",
            "bt709",
            "-color_range",
            color_range,
        ),
    )
    assert source.metadata["color_space"] == "bt709"
    assert source.metadata["color_range"] == color_range
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    _completed(job)
    original = _raw(ffmpeg, source.path)
    actual = _raw(ffmpeg, job.output_path / "frame_000001.jpg")
    assert len(original) == len(actual) == 64 * 36 * 3
    errors = [abs(left - right) for left, right in zip(original, actual, strict=True)]
    assert max(errors) <= 5
    assert sum(errors) / len(errors) <= 3


def test_jpg_verification_rejects_disguised_or_truncated_images(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    source = _video(tmp_path, ffmpeg, ffprobe)
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    png_job = manager.create(
        source, start=0, end=0.1, output_directory=tmp_path, frame_format="png"
    )
    _completed(png_job)
    job = manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    _completed(job)
    frame = job.output_path / "frame_000001.jpg"
    jpeg = frame.read_bytes()
    frame.write_bytes((png_job.output_path / "frame_000001.png").read_bytes())
    with pytest.raises(MediaError):
        manager._verify_frames(job, [frame])
    frame.write_bytes(jpeg[:-16])
    with pytest.raises(MediaError):
        manager._verify_frames(job, [frame])


def test_jpg_round_trip_does_not_overwrite_previous_output(
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    source = _video(tmp_path, ffmpeg, ffprobe)
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    first = manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    _completed(first)
    existing = (first.output_path / "frame_000001.jpg").read_bytes()
    second = manager.create(source, start=0, end=0.1, output_directory=tmp_path)
    _completed(second)
    assert first.output_path != second.output_path
    assert (first.output_path / "frame_000001.jpg").read_bytes() == existing


def test_jpg_frames_keep_rotated_display_dimensions(
    sample_video: Path,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
) -> None:
    rotated = tmp_path / "rotation.mp4"
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-display_rotation",
            "90",
            "-i",
            str(sample_video),
            "-c",
            "copy",
            str(rotated),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    source = VideoSource("rotated", rotated, probe_video(rotated, ffprobe=ffprobe))
    assert (source.metadata["width"], source.metadata["height"]) == (180, 320)
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(source, start=0.1, end=0.2, output_directory=tmp_path)
    assert _completed(job)["frame_count"] == 3
    for frame in job.output_path.iterdir():
        stream = manager._probe_still(frame)
        assert (stream["width"], stream["height"]) == (180, 320)


@pytest.mark.parametrize(
    "frame_format,encoders,missing",
    [
        ("jpg", {"png"}, "mjpeg"),
        ("png", {"mjpeg"}, "png"),
    ],
)
def test_selected_encoder_is_required_without_silent_fallback(
    sample_video: Path,
    tmp_path: Path,
    ffmpeg: str,
    ffprobe: str,
    frame_format: str,
    encoders: set[str],
    missing: str,
) -> None:
    source = VideoSource(
        "encoder", sample_video, probe_video(sample_video, ffprobe=ffprobe)
    )
    manager = FrameExtractionManager(ffmpeg=ffmpeg, ffprobe=ffprobe, encoders=encoders)
    with pytest.raises(MediaError, match=f"encoder is not available: {missing}"):
        manager.create(
            source,
            start=0,
            end=0.1,
            output_directory=tmp_path,
            frame_format=frame_format,
        )
