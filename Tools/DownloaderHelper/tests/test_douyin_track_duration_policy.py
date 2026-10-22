"""Original-byte Douyin track-duration notices require complete-file evidence."""

from __future__ import annotations

import hashlib
import json
import shutil
import socket
import subprocess
import sys
import tempfile
from collections import deque
from io import BytesIO
from pathlib import Path

import pytest
from yt_dlp.utils import DownloadCancelled

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader
from app.downloader import DownloaderConfig, MediaDownloader
from app.errors import DownloadCancelledError, MediaDownloadError
from app.models import DownloadItem, MediaType, Platform
from app.xiaohongshu import RemoteAsset

CANDIDATE_URL = "https://api-play.amemv.com/aweme/v1/play/?video_id=trackdurationfixture"
FINAL_URL = "https://v26-web.douyinvod.com/track-duration-fixture.mp4"
DECLARED_DURATION = 50.804
VIDEO_DURATION = 10.033333
PREFIX = b"\x00\x00\x00\x18ftypisom" + b"a" * (downloader.DOUYIN_PROBE_BYTES - 12)
FULL_PAYLOAD = PREFIX + b"complete-audio-tail"


@pytest.fixture(autouse=True)
def forbid_external_resources(monkeypatch, tmp_path):
    def blocked(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in track duration tests")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket, "create_connection", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)
    from app import browser

    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: tmp_path / "chrome")


def parsed_media(**updates):
    value = {
        "width": 1080, "height": 1920, "vcodec": "h264", "acodec": "aac",
        "bit_rate": 2_000_000, "duration": VIDEO_DURATION,
        "video_duration": VIDEO_DURATION, "audio_duration": DECLARED_DURATION,
        "container_duration": DECLARED_DURATION,
    }
    value.update(updates)
    return value


class Response(BytesIO):
    def __init__(self, payload, *, total=None):
        super().__init__(payload)
        self.url = FINAL_URL
        self.status = 206 if total is not None else 200
        self.headers = {"Content-Type": "video/mp4", "Content-Length": str(len(payload))}
        if total is not None:
            self.headers["Content-Range"] = f"bytes 0-{len(payload) - 1}/{total}"


def source_timing(**updates):
    value = {
        "declared_duration": DECLARED_DURATION, "video_duration": VIDEO_DURATION,
        "audio_duration": DECLARED_DURATION, "container_duration": DECLARED_DURATION,
    }
    value.update(updates)
    return value


def install_probe(monkeypatch, *, complete_media=None, prefix_media=None,
                  full_payload=FULL_PAYLOAD, prefix=PREFIX, complete_response=False,
                  allow_unequal_tracks=True):
    engine = MediaDownloader(DownloaderConfig(
        cookie_browser=None, allow_douyin_unequal_tracks=allow_unequal_tracks,
    ))
    responses = (
        [Response(prefix)] if complete_response
        else [Response(prefix, total=len(FULL_PAYLOAD)), Response(full_payload)]
    )
    pending = deque(responses)
    requests = []
    probe_paths = []
    local_bytes = []

    def open_response(ydl, request, *, redirect_rejection_reason, should_cancel):
        if should_cancel():
            raise DownloadCancelled("Task cancelled")
        assert redirect_rejection_reason(request.url) is None
        requests.append(request)
        assert pending, "Unexpected extra media transfer"
        response = pending.popleft()
        assert redirect_rejection_reason(response.url) is None
        return response

    def ffprobe(data, *, local_path=None, should_cancel):
        if should_cancel():
            raise DownloadCancelled("Task cancelled")
        if local_path is None:
            return dict(prefix_media or parsed_media())
        probe_paths.append(local_path)
        local_bytes.append(local_path.read_bytes())
        return dict(complete_media or parsed_media())

    monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
    monkeypatch.setattr(engine, "_ffprobe_douyin_media", ffprobe)
    return engine, responses, pending, requests, probe_paths, local_bytes


def probe(engine, *, ratio="default", should_cancel=lambda: False):
    return engine._probe_douyin_candidate(
        object(), CANDIDATE_URL, ratio=ratio,
        expected_duration=DECLARED_DURATION, should_cancel=should_cancel,
    )


def assert_cleaned(responses, paths):
    assert all(response.closed for response in responses)
    assert all(not path.exists() for path in paths)


@pytest.mark.parametrize("ratio", ["default", "author-feed-1"])
def test_complete_source_with_short_picture_preserves_each_duration(monkeypatch, ratio):
    engine, responses, pending, requests, paths, local_bytes = install_probe(monkeypatch)

    result = probe(engine, ratio=ratio)

    assert result["duration"] == VIDEO_DURATION
    assert result["video_duration"] == VIDEO_DURATION
    assert result["audio_duration"] == DECLARED_DURATION
    assert result["container_duration"] == DECLARED_DURATION
    assert result["source_timing"] == source_timing()
    assert result["filesize"] == len(FULL_PAYLOAD)
    assert result["probe_prefix_sha256"] == hashlib.sha256(PREFIX).hexdigest()
    assert ["Range" in request.headers for request in requests] == [True, False]
    assert local_bytes == [FULL_PAYLOAD] and not pending
    assert_cleaned(responses, paths)


def test_standalone_default_keeps_strict_picture_duration_policy(monkeypatch):
    assert DownloaderConfig(cookie_browser=None).allow_douyin_unequal_tracks is False
    engine, responses, pending, requests, paths, _ = install_probe(
        monkeypatch, allow_unequal_tracks=False,
    )
    with pytest.raises(downloader._DouyinProbeRejected, match="duration did not match"):
        probe(engine)
    assert len(requests) == 2 and not pending
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("changes", [
    {"audio_duration": 10.033333},
    {"container_duration": 10.033333},
    {"audio_duration": 50.2},
    {"container_duration": 50.2},
    {"audio_duration": 51.5},
    {"container_duration": 51.5},
    {"audio_duration": None},
    {"container_duration": None},
    {"video_duration": None},
    {"audio_duration": "N/A"},
    {"container_duration": "N/A"},
    {"video_duration": "N/A"},
    {"audio_duration": float("nan")},
    {"container_duration": float("inf")},
    {"video_duration": float("nan")},
    {"audio_duration": -1},
    {"container_duration": 0},
    {"video_duration": -1},
    {"acodec": "none"},
    {"acodec": None},
    {"duration": 60.0, "video_duration": 60.0},
    {"video_duration": 60.0},
])
def test_incomplete_or_conflicting_track_evidence_does_not_grant_exception(monkeypatch, changes):
    engine, responses, pending, requests, paths, _ = install_probe(
        monkeypatch, complete_media=parsed_media(**changes),
    )

    with pytest.raises(downloader._DouyinProbeRejected):
        probe(engine)

    assert len(requests) == 2 and not pending
    assert_cleaned(responses, paths)


def test_prefix_claim_alone_cannot_accept_a_different_complete_timeline(monkeypatch):
    engine, responses, pending, requests, paths, _ = install_probe(
        monkeypatch, complete_media=parsed_media(audio_duration=20, container_duration=20),
    )

    with pytest.raises(downloader._DouyinProbeRejected):
        probe(engine)

    assert ["Range" in request.headers for request in requests] == [True, False]
    assert not pending
    assert_cleaned(responses, paths)


def test_unknown_total_size_does_not_grant_track_duration_exception(monkeypatch):
    engine, responses, pending, requests, paths, _ = install_probe(monkeypatch)
    responses[0].headers["Content-Range"] = f"bytes 0-{len(PREFIX) - 1}/*"
    with pytest.raises(downloader._DouyinProbeRejected, match="duration did not match"):
        probe(engine)
    assert len(requests) == 2 and not pending
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("declared", [True, False, float("nan"), float("inf"), 0, -1, "N/A"])
def test_invalid_declared_duration_is_rejected_before_media_io(monkeypatch, declared):
    engine, responses, pending, requests, paths, _ = install_probe(monkeypatch)
    try:
        with pytest.raises(downloader._DouyinProbeRejected):
            engine._probe_douyin_candidate(
                object(), CANDIDATE_URL, expected_duration=declared, should_cancel=lambda: False,
            )
        assert not requests and not paths and len(pending) == 2
    finally:
        for response in responses:
            response.close()


def test_album_strict_context_does_not_inherit_native_unequal_track_opt_in(monkeypatch):
    engine, responses, pending, requests, paths, _ = install_probe(monkeypatch)
    engine._douyin_probe_context.strict_track_duration = True
    with pytest.raises(downloader._DouyinProbeRejected, match="duration did not match"):
        probe(engine)
    assert len(requests) == 2 and not pending
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("previous", [False, True])
@pytest.mark.parametrize("failure", [False, True])
def test_live_photo_wrapper_restores_caller_policy_on_success_and_failure(
    monkeypatch, previous, failure,
):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None, allow_douyin_unequal_tracks=True))
    engine._douyin_probe_context.strict_track_duration = previous
    asset = RemoteAsset(candidates=[FINAL_URL], index=1)

    def scoped(*args, **kwargs):
        assert engine._douyin_probe_context.strict_track_duration is True
        if failure:
            raise DownloadCancelledError("Task cancelled")
        return asset

    monkeypatch.setattr(engine, "_select_highest_douyin_live_photo_asset_scoped", scoped)
    if failure:
        with pytest.raises(DownloadCancelledError):
            engine._select_highest_douyin_live_photo_asset(
                object(), asset, callback=None, should_cancel=lambda: False,
            )
    else:
        assert engine._select_highest_douyin_live_photo_asset(
            object(), asset, callback=None, should_cancel=lambda: False,
        ) is asset
    assert engine._douyin_probe_context.strict_track_duration is previous


def test_complete_small_http_object_is_confirmed_seekably_before_exception(monkeypatch):
    payload = b"\x00\x00\x00\x18ftypisom-complete-track-fixture"
    engine, responses, pending, requests, paths, local_bytes = install_probe(
        monkeypatch, prefix=payload, complete_response=True,
    )

    result = probe(engine)

    assert result["duration"] == VIDEO_DURATION
    assert local_bytes == [payload]
    assert len(requests) == 1 and not pending
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("failure", ["prefix", "size"])
def test_matching_track_metadata_does_not_bypass_complete_object_identity(monkeypatch, failure):
    payload = FULL_PAYLOAD[:-1] if failure == "size" else b"x" + FULL_PAYLOAD[1:]
    engine, responses, pending, requests, paths, local_bytes = install_probe(
        monkeypatch, full_payload=payload,
    )

    with pytest.raises(downloader._DouyinProbeRejected):
        probe(engine)

    assert len(requests) == 2 and not pending
    assert not local_bytes
    assert_cleaned(responses, paths)


def test_cancel_during_complete_duration_confirmation_cleans_owned_media(monkeypatch):
    engine, responses, pending, requests, paths, _ = install_probe(monkeypatch)
    original = engine._ffprobe_douyin_media
    cancelled = False

    def cancel_local(data, *, local_path=None, should_cancel):
        nonlocal cancelled
        if local_path is not None:
            paths.append(local_path)
            cancelled = True
        return original(data, local_path=local_path, should_cancel=should_cancel)

    monkeypatch.setattr(engine, "_ffprobe_douyin_media", cancel_local)
    with pytest.raises(DownloadCancelled):
        probe(engine, should_cancel=lambda: cancelled)

    assert len(requests) == 2 and not pending and len(paths) == 1
    assert_cleaned(responses, paths)


def raw_ffprobe(**updates):
    value = {
        "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1080,
             "height": 1920, "bit_rate": "2000000", "duration": str(VIDEO_DURATION)},
            {"codec_type": "audio", "codec_name": "aac", "duration": str(DECLARED_DURATION)},
        ],
        "format": {"duration": str(DECLARED_DURATION)},
    }
    value.update(updates)
    return value


def test_ffprobe_parser_keeps_picture_audio_and_container_times_separate():
    parsed = MediaDownloader._parse_ffprobe_payload(json.dumps(raw_ffprobe()).encode())
    assert float(parsed["duration"]) == VIDEO_DURATION
    assert float(parsed["video_duration"]) == VIDEO_DURATION
    assert float(parsed["audio_duration"]) == DECLARED_DURATION
    assert float(parsed["container_duration"]) == DECLARED_DURATION


@pytest.mark.parametrize("field,stream_index", [("video_duration", 0), ("audio_duration", 1)])
@pytest.mark.parametrize("bad_duration", [None, "N/A", "nan", "inf", "-inf", "0", "-2"])
def test_ffprobe_parser_never_backfills_missing_track_time_from_container(
    field, stream_index, bad_duration,
):
    payload = raw_ffprobe()
    payload["streams"][stream_index]["duration"] = bad_duration
    parsed = MediaDownloader._parse_ffprobe_payload(json.dumps(payload).encode())
    assert parsed[field] is None
    assert float(parsed["container_duration"]) == DECLARED_DURATION


def selected_asset(**updates):
    values = {
        "candidates": [CANDIDATE_URL, FINAL_URL], "index": 1, "width": 1080,
        "height": 1920, "size": len(FULL_PAYLOAD), "duration": VIDEO_DURATION,
        "format_id": "douyin-api-1080x1920-1", "video_codec": "h264", "audio_codec": "aac",
        "bit_rate": 2_000_000, "probe_prefix_size": len(PREFIX),
        "probe_prefix_sha256": hashlib.sha256(PREFIX).hexdigest(),
        "source_timing": source_timing(),
    }
    values.update(updates)
    return RemoteAsset(**values)


def install_final_probe(monkeypatch, *, raw=None, allow_unequal_tracks=True):
    engine = MediaDownloader(DownloaderConfig(
        cookie_browser=None, allow_douyin_unequal_tracks=allow_unequal_tracks,
        preserve_existing_files=True,
    ))
    calls = []
    monkeypatch.setattr(engine, "_find_ffprobe_executable", lambda: "synthetic-ffprobe")

    def run_ffprobe(command, *, timeout_seconds, should_cancel):
        assert not should_cancel()
        calls.append(command)
        assert Path(command[-1]).read_bytes() == FULL_PAYLOAD
        return json.dumps(raw or raw_ffprobe()).encode()

    monkeypatch.setattr(engine, "_run_ffprobe", run_ffprobe)
    return engine, calls


def verify_final(engine, path, asset):
    return engine._verify_local_video_asset(
        path, asset, should_cancel=lambda: False, require_quality_fingerprint=True,
    )


def test_final_asset_rechecks_complete_tracks_and_keeps_warning(monkeypatch, tmp_path):
    engine, calls = install_final_probe(monkeypatch)
    path = tmp_path / "synthetic-video.mp4"
    path.write_bytes(FULL_PAYLOAD)
    verified = verify_final(engine, path, selected_asset())
    assert len(calls) == 1
    assert verified.duration == VIDEO_DURATION
    assert verified.source_timing == source_timing()
    assert path.read_bytes() == FULL_PAYLOAD


@pytest.mark.parametrize("track,value", [
    ("video", "9.000"), ("audio", "49.000"), ("container", "49.000"),
    ("video", "10.035333"), ("audio", "50.806"), ("container", "50.806"),
    ("video", "N/A"), ("audio", "N/A"), ("container", "N/A"),
    ("video", "nan"), ("audio", "inf"), ("container", "-inf"),
])
def test_final_track_changes_cannot_reuse_previously_accepted_notice(
    monkeypatch, tmp_path, track, value,
):
    raw = raw_ffprobe()
    if track == "container":
        raw["format"]["duration"] = value
    else:
        raw["streams"][0 if track == "video" else 1]["duration"] = value
    engine, calls = install_final_probe(monkeypatch, raw=raw)
    path = tmp_path / "synthetic-video.mp4"
    path.write_bytes(FULL_PAYLOAD)
    with pytest.raises(MediaDownloadError):
        verify_final(engine, path, selected_asset())
    assert len(calls) == 1


def test_final_verification_cannot_opt_in_a_strict_engine_using_asset_metadata(monkeypatch, tmp_path):
    engine, _ = install_final_probe(monkeypatch, allow_unequal_tracks=False)
    path = tmp_path / "synthetic-video.mp4"
    path.write_bytes(FULL_PAYLOAD)
    with pytest.raises(MediaDownloadError):
        verify_final(engine, path, selected_asset())


@pytest.mark.parametrize("failure", ["prefix", "codec", "resolution", "bitrate"])
def test_accepted_track_notice_never_bypasses_other_final_quality_gates(monkeypatch, tmp_path, failure):
    raw = raw_ffprobe()
    asset = selected_asset()
    if failure == "codec":
        raw["streams"][0]["codec_name"] = "hevc"
    elif failure == "resolution":
        raw["streams"][0]["width"] = 720
        raw["streams"][0]["height"] = 1280
    elif failure == "bitrate":
        raw["streams"][0]["bit_rate"] = "1000000"
    else:
        asset.probe_prefix_sha256 = "0" * 64
    engine, _ = install_final_probe(monkeypatch, raw=raw)
    path = tmp_path / "synthetic-video.mp4"
    path.write_bytes(FULL_PAYLOAD)
    with pytest.raises(MediaDownloadError):
        verify_final(engine, path, asset)


def publish_probe(engine, probe_path, output_dir, *, should_cancel=lambda: False):
    return engine._reuse_verified_douyin_probe_file(
        probe_path, selected_asset(), output_dir, "20260101", "Synthetic", "7000000000000000001",
        callback=None, should_cancel=should_cancel, asset_index=None,
        progress_index=None, progress_count=None,
    )


def test_publication_preserves_original_bytes_and_duration_notice(monkeypatch, tmp_path):
    engine, calls = install_final_probe(monkeypatch)
    original = tmp_path / "candidate.mp4"
    original.write_bytes(FULL_PAYLOAD)
    destination = tmp_path / "author"
    destination.mkdir()
    saved, verified = publish_probe(engine, original, destination)
    assert len(calls) == 1 and not original.exists()
    assert saved.parent == destination
    assert saved.read_bytes() == FULL_PAYLOAD
    assert verified.source_timing == source_timing()


def test_cancel_after_final_recheck_prevents_publication_and_removes_probe(monkeypatch, tmp_path):
    engine, calls = install_final_probe(monkeypatch)
    original_run = engine._run_ffprobe
    cancelled = False

    def cancel_after_probe(command, *, timeout_seconds, should_cancel):
        nonlocal cancelled
        result = original_run(command, timeout_seconds=timeout_seconds, should_cancel=should_cancel)
        cancelled = True
        return result

    monkeypatch.setattr(engine, "_run_ffprobe", cancel_after_probe)
    original = tmp_path / "candidate.mp4"
    original.write_bytes(FULL_PAYLOAD)
    destination = tmp_path / "author"
    destination.mkdir()
    with pytest.raises(DownloadCancelledError):
        publish_probe(engine, original, destination, should_cancel=lambda: cancelled)
    assert len(calls) == 1
    assert not original.exists()
    assert not list(destination.iterdir())


@pytest.mark.parametrize("field", ["declared_duration", "video_duration", "audio_duration", "container_duration"])
def test_probe_cache_identity_includes_accepted_track_timings(field):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    original = {**parsed_media(), "source_timing": source_timing()}
    changed = {**original, "source_timing": source_timing(**{field: source_timing()[field] + 1})}
    assert engine._douyin_probe_media_identity_key(original) != engine._douyin_probe_media_identity_key(changed)
    assert engine._douyin_asset_media_identity_key(selected_asset()) != engine._douyin_asset_media_identity_key(
        selected_asset(source_timing=changed["source_timing"]),
    )


def test_real_ffprobe_short_picture_long_audio_remains_unmodified_on_publication(monkeypatch):
    ffmpeg = shutil.which("ffmpeg")
    engine = MediaDownloader(DownloaderConfig(
        cookie_browser=None, allow_douyin_unequal_tracks=True, preserve_existing_files=True,
    ))
    if not ffmpeg or not engine._find_ffprobe_executable():
        pytest.skip("FFmpeg and FFprobe are required for complete source timing checks")
    with tempfile.TemporaryDirectory(prefix="chengying-source-timing-fixture-") as directory:
        root = Path(directory)
        original = root / "fixture.mp4"
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=black:s=64x64:r=30:d=10.033333",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=50.804",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-b:a", "64k",
            str(original),
        ], check=True, capture_output=True, timeout=30)
        original_bytes = original.read_bytes()
        assert len(original_bytes) > downloader.DOUYIN_PROBE_BYTES
        prefix = original_bytes[:downloader.DOUYIN_PROBE_BYTES]
        responses = [Response(prefix, total=len(original_bytes)), Response(original_bytes)]
        pending = deque(responses)
        requests = []
        probe_paths = []
        real_probe = engine._ffprobe_douyin_media

        def open_response(ydl, request, *, redirect_rejection_reason, should_cancel):
            assert not should_cancel()
            assert redirect_rejection_reason(request.url) is None
            requests.append(request)
            return pending.popleft()

        def observe_probe(data, *, local_path=None, should_cancel):
            if local_path is not None:
                probe_paths.append(local_path)
            return real_probe(data, local_path=local_path, should_cancel=should_cancel)

        monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
        monkeypatch.setattr(engine, "_ffprobe_douyin_media", observe_probe)
        output = root / "author"
        output.mkdir()
        with engine._douyin_probe_reuse_scope(root):
            result = probe(engine)
            timing = result["source_timing"]
            assert timing["declared_duration"] == DECLARED_DURATION
            assert timing["video_duration"] == pytest.approx(VIDEO_DURATION, abs=0.001)
            assert timing["audio_duration"] == pytest.approx(DECLARED_DURATION, abs=0.001)
            assert timing["container_duration"] == pytest.approx(DECLARED_DURATION, abs=0.001)
            assert len(probe_paths) == 1 and probe_paths[0].read_bytes() == original_bytes
            asset = selected_asset(
                width=64, height=64, size=result["filesize"],
                duration=float(result["duration"]), bit_rate=result["bit_rate"],
                probe_prefix_sha256=result["probe_prefix_sha256"], source_timing=timing,
            )
            saved, verified = engine._reuse_verified_douyin_probe_file(
                probe_paths[0], asset, output, "20260101", "Synthetic", "7000000000000000001",
                callback=None, should_cancel=lambda: False, asset_index=None,
                progress_index=None, progress_count=None,
            )
            assert saved.read_bytes() == original_bytes
            assert verified.source_timing == timing
        assert len(requests) == 2 and not pending
        assert_cleaned(responses, probe_paths)
        assert original.read_bytes() == original_bytes
    assert not Path(directory).exists()


def raw_discovered_video(engine):
    return engine._douyin_raw_info_from_profile_metadata(
        {"profile_owner_verified": True, "douyin_profile_media": {
            "media_id": "7000000000000000001", "owner_id": "fixture-owner",
            "media_kind": "video", "video_uri": "v0200fg10000fixturevideoid",
            "duration_ms": 50804, "direct_candidates": [{
                "width": 1080, "height": 1920, "bit_rate": 2_000_000,
                "video_uri": "v0200fg10000fixturevideoid", "urls": [FINAL_URL],
            }],
        }},
        expected_id="7000000000000000001", expected_profile_id="fixture-owner",
        verification_url="https://www.douyin.com/user/fixture-owner", fallback_title="Synthetic",
    )


@pytest.mark.parametrize("default_verified", [True, False])
def test_format_selection_carries_notice_but_keeps_default_quality_mandatory(
    monkeypatch, default_verified,
):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None, allow_douyin_unequal_tracks=True))
    info = raw_discovered_video(engine)
    assert info is not None
    candidate = {
        **parsed_media(), "source_timing": source_timing(), "url": FINAL_URL,
        "source_url": CANDIDATE_URL, "filesize": len(FULL_PAYLOAD),
        "probe_prefix_size": len(PREFIX), "probe_prefix_sha256": hashlib.sha256(PREFIX).hexdigest(),
    }
    calls = []

    def rendition(*args, **kwargs):
        calls.append("author-feed")
        return dict(candidate), None

    def original(*args, **kwargs):
        calls.append("default")
        if not default_verified:
            raise downloader._DouyinProbeRejected("Synthetic default validation failure")
        return dict(candidate)

    monkeypatch.setattr(engine, "_probe_douyin_direct_rendition", rendition)
    monkeypatch.setattr(engine, "_probe_douyin_default_with_fallback", original)
    accepted = engine._add_douyin_probe_formats(
        object(), info, expected_id="7000000000000000001", expected_profile_id="fixture-owner",
        verification_url="https://www.douyin.com/user/fixture-owner", should_cancel=lambda: False,
    )
    assert calls == ["author-feed", "default"]
    assert accepted is default_verified
    added = [value for value in info["formats"] if value["format_id"].startswith("douyin-api-")]
    if default_verified:
        assert added
        assert all(value["_douyin_source_timing"] == source_timing() for value in added)
    else:
        assert not added
        assert "default" in info["_douyin_probe_failure"]


def test_download_pipeline_carries_reverified_timing_into_outcome_and_completed_event(monkeypatch, tmp_path):
    engine = MediaDownloader(DownloaderConfig(
        cookie_browser=None, allow_douyin_unequal_tracks=True, preserve_existing_files=True,
    ))
    info = raw_discovered_video(engine)
    assert info is not None
    media_id = "7000000000000000001"
    source_url = f"https://www.douyin.com/video/{media_id}"
    profile_url = "https://www.douyin.com/user/fixture-owner"
    item = DownloadItem(
        id="synthetic-duration-item", media_id=media_id, source_url=source_url,
        title="Synthetic", media_type=MediaType.VIDEO,
        metadata={"profile_url": profile_url},
    )
    options = []
    requests = []
    responses = []
    probe_paths = []
    selected_assets = []
    chosen_assets = []
    final_checks = []
    events = []

    class FixtureYoutubeDL:
        def __init__(self, value):
            self.options = value
            options.append(value)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def add_post_processor(self, processor, when):
            assert when == "pre_process"

        def extract_info(self, *args, **kwargs):
            raise AssertionError("Fixture discovery must not invoke yt-dlp extraction")

    def extract(ydl, url, **kwargs):
        assert isinstance(ydl, FixtureYoutubeDL)
        assert url == source_url
        assert kwargs["expected_id"] == media_id
        assert kwargs["expected_profile_id"] == "fixture-owner"
        assert kwargs["verification_url"] == profile_url
        assert not kwargs["should_cancel"]()
        return info

    def open_response(ydl, request, *, redirect_rejection_reason, should_cancel):
        assert isinstance(ydl, FixtureYoutubeDL)
        assert not should_cancel()
        assert redirect_rejection_reason(request.url) is None
        is_range = "Range" in request.headers
        response = Response(PREFIX, total=len(FULL_PAYLOAD)) if is_range else Response(FULL_PAYLOAD)
        assert redirect_rejection_reason(response.url) is None
        requests.append(is_range)
        responses.append(response)
        return response

    def probe_media(data, *, local_path=None, should_cancel):
        assert not should_cancel() and data == PREFIX
        if local_path is not None:
            probe_paths.append(local_path)
            assert local_path.read_bytes() == FULL_PAYLOAD
        return parsed_media()

    def final_probe(command, *, timeout_seconds, should_cancel):
        assert not should_cancel()
        final_checks.append(Path(command[-1]))
        assert final_checks[-1].read_bytes() == FULL_PAYLOAD
        return json.dumps(raw_ffprobe()).encode()

    original_transfer = engine._download_first_available_asset

    def observe_transfer(ydl, assets, *args, **kwargs):
        assert len(assets) == 1
        assert kwargs["platform"] == Platform.DOUYIN
        assert kwargs["media_type"] == MediaType.VIDEO
        assert kwargs["verify_declared_dimensions"] is True
        assert kwargs["require_quality_fingerprint"] is True
        selected_assets.extend(assets)
        saved, chosen = original_transfer(ydl, assets, *args, **kwargs)
        chosen_assets.append(chosen)
        return saved, chosen

    monkeypatch.setattr(downloader, "YoutubeDL", FixtureYoutubeDL)
    monkeypatch.setattr(engine, "_extract_douyin_raw_info", extract)
    monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
    monkeypatch.setattr(engine, "_ffprobe_douyin_media", probe_media)
    monkeypatch.setattr(engine, "_find_ffprobe_executable", lambda: "synthetic-ffprobe")
    monkeypatch.setattr(engine, "_run_ffprobe", final_probe)
    monkeypatch.setattr(engine, "_download_first_available_asset", observe_transfer)

    outcome = engine.download_item(
        item, Platform.DOUYIN, tmp_path, callback=events.append, should_cancel=lambda: False,
    )

    assert len(options) == 1 and options[0]["continuedl"] is False
    assert requests == [True, False, True, False]
    assert len(probe_paths) == 2 and len(final_checks) == 1
    assert len(selected_assets) == len(chosen_assets) == 1
    assert selected_assets[0].source_timing == source_timing()
    assert chosen_assets[0].source_timing == source_timing()
    assert chosen_assets[0] is not selected_assets[0]
    assert outcome.source_timing == source_timing()
    assert outcome.resolution == "1080x1920"
    assert len(outcome.output_paths) == 1
    completed = [event for event in events if event.event == "completed"]
    assert len(completed) == 1
    assert completed[0].source_timing == source_timing()
    assert completed[0].output_paths == outcome.output_paths
    saved = Path(outcome.output_paths[0])
    assert saved.read_bytes() == FULL_PAYLOAD
    assert sorted(tmp_path.iterdir()) == [saved]
    assert_cleaned(responses, probe_paths)
