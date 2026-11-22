"""Typed signer-html failures stay item-local on opt-in Douyin profile queues.

Synthetic engines, local files and mocked signing routes only; no accounts,
network or real browser access. The queue policy, the targeted author-feed
fallback and the final signing classification are checked together with their
negative controls: every other response change, gate and standalone default
must keep the original whole-task pause.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import test_batch_retry_round as batch_fixtures
from app import douyin, douyin_signing
from app.downloader import DiscoveryResult
from app.errors import (
    AuthenticationRequiredError,
    DouyinSignerHtmlError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import DownloadItem, ItemStatus, JobStatus, MediaType, Platform
from app.task_manager import DownloadManager
from test_batch_retry_round import SyntheticEngine, install_engine, run, wait

forbid_network = batch_fixtures.forbid_network
manager = batch_fixtures.manager

PROFILE_ID = "MS4wLjABAAAAfixture-signer-queue-owner"
SOURCE = f"https://www.douyin.com/user/{PROFILE_ID}"
SIGNER_MESSAGE = (
    "Douyin returned incomplete or changed signed response data after "
    "automatic retries. The response could not be verified, so the task "
    "was paused without downloading a fallback. Reason category: signer-html."
)


def signer_error():
    return DouyinSignerHtmlError(SIGNER_MESSAGE)


class SignerProfileEngine(SyntheticEngine):
    """Verified Douyin profile items with cached, identity-bound metadata."""

    def discover(self, url, platform, kind, *, should_cancel):
        assert not should_cancel()
        assert url == SOURCE
        assert platform == Platform.DOUYIN
        self.discoveries.append((url, platform, kind))
        items = []
        for position, key in enumerate(self.ids, 1):
            media_id = str(7100000000000000000 + position)
            items.append(DownloadItem(
                id=key,
                media_id=media_id,
                source_url=f"https://www.douyin.com/video/{media_id}",
                title=f"Fixture video {key}",
                extractor_key="Douyin",
                media_type=MediaType.VIDEO,
                metadata={
                    "profile_url": SOURCE,
                    "profile_owner_verified": True,
                    "douyin_profile_media": {
                        "media_id": media_id,
                        "owner_id": PROFILE_ID,
                        "media_kind": "video",
                        "title": f"Fixture video {key}",
                        "author": "Fixture Signer Author",
                        "create_time": 1660000000,
                        "video_uri": f"v0200fg10000fixturesigner{position}",
                        "minimum_width": 1080,
                        "minimum_height": 1920,
                        "direct_candidates": [{
                            "video_uri": f"v0200fg10000fixturesigner{position}",
                            "width": 1080,
                            "height": 1920,
                            "urls": [
                                f"https://v26-web.douyinvod.com/fixture-signer-{position}.mp4",
                            ],
                        }],
                    },
                },
            ))
        return DiscoveryResult(
            author="Fixture Signer Author", items=items,
            discovery_complete=self.discovery_complete, warning=self.warning,
        )


def test_signer_html_failure_finishes_queue_then_retries_once(manager, monkeypatch):
    engine = SignerProfileEngine({"B": [signer_error()]}, ids=("A", "B", "C"))
    identities = install_engine(manager, engine, monkeypatch)
    events = []

    def listener(event, job):
        saved = manager.store.get(job.id)
        assert saved.revision == job.revision
        events.append((event.event, event.item_id, saved))

    manager.add_listener(listener)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "C", "B"]
    assert len(engine.discoveries) == 1
    assert result.status == JobStatus.COMPLETED
    assert result.completed_items == 3
    assert result.failed_items == 0
    assert [item.attempts for item in result.items] == [1, 2, 1]
    assert result.auto_retry_round == result.auto_retry_total == 1
    assert result.discovery_complete
    assert result.issue_code is result.issue_message is result.error is None
    assert identities == [("chrome", "Profile 1", SOURCE)]
    names = [(name, item_id) for name, item_id, _ in events]
    assert names.index(("item_failed", "B")) < names.index(("item_started", "C"))
    assert names.index(("item_completed", "C")) < names.index(("auto_retry_started", None))
    failure = next(job for name, _, job in events if name == "item_failed")
    assert failure.status == JobStatus.DOWNLOADING
    assert failure.discovery_complete
    assert failure.items[1].issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert failure.items[1].retryable
    assert failure.items[1].output_paths == []


def test_persistent_signer_html_failure_leaves_partial_with_every_item_processed(
    manager, monkeypatch,
):
    engine = SignerProfileEngine(
        {"B": [signer_error(), signer_error()]}, ids=("A", "B", "C"),
    )
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "C", "B"]
    assert result.status == JobStatus.PARTIAL
    assert result.completed_items == 2
    assert result.failed_items == 1
    assert all(item.status != ItemStatus.QUEUED for item in result.items)
    assert result.items[1].attempts == 2
    assert result.items[1].issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert result.retryable
    assert result.items[1].retryable
    assert result.discovery_complete
    assert result.auto_retry_round == result.auto_retry_total == 1


def test_restart_and_manual_continue_preserve_completed_files_and_attempts(
    manager, monkeypatch, tmp_path,
):
    engine = SignerProfileEngine({"A": [signer_error(), signer_error()]})
    install_engine(manager, engine, monkeypatch)
    failed = run(manager, source=SOURCE)
    path = Path(failed.items[1].output_paths[0])
    original = (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns)
    manager.shutdown()
    resumed = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
        max_workers=1, auto_retry_failed_items=True,
    )
    try:
        stored = resumed.get_job(failed.id)
        assert stored.status == JobStatus.PARTIAL
        assert stored.discovery_complete
        assert not resumed._futures
        assert stored.auto_retry_round == 1
        assert stored.items[0].attempts == 2
        next_engine = SignerProfileEngine()
        identities = install_engine(resumed, next_engine, monkeypatch)
        resumed.retry_failed(failed.id)
        completed = wait(resumed, failed.id)
        assert next_engine.calls == ["A"]
        assert completed.status == JobStatus.COMPLETED
        assert [item.attempts for item in completed.items] == [3, 1]
        assert completed.output_dir == failed.output_dir
        assert identities == [("chrome", "Profile 1", SOURCE)]
        assert (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns) == original
    finally:
        resumed.shutdown()


def test_previous_signer_html_failure_grants_no_exemption_to_next_submission(
    manager, monkeypatch,
):
    engine = SignerProfileEngine({"A": [signer_error(), signer_error()]})
    install_engine(manager, engine, monkeypatch)
    failed = run(manager, source=SOURCE)
    engine.errors["A"] = [MediaDownloadError(
        SIGNER_MESSAGE, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
    )]
    manager.retry_failed(failed.id)
    result = wait(manager, failed.id)
    assert engine.calls == ["A", "B", "A", "A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.auto_retry_round == result.auto_retry_total == 0
    assert result.items[0].attempts == 3


def test_old_error_text_does_not_make_an_item_automatically_retryable():
    item = DownloadItem(
        id="legacy", source_url="https://www.douyin.com/video/7100000000000000001",
        extractor_key="Douyin", media_type=MediaType.VIDEO,
        status=ItemStatus.FAILED, error=SIGNER_MESSAGE,
        issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
    )
    assert not DownloadManager._can_auto_retry_item(item)


@pytest.mark.parametrize("code", [
    SiteIssueCode.SECURITY_BLOCKED, SiteIssueCode.COOKIE_UNAVAILABLE,
    SiteIssueCode.LOCAL_CONFIGURATION, SiteIssueCode.RATE_LIMITED,
    SiteIssueCode.REQUEST_REJECTED, SiteIssueCode.LOGIN_REQUIRED,
    SiteIssueCode.VERIFICATION_REQUIRED,
])
def test_typed_exception_does_not_override_an_explicit_gate(manager, monkeypatch, code):
    engine = SignerProfileEngine({"A": [DouyinSignerHtmlError(
        SIGNER_MESSAGE, issue_code=code,
    )]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.issue_code == code
    assert result.items[1].status == ItemStatus.QUEUED
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_untyped_temporary_access_error_still_pauses_the_whole_queue(
    manager, monkeypatch,
):
    engine = SignerProfileEngine({"A": [TemporaryAccessError(SIGNER_MESSAGE)]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.items[1].status == ItemStatus.QUEUED
    assert not result.discovery_complete
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_untyped_media_response_change_pauses_without_a_tail_retry(
    manager, monkeypatch,
):
    engine = SignerProfileEngine({"A": [MediaDownloadError(
        SIGNER_MESSAGE, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
    )]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.items[1].status == ItemStatus.QUEUED
    assert result.auto_retry_round == result.auto_retry_total == 0


@pytest.mark.parametrize("failure", [
    AuthenticationRequiredError("Login required"),
    DownloadCancelledError("Task cancelled"),
])
def test_control_failures_keep_their_original_handling(manager, monkeypatch, failure):
    engine = SignerProfileEngine({"A": [failure]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status in {JobStatus.NEEDS_AUTH, JobStatus.CANCELLED}
    assert result.auto_retry_round == 0


def test_single_video_task_keeps_the_original_pause(manager, monkeypatch):
    item_url = "https://www.douyin.com/video/7100000000000000001"
    engine = SignerProfileEngine({"A": [signer_error()]}, ids=("A",))
    original_discover = engine.discover

    def discover(url, platform, kind, *, should_cancel):
        result = original_discover(SOURCE, platform, kind, should_cancel=should_cancel)
        result.items[0].source_url = item_url
        return result

    engine.discover = discover
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=item_url)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_standalone_default_keeps_the_original_pause(monkeypatch, tmp_path):
    standalone = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
    )
    try:
        engine = SignerProfileEngine({"A": [signer_error()]})
        install_engine(standalone, engine, monkeypatch)
        result = run(standalone, source=SOURCE)
        assert engine.calls == ["A"]
        assert result.status == JobStatus.INTERRUPTED
        assert result.items[1].status == ItemStatus.QUEUED
        assert result.auto_retry_enabled is False
        assert result.auto_retry_round == result.auto_retry_total == 0
    finally:
        standalone.shutdown()


@pytest.mark.parametrize("cancel_on", ["item_failed", "auto_retry_started"])
def test_cancel_prevents_signer_html_tail_retry(manager, monkeypatch, cancel_on):
    engine = SignerProfileEngine({"A": [signer_error()]})
    install_engine(manager, engine, monkeypatch)
    manager.add_listener(
        lambda event, job: manager.cancel_job(job.id) if event.event == cancel_on else None
    )
    result = run(manager, source=SOURCE)
    assert result.status == JobStatus.CANCELLED
    assert engine.calls == (["A"] if cancel_on == "item_failed" else ["A", "B"])
    assert result.items[0].attempts == 1


@pytest.mark.parametrize("failure", [
    MediaDownloadError("Untrusted media route", issue_code=SiteIssueCode.SECURITY_BLOCKED),
    MediaDownloadError("HTTP 429", issue_code=SiteIssueCode.RATE_LIMITED),
    MediaDownloadError(SIGNER_MESSAGE, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED),
    AuthenticationRequiredError("Login required"),
])
def test_new_gate_on_tail_stops_before_other_failed_items(manager, monkeypatch, failure):
    engine = SignerProfileEngine({
        "A": [signer_error(), failure], "B": [signer_error()],
    })
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "A"]
    assert result.status in {JobStatus.INTERRUPTED, JobStatus.NEEDS_AUTH}
    assert result.items[1].attempts == 1
    assert result.auto_retry_total == 2


def test_signer_html_error_is_raised_only_for_the_fixed_category():
    cause = douyin_signing._TransientSigningFailure(
        "private detail", category="signer-html",
    )
    with pytest.raises(DouyinSignerHtmlError) as captured:
        douyin_signing._raise_signing_error(
            "https://www.douyin.com/video/7100000000000000001", cause,
        )
    assert captured.value.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert captured.value.__cause__ is cause
    assert "Reason category: signer-html." in str(captured.value)
    assert "private detail" not in str(captured.value)

    other = douyin_signing._TransientSigningFailure(
        "private detail", category="http-5xx",
    )
    with pytest.raises(TemporaryAccessError) as captured:
        douyin_signing._raise_signing_error(
            "https://www.douyin.com/video/7100000000000000001", other,
        )
    assert not isinstance(captured.value, DouyinSignerHtmlError)


def _feed_aweme(media_id, profile_id, *, width=1440, height=2560):
    return {
        "aweme_id": media_id,
        "author": {"sec_uid": profile_id, "nickname": "Fixture Author"},
        "video": {
            "play_addr": {
                "uri": "v0200fg10000fixturesignerfeed",
                "width": width,
                "height": height,
                "url_list": ["https://v26-web.douyinvod.com/fixture-feed.mp4"],
            }
        },
    }


def test_targeted_discovery_recovers_signer_html_through_the_author_feed(monkeypatch):
    media_id = "7100000000000000001"
    detail_calls = []
    feed_calls = []

    def fetch_detail(*args, **kwargs):
        detail_calls.append(kwargs)
        raise signer_error()

    def fetch_feed(profile_url, requested_profile_id, **kwargs):
        feed_calls.append((profile_url, requested_profile_id, kwargs))
        return [_feed_aweme(media_id, PROFILE_ID)]

    monkeypatch.setattr(douyin, "fetch_signed_aweme_detail", fetch_detail)
    monkeypatch.setattr(douyin, "fetch_signed_profile_awemes", fetch_feed)

    result = douyin.discover_item_metadata_from_profile(
        PROFILE_ID, media_id, prefer_exact_detail=True,
    )

    assert result and result["media_id"] == media_id
    assert result["owner_id"] == PROFILE_ID
    assert result["minimum_width"] == 1440
    assert result["minimum_height"] == 2560
    assert len(detail_calls) == 1
    assert len(feed_calls) == 1
    assert feed_calls[0][2]["target_aweme_id"] == media_id
    assert feed_calls[0][2]["progress_budget"] is detail_calls[0]["progress_budget"]


def test_targeted_discovery_surfaces_signer_html_when_feed_lacks_the_item(monkeypatch):
    media_id = "7100000000000000001"
    original = signer_error()

    monkeypatch.setattr(
        douyin, "fetch_signed_aweme_detail",
        lambda *args, **kwargs: (_ for _ in ()).throw(original),
    )
    monkeypatch.setattr(
        douyin, "fetch_signed_profile_awemes",
        lambda *args, **kwargs: [_feed_aweme("7100000000000000002", PROFILE_ID)],
    )

    with pytest.raises(DouyinSignerHtmlError) as captured:
        douyin.discover_item_metadata_from_profile(
            PROFILE_ID, media_id, prefer_exact_detail=True,
        )
    assert captured.value is original


@pytest.mark.parametrize("gate", [
    SiteIssueCode.LOGIN_REQUIRED, SiteIssueCode.VERIFICATION_REQUIRED,
])
def test_targeted_discovery_feed_authentication_still_propagates(monkeypatch, gate):
    media_id = "7100000000000000001"
    monkeypatch.setattr(
        douyin, "fetch_signed_aweme_detail",
        lambda *args, **kwargs: (_ for _ in ()).throw(signer_error()),
    )
    monkeypatch.setattr(
        douyin, "fetch_signed_profile_awemes",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            AuthenticationRequiredError("Login required", issue_code=gate)
        ),
    )
    with pytest.raises(AuthenticationRequiredError):
        douyin.discover_item_metadata_from_profile(
            PROFILE_ID, media_id, prefer_exact_detail=True,
        )


def test_targeted_discovery_rejects_crosswired_feed_identity(monkeypatch):
    media_id = "7100000000000000001"
    monkeypatch.setattr(
        douyin, "fetch_signed_aweme_detail",
        lambda *args, **kwargs: (_ for _ in ()).throw(signer_error()),
    )
    monkeypatch.setattr(
        douyin, "fetch_signed_profile_awemes",
        lambda *args, **kwargs: [
            _feed_aweme(media_id, "MS4wLjABAAAAforeign-author")
        ],
    )
    with pytest.raises(TemporaryAccessError) as captured:
        douyin.discover_item_metadata_from_profile(
            PROFILE_ID, media_id, prefer_exact_detail=True,
        )
    assert captured.value.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED


def test_other_detail_response_changes_keep_their_existing_fallback_semantics(monkeypatch):
    media_id = "7100000000000000001"
    original = TemporaryAccessError(
        "detail endpoint was temporarily limited",
        issue_code=SiteIssueCode.SITE_UNAVAILABLE,
    )
    feed_gate = TemporaryAccessError(
        "profile endpoint was temporarily limited",
        issue_code=SiteIssueCode.SITE_UNAVAILABLE,
    )
    monkeypatch.setattr(
        douyin, "fetch_signed_aweme_detail",
        lambda *args, **kwargs: (_ for _ in ()).throw(original),
    )
    monkeypatch.setattr(
        douyin, "fetch_signed_profile_awemes",
        lambda *args, **kwargs: (_ for _ in ()).throw(feed_gate),
    )
    with pytest.raises(TemporaryAccessError) as captured:
        douyin.discover_item_metadata_from_profile(
            PROFILE_ID, media_id, prefer_exact_detail=True,
        )
    assert captured.value is feed_gate