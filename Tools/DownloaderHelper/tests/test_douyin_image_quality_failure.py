"""Typed image-quality failures with synthetic bytes and no external resources."""

from __future__ import annotations

import socket
import sys
from collections import deque
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader
from app.downloader import DownloaderConfig, MediaDownloader
from app.errors import (
    AuthenticationRequiredError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import DownloadItem, MediaType, Platform
from app.xiaohongshu import RemoteAsset
from test_douyin_image_fragmented_transfer import image_payload, response_for
from yt_dlp.networking.common import Response
from yt_dlp.networking.exceptions import HTTPError, TransportError

DECLARED = (1000, 2079)
MEASURED_LOW = (924, 1920)
MEDIA_ID = "1234567890123456789"
PROFILE_ID = "MS4wLjABAAAAsyntheticqualityowner"
SOURCE_URL = f"https://www.douyin.com/video/{MEDIA_ID}"
PROFILE_URL = f"https://www.douyin.com/user/{PROFILE_ID}"
PRIVATE_MARKER = "synthetic-private-signature"


@pytest.fixture(autouse=True)
def forbid_external_resources(monkeypatch, tmp_path):
    def blocked(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in image-quality tests")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket, "create_connection", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)
    from app import browser

    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda: tmp_path / "chrome")


def image_response(dimensions=MEASURED_LOW, *, payload=None, mime="image/png"):
    payload = image_payload("png", dimensions=dimensions) if payload is None else payload
    response = response_for(payload, fragment_size=65536)[0]
    response.headers["Content-Type"] = mime
    return response


def candidate_urls(count):
    return [
        f"https://p{index + 1}.douyinpic.com/synthetic-{index}.png?signature={PRIVATE_MARKER}"
        for index in range(count)
    ]


def install_outcomes(monkeypatch, outcomes):
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    remaining = deque(outcomes)
    requests = []

    def open_response(ydl, request, **kwargs):
        requests.append(request)
        if not remaining:
            raise AssertionError("The transfer exceeded its synthetic response budget")
        outcome = remaining.popleft()
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    monkeypatch.setattr(engine, "_open_douyin_media_response", open_response)
    monkeypatch.setattr(engine, "_wait_for_douyin_probe_retry", lambda *args: None)
    return engine, requests, remaining


def transfer(engine, tmp_path, candidates, *, should_cancel=lambda: False):
    return engine._download_first_available_asset(
        object(),
        [RemoteAsset(candidates=candidates, index=1, width=DECLARED[0], height=DECLARED[1])],
        tmp_path, "20261019", "Synthetic quality fixture", MEDIA_ID, SOURCE_URL,
        platform=Platform.DOUYIN, media_type=MediaType.IMAGE,
        callback=None, should_cancel=should_cancel, asset_index=1,
        verify_declared_dimensions=True,
    )


def assert_not_item_quality_error(exc):
    assert isinstance(exc, (MediaDownloadError, TemporaryAccessError, AuthenticationRequiredError))
    assert not isinstance(exc, downloader.DouyinImageDimensionsError)
    assert PRIVATE_MARKER not in str(exc)


@pytest.mark.parametrize("count", [1, 3, 5])
def test_all_candidates_measured_lower_are_typed_without_publication(monkeypatch, tmp_path, count):
    responses = [image_response() for _ in range(count)]
    engine, requests, remaining = install_outcomes(monkeypatch, responses)
    urls = candidate_urls(count)
    with pytest.raises(downloader.DouyinImageDimensionsError) as caught:
        transfer(engine, tmp_path, urls)
    message = str(caught.value)
    assert "1000x2079" in message
    assert "924x1920" in message
    assert PRIVATE_MARKER not in message
    assert "https://" not in message
    assert caught.value.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert [request.url for request in requests] == urls
    assert not remaining
    assert all(response.closed for response in responses)
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("dimensions", [(999, 2079), (1000, 2078), (2078, 1000), (1, 1)])
def test_one_pixel_or_one_edge_short_is_not_silently_accepted(monkeypatch, tmp_path, dimensions):
    response = image_response(dimensions)
    engine, requests, _ = install_outcomes(monkeypatch, [response])
    with pytest.raises(downloader.DouyinImageDimensionsError):
        transfer(engine, tmp_path, candidate_urls(1))
    assert len(requests) == 1
    assert response.closed
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("dimensions", [DECLARED, tuple(reversed(DECLARED)), (1200, 2400)])
def test_later_valid_original_preserves_bytes_and_accepts_rotated_dimensions(
    monkeypatch, tmp_path, dimensions,
):
    payload = image_payload("png", dimensions=dimensions)
    responses = [image_response(), image_response(payload=payload)]
    engine, requests, _ = install_outcomes(monkeypatch, responses)
    path, selected = transfer(engine, tmp_path, candidate_urls(2))
    assert path.read_bytes() == payload
    assert (selected.width, selected.height) == dimensions
    assert len(requests) == 2
    assert all(response.closed for response in responses)
    assert list(tmp_path.iterdir()) == [path]


def different_failure(kind):
    if kind == "invalid_header":
        return image_response(payload=b"unsupported synthetic image")
    if kind == "empty":
        return image_response(payload=b"")
    if kind == "html":
        return image_response(payload=b"<html>synthetic failure</html>", mime="text/html")
    if kind == "redirect":
        return downloader._DouyinRedirectRejected(
            "Synthetic untrusted redirect", redirect_host="unrecognized",
            redirect_port=58001, redirect_reason="nonstandard-port",
            redirect_host_fingerprint="000000000000",
        )
    if kind == "authentication":
        return AuthenticationRequiredError(
            "Synthetic login required", issue_code=SiteIssueCode.LOGIN_REQUIRED,
        )
    if kind == "verification":
        return TemporaryAccessError(
            "Synthetic verification required", issue_code=SiteIssueCode.VERIFICATION_REQUIRED,
        )
    if kind == "transport":
        return TransportError("Synthetic network timeout")
    if kind in {"401", "403", "429"}:
        return HTTPError(Response(BytesIO(), candidate_urls(1)[0], {}, status=int(kind)))
    if kind == "unknown":
        return RuntimeError("Synthetic unknown response failure")
    if kind == "misleading_text":
        return MediaDownloadError(
            "Media server returned an image below its declared 1000x2079 resolution; "
            "measured 924x1920"
        )
    raise AssertionError(f"Unknown synthetic failure: {kind}")


@pytest.mark.parametrize("kind", [
    "invalid_header", "empty", "html", "redirect", "authentication",
    "verification", "transport", "401", "403", "429", "unknown", "misleading_text",
])
@pytest.mark.parametrize("bad_first", [True, False])
def test_mixed_failure_never_becomes_item_only_quality_failure(
    monkeypatch, tmp_path, kind, bad_first,
):
    outcomes = []
    for _ in range(3):
        pair = [different_failure(kind), image_response()]
        outcomes.extend(pair if bad_first else list(reversed(pair)))
    engine, requests, _ = install_outcomes(monkeypatch, outcomes)
    with pytest.raises(Exception) as caught:
        transfer(engine, tmp_path, candidate_urls(2))
    assert_not_item_quality_error(caught.value)
    assert 1 <= len(requests) <= 6
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("kind", ["transport", "401", "403", "429"])
def test_previous_transfer_failure_cannot_be_erased_by_later_low_only_attempt(
    monkeypatch, tmp_path, kind,
):
    outcomes = [different_failure(kind), image_response()]
    outcomes.extend(image_response() for _ in range(4))
    engine, requests, _ = install_outcomes(monkeypatch, outcomes)
    with pytest.raises(Exception) as caught:
        transfer(engine, tmp_path, candidate_urls(2))
    assert_not_item_quality_error(caught.value)
    assert 2 <= len(requests) <= 6
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("kind", ["invalid_header", "empty", "html", "redirect", "authentication"])
def test_global_failure_in_first_attempt_survives_transport_retry(monkeypatch, tmp_path, kind):
    outcomes = [different_failure(kind), different_failure("transport")]
    outcomes.extend(image_response() for _ in range(4))
    engine, requests, _ = install_outcomes(monkeypatch, outcomes)
    with pytest.raises(Exception) as caught:
        transfer(engine, tmp_path, candidate_urls(2))
    assert_not_item_quality_error(caught.value)
    assert 2 <= len(requests) <= 6
    assert not list(tmp_path.iterdir())


def test_security_candidate_is_not_hidden_by_another_lower_image(monkeypatch, tmp_path):
    engine, requests, _ = install_outcomes(monkeypatch, [image_response()])
    urls = ["https://p3.douyinpic.com:58001/synthetic.png", *candidate_urls(1)]
    with pytest.raises(Exception) as caught:
        transfer(engine, tmp_path, urls)
    assert_not_item_quality_error(caught.value)
    assert caught.value.issue_code == SiteIssueCode.SECURITY_BLOCKED
    assert len(requests) == 1
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("cancel_phase", ["before_request", "after_lower_candidate"])
def test_cancellation_has_priority_over_typed_quality_failure(monkeypatch, tmp_path, cancel_phase):
    responses = [image_response(), image_response()]
    engine, requests, _ = install_outcomes(monkeypatch, responses)

    def should_cancel():
        return cancel_phase == "before_request" or responses[0].closed

    with pytest.raises(DownloadCancelledError):
        transfer(engine, tmp_path, candidate_urls(2), should_cancel=should_cancel)
    assert len(requests) == (0 if cancel_phase == "before_request" else 1)
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("platform", [Platform.XIAOHONGSHU, Platform.KUAISHOU, Platform.INSTAGRAM])
def test_other_platforms_keep_existing_error_type(monkeypatch, tmp_path, platform):
    hosts = {
        Platform.XIAOHONGSHU: "sns-img-bd.xhscdn.com",
        Platform.KUAISHOU: "p3.a.yximgs.com",
        Platform.INSTAGRAM: "scontent.cdninstagram.com",
    }
    url = f"https://{hosts[platform]}/synthetic.png"
    response = Response(BytesIO(image_payload("png", dimensions=MEASURED_LOW)), url, {
        "Content-Type": "image/png",
    })
    engine = MediaDownloader(DownloaderConfig(cookie_browser=None))
    calls = []

    def open_response(*args, **kwargs):
        calls.append(True)
        return response

    monkeypatch.setattr(downloader, "_open_xiaohongshu_response", open_response)
    with pytest.raises(MediaDownloadError) as caught:
        engine._download_first_available_asset(
            object(), [RemoteAsset(candidates=[url], index=1, width=1000, height=2079)],
            tmp_path, "20261019", "Synthetic other platform", MEDIA_ID, "https://example.invalid/",
            platform=platform, media_type=MediaType.IMAGE, callback=None,
            should_cancel=lambda: False, verify_declared_dimensions=True,
        )
    assert_not_item_quality_error(caught.value)
    assert "below its declared" in str(caught.value)
    assert calls == [True]
    assert response.closed
    assert not list(tmp_path.iterdir())


@pytest.mark.parametrize("bound_item", [False, True])
def test_image_outer_wrapper_retains_typed_failure_and_completed_assets(
    monkeypatch, tmp_path, bound_item,
):
    urls = candidate_urls(2)
    metadata = {
        "media_id": MEDIA_ID, "owner_id": PROFILE_ID, "media_kind": "image",
        "title": "Synthetic two-image post", "author": "Synthetic Author",
        "create_time": 1_756_656_000,
        "image_assets": [
            {"index": index + 1, "width": 1000, "height": 2079, "candidates": [url]}
            for index, url in enumerate(urls)
        ],
    }
    binding = {
        "profile_url": PROFILE_URL, "profile_owner_verified": True,
        "douyin_profile_media": metadata,
    }
    if bound_item:
        binding = {
            "verification_url": SOURCE_URL, "item_identity_verified": True,
            "douyin_item_media": metadata,
        }
    item = DownloadItem(
        id="synthetic-quality-item", media_id=MEDIA_ID, source_url=SOURCE_URL,
        media_type=MediaType.IMAGE, metadata=binding,
    )
    payload = image_payload("png", dimensions=DECLARED)
    responses = [image_response(payload=payload), image_response()]
    engine, requests, _ = install_outcomes(monkeypatch, responses)
    monkeypatch.setattr(downloader, "YoutubeDL", lambda options: FakeYoutubeDL())
    events = []
    with pytest.raises(downloader.DouyinImageDimensionsError) as caught:
        engine._download_douyin_profile_image(
            item, tmp_path, callback=events.append, should_cancel=lambda: False,
        )
    assert "1000x2079" in str(caught.value)
    assert "924x1920" in str(caught.value)
    assert PRIVATE_MARKER not in str(caught.value)
    assert len(requests) == 2
    completed = [event for event in events if event.event == "asset_completed"]
    assert len(completed) == 1
    assert len(completed[0].output_paths) == 1
    saved = Path(completed[0].output_paths[0])
    assert saved.read_bytes() == payload
    assert list(tmp_path.iterdir()) == [saved]
    assert all(response.closed for response in responses)
    assert not any(event.event == "completed" for event in events)


class FakeYoutubeDL:
    def __enter__(self):
        return SimpleNamespace()

    def __exit__(self, *args):
        return False
