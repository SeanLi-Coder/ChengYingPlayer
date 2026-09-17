from __future__ import annotations

import hashlib
import json
import subprocess
import threading
import time
from pathlib import Path

import pytest

import conversion
from conversion import ConversionJob, ConversionManager
from media import MediaError, VideoSource, probe_video


def run(ffmpeg: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", *arguments],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result


def wait(job: ConversionJob) -> dict:
    assert job.worker is not None
    job.worker.join(timeout=120)
    assert not job.worker.is_alive(), "Conversion worker exceeded its test deadline"
    return job.snapshot()


def source(path: Path, ffprobe: str) -> VideoSource:
    return VideoSource("conversion-source", path, probe_video(path, ffprobe=ffprobe))


@pytest.fixture
def manager(ffmpeg: str, ffprobe: str):
    instance = ConversionManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    yield instance
    instance.cancel_all()


def packet_hashes(ffprobe: str, path: Path, selector: str) -> list[str]:
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            selector,
            "-show_packets",
            "-show_entries",
            "packet=data_hash",
            "-show_data_hash",
            "sha256",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    return [packet["data_hash"] for packet in json.loads(result.stdout)["packets"]]


@pytest.mark.parametrize("target_format", ["mp4", "mkv", "mov"])
def test_lossless_container_conversion_preserves_video_and_audio_packets(
    manager,
    sample_video: Path,
    ffprobe: str,
    target_format: str,
) -> None:
    original_hash = hashlib.sha256(sample_video.read_bytes()).hexdigest()
    job = manager.create(
        source(sample_video, ffprobe),
        target_format=target_format,
        mode="copy",
        output_directory=sample_video.parent,
    )
    status = wait(job)
    assert status["status"] == "completed", status
    assert status["progress"] == 100
    assert status["operation"] == "convert"
    assert status["conversion_mode"] == "copy"
    assert job.output_path != sample_video
    assert job.output_path.suffix == f".{target_format}"
    for selector in ("v:0", "a:0"):
        assert packet_hashes(ffprobe, sample_video, selector) == packet_hashes(
            ffprobe,
            job.output_path,
            selector,
        )
    assert hashlib.sha256(sample_video.read_bytes()).hexdigest() == original_hash
    assert not list(sample_video.parent.glob(".conversion-*"))


@pytest.mark.parametrize("mode", ["h264", "hevc"])
def test_high_quality_transcode_preserves_dimensions_and_copied_audio(
    manager,
    sample_video: Path,
    ffprobe: str,
    mode: str,
) -> None:
    if mode == "hevc" and "libx265" not in manager.encoders:
        pytest.skip("libx265 is unavailable")
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode=mode,
        output_directory=sample_video.parent,
    )
    status = wait(job)
    assert status["status"] == "completed", status
    result = probe_video(job.output_path, ffprobe=ffprobe)
    assert result["video_codec"] == mode
    assert (result["width"], result["height"], result["pix_fmt"]) == (
        320,
        180,
        "yuv420p",
    )
    assert result["duration"] == pytest.approx(6, abs=0.12)
    assert packet_hashes(ffprobe, sample_video, "a:0") == packet_hashes(
        ffprobe, job.output_path, "a:0"
    )


def test_output_collision_never_overwrites_existing_video(
    manager, sample_video, ffprobe
) -> None:
    before = sample_video.read_bytes()
    jobs = [
        manager.create(
            source(sample_video, ffprobe),
            target_format="mp4",
            mode="copy",
            output_directory=sample_video.parent,
        )
        for _ in range(2)
    ]
    for job in jobs:
        assert wait(job)["status"] == "completed", job.snapshot()
    assert len({job.output_path for job in jobs}) == 2
    assert sample_video.read_bytes() == before
    assert all(job.output_path.exists() for job in jobs)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("target_format", "../mp4"),
        ("target_format", "-y"),
        ("target_format", "webm"),
        ("target_format", None),
        ("target_format", []),
        ("target_format", "MP4"),
        ("mode", "copy;touch /tmp/unsafe"),
        ("mode", "av1"),
        ("mode", None),
        ("mode", {}),
    ],
)
def test_untrusted_parameters_rejected_before_worker(
    manager, tmp_path, field, value
) -> None:
    arguments = {"target_format": "mp4", "mode": "copy", "output_directory": tmp_path}
    arguments[field] = value
    with pytest.raises(MediaError, match="Unsupported"):
        manager.create(VideoSource("bad", tmp_path / "missing.mp4", {}), **arguments)
    assert not manager._jobs


def test_missing_output_directory_rejected(manager, sample_video, ffprobe) -> None:
    with pytest.raises(MediaError, match="writable"):
        manager.create(
            source(sample_video, ffprobe),
            target_format="mp4",
            mode="copy",
            output_directory=sample_video.parent / "missing",
        )


def test_multi_audio_and_subtitles_preserved_or_explicitly_rejected(
    manager,
    sample_video,
    ffmpeg,
    ffprobe,
    tmp_path,
) -> None:
    subtitles = tmp_path / "captions.srt"
    subtitles.write_text("1\n00:00:00,100 --> 00:00:01,000\nHello\n", encoding="utf-8")
    rich = tmp_path / "multiple tracks.mkv"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-i",
        str(subtitles),
        "-map",
        "0:v",
        "-map",
        "0:a",
        "-map",
        "0:a",
        "-map",
        "1:s",
        "-c",
        "copy",
        "-metadata:s:a:0",
        "language=eng",
        "-metadata:s:a:1",
        "language=jpn",
        "-metadata:s:s:0",
        "language=eng",
        str(rich),
    )
    successful = manager.create(
        source(rich, ffprobe),
        target_format="mkv",
        mode="copy",
        output_directory=tmp_path,
    )
    assert wait(successful)["status"] == "completed", successful.snapshot()
    for selector in ("a:0", "a:1", "s:0"):
        assert packet_hashes(ffprobe, rich, selector) == packet_hashes(
            ffprobe, successful.output_path, selector
        )
    rejected = manager.create(
        source(rich, ffprobe),
        target_format="mp4",
        mode="h264",
        output_directory=tmp_path,
    )
    status = wait(rejected)
    assert status["status"] == "failed"
    assert "subtitle" in status["error"] and "subrip" in status["error"]
    assert not rejected.output_path.exists()


def test_incompatible_audio_is_not_silently_transcoded(
    manager, sample_video, ffmpeg, ffprobe, tmp_path
) -> None:
    flac = tmp_path / "lossless-audio.mkv"
    run(ffmpeg, "-i", str(sample_video), "-c:v", "copy", "-c:a", "flac", str(flac))
    job = manager.create(
        source(flac, ffprobe),
        target_format="mp4",
        mode="h264",
        output_directory=tmp_path,
    )
    status = wait(job)
    assert status["status"] == "failed"
    assert "audio" in status["error"] and "flac" in status["error"]
    assert not job.output_path.exists()


def test_multiple_video_tracks_rejected_without_removing_one(
    manager, sample_video, ffmpeg, ffprobe, tmp_path
) -> None:
    multi = tmp_path / "two-video-tracks.mkv"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-map",
        "0:v",
        "-map",
        "0:v",
        "-map",
        "0:a",
        "-c",
        "copy",
        str(multi),
    )
    job = manager.create(
        source(multi, ffprobe),
        target_format="mkv",
        mode="copy",
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "failed"
    assert "Multiple video tracks" in job.error
    assert not job.output_path.exists()


@pytest.mark.parametrize("mode", ["copy", "h264"])
def test_display_rotation_and_anamorphic_pixels_preserved(
    manager,
    sample_video,
    ffmpeg,
    ffprobe,
    tmp_path,
    mode,
) -> None:
    anamorphic = tmp_path / "anamorphic.mp4"
    rotated = tmp_path / "portrait.mov"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-vf",
        "setsar=4/3",
        "-c:v",
        "libx264",
        "-c:a",
        "copy",
        str(anamorphic),
    )
    run(
        ffmpeg,
        "-display_rotation:v:0",
        "90",
        "-i",
        str(anamorphic),
        "-c",
        "copy",
        str(rotated),
    )
    assert probe_video(rotated, ffprobe=ffprobe)["rotation"] == 90
    job = manager.create(
        source(rotated, ffprobe),
        target_format="mov",
        mode=mode,
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "completed", job.snapshot()
    output = probe_video(job.output_path, ffprobe=ffprobe)
    assert output["rotation"] == 90
    assert output["sample_aspect_ratio"] == "3:4"
    assert output["encoded_width"] == 320 and output["encoded_height"] == 180


def test_high_bit_depth_hdr_uses_hevc_without_color_reduction(
    manager, ffmpeg, ffprobe, tmp_path
) -> None:
    if "libx265" not in manager.encoders:
        pytest.skip("libx265 is unavailable")
    hdr = tmp_path / "hdr10.mp4"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=128x72:rate=12:duration=1",
        "-c:v",
        "libx265",
        "-pix_fmt",
        "yuv420p10le",
        "-color_trc",
        "smpte2084",
        "-color_primaries",
        "bt2020",
        "-colorspace",
        "bt2020nc",
        "-color_range",
        "tv",
        "-x265-params",
        "pools=1:log-level=error:hdr-opt=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400",
        str(hdr),
    )
    job = manager.create(
        source(hdr, ffprobe),
        target_format="mp4",
        mode="hevc",
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "completed", job.snapshot()
    result = probe_video(job.output_path, ffprobe=ffprobe)
    assert result["video_bit_depth"] == 10
    assert result["static_hdr_metadata"] == job.source.metadata["static_hdr_metadata"]
    rejected = manager.create(
        source(hdr, ffprobe),
        target_format="mp4",
        mode="h264",
        output_directory=tmp_path,
    )
    assert wait(rejected)["status"] == "failed"
    assert "HDR" in rejected.error


def test_chapters_and_attachments_survive_mkv_copy(
    manager, sample_video, ffmpeg, ffprobe, tmp_path
) -> None:
    chapter_file = tmp_path / "chapters.ffmeta"
    chapter_file.write_text(
        ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=3000\ntitle=First\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=3000\nEND=6000\ntitle=Second\n",
        encoding="utf-8",
    )
    attachment = tmp_path / "readme.txt"
    attachment.write_text("A retained attachment", encoding="utf-8")
    rich = tmp_path / "chapters.mkv"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-i",
        str(chapter_file),
        "-map",
        "0",
        "-map_chapters",
        "1",
        "-c",
        "copy",
        "-attach",
        str(attachment),
        "-metadata:s:t:0",
        "mimetype=text/plain",
        str(rich),
    )
    job = manager.create(
        source(rich, ffprobe),
        target_format="mkv",
        mode="copy",
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "completed", job.snapshot()
    inventory = manager._inventory(job.output_path, threading.Event())
    assert len(inventory["chapters"]) == 2
    assert any(stream["codec_type"] == "attachment" for stream in inventory["streams"])


def test_cancel_during_validation_never_publishes_output(
    manager, sample_video, ffprobe, monkeypatch
) -> None:
    entered = threading.Event()
    original = manager._verify_conversion

    def verify(job, path, inventory):
        assert job.progress == 99
        assert job.snapshot()["estimated_remaining_seconds"] is None
        entered.set()
        assert job.cancel_event.wait(timeout=10)
        raise InterruptedError

    monkeypatch.setattr(manager, "_verify_conversion", verify)
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=sample_video.parent,
    )
    assert entered.wait(timeout=30)
    manager.cancel(job.id)
    status = wait(job)
    assert status["status"] == "cancelled", status
    assert status["output_path"] is None
    assert not job.output_path.exists()
    assert not list(sample_video.parent.glob(".conversion-*"))
    monkeypatch.setattr(manager, "_verify_conversion", original)


def test_encoding_failure_cleans_owned_partial_only(
    manager, sample_video, ffprobe, monkeypatch
) -> None:
    unrelated = sample_video.parent / ".conversion-unrelated.mp4"
    unrelated.write_bytes(b"keep")
    monkeypatch.setattr(
        manager, "_command", lambda *args: [manager.ffmpeg, "-not-a-real-option"]
    )
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=sample_video.parent,
    )
    assert wait(job)["status"] == "failed"
    assert not job.output_path.exists()
    assert unrelated.read_bytes() == b"keep"
    assert list(sample_video.parent.glob(".conversion-*")) == [unrelated]


def test_source_change_during_conversion_prevents_publish(
    manager, sample_video, ffprobe, monkeypatch
) -> None:
    original = manager._verify_conversion

    def verify(job, path, inventory):
        original(job, path, inventory)
        with sample_video.open("ab") as stream:
            stream.write(b"source was changed")

    monkeypatch.setattr(manager, "_verify_conversion", verify)
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=sample_video.parent,
    )
    assert wait(job)["status"] == "failed"
    assert "original video changed" in job.error
    assert not job.output_path.exists()


def test_conversion_eta_excludes_preflight_scan_time(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(conversion.time, "time", lambda: 100.0)
    job = ConversionJob(
        id="eta",
        source=VideoSource("source", tmp_path / "source.mov", {}),
        target_format="mp4",
        mode="hevc",
        output_path=tmp_path / "out.mp4",
        status="running",
        progress=25,
        started_at=10,
        encoding_started_at=80,
    )
    assert job.snapshot()["elapsed_seconds"] == 90
    assert job.snapshot()["estimated_remaining_seconds"] == 75


def test_cancel_unknown_job_and_terminal_job(manager, tmp_path) -> None:
    with pytest.raises(MediaError, match="not found"):
        manager.cancel("missing")
    job = ConversionJob(
        "done",
        VideoSource("source", tmp_path / "video.mp4", {}),
        "mp4",
        "copy",
        tmp_path / "out.mp4",
    )
    job.status = "completed"
    manager._jobs[job.id] = job
    assert manager.cancel(job.id) is job
    assert not job.cancel_event.is_set()


@pytest.mark.parametrize("mode", ["copy", "h264"])
def test_rotation_to_mkv_preserved_or_rejected_without_publish(
    manager,
    sample_video,
    ffmpeg,
    ffprobe,
    tmp_path,
    mode,
) -> None:
    rotated = tmp_path / "rotated.mov"
    run(
        ffmpeg,
        "-display_rotation",
        "90",
        "-i",
        str(sample_video),
        "-c",
        "copy",
        str(rotated),
    )
    job = manager.create(
        source(rotated, ffprobe),
        target_format="mkv",
        mode=mode,
        output_directory=tmp_path,
    )
    status = wait(job)
    if status["status"] == "completed":
        assert probe_video(job.output_path, ffprobe=ffprobe)["rotation"] == 90
    else:
        assert status["status"] == "failed"
        assert "rotation" in status["error"]
        assert not job.output_path.exists()


@pytest.mark.parametrize("mode", ["copy", "h264", "hevc"])
def test_nonzero_start_and_vfr_timestamps_preserved(
    manager,
    sample_video,
    ffmpeg,
    ffprobe,
    tmp_path,
    mode,
) -> None:
    if mode == "hevc" and "libx265" not in manager.encoders:
        pytest.skip("libx265 is unavailable")
    variable = tmp_path / "variable frame rate.mp4"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-vf",
        "select='not(mod(n,2))+not(mod(n,5))'",
        "-fps_mode",
        "vfr",
        "-c:v",
        "libx264",
        "-c:a",
        "copy",
        "-output_ts_offset",
        "3",
        str(variable),
    )
    job = manager.create(
        source(variable, ffprobe),
        target_format="mp4",
        mode=mode,
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "completed", job.snapshot()

    def timestamps(path):
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
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        return sorted(
            float(packet["pts_time"]) for packet in json.loads(result.stdout)["packets"]
        )

    assert timestamps(variable) == pytest.approx(timestamps(job.output_path), abs=0.001)


def test_unknown_data_track_is_not_confused_with_chapters(manager, tmp_path) -> None:
    job = ConversionJob(
        "tracks",
        VideoSource("s", tmp_path / "in.mov", {}),
        "mov",
        "copy",
        tmp_path / "out.mov",
    )
    inventory = {
        "chapters": [{"start_time": "0", "end_time": "2"}],
        "streams": [
            {"index": 0, "codec_type": "video", "codec_name": "h264"},
            {
                "index": 1,
                "codec_type": "data",
                "codec_name": "bin_data",
                "codec_tag_string": "text",
            },
        ],
    }
    with pytest.raises(MediaError, match="Unsupported data track"):
        manager._validate_tracks(job, inventory)


@pytest.mark.parametrize(
    "metadata",
    [
        {"is_dolby_vision": True},
        {"dynamic_hdr_metadata_types": ["HDR Dynamic Metadata SMPTE2094-40"]},
    ],
)
@pytest.mark.parametrize("mode", ["copy", "h264", "hevc"])
def test_dynamic_hdr_is_rejected_before_creating_output(
    manager, tmp_path, metadata, mode
) -> None:
    job = ConversionJob(
        "hdr",
        VideoSource("s", tmp_path / "in.mov", metadata),
        "mov",
        mode,
        tmp_path / "out.mov",
    )
    with pytest.raises(MediaError, match="Dynamic HDR"):
        manager._validate_tracks(
            job,
            {"streams": [{"index": 0, "codec_type": "video", "codec_name": "hevc"}]},
        )


def test_alpha_reencoding_refused(manager, ffmpeg, ffprobe, tmp_path) -> None:
    alpha = tmp_path / "alpha.mov"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "color=red@0.5:size=64x64:duration=1,format=argb",
        "-c:v",
        "qtrle",
        str(alpha),
    )
    job = manager.create(
        source(alpha, ffprobe),
        target_format="mp4",
        mode="h264",
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "failed"
    assert "Alpha" in job.error


def test_metadata_verification_failure_never_publishes(
    manager, sample_video, ffprobe, monkeypatch
) -> None:
    def verify(*_args):
        raise MediaError("Output verification detected changed chroma_location")

    monkeypatch.setattr(manager, "_verify_conversion", verify)
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=sample_video.parent,
    )
    status = wait(job)
    assert status["status"] == "failed" and status["progress"] <= 99
    assert status["output_path"] is None and not job.output_path.exists()
    assert not list(sample_video.parent.glob(".conversion-*"))


def test_copy_av1_into_mp4_does_not_require_av1_encoder(
    manager, ffmpeg, ffprobe, tmp_path
) -> None:
    if "libaom-av1" not in manager.encoders:
        pytest.skip("AV1 fixture encoder is unavailable")
    av1 = tmp_path / "av1.mkv"
    run(
        ffmpeg,
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=64x64:rate=5:duration=1",
        "-c:v",
        "libaom-av1",
        "-cpu-used",
        "8",
        str(av1),
    )
    job = manager.create(
        source(av1, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=tmp_path,
    )
    assert wait(job)["status"] == "completed", job.snapshot()
    assert packet_hashes(ffprobe, av1, "v:0") == packet_hashes(
        ffprobe, job.output_path, "v:0"
    )


def test_cancel_stops_running_ffmpeg_and_removes_partial(
    manager, sample_video, ffprobe, monkeypatch
) -> None:
    original_command = manager._command

    def command(*args):
        arguments = original_command(*args)
        index = arguments.index("-i")
        arguments[index:index] = ["-readrate", "0.1"]
        return arguments

    monkeypatch.setattr(manager, "_command", command)
    job = manager.create(
        source(sample_video, ffprobe),
        target_format="mp4",
        mode="copy",
        output_directory=sample_video.parent,
    )
    deadline = time.monotonic() + 20
    process = None
    while time.monotonic() < deadline:
        with job.lock:
            if job.encoding_started_at is not None:
                process = job.process
                break
        time.sleep(0.02)
    assert process is not None and process.poll() is None
    manager.cancel(job.id)
    assert wait(job)["status"] == "cancelled", job.snapshot()
    assert process.poll() is not None
    assert not job.output_path.exists()
    assert not list(sample_video.parent.glob(".conversion-*"))


def test_large_input_pts_does_not_prematurely_complete_progress(
    manager,
    sample_video,
    ffmpeg,
    ffprobe,
    tmp_path,
    monkeypatch,
) -> None:
    shifted = tmp_path / "late-timestamp.mp4"
    run(
        ffmpeg,
        "-i",
        str(sample_video),
        "-c",
        "copy",
        "-output_ts_offset",
        "1800",
        str(shifted),
    )
    original_command = manager._command

    def command(*args):
        arguments = original_command(*args)
        index = arguments.index("-i")
        arguments[index:index] = ["-readrate", "2"]
        return arguments

    monkeypatch.setattr(manager, "_command", command)
    job = manager.create(
        source(shifted, ffprobe),
        target_format="mov",
        mode="copy",
        output_directory=tmp_path,
    )
    observed = []
    deadline = time.monotonic() + 20
    while job.worker.is_alive() and time.monotonic() < deadline:
        observed.append(job.snapshot()["progress"])
        job.worker.join(timeout=0.02)
    assert wait(job)["status"] == "completed", job.snapshot()
    assert any(5 < progress < 90 for progress in observed)
    assert all(progress <= 99 for progress in observed)
