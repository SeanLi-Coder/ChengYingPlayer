"""Typed, item-local image failures must not suppress independent profile works."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import test_batch_retry_round as batch_fixtures
from app.downloader import DiscoveryResult, DouyinImageDimensionsError
from app.errors import (
    AuthenticationRequiredError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
)
from app.models import DownloadItem, ItemStatus, JobStatus, MediaType, Platform
from app.task_manager import DownloadManager
from test_batch_retry_round import (
    SyntheticEngine,
    install_engine,
    run,
    wait,
)

forbid_network = batch_fixtures.forbid_network
manager = batch_fixtures.manager

SOURCE = "https://www.douyin.com/user/fixture-image-queue-owner"
DIMENSION_MESSAGE = "Media server returned an image below its declared 1200x1600 resolution"


def dimensions_error():
    return DouyinImageDimensionsError(DIMENSION_MESSAGE)


class ImageEngine(SyntheticEngine):
    def discover(self, url, platform, kind, *, should_cancel):
        assert not should_cancel()
        assert url == SOURCE
        assert platform == Platform.DOUYIN
        self.discoveries.append((url, platform, kind))
        items = []
        for position, key in enumerate(self.ids, 1):
            media_id = str(7000000000000000000 + position)
            items.append(DownloadItem(
                id=key,
                media_id=media_id,
                source_url=f"https://www.douyin.com/video/{media_id}",
                title=f"Fixture image {key}",
                media_type=MediaType.IMAGE,
                metadata={
                    "profile_url": SOURCE,
                    "profile_owner_verified": True,
                    "douyin_profile_media": {
                        "media_id": media_id,
                        "owner_id": SOURCE.rsplit("/", 1)[1],
                        "media_kind": "image",
                        "title": f"Fixture image {key}",
                        "create_time": 1660000000,
                        "image_assets": [{
                            "index": 1,
                            "width": 1200,
                            "height": 1600,
                            "candidates": [f"https://p3.douyinpic.com/fixture-{key}.jpg"],
                        }],
                    },
                },
            ))
        return DiscoveryResult(
            author="Fixture Image Author", items=items,
            discovery_complete=self.discovery_complete, warning=self.warning,
        )


def test_isolated_dimensions_failure_finishes_queue_then_retries_once(manager, monkeypatch):
    engine = ImageEngine({"A": [dimensions_error()]}, ids=("A", "B", "C"))
    identities = install_engine(manager, engine, monkeypatch)
    events = []

    def listener(event, job):
        saved = manager.store.get(job.id)
        assert saved.revision == job.revision
        events.append((event.event, event.item_id, saved))

    manager.add_listener(listener)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "C", "A"]
    assert len(engine.discoveries) == 1
    assert result.status == JobStatus.COMPLETED
    assert result.completed_items == 3
    assert result.failed_items == 0
    assert [item.attempts for item in result.items] == [2, 1, 1]
    assert result.auto_retry_round == result.auto_retry_total == 1
    assert result.issue_code is result.issue_message is result.error is None
    assert identities == [("chrome", "Profile 1", SOURCE)]
    names = [(name, item_id) for name, item_id, _ in events]
    assert names.index(("item_failed", "A")) < names.index(("item_started", "B"))
    assert names.index(("item_completed", "C")) < names.index(("auto_retry_started", None))
    first_failure = next(job for name, _, job in events if name == "item_failed")
    assert first_failure.status == JobStatus.DOWNLOADING
    assert first_failure.items[0].issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert first_failure.items[0].output_paths == []
    assert first_failure.items[0].retryable
    assert first_failure.items[0].error == DIMENSION_MESSAGE


def test_persistent_dimensions_failure_does_not_leave_queue_unprocessed(manager, monkeypatch):
    engine = ImageEngine({"A": [dimensions_error(), dimensions_error()]}, ids=("A", "B", "C"))
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "C", "A"]
    assert result.status == JobStatus.PARTIAL
    assert result.completed_items == 2
    assert result.failed_items == 1
    assert all(item.status != ItemStatus.QUEUED for item in result.items)
    assert result.items[0].output_paths == []
    assert result.items[0].attempts == 2
    assert result.retryable
    assert result.items[0].retryable
    assert result.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert result.issue_message == DIMENSION_MESSAGE
    assert result.auto_retry_round == result.auto_retry_total == 1


def test_restart_and_manual_continue_preserve_files_identity_and_attempts(
    manager, monkeypatch, tmp_path,
):
    engine = ImageEngine({"A": [dimensions_error(), dimensions_error()]})
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
        assert not resumed._futures
        assert stored.auto_retry_round == 1
        assert stored.items[0].attempts == 2
        next_engine = ImageEngine({"A": [dimensions_error()]})
        identities = install_engine(resumed, next_engine, monkeypatch)
        resumed.retry_failed(failed.id)
        completed = wait(resumed, failed.id)
        assert next_engine.calls == ["A", "A"]
        assert len(next_engine.discoveries) == 1
        assert completed.status == JobStatus.COMPLETED
        assert [item.attempts for item in completed.items] == [4, 1]
        assert completed.output_dir == failed.output_dir
        assert identities == [("chrome", "Profile 1", SOURCE)]
        assert (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns) == original
    finally:
        resumed.shutdown()


@pytest.mark.parametrize("message", [
    DIMENSION_MESSAGE,
    "Highest-available image dimensions could not be verified",
    "Downloaded video content did not match the verified media endpoint",
    "Douyin metadata belongs to a different item and a different author",
])
def test_untyped_response_changes_still_pause_before_later_items(manager, monkeypatch, message):
    engine = ImageEngine({"A": [MediaDownloadError(
        message, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
    )]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.items[1].status == ItemStatus.QUEUED
    assert result.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert result.auto_retry_round == result.auto_retry_total == 0


@pytest.mark.parametrize("code", [
    SiteIssueCode.SECURITY_BLOCKED, SiteIssueCode.COOKIE_UNAVAILABLE,
    SiteIssueCode.LOCAL_CONFIGURATION, SiteIssueCode.RATE_LIMITED,
    SiteIssueCode.REQUEST_REJECTED, SiteIssueCode.LOGIN_REQUIRED,
    SiteIssueCode.VERIFICATION_REQUIRED,
])
@pytest.mark.parametrize("failure_type", [MediaDownloadError, DouyinImageDimensionsError])
def test_image_wording_does_not_override_explicit_global_gate(
    manager, monkeypatch, code, failure_type,
):
    engine = ImageEngine({"A": [failure_type(DIMENSION_MESSAGE, issue_code=code)]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.issue_code == code
    assert result.items[1].status == ItemStatus.QUEUED
    assert result.auto_retry_round == result.auto_retry_total == 0


@pytest.mark.parametrize("failure", [
    MediaDownloadError("Untrusted media route", issue_code=SiteIssueCode.SECURITY_BLOCKED),
    MediaDownloadError("HTTP 429", issue_code=SiteIssueCode.RATE_LIMITED),
    MediaDownloadError(DIMENSION_MESSAGE, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED),
    AuthenticationRequiredError("Login required"),
    DownloadCancelledError("Task cancelled"),
])
def test_new_gate_on_tail_stops_before_other_failed_items(manager, monkeypatch, failure):
    engine = ImageEngine({
        "A": [dimensions_error(), failure], "B": [dimensions_error()],
    })
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "A"]
    assert result.status in {JobStatus.INTERRUPTED, JobStatus.NEEDS_AUTH, JobStatus.CANCELLED}
    assert result.items[1].attempts == 1
    assert result.auto_retry_total == 2


@pytest.mark.parametrize("cancel_on", ["item_failed", "auto_retry_started"])
def test_cancel_prevents_dimension_tail_retry(manager, monkeypatch, cancel_on):
    engine = ImageEngine({"A": [dimensions_error()]})
    install_engine(manager, engine, monkeypatch)
    manager.add_listener(
        lambda event, job: manager.cancel_job(job.id) if event.event == cancel_on else None
    )
    result = run(manager, source=SOURCE)
    assert result.status == JobStatus.CANCELLED
    assert engine.calls == (["A"] if cancel_on == "item_failed" else ["A", "B"])
    assert result.items[0].attempts == 1


def test_typed_failure_keeps_partial_asset_receipts_and_output_paths(manager, monkeypatch):
    engine = ImageEngine({"A": [dimensions_error()]})
    engine.partial_receipts = True
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert result.status == JobStatus.COMPLETED
    retried = engine.snapshots[-1]
    assert retried.id == "A"
    assert len(retried.output_paths) == 1
    assert Path(retried.output_paths[0]).read_bytes() == b"verified synthetic partial bytes"
    assert retried.metadata["kuaishou_saved_assets"][0]["local_sha256"] == "a" * 64


def test_previous_typed_failure_does_not_grant_next_submission_an_exemption(manager, monkeypatch):
    engine = ImageEngine({"A": [dimensions_error(), dimensions_error()]})
    install_engine(manager, engine, monkeypatch)
    failed = run(manager, source=SOURCE)
    engine.errors["A"] = [MediaDownloadError(DIMENSION_MESSAGE)]
    manager.retry_failed(failed.id)
    result = wait(manager, failed.id)
    assert engine.calls == ["A", "B", "A", "A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.auto_retry_round == result.auto_retry_total == 0
    assert result.items[0].attempts == 3


def test_old_error_text_does_not_make_an_item_automatically_retryable():
    item = DownloadItem(
        id="legacy", source_url="https://www.douyin.com/video/7000000000000000001",
        media_type=MediaType.IMAGE, status=ItemStatus.FAILED,
        error=DIMENSION_MESSAGE, issue_code=SiteIssueCode.SITE_RESPONSE_CHANGED,
    )
    assert not DownloadManager._can_auto_retry_item(item)


def test_video_failure_cannot_claim_image_exemption(manager, monkeypatch):
    engine = ImageEngine({"A": [dimensions_error()]})
    original_discover = engine.discover

    def discover(*args, **kwargs):
        result = original_discover(*args, **kwargs)
        result.items[0].media_type = MediaType.VIDEO
        return result

    engine.discover = discover
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.items[1].status == ItemStatus.QUEUED
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_non_douyin_item_cannot_gain_an_image_tail_retry(manager, monkeypatch):
    engine = SyntheticEngine({"A": [dimensions_error()]})
    original_discover = engine.discover

    def discover(*args, **kwargs):
        result = original_discover(*args, **kwargs)
        for item in result.items:
            item.media_type = MediaType.IMAGE
        return result

    engine.discover = discover
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B"]
    assert result.status == JobStatus.PARTIAL
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_all_images_fail_after_exactly_two_rounds(manager, monkeypatch):
    engine = ImageEngine({
        key: [dimensions_error(), dimensions_error(), dimensions_error()]
        for key in ("A", "B")
    })
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == ["A", "B", "A", "B"]
    assert result.status == JobStatus.FAILED
    assert result.failed_items == 2
    assert result.auto_retry_total == 2
    assert result.auto_retry_round == 1
    assert [item.attempts for item in result.items] == [2, 2]
    assert [len(engine.errors[key]) for key in ("A", "B")] == [1, 1]


def test_standalone_dimensions_failure_retains_original_pause(monkeypatch, tmp_path):
    standalone = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
    )
    try:
        engine = ImageEngine({"A": [dimensions_error()]})
        install_engine(standalone, engine, monkeypatch)
        result = run(standalone, source=SOURCE)
        assert engine.calls == ["A"]
        assert result.status == JobStatus.INTERRUPTED
        assert result.items[1].status == ItemStatus.QUEUED
        assert result.auto_retry_enabled is False
        assert result.auto_retry_round == result.auto_retry_total == 0
    finally:
        standalone.shutdown()


def test_discovery_failure_is_not_converted_into_an_item_retry(manager, monkeypatch):
    engine = ImageEngine()

    def failure(*args, **kwargs):
        raise dimensions_error()

    engine.discover = failure
    install_engine(manager, engine, monkeypatch)
    result = run(manager, source=SOURCE)
    assert engine.calls == []
    assert result.status == JobStatus.FAILED
    assert result.auto_retry_round == result.auto_retry_total == 0
