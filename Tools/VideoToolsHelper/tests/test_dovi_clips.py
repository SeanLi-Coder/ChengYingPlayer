from __future__ import annotations

import copy
import hashlib
import subprocess
import threading

import pytest
from dovi_fixtures import make_dovi_fixture
from test_display_transform import ORIENTATIONS, transform_matrix, with_matrix

import dovi_clip
from media import ExportManager, MediaError, VideoSource, probe_video


@pytest.fixture(scope="module")
def dovi_sources(tmp_path_factory, ffmpeg):
    root = tmp_path_factory.mktemp("dovi-sources")
    return {
        (compatibility, variable): make_dovi_fixture(
            ffmpeg,
            root / f"{compatibility}-{variable}",
            compatibility=compatibility,
            variable_rate=variable,
        )
        for compatibility in (1, 4)
        for variable in (False, True)
    }


def clip(ffmpeg, ffprobe, path, directory, *, start=0.417, end=1.863):
    source = VideoSource("synthetic", path, probe_video(path, ffprobe=ffprobe))
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(source, start=start, end=end, output_directory=directory)
    job.worker.join(30)
    if job.worker.is_alive():
        manager.cancel(job.id)
        raise AssertionError("Synthetic Dolby Vision clip timed out")
    return job


@pytest.mark.parametrize(
    "compatibility,variable", [(1, False), (4, False), (1, True), (4, True)]
)
@pytest.mark.parametrize("start,end", [(0, 0.613), (0.417, 1.863), (1.984, 2.501)])
def test_dolby_clip_preserves_complete_dynamic_metadata_and_timestamps(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    compatibility,
    variable,
    start,
    end,
):
    source = dovi_sources[compatibility, variable]
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    job = clip(ffmpeg, ffprobe, source, tmp_path, start=start, end=end)
    assert job.status == "completed", job.snapshot()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    result = probe_video(job.output_path, ffprobe=ffprobe)
    assert (
        result["dovi_configuration"]["dv_bl_signal_compatibility_id"] == compatibility
    )
    assert result["dovi_configuration"]["rpu_present_flag"] == 1
    assert result["dovi_configuration"]["el_present_flag"] == 0
    assert result["pix_fmt"] == "yuv420p10le"
    assert result["audio_codec"] == "alac"
    assert result["audio_sample_rate"] == 48000
    assert result["audio_channels"] == 2
    assert job.output_path.suffix == ".mp4"
    assert not list(tmp_path.glob(".*partial*"))
    assert not list(tmp_path.glob(".dovi-verify-*"))


@pytest.mark.parametrize("name,linear", ORIENTATIONS[1:])
def test_dolby_clip_keeps_display_matrix_without_transforming_rpu_geometry(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    name,
    linear,
):
    matrix = transform_matrix(linear)
    source = with_matrix(dovi_sources[4, False], tmp_path / f"{name}.mp4", matrix)
    job = clip(ffmpeg, ffprobe, source, tmp_path)
    assert job.status == "completed", job.snapshot()
    result = probe_video(job.output_path, ffprobe=ffprobe)
    assert result["display_matrix"] == matrix
    assert (result["encoded_width"], result["encoded_height"]) == (160, 96)


def test_dolby_clip_handles_nonzero_container_origin(
    dovi_sources, tmp_path, ffmpeg, ffprobe
):
    source = tmp_path / "delayed.mp4"
    completed = subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-copyts",
            "-itsoffset",
            "5",
            "-i",
            str(dovi_sources[4, True]),
            "-map",
            "0",
            "-c",
            "copy",
            "-strict",
            "unofficial",
            str(source),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr
    assert probe_video(source, ffprobe=ffprobe)["format_start_time"] > 4
    job = clip(ffmpeg, ffprobe, source, tmp_path)
    assert job.status == "completed", job.snapshot()


@pytest.mark.parametrize(
    "patch",
    [
        {"video_codec": "av1"},
        {"pix_fmt": "yuv420p"},
        {"color_range": "pc"},
        {"color_space": "bt709"},
        {"color_primaries": "bt709"},
        {"color_transfer": "bt709"},
        {"field_order": "tt"},
        {
            "dynamic_hdr_metadata_types": [
                "Dolby Vision Metadata",
                "HDR10+ Dynamic Metadata",
            ]
        },
        {"dovi_configuration": {}},
        {"dovi_configuration": {"dv_profile": 7}},
        {"dovi_configuration": {"el_present_flag": 1}},
        {"dovi_configuration": {"rpu_present_flag": 0}},
        {"dovi_configuration": {"bl_present_flag": 0}},
        {"dovi_configuration": {"dv_md_compression": "extended"}},
        {"dovi_configuration": {"dv_bl_signal_compatibility_id": 0}},
    ],
)
def test_dolby_clip_rejects_unsupported_sources_without_starting(
    dovi_sources, tmp_path, ffmpeg, ffprobe, patch
):
    metadata = probe_video(dovi_sources[4, False], ffprobe=ffprobe)
    for key, value in patch.items():
        if key == "dovi_configuration" and value:
            metadata[key].update(value)
        else:
            metadata[key] = value
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    with pytest.raises(MediaError, match="Dolby Vision"):
        manager.create(
            VideoSource("synthetic", dovi_sources[4, False], metadata),
            start=0,
            end=1,
            output_directory=tmp_path,
        )
    assert not list(tmp_path.iterdir())


def test_dolby_clip_rejects_missing_pq_mastering_metadata(dovi_sources, ffprobe):
    metadata = probe_video(dovi_sources[1, False], ffprobe=ffprobe)
    metadata["static_hdr_metadata"] = {}
    with pytest.raises(MediaError, match="verified static HDR"):
        dovi_clip.validate_dovi_clip_source(metadata)


def test_dolby_clip_rejects_changed_rpu_before_publishing(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    monkeypatch,
):
    original = dovi_clip._fingerprints

    def corrupt(manager, job, path, connection, table, *, source):
        result = original(manager, job, path, connection, table, source=source)
        if not source:
            connection.execute(
                "UPDATE exported SET digest = ? WHERE pts = (SELECT MIN(pts) FROM exported)",
                ("0" * 64,),
            )
        return result

    monkeypatch.setattr(dovi_clip, "_fingerprints", corrupt)
    job = clip(ffmpeg, ffprobe, dovi_sources[4, False], tmp_path)
    assert job.status == "failed"
    assert "changed Dolby Vision RPU" in job.error
    assert not list(tmp_path.iterdir())


def test_dolby_clip_rejects_a_hybrid_hdr_frame_in_the_range(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    monkeypatch,
):
    original = dovi_clip._lines

    def hybrid(manager, job, command):
        for line in original(manager, job, command):
            if line.startswith("frame|"):
                line += "|side_data_type=HDR10+ Dynamic Metadata"
            yield line

    monkeypatch.setattr(dovi_clip, "_lines", hybrid)
    job = clip(ffmpeg, ffprobe, dovi_sources[4, False], tmp_path)
    assert job.status == "failed"
    assert "single-layer Dolby Vision" in job.error
    assert not list(tmp_path.iterdir())


def test_dolby_clip_rejects_variable_static_hdr_metadata(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    monkeypatch,
):
    original = dovi_clip._lines

    def changing(manager, job, command):
        for line in original(manager, job, command):
            if line.startswith("frame|"):
                line = line.replace("max_content=1000", "max_content=2000")
            yield line

    monkeypatch.setattr(dovi_clip, "_lines", changing)
    job = clip(ffmpeg, ffprobe, dovi_sources[1, False], tmp_path)
    assert job.status == "failed"
    assert "Variable static HDR" in job.error
    assert not list(tmp_path.iterdir())


def test_dolby_clip_rejects_missing_rpu_with_a_stale_container_tag(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
):
    source = tmp_path / "stripped.mp4"
    completed = subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(dovi_sources[4, False]),
            "-c",
            "copy",
            "-bsf:v",
            "filter_units=remove_types=62",
            "-strict",
            "unofficial",
            str(source),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr
    output = tmp_path / "exports"
    output.mkdir()
    job = clip(ffmpeg, ffprobe, source, output)
    assert job.status == "failed"
    assert "missing Dolby Vision metadata" in job.error
    assert not list(output.iterdir())


def test_dolby_clip_cancel_during_frame_inspection_leaves_no_output(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    monkeypatch,
):
    started = threading.Event()

    def wait_for_cancel(manager, job):
        started.set()
        assert job.cancel_event.wait(10)
        raise InterruptedError

    monkeypatch.setattr(dovi_clip, "inspect_dovi_clip_frames", wait_for_cancel)
    metadata = probe_video(dovi_sources[4, False], ffprobe=ffprobe)
    source = VideoSource("synthetic", dovi_sources[4, False], metadata)
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(source, start=0.417, end=1.863, output_directory=tmp_path)
    assert started.wait(10)
    manager.cancel(job.id)
    job.worker.join(10)
    assert job.status == "cancelled", job.snapshot()
    assert not list(tmp_path.iterdir())


def test_dolby_encoder_never_replaces_existing_static_hdr_parameters(
    dovi_sources, ffmpeg, ffprobe, tmp_path
):
    metadata = probe_video(dovi_sources[1, False], ffprobe=ffprobe)
    original = copy.deepcopy(metadata)
    options = dovi_clip.dovi_encoding_options(metadata)
    assert "-dolbyvision" in options and "-enc_time_base:v" in options
    assert "-x265-params" not in options
    assert "-strict" in options and "unofficial" in options
    assert metadata == original


def test_dolby_verification_does_not_reuse_encoding_eta(
    dovi_sources,
    tmp_path,
    ffmpeg,
    ffprobe,
    monkeypatch,
):
    original = dovi_clip.verify_dovi_clip
    original_command = ExportManager._command
    observed = []
    command_messages = []

    def command(manager, job, output):
        command_messages.append(job.message)
        return original_command(manager, job, output)

    def verify(manager, job, output):
        observed.append(job.snapshot()["estimated_remaining_seconds"])
        assert job.estimate_remaining is False
        return original(manager, job, output)

    monkeypatch.setattr(dovi_clip, "verify_dovi_clip", verify)
    monkeypatch.setattr(ExportManager, "_command", command)
    job = clip(ffmpeg, ffprobe, dovi_sources[4, False], tmp_path)
    assert job.status == "completed", job.snapshot()
    assert observed == [None]
    assert command_messages == ["Creating a high-fidelity precise clip"]
    assert job.snapshot()["estimated_remaining_seconds"] == 0
