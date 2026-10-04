from __future__ import annotations

import contextlib
import hashlib
import json
import sqlite3
import subprocess
import sys
import threading
from itertools import pairwise

import pytest
from hdr10plus_fixtures import hdr10plus_payload, make_hdr10plus_fixture, sei_nal
from test_display_transform import transform_matrix, with_matrix

import hdr10plus_clip as hdr
from media import ExportJob, ExportManager, MediaError, VideoSource, probe_video


@pytest.fixture(scope="module")
def hdr_sources(tmp_path_factory, ffmpeg):
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-h", "encoder=libx265"],
        capture_output=True,
        text=True,
        check=True,
    )
    if "-hdr10plus " not in result.stdout:
        pytest.skip(
            "This FFmpeg lacks the application's explicit HDR10+ encoder support"
        )
    directory = tmp_path_factory.mktemp("hdr10plus-sources")
    return {
        (variable, static, advanced): make_hdr10plus_fixture(
            ffmpeg,
            directory / f"{variable}-{static}-{advanced}",
            variable_rate=variable,
            static_metadata=static,
            advanced=advanced,
        )
        for variable, static, advanced in (
            (False, False, False),
            (True, False, False),
            (False, True, False),
            (True, True, True),
        )
    }


def clip(ffmpeg, ffprobe, source, directory, *, start=0.417, end=1.863):
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(
        VideoSource("synthetic", source, probe_video(source, ffprobe=ffprobe)),
        start=start,
        end=end,
        output_directory=directory,
    )
    job.worker.join(60)
    if job.worker.is_alive():
        manager.cancel(job.id)
        job.worker.join(10)
        pytest.fail("Synthetic HDR10+ clip timed out")
    return job


@pytest.mark.parametrize(
    "key",
    [
        (False, False, False),
        (True, False, False),
        (False, True, False),
        (True, True, True),
    ],
)
@pytest.mark.parametrize("start,end", [(0, 0.613), (0.417, 1.863), (1.984, 2.501)])
def test_hdr10plus_clip_preserves_dynamic_payloads_timestamps_and_quality(
    hdr_sources, tmp_path, ffmpeg, ffprobe, key, start, end
):
    source = hdr_sources[key]
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    job = clip(ffmpeg, ffprobe, source, tmp_path, start=start, end=end)
    assert job.status == "completed", job.snapshot()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == original
    metadata = probe_video(job.output_path, ffprobe=ffprobe)
    assert (metadata["encoded_width"], metadata["encoded_height"]) == (160, 96)
    assert metadata["pix_fmt"] == "yuv420p10le"
    assert metadata["color_transfer"] == "smpte2084"
    assert metadata["color_primaries"] == "bt2020"
    assert metadata["dynamic_hdr_metadata_types"] == (hdr.HDR10PLUS_TYPE,)
    assert bool(metadata["static_hdr_metadata"]) == key[1]
    assert metadata["audio_codec"] == "alac"
    assert metadata["audio_channels"] == 2
    assert metadata["audio_sample_rate"] == 48000
    assert not list(tmp_path.glob(".*partial*"))
    assert not list(tmp_path.glob(".hdr10plus-*"))


@pytest.mark.parametrize("linear", [(0, -1, 1, 0), (-1, 0, 0, 1)])
def test_hdr10plus_keeps_display_geometry(
    hdr_sources, tmp_path, ffmpeg, ffprobe, linear
):
    matrix = transform_matrix(linear)
    source = with_matrix(
        hdr_sources[False, False, False], tmp_path / "oriented.mp4", matrix
    )
    job = clip(ffmpeg, ffprobe, source, tmp_path)
    assert job.status == "completed", job.snapshot()
    assert probe_video(job.output_path, ffprobe=ffprobe)["display_matrix"] == matrix


def test_hdr10plus_nonzero_timeline_and_collision_preserve_source(
    hdr_sources, tmp_path, ffmpeg, ffprobe
):
    source = tmp_path / "delayed.mp4"
    subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(hdr_sources[True, False, False]),
            "-c",
            "copy",
            "-output_ts_offset",
            "5",
            str(source),
        ],
        capture_output=True,
        check=True,
    )
    assert probe_video(source, ffprobe=ffprobe)["format_start_time"] > 4
    first = clip(ffmpeg, ffprobe, source, tmp_path)
    assert first.status == "completed", first.snapshot()
    digest = hashlib.sha256(first.output_path.read_bytes()).hexdigest()
    second = clip(ffmpeg, ffprobe, source, tmp_path)
    assert second.status == "completed", second.snapshot()
    assert first.output_path != second.output_path
    assert hashlib.sha256(first.output_path.read_bytes()).hexdigest() == digest


@pytest.mark.parametrize("layout", ["silent", "double-audio", "double-video"])
def test_hdr10plus_never_silently_drops_additional_tracks(
    hdr_sources, tmp_path, ffmpeg, ffprobe, layout
):
    source = tmp_path / "tracks.mp4"
    maps = ["-map", "0:v:0"]
    if layout != "silent":
        maps += [
            "-map",
            "0:a:0",
            "-map",
            "0:a:0" if layout == "double-audio" else "0:v:0",
        ]
    subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(hdr_sources[False, False, False]),
            *maps,
            "-c",
            "copy",
            str(source),
        ],
        capture_output=True,
        check=True,
    )
    metadata = probe_video(source, ffprobe=ffprobe)
    destination = tmp_path / "exports"
    destination.mkdir()
    if layout == "silent":
        job = clip(ffmpeg, ffprobe, source, destination)
        assert job.status == "completed", job.snapshot()
        assert not probe_video(job.output_path, ffprobe=ffprobe)["has_audio"]
    else:
        manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
        with pytest.raises(MediaError, match="one video track and at most one audio"):
            manager.create(
                VideoSource("synthetic", source, metadata),
                start=0.417,
                end=1.863,
                output_directory=destination,
            )
        assert not list(destination.iterdir())


@pytest.mark.parametrize(
    "layout,codec,channels,depth",
    [("5.1", "pcm_s24le", 6, 24), ("mono", "pcm_s32le", 1, 32)],
)
def test_hdr10plus_preserves_multichannel_and_high_bit_depth_audio(
    hdr_sources, tmp_path, ffmpeg, ffprobe, layout, codec, channels, depth
):
    source = tmp_path / "precision-audio.mov"
    subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(hdr_sources[False, False, False]),
            "-f",
            "lavfi",
            "-i",
            f"anullsrc=channel_layout={layout}:sample_rate=48000",
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "copy",
            "-c:a",
            codec,
            "-t",
            "3",
            str(source),
        ],
        check=True,
        capture_output=True,
    )
    destination = tmp_path / "exports"
    destination.mkdir()
    job = clip(ffmpeg, ffprobe, source, destination)
    assert job.status == "completed", job.snapshot()
    metadata = probe_video(job.output_path, ffprobe=ffprobe)
    assert job.output_path.suffix == ".mov"
    assert metadata["audio_codec"] == codec
    assert metadata["audio_channels"] == channels
    assert metadata["audio_sample_rate"] == 48000
    assert (
        ExportManager._audio_bit_depth(
            VideoSource("exported", job.output_path, metadata)
        )
        == depth
    )


def test_hdr10plus_sparse_open_gop_clip_does_not_skip_leading_frames(
    hdr_sources, tmp_path, ffmpeg, ffprobe, monkeypatch
):
    # The long timestamp gap crosses an open-GOP random-access picture. Input
    # seeking can start at that picture after valid selected leading B frames.
    source = make_hdr10plus_fixture(
        ffmpeg, tmp_path / "sparse-fixture", sparse_rate=True
    )
    destination = tmp_path / "exports"
    destination.mkdir()
    end = probe_video(source, ffprobe=ffprobe)["duration"]
    job = clip(ffmpeg, ffprobe, source, destination, start=6.417, end=end)
    assert job.status == "completed", job.snapshot()
    original_command = ExportManager._command

    def old_seek(manager, job, output):
        command = original_command(manager, job, output)
        seek = command.index("-ss")
        arguments = command[seek : seek + 2]
        del command[seek : seek + 2]
        position = command.index("-i")
        command[position:position] = arguments
        return command

    monkeypatch.setattr(ExportManager, "_command", old_seek)
    previous = clip(ffmpeg, ffprobe, source, destination, start=6.417, end=end)
    assert previous.status == "failed", previous.snapshot()
    assert "HDR10+ frame" in previous.error


@pytest.mark.parametrize(
    "patch",
    [
        {"video_codec": "h264"},
        {"pix_fmt": "yuv420p"},
        {"color_range": "pc"},
        {"color_space": "bt709"},
        {"color_primaries": "bt709"},
        {"color_transfer": "arib-std-b67"},
        {"field_order": "tt"},
        {"is_dolby_vision": True},
        {"dovi_configuration": {"dv_profile": 8}},
        {"dynamic_hdr_metadata_types": [hdr.HDR10PLUS_TYPE, "HDR Vivid"]},
    ],
)
def test_hdr10plus_rejects_unsupported_source_before_encoding(
    hdr_sources, ffprobe, patch
):
    metadata = probe_video(hdr_sources[False, False, False], ffprobe=ffprobe)
    metadata.update(patch)
    with pytest.raises(MediaError, match="HDR10\\+ clipping requires"):
        hdr.validate_hdr10plus_clip_source(metadata)


def test_hdr10plus_refuses_old_encoder_before_creating_output(
    tmp_path, ffmpeg, ffprobe, monkeypatch
):
    source = make_hdr10plus_fixture(ffmpeg, tmp_path / "fixture", reencode=False)
    destination = tmp_path / "exports"
    destination.mkdir()
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    monkeypatch.setattr(
        hdr,
        "_run_capture",
        lambda *args, **kwargs: subprocess.CompletedProcess(
            [], 0, "Encoder libx265", ""
        ),
    )
    with pytest.raises(MediaError, match="encoder does not support HDR10"):
        manager.create(
            VideoSource("synthetic", source, probe_video(source, ffprobe=ffprobe)),
            start=0,
            end=1,
            output_directory=destination,
        )
    assert not list(destination.iterdir())


@pytest.mark.parametrize(
    "change,error",
    [
        ("payload", "changed HDR10+ metadata"),
        ("pts", "changed HDR10+ frame timestamps"),
        ("count", "changed HDR10+ frame count"),
    ],
)
def test_hdr10plus_verification_failure_never_publishes(
    hdr_sources, tmp_path, ffmpeg, ffprobe, monkeypatch, change, error
):
    original = hdr._fingerprints

    def corrupt(manager, job, path, connection, table, *, source):
        base = original(manager, job, path, connection, table, source=source)
        if not source:
            if change == "payload":
                connection.execute(
                    "UPDATE exported SET digest = ? WHERE pts = (SELECT MIN(pts) FROM exported)",
                    ("0" * 64,),
                )
            elif change == "pts":
                connection.execute(
                    "UPDATE exported SET pts = pts + 10 WHERE pts = (SELECT MIN(pts) FROM exported)"
                )
            else:
                connection.execute(
                    "DELETE FROM exported WHERE pts = (SELECT MAX(pts) FROM exported)"
                )
        return base

    monkeypatch.setattr(hdr, "_fingerprints", corrupt)
    job = clip(ffmpeg, ffprobe, hdr_sources[True, False, False], tmp_path)
    assert job.status == "failed", job.snapshot()
    assert error in job.error
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("kind", ["missing", "hybrid", "static"])
def test_hdr10plus_full_range_inspection_rejects_metadata_change(
    hdr_sources, tmp_path, ffmpeg, ffprobe, monkeypatch, kind
):
    original = hdr._lines

    def changed(manager, job, command):
        for line in original(manager, job, command):
            if line.startswith("frame|"):
                if kind == "missing":
                    line = line.replace(hdr.HDR10PLUS_TYPE, "Removed")
                elif kind == "hybrid":
                    line += "|side_data_type=Dolby Vision Metadata"
                else:
                    line += "|side_datum/content_light_level_metadata:max_content=123"
            yield line

    monkeypatch.setattr(hdr, "_lines", changed)
    job = clip(ffmpeg, ffprobe, hdr_sources[False, False, False], tmp_path)
    assert job.status == "failed", job.snapshot()
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize(
    "before,after",
    [
        ("width=160", "width=192"),
        ("height=96", "height=108"),
        ("pix_fmt=yuv420p10le", "pix_fmt=yuv420p"),
        ("color_transfer=smpte2084", "color_transfer=arib-std-b67"),
        ("color_space=bt2020nc", "color_space=bt709"),
        ("color_primaries=bt2020", "color_primaries=bt709"),
        ("color_range=tv", "color_range=pc"),
        ("interlaced_frame=0", "interlaced_frame=1"),
    ],
)
def test_hdr10plus_late_frame_properties_are_checked(
    hdr_sources, tmp_path, ffmpeg, ffprobe, monkeypatch, before, after
):
    original = hdr._lines
    changed_count = []

    def changed(manager, job, command):
        count = 0
        for line in original(manager, job, command):
            if line.startswith("frame|"):
                count += 1
                if count == 25:
                    assert before in line
                    line = line.replace(before, after)
                    changed_count.append(count)
            yield line

    monkeypatch.setattr(hdr, "_lines", changed)
    job = clip(ffmpeg, ffprobe, hdr_sources[False, False, False], tmp_path)
    assert changed_count
    assert job.status == "failed", job.snapshot()
    assert "geometry, color, or scan" in job.error
    assert not list(tmp_path.iterdir())


def test_hdr10plus_real_missing_sei_packet_fails_without_publishing(
    hdr_sources, tmp_path, ffmpeg, ffprobe
):
    original = hdr_sources[False, False, False]
    metadata = probe_video(original, ffprobe=ffprobe)
    packet_info = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=pos,size,pts_time",
            "-of",
            "json",
            str(original),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    data = bytearray(original.read_bytes())
    changed = 0
    for packet in json.loads(packet_info.stdout)["packets"]:
        if not 1 < float(packet["pts_time"]) < 1.1:
            continue
        start = int(packet["pos"])
        end = start + int(packet["size"])
        offset = start
        while offset < end:
            size = int.from_bytes(data[offset : offset + 4], "big")
            nal_start = offset + 4
            if (data[nal_start] >> 1) & 63 == 39:
                # Change a registered HDR10+ payload into an unrelated registered
                # provider without changing sample offsets or compressed pixels.
                marker = data.find(
                    bytes.fromhex("b5003c000104"), nal_start, nal_start + size
                )
                if marker >= 0:
                    data[marker + 2] = 0x3D
                    changed += 1
            offset = nal_start + size
    assert changed
    source = tmp_path / "missing-sei.mp4"
    source.write_bytes(data)
    destination = tmp_path / "exports"
    destination.mkdir()
    assert (
        probe_video(source, ffprobe=ffprobe)["dynamic_hdr_metadata_types"]
        == metadata["dynamic_hdr_metadata_types"]
    )
    job = clip(ffmpeg, ffprobe, source, destination)
    assert job.status == "failed", job.snapshot()
    assert "missing HDR10+" in job.error
    assert not list(destination.iterdir())


def remove_early_hdr10plus(original, destination, ffprobe):
    packets = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=pos,size,pts_time",
            "-of",
            "json",
            str(original),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    data = bytearray(original.read_bytes())
    changed = 0
    for packet in json.loads(packets.stdout)["packets"]:
        if float(packet["pts_time"]) >= 1:
            continue
        offset = int(packet["pos"])
        end = offset + int(packet["size"])
        while offset < end:
            size = int.from_bytes(data[offset : offset + 4], "big")
            nal_start = offset + 4
            if (data[nal_start] >> 1) & 63 == 39:
                marker = data.find(
                    bytes.fromhex("b5003c000104"), nal_start, nal_start + size
                )
                if marker >= 0:
                    data[marker + 2] = 0x3D
                    changed += 1
            offset = nal_start + size
    assert changed == 30
    destination.write_bytes(data)
    return destination


@pytest.mark.parametrize("static", [False, True])
def test_initially_static_hdr_rejects_late_dynamic_metadata_only_in_selected_range(
    hdr_sources, tmp_path, ffmpeg, ffprobe, static
):
    original = hdr_sources[False, static, False]
    source = remove_early_hdr10plus(original, tmp_path / "late-hdr10plus.mp4", ffprobe)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    metadata = probe_video(source, ffprobe=ffprobe)
    assert metadata["is_hdr"]
    assert metadata["dynamic_hdr_metadata_types"] == ()
    assert not metadata["is_dolby_vision"]
    destination = tmp_path / "exports"
    destination.mkdir()
    before = clip(ffmpeg, ffprobe, source, destination, start=0.1, end=0.8)
    assert before.status == "completed", before.snapshot()
    output = probe_video(before.output_path, ffprobe=ffprobe)
    assert output["dynamic_hdr_metadata_types"] == ()
    assert output["is_hdr"] and output["color_transfer"] == "smpte2084"
    for start, end in ((0.417, 1.863), (1.417, 2.863)):
        job = clip(ffmpeg, ffprobe, source, destination, start=start, end=end)
        assert job.status == "failed", job.snapshot()
        assert (
            job.error
            == "The selected HDR range contains dynamic metadata not detected in the initial frame; no output was published"
        )
        assert sorted(destination.iterdir()) == [before.output_path]
    assert hashlib.sha256(source.read_bytes()).hexdigest() == digest


def test_static_hdr_scan_cancel_cleans_worker_without_encoding(
    hdr_sources, tmp_path, ffmpeg, ffprobe, monkeypatch
):
    source = remove_early_hdr10plus(
        hdr_sources[False, True, False], tmp_path / "late.mp4", ffprobe
    )
    destination = tmp_path / "exports"
    destination.mkdir()
    original = hdr._lines
    started = threading.Event()
    seen_processes = []

    def blocking(manager, job, command):
        command = [
            sys.executable,
            "-u",
            "-c",
            "import time; print('frame|pts=0', flush=True); time.sleep(30)",
        ]
        with contextlib.closing(original(manager, job, command)) as lines:
            for line in lines:
                seen_processes.append(job.process)
                started.set()
                yield line

    monkeypatch.setattr(hdr, "_lines", blocking)
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = manager.create(
        VideoSource("synthetic", source, probe_video(source, ffprobe=ffprobe)),
        start=0.1,
        end=0.8,
        output_directory=destination,
    )
    assert started.wait(10)
    manager.cancel(job.id)
    job.worker.join(10)
    assert job.status == "cancelled", job.snapshot()
    assert not job.worker.is_alive()
    assert all(process.poll() is not None for process in seen_processes)
    assert not list(destination.iterdir())


def test_sdr_clip_does_not_enter_static_hdr_scan(
    sample_video, tmp_path, ffmpeg, ffprobe, monkeypatch
):
    def unexpected(*args):
        pytest.fail("An SDR source entered the HDR metadata scan")

    monkeypatch.setattr(hdr, "inspect_static_hdr_clip_frames", unexpected)
    job = clip(ffmpeg, ffprobe, sample_video, tmp_path)
    assert job.status == "completed", job.snapshot()


def test_hdr10plus_cancel_terminates_real_inspection_child(tmp_path, ffmpeg, ffprobe):
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = ExportJob(
        "synthetic",
        VideoSource("synthetic", tmp_path / "unused.mp4", {}),
        0,
        1,
        tmp_path / "output.mp4",
    )
    started = threading.Event()
    result = []

    def worker():
        try:
            for _ in hdr._lines(
                manager,
                job,
                [
                    sys.executable,
                    "-u",
                    "-c",
                    "import time; print('started', flush=True); time.sleep(30)",
                ],
            ):
                started.set()
        except InterruptedError:
            result.append("cancelled")

    thread = threading.Thread(target=worker)
    thread.start()
    assert started.wait(10)
    process = job.process
    job.cancel_event.set()
    manager._escalate_process_stop(process)
    thread.join(10)
    assert not thread.is_alive()
    assert result == ["cancelled"]
    assert process.poll() is not None
    assert job.process is None


def test_hdr10plus_packet_inspection_is_bounded(tmp_path, ffmpeg, ffprobe, monkeypatch):
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    job = ExportJob(
        "synthetic",
        VideoSource("synthetic", tmp_path / "unused", {}),
        0,
        1,
        tmp_path / "output",
    )
    monkeypatch.setattr(hdr, "MAX_PROBE_LINE", 128)
    with pytest.raises(MediaError, match="per-packet safety limit"):
        list(hdr._lines(manager, job, [sys.executable, "-c", "print('a' * 1024)"]))
    assert job.process is None


@pytest.mark.parametrize("length", [1, 2, 4, None])
@pytest.mark.parametrize("advanced", [False, True])
def test_full_registered_sei_survives_framing_and_other_messages(length, advanced):
    expected = hdr10plus_payload(17, advanced=advanced)
    nal = sei_nal(expected, extra_message=b"\x05\x10" + bytes(16))
    packet = (len(nal).to_bytes(length, "big") if length else b"\x00\x00\x00\x01") + nal
    assert hdr._payload(packet, length) == expected


@pytest.mark.parametrize(
    "failure",
    ["duplicate", "truncated", "version", "layer", "trailing", "escape", "missing"],
)
def test_malformed_or_ambiguous_hdr10plus_packet_rejected(failure):
    expected = hdr10plus_payload(1)
    nal = sei_nal(expected)
    if failure == "duplicate":
        packet = len(nal).to_bytes(4, "big") + nal
        packet *= 2
    else:
        if failure == "truncated":
            nal = nal[:-3]
        elif failure == "version":
            nal = sei_nal(expected[:6] + b"\x02" + expected[7:])
        elif failure == "layer":
            nal = nal[:1] + b"\x09" + nal[2:]
        elif failure == "trailing":
            nal = nal[:-1]
        elif failure == "escape":
            nal = b"\x4e\x01\x00\x00\x03\x04\x80"
        else:
            nal = b"\x4e\x01\x05\x01\x42\x80"
        packet = len(nal).to_bytes(4, "big") + nal
    with pytest.raises(MediaError):
        hdr._payload(packet, 4)


def test_hex_packet_ascii_escapes_do_not_create_false_rows():
    # The hex bytes, not arbitrary printable ASCII, define the packet.
    raw = "\n00000000: 0001 0203 0405 0607 0809 0a0b 0c0d 0e0f  literal\\n\\|text\n"
    escaped = raw.replace("\\", "\\\\").replace("|", "\\|").replace("\n", "\\n")
    assert hdr._hex_bytes(raw) == bytes(range(16))
    assert hdr._hex_bytes(escaped, escaped=True) == bytes(range(16))


def test_fixture_keeps_changing_payloads_before_and_after_encode(
    hdr_sources, ffmpeg, ffprobe, tmp_path
):
    source = hdr_sources[True, True, True]
    manager = ExportManager(ffmpeg=ffmpeg, ffprobe=ffprobe)
    metadata = probe_video(source, ffprobe=ffprobe)
    job = ExportJob(
        "synthetic",
        VideoSource("synthetic", source, metadata),
        0,
        metadata["duration"],
        tmp_path / "unused.mp4",
    )
    connection = sqlite3.connect(":memory:")
    try:
        hdr._fingerprints(manager, job, source, connection, "original", source=True)
        assert (
            connection.execute(
                "SELECT COUNT(DISTINCT digest) FROM original"
            ).fetchone()[0]
            == 90
        )
    finally:
        connection.close()
    packet_probe = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=pts,dts",
            "-of",
            "json",
            str(source),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    packets = json.loads(packet_probe.stdout)["packets"]
    assert any(item["pts"] != item["dts"] for item in packets)
    pts = sorted(item["pts"] for item in packets)
    assert len({after - before for before, after in pairwise(pts)}) > 1
