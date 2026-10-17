"""Synthetic image-header transfers: no network, browser data, or image re-encoding."""

from __future__ import annotations

import socket
import struct
import sys
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader
from app.downloader import DownloaderConfig, MediaDownloader
from app.errors import (
    DouyinMediaRefreshRequiredError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import MediaType, Platform
from app.xiaohongshu import RemoteAsset
from yt_dlp.networking._requests import RequestsResponseAdapter
from yt_dlp.networking.exceptions import TransportError

MEDIA_URL = "https://p3.douyinpic.com/synthetic-image.png"
SOURCE_URL = "https://www.douyin.com/note/1234567890123456789"
DIMENSIONS = (1920, 1080)


@pytest.fixture(autouse=True)
def forbid_external_resources(monkeypatch, tmp_path):
    def blocked(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in synthetic image tests")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket, "create_connection", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)
    from app import browser
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: tmp_path / "chrome")


def image_payload(kind, *, dimensions=DIMENSIONS):
    """Build dimension-parser fixtures, not complete image-decoder fixtures."""
    width, height = dimensions
    if kind == "png":
        header = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
        header += struct.pack(">II", width, height)
    elif kind in {"jpeg", "jpeg-large-metadata"}:
        header = b"\xff\xd8"
        if kind == "jpeg-large-metadata":
            # A valid maximum-size APP segment, then another metadata segment,
            # puts the SOF beyond a 64 KiB transfer chunk.
            header += b"\xff\xe1\xff\xff" + b"x" * 65533
            header += b"\xff\xe2\x10\x02" + b"y" * 4096
        header += b"\xff\xc0\x00\x11\x08" + struct.pack(">HH", height, width)
        header += b"\x03\x01\x11\x00\x02\x11\x00\x03\x11\x00"
    elif kind == "webp-vp8x":
        header = b"RIFF\x2a\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00"
        header += (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
    elif kind == "webp-vp8l":
        header = b"RIFF\x2a\x00\x00\x00WEBPVP8L\x0a\x00\x00\x00\x2f"
        header += ((width - 1) | ((height - 1) << 14)).to_bytes(4, "little")
    elif kind == "webp-vp8":
        header = b"RIFF\x2a\x00\x00\x00WEBPVP8 \x0a\x00\x00\x00\x00\x00\x00\x9d\x01\x2a"
        header += struct.pack("<HH", width, height)
    else:
        raise AssertionError(f"Unknown synthetic image kind: {kind}")
    return header + b"synthetic-image-body" * 5


class FragmentedRaw(BytesIO):
    def __init__(self, payload, fragment_size, on_read=None):
        super().__init__(payload)
        self.fragment_size = fragment_size
        self.on_read = on_read
        self.read1_sizes = []
        self.bytes_read = 0

    def read(self, size=-1, decode_content=False):
        raise AssertionError("A blocking raw read must not replace read1")

    def read1(self, size, decode_content=False):
        assert decode_content is True
        assert size > 0
        self.read1_sizes.append(size)
        if self.on_read:
            self.on_read(len(self.read1_sizes))
        chunk = BytesIO.read(self, min(size, self.fragment_size))
        self.bytes_read += len(chunk)
        return chunk


def response_for(payload, *, fragment_size=2, on_read=None, content_length=None):
    raw = FragmentedRaw(payload, fragment_size, on_read)
    response = RequestsResponseAdapter(SimpleNamespace(
        raw=raw, url=MEDIA_URL, status_code=200, reason="OK",
        headers={
            "Content-Type": "image/png",
            "Content-Length": str(len(payload) if content_length is None else content_length),
        },
    ))
    return response, raw


def transfer(engine, tmp_path, *, asset=None, should_cancel=lambda: False, **kwargs):
    asset = asset or RemoteAsset(
        candidates=[MEDIA_URL], index=1, width=DIMENSIONS[0], height=DIMENSIONS[1],
    )
    return engine._download_first_available_asset(
        object(), [asset], tmp_path, "20261018", "Synthetic image", "1234567890123456789",
        SOURCE_URL, platform=Platform.DOUYIN, media_type=MediaType.IMAGE,
        callback=None, should_cancel=should_cancel, verify_declared_dimensions=True,
        **kwargs,
    )


def install_responses(monkeypatch, responses):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    requests = []
    remaining = iter(responses)

    def open_response(ydl, request, **kwargs):
        requests.append(request)
        return next(remaining)

    monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
    monkeypatch.setattr(engine, "_wait_for_douyin_probe_retry", lambda *args: None)
    return engine, requests


@pytest.mark.parametrize("kind", [
    "png", "jpeg", "jpeg-large-metadata", "webp-vp8x", "webp-vp8l", "webp-vp8",
])
@pytest.mark.parametrize("fragment_size", [1, 2, 65536])
def test_fragmented_image_header_preserves_exact_bytes(
    monkeypatch, tmp_path, kind, fragment_size,
):
    payload = image_payload(kind)
    response, raw = response_for(payload, fragment_size=fragment_size)
    engine, requests = install_responses(monkeypatch, [response])
    original_parser = engine._image_dimensions
    parsed_sizes = []

    def parse(header):
        parsed_sizes.append(len(header))
        return original_parser(header)

    monkeypatch.setattr(engine, "_image_dimensions", parse)
    path, chosen = transfer(engine, tmp_path)
    assert path.read_bytes() == payload
    assert (chosen.width, chosen.height) == DIMENSIONS
    assert chosen.candidates == [MEDIA_URL]
    assert raw.bytes_read == len(payload)
    assert len(requests) == 1
    assert 0 < requests[0].extensions["timeout"] <= 30
    assert response.closed
    assert len(parsed_sizes) <= 16
    assert max(raw.read1_sizes) <= downloader.DOUYIN_STREAM_CHUNK_BYTES
    assert list(tmp_path.iterdir()) == [path]


@pytest.mark.parametrize("dimensions", [(1280, 720), (1920, 720), (1280, 1080)])
def test_fragmented_lower_resolution_is_still_rejected(monkeypatch, tmp_path, dimensions):
    response, _ = response_for(image_payload("png", dimensions=dimensions))
    engine, _ = install_responses(monkeypatch, [response])
    with pytest.raises(MediaDownloadError, match="below its declared 1920x1080 resolution"):
        transfer(engine, tmp_path)
    assert response.closed
    assert not list(tmp_path.iterdir())


def test_fragmented_rejected_candidate_tries_only_next_original(monkeypatch, tmp_path):
    low, _ = response_for(image_payload("png", dimensions=(1280, 720)))
    payload = image_payload("png")
    original, _ = response_for(payload)
    engine, requests = install_responses(monkeypatch, [low, original])
    candidates = [MEDIA_URL, "https://p6.douyinpic.com/synthetic-original.png"]
    asset = RemoteAsset(candidates=candidates, index=1, width=1920, height=1080)
    path, _ = transfer(engine, tmp_path, asset=asset)
    assert path.read_bytes() == payload
    assert [request.url for request in requests] == candidates
    assert low.closed and original.closed


@pytest.mark.parametrize("payload", [b"\x89PNG", b"\xff\xd8\xff\xe1\xff\xff"])
def test_truncated_header_fails_without_publishing(monkeypatch, tmp_path, payload):
    response, raw = response_for(payload)
    engine, requests = install_responses(monkeypatch, [response])
    with pytest.raises(MediaDownloadError, match="image dimensions could not be verified"):
        transfer(engine, tmp_path)
    assert raw.bytes_read == len(payload)
    assert len(requests) == 1
    assert response.closed
    assert not list(tmp_path.iterdir())


def test_header_byte_budget_is_bounded_with_one_byte_fragments(monkeypatch, tmp_path):
    monkeypatch.setattr(downloader, "DOUYIN_IMAGE_HEADER_MAX_BYTES", 256)
    response, raw = response_for(b"x" * 1024, fragment_size=1)
    engine, _ = install_responses(monkeypatch, [response])
    with pytest.raises(MediaDownloadError, match="image dimensions could not be verified"):
        transfer(engine, tmp_path)
    assert raw.bytes_read == 256
    assert len(raw.read1_sizes) == 256
    assert response.closed
    assert not list(tmp_path.iterdir())


def test_header_elapsed_budget_does_not_refresh_on_tiny_progress(monkeypatch, tmp_path):
    now = [0.0]
    monkeypatch.setattr(downloader.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(downloader, "DOUYIN_IMAGE_HEADER_TIMEOUT_SECONDS", 5.0)

    def advance(read_number):
        now[0] += 1.0

    response, raw = response_for(image_payload("png"), fragment_size=1, on_read=advance)
    engine, requests = install_responses(monkeypatch, [response])
    with pytest.raises(TemporaryAccessError, match="header could not be verified within 5 seconds") as error:
        transfer(engine, tmp_path)
    assert error.value.issue_code == SiteIssueCode.NETWORK_ERROR
    assert len(raw.read1_sizes) == 5
    assert len(requests) == 1
    assert response.closed
    assert not list(tmp_path.iterdir())


def test_header_idle_budget_is_not_refreshed_after_expired_read(monkeypatch, tmp_path):
    now = [0.0]
    monkeypatch.setattr(downloader.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(downloader, "DOUYIN_TRANSFER_IDLE_TIMEOUT_SECONDS", 3.0)

    def advance(read_number):
        now[0] += 0.1 if read_number == 1 else 4.0

    response, raw = response_for(image_payload("png"), fragment_size=1, on_read=advance)
    engine, _ = install_responses(monkeypatch, [response])
    with pytest.raises(TemporaryAccessError, match="made no media progress"):
        transfer(engine, tmp_path)
    assert len(raw.read1_sizes) == 2
    assert response.closed
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("cancel_read", [1, 4, 32])
def test_cancel_during_header_never_publishes(monkeypatch, tmp_path, cancel_read):
    response, raw = response_for(image_payload("png"), fragment_size=1)
    engine, requests = install_responses(monkeypatch, [response])
    with pytest.raises(DownloadCancelledError):
        transfer(engine, tmp_path, should_cancel=lambda: len(raw.read1_sizes) >= cancel_read)
    assert len(raw.read1_sizes) == cancel_read
    assert len(requests) == 1
    assert response.closed
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("mismatch", ["content_length", "verified_size"])
def test_fragmented_image_does_not_bypass_size_integrity(monkeypatch, tmp_path, mismatch):
    payload = image_payload("png")
    length = len(payload) + 1 if mismatch == "content_length" else len(payload)
    responses = [response_for(payload, content_length=length)[0] for _ in range(3)]
    engine, _ = install_responses(monkeypatch, responses)
    asset = RemoteAsset(
        candidates=[MEDIA_URL], index=1, width=1920, height=1080,
        size=len(payload) + 1 if mismatch == "verified_size" else None,
    )
    with pytest.raises((TemporaryAccessError, MediaDownloadError), match="expected"):
        transfer(engine, tmp_path, asset=asset)
    assert all(response.closed for response in responses)
    assert not list(tmp_path.iterdir())


def test_header_transport_error_keeps_bounded_existing_retries(monkeypatch, tmp_path):
    def fail_after_fragment(read_number):
        if read_number == 2:
            raise TransportError("Synthetic network timeout")

    responses = [response_for(image_payload("png"), on_read=fail_after_fragment)[0] for _ in range(3)]
    engine, requests = install_responses(monkeypatch, responses)
    with pytest.raises(TemporaryAccessError):
        transfer(engine, tmp_path)
    assert len(requests) == 3
    assert all(response.closed for response in responses)
    assert not list(tmp_path.iterdir())


def test_untrusted_image_url_is_rejected_before_any_header_read(monkeypatch, tmp_path):
    engine, requests = install_responses(monkeypatch, [])
    asset = RemoteAsset(
        candidates=["https://p3.douyinpic.com:58001/synthetic.png"], index=1,
        width=1920, height=1080,
    )
    with pytest.raises(DouyinMediaRefreshRequiredError) as error:
        transfer(engine, tmp_path, asset=asset)
    assert error.value.issue_code == SiteIssueCode.SECURITY_BLOCKED
    assert not requests
    assert not list(tmp_path.iterdir())
