"""Seekable duration checks for complete synthetic MP4 range responses."""

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

CANDIDATE_URL = "https://api-play.amemv.com/aweme/v1/play/?video_id=durationfixture"
FINAL_URL = "https://v26-web.douyinvod.com/synthetic-duration.mp4"
EXPECTED_DURATION = 50.804


@pytest.fixture(autouse=True)
def forbid_external_resources(monkeypatch, tmp_path):
    def blocked(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in duration tests")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket, "create_connection", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)
    from app import browser

    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: tmp_path / "chrome")


@pytest.fixture(scope="module")
def synthetic_media():
    ffmpeg = shutil.which("ffmpeg")
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    if not ffmpeg or not engine._find_ffprobe_executable():
        pytest.skip("FFmpeg and FFprobe are required for real fragmented MP4 checks")
    result = {}
    with tempfile.TemporaryDirectory(prefix="chengying-duration-fixture-") as directory:
        for name, duration in (("complete", "50.804"), ("short", "10.033333")):
            path = Path(directory) / f"{name}.mp4"
            subprocess.run(
                [
                    ffmpeg, "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "color=black:s=64x64:r=30",
                    "-t", duration, "-an", "-c:v", "libx264", "-preset", "ultrafast",
                    "-g", "301", "-movflags",
                    "frag_keyframe+empty_moov+default_base_moof", str(path),
                ],
                check=True, capture_output=True, timeout=30,
            )
            payload = path.read_bytes()
            assert 12 < len(payload) < downloader.DOUYIN_PROBE_BYTES
            result[name] = payload
    assert not Path(directory).exists()
    return result


class SyntheticResponse(BytesIO):
    def __init__(self, payload, *, status=206, total="complete"):
        super().__init__(payload)
        self.url = FINAL_URL
        self.status = status
        self.headers = {"Content-Type": "video/mp4", "Content-Length": str(len(payload))}
        if status == 206:
            size = len(payload) if total == "complete" else total
            self.headers["Content-Range"] = f"bytes 0-{len(payload) - 1}/{size}"


def install_engine(monkeypatch, responses):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    remaining = deque(responses)
    requests = []
    probe_paths = []
    original_probe = engine._ffprobe_douyin_media

    def open_response(ydl, request, *, redirect_rejection_reason, should_cancel):
        assert not should_cancel()
        assert redirect_rejection_reason(request.url) is None
        requests.append(request)
        assert remaining, "A complete range body must not trigger another transfer"
        response = remaining.popleft()
        assert redirect_rejection_reason(response.url) is None
        return response

    def ffprobe(data, *, local_path=None, should_cancel):
        if local_path is not None:
            probe_paths.append(local_path)
            assert local_path.read_bytes().startswith(data)
        return original_probe(data, local_path=local_path, should_cancel=should_cancel)

    monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
    monkeypatch.setattr(engine, "_ffprobe_douyin_media", ffprobe)
    return engine, requests, remaining, probe_paths


def probe(engine, *, should_cancel=lambda: False):
    return engine._probe_douyin_candidate(
        object(), CANDIDATE_URL, expected_duration=EXPECTED_DURATION,
        should_cancel=should_cancel,
    )


def assert_cleaned(responses, paths):
    assert all(response.closed for response in responses)
    assert all(not path.exists() for path in paths)


@pytest.mark.parametrize("status", [200, 206])
def test_complete_fragmented_body_is_reprobed_seekably_without_redownload(
    monkeypatch, synthetic_media, status,
):
    payload = synthetic_media["complete"]
    responses = [SyntheticResponse(payload, status=status)]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)

    initial = engine._ffprobe_douyin_media(payload, should_cancel=lambda: False)
    assert float(initial["duration"]) == pytest.approx(10.033333, abs=0.001)
    result = probe(engine)

    assert float(result["duration"]) == pytest.approx(50.8, abs=0.001)
    assert (result["width"], result["height"]) == (64, 64)
    assert result["filesize"] == len(payload)
    assert result["probe_prefix_size"] == len(payload)
    assert result["probe_prefix_sha256"] == hashlib.sha256(payload).hexdigest()
    assert len(requests) == 1 and "Range" in requests[0].headers
    assert not remaining
    assert len(paths) == 1
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("status", [200, 206])
def test_genuinely_short_complete_video_still_fails_strict_duration_gate(
    monkeypatch, synthetic_media, status,
):
    responses = [SyntheticResponse(synthetic_media["short"], status=status)]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)

    with pytest.raises(downloader._DouyinProbeRejected, match="duration did not match") as caught:
        probe(engine)

    assert "expected 50.804s, measured 10.033s, tolerance 0.508s" in str(caught.value)
    assert len(requests) == 1 and not remaining
    assert len(paths) == 1
    assert_cleaned(responses, paths)


def test_cancellation_during_complete_body_reprobe_removes_temporary_media(
    monkeypatch, synthetic_media,
):
    responses = [SyntheticResponse(synthetic_media["complete"])]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)
    original_probe = engine._ffprobe_douyin_media
    cancelled = False

    def cancel_local_probe(data, *, local_path=None, should_cancel):
        nonlocal cancelled
        if local_path is not None:
            cancelled = True
        return original_probe(data, local_path=local_path, should_cancel=should_cancel)

    monkeypatch.setattr(engine, "_ffprobe_douyin_media", cancel_local_probe)
    with pytest.raises(DownloadCancelled, match="Task cancelled"):
        probe(engine, should_cancel=lambda: cancelled)

    assert len(requests) == 1 and not remaining
    assert len(paths) == 1
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("known_total", [False, True])
def test_unproven_or_incomplete_range_still_fetches_and_verifies_full_file(
    monkeypatch, synthetic_media, known_total,
):
    payload = synthetic_media["complete"]
    prefix = payload[:8192] if known_total else payload
    responses = [
        SyntheticResponse(prefix, total=len(payload) if known_total else "*"),
        SyntheticResponse(payload, status=200),
    ]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)

    result = probe(engine)

    assert float(result["duration"]) == pytest.approx(50.8, abs=0.001)
    assert ["Range" in request.headers for request in requests] == [True, False]
    assert not remaining and len(paths) == 1
    assert_cleaned(responses, paths)


@pytest.mark.parametrize("invalid_header", ["range_start", "range_end", "range_syntax", "length"])
def test_inconsistent_range_headers_do_not_grant_complete_body_reuse(
    monkeypatch, synthetic_media, invalid_header,
):
    payload = synthetic_media["complete"]
    first = SyntheticResponse(payload)
    size = len(payload)
    if invalid_header == "range_start":
        first.headers["Content-Range"] = f"bytes 1-{size}/{size}"
    elif invalid_header == "range_end":
        first.headers["Content-Range"] = f"bytes 0-{size - 2}/{size}"
    elif invalid_header == "range_syntax":
        first.headers["Content-Range"] = f"invalid/{size}"
    else:
        first.headers["Content-Length"] = str(size - 1)
    responses = [first, SyntheticResponse(payload, status=200)]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)

    result = probe(engine)

    assert float(result["duration"]) == pytest.approx(50.8, abs=0.001)
    assert ["Range" in request.headers for request in requests] == [True, False]
    assert not remaining and len(paths) == 1
    assert_cleaned(responses, paths)


def test_complete_body_probe_cache_retains_exact_bytes_only_until_scope_exit(
    monkeypatch, synthetic_media, tmp_path,
):
    payload = synthetic_media["complete"]
    responses = [SyntheticResponse(payload)]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)
    with engine._douyin_probe_reuse_scope(tmp_path):
        result = probe(engine)
        assert float(result["duration"]) == pytest.approx(50.8, abs=0.001)
        assert len(paths) == 1
        assert paths[0].read_bytes() == payload
    assert len(requests) == 1 and not remaining
    assert_cleaned(responses, paths)
    assert not list(tmp_path.iterdir())


def test_long_audio_and_matching_container_cannot_hide_a_short_video(
    monkeypatch, synthetic_media,
):
    # The shared fixture has already checked that real FFmpeg and FFprobe exist.
    ffmpeg = shutil.which("ffmpeg")
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    with tempfile.TemporaryDirectory(prefix="chengying-duration-audio-fixture-") as directory:
        path = Path(directory) / "short-video-long-audio.mp4"
        subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "color=black:s=64x64:r=30:d=10.033333",
                "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=50.804",
                "-c:v", "libx264", "-preset", "ultrafast",
                "-c:a", "aac", "-b:a", "64k", str(path),
            ],
            check=True, capture_output=True, timeout=30,
        )
        raw = subprocess.run(
            [
                engine._find_ffprobe_executable(), "-v", "error", "-count_packets",
                "-show_entries", "stream=codec_type,duration,nb_read_packets:format=duration",
                "-of", "json", str(path),
            ],
            check=True, capture_output=True, timeout=30,
        )
        metadata = json.loads(raw.stdout)
        streams = {stream["codec_type"]: stream for stream in metadata["streams"]}
        assert float(metadata["format"]["duration"]) == pytest.approx(50.804, abs=0.001)
        assert float(streams["audio"]["duration"]) == pytest.approx(50.804, abs=0.001)
        assert float(streams["video"]["duration"]) == pytest.approx(10.033333, abs=0.001)
        assert int(streams["video"]["nb_read_packets"]) == 301
        payload = path.read_bytes()
    assert not Path(directory).exists()
    assert len(payload) > downloader.DOUYIN_PROBE_BYTES
    responses = [SyntheticResponse(payload), SyntheticResponse(payload, status=200)]
    engine, requests, remaining, paths = install_engine(monkeypatch, responses)

    with pytest.raises(downloader._DouyinProbeRejected, match="duration did not match") as caught:
        probe(engine)

    assert "expected 50.804s, measured 10.033s, tolerance 0.508s" in str(caught.value)
    assert ["Range" in request.headers for request in requests] == [True, False]
    assert not remaining and len(paths) == 1
    assert_cleaned(responses, paths)
