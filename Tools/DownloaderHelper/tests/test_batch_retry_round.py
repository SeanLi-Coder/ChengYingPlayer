"""Bounded queue retry tests with synthetic files, no accounts or network."""

from __future__ import annotations

import socket
import sys
from collections import Counter
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app.downloader import DiscoveryResult, DownloadOutcome, EngineEvent
from app.errors import (
    AuthenticationRequiredError,
    DouyinMediaRefreshRequiredError,
    DownloadCancelledError,
    MediaDownloadError,
    SiteIssueCode,
    TemporaryAccessError,
)
from app.models import DownloadItem, DownloadJob, ItemStatus, JobStatus, OutputLayout
from app.task_manager import DownloadManager

SOURCE = "https://www.youtube.com/@FixtureAuthor"


@pytest.fixture(autouse=True)
def forbid_network(monkeypatch):
    def blocked(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in queue tests")

    monkeypatch.setattr(socket.socket, "connect", blocked)
    monkeypatch.setattr(socket, "create_connection", blocked)
    monkeypatch.setattr(socket, "getaddrinfo", blocked)


class SyntheticEngine:
    def __init__(self, errors=None, ids=("A", "B"), warning=None):
        self.errors = errors or {}
        self.ids = ids
        self.warning = warning
        self.discovery_complete = warning is None
        self.calls = []
        self.snapshots = []
        self.discoveries = []
        self.attempts = Counter()
        self.partial_receipts = False

    def discover(self, url, platform, kind, *, should_cancel):
        assert not should_cancel()
        self.discoveries.append((url, platform, kind))
        return DiscoveryResult(
            author="Fixture Author",
            items=[DownloadItem(
                id=key, media_id=f"fixture{key:0>4}",
                source_url=f"https://www.youtube.com/watch?v=fixture{key:0>4}",
            ) for key in self.ids],
            discovery_complete=self.discovery_complete,
            warning=self.warning,
        )

    def download_item(self, item, platform, output_dir, *, callback, should_cancel):
        assert not should_cancel()
        self.calls.append(item.id)
        self.snapshots.append(item.model_copy(deep=True))
        self.attempts[item.id] += 1
        failures = self.errors.get(item.id, [])
        if failures:
            failure = failures.pop(0)
            if failure:
                if self.partial_receipts and not item.output_paths:
                    partial = output_dir / f"{item.id}-verified-part.bin"
                    with partial.open("xb") as handle:
                        handle.write(b"verified synthetic partial bytes")
                    callback(EngineEvent(
                        event="asset_completed", output_paths=[str(partial)],
                        asset_records=[{
                            "media_id": item.media_id, "index": 1,
                            "media_kind": "video", "path": str(partial),
                            "local_sha256": "a" * 64, "source_sha256": "b" * 64,
                        }],
                    ))
                raise failure
        destination = output_dir / f"{item.id}.bin"
        with destination.open("xb") as handle:
            handle.write(f"verified synthetic {item.id}".encode())
        return DownloadOutcome(output_paths=[str(destination)])


@pytest.fixture
def manager(tmp_path):
    instance = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
        max_workers=1, new_job_output_layout=OutputLayout.AUTHOR,
        auto_retry_failed_items=True,
    )
    try:
        yield instance
    finally:
        instance.shutdown()


def install_engine(manager, engine, monkeypatch):
    observed_identities = []

    def get_engine(job):
        observed_identities.append((job.cookie_browser, job.cookie_profile, job.source_url))
        return engine

    monkeypatch.setattr(manager, "_engine_for_job", get_engine)
    return observed_identities


def run(manager, *, source=SOURCE):
    job = manager.create_job(
        source, cookie_browser="chrome", cookie_profile="Profile 1", auto_start=False,
    )
    manager.start_job(job.id)
    return wait(manager, job.id)


def wait(manager, job_id):
    manager._futures[job_id].result(timeout=5)
    return manager.get_job(job_id)


@pytest.mark.parametrize("code", [
    SiteIssueCode.NETWORK_ERROR, SiteIssueCode.SITE_UNAVAILABLE,
    SiteIssueCode.MEDIA_LINK_EXPIRED, SiteIssueCode.SITE_PROCESSING,
])
@pytest.mark.parametrize("failure_type", [MediaDownloadError, TemporaryAccessError])
def test_transient_failure_persists_then_continues_and_retries_once(
    manager, monkeypatch, code, failure_type,
):
    engine = SyntheticEngine({"A": [failure_type("Synthetic failure", issue_code=code)]})
    identities = install_engine(manager, engine, monkeypatch)
    events = []

    def listener(event, job):
        persisted = manager.store.get(job.id)
        assert persisted.revision == job.revision
        events.append((event.event, event.item_id, job, persisted))

    manager.add_listener(listener)
    result = run(manager)
    assert engine.calls == ["A", "B", "A"]
    assert [item.attempts for item in result.items] == [2, 1]
    assert result.status == JobStatus.COMPLETED
    assert result.auto_retry_enabled
    assert result.auto_retry_round == 1
    assert result.auto_retry_total == 1
    assert result.error is result.issue_code is result.issue_message is None
    assert identities == [("chrome", "Profile 1", SOURCE)]
    event_names = [(name, item_id) for name, item_id, *_ in events]
    assert event_names.index(("item_failed", "A")) < event_names.index(("item_started", "B"))
    assert event_names.index(("item_completed", "B")) < event_names.index(("auto_retry_started", None))
    failed = next(job for name, _, job, _ in events if name == "item_failed")
    assert failed.items[0].status == ItemStatus.FAILED
    assert failed.items[0].issue_code == code
    assert failed.failed_items == 1
    retry = next(job for name, _, job, _ in events if name == "auto_retry_started")
    assert retry.items[0].status == ItemStatus.FAILED
    assert retry.auto_retry_total == 1
    assert retry.items[1].status == ItemStatus.COMPLETED


def test_persistent_failure_survives_restart_and_explicit_continue(
    manager, monkeypatch, tmp_path,
):
    error = lambda: MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)
    engine = SyntheticEngine({"A": [error(), error()]})
    install_engine(manager, engine, monkeypatch)
    failed = run(manager)
    assert failed.status == JobStatus.PARTIAL
    assert failed.failed_items == 1
    assert failed.retryable
    assert engine.calls == ["A", "B", "A"]
    completed_path = Path(failed.items[1].output_paths[0])
    original_bytes = completed_path.read_bytes()
    original_stat = completed_path.stat()
    manager.shutdown()
    resumed = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
        max_workers=1, new_job_output_layout=OutputLayout.AUTHOR,
        auto_retry_failed_items=True,
    )
    try:
        stored = resumed.get_job(failed.id)
        assert stored.auto_retry_round == 1
        assert stored.auto_retry_total == 1
        assert stored.items[0].attempts == 2
        assert not resumed._futures
        next_engine = SyntheticEngine({"A": [error()]})
        identities = install_engine(resumed, next_engine, monkeypatch)
        rounds = []
        resumed.add_listener(lambda event, job: rounds.append((event.event, job.auto_retry_round)))
        resumed.retry_failed(failed.id)
        completed = wait(resumed, failed.id)
        assert next_engine.calls == ["A", "A"]
        assert completed.status == JobStatus.COMPLETED
        assert [item.attempts for item in completed.items] == [4, 1]
        assert ("started", 0) in rounds
        assert rounds.count(("auto_retry_started", 1)) == 1
        assert identities == [("chrome", "Profile 1", SOURCE)]
        assert completed_path.read_bytes() == original_bytes
        assert completed_path.stat().st_mtime_ns == original_stat.st_mtime_ns
        assert completed_path.stat().st_ino == original_stat.st_ino
    finally:
        resumed.shutdown()


def test_explicit_retry_subset_never_retries_unrelated_historical_failure(
    manager, monkeypatch,
):
    engine = SyntheticEngine({
        "A": [MediaDownloadError("Synthetic unknown failure")],
        "C": [MediaDownloadError("Synthetic unknown failure")],
    }, ids=("A", "B", "C"))
    install_engine(manager, engine, monkeypatch)
    failed = run(manager)
    engine.errors["A"] = [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)]
    manager.retry_item(failed.id, "A")
    result = wait(manager, failed.id)
    assert engine.calls == ["A", "B", "C", "A", "A"]
    assert result.status == JobStatus.PARTIAL
    assert result.items[2].status == ItemStatus.FAILED
    assert result.items[2].attempts == 1
    assert result.auto_retry_total == 1
    assert result.issue_code == SiteIssueCode.UNKNOWN


@pytest.mark.parametrize("code", [SiteIssueCode.CONTENT_UNAVAILABLE, SiteIssueCode.REGION_RESTRICTED])
def test_permanent_failure_continues_without_retry_and_keeps_correct_final_issue(
    manager, monkeypatch, code,
):
    engine = SyntheticEngine({
        "A": [MediaDownloadError("Synthetic permanent failure", issue_code=code)],
        "B": [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)],
    })
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B", "B"]
    assert result.status == JobStatus.PARTIAL
    assert result.issue_code == code
    assert result.issue_message == result.items[0].error
    assert not result.items[0].retryable
    assert not result.retryable


@pytest.mark.parametrize("code", [
    SiteIssueCode.SECURITY_BLOCKED, SiteIssueCode.COOKIE_UNAVAILABLE,
    SiteIssueCode.LOCAL_CONFIGURATION, SiteIssueCode.RATE_LIMITED,
    SiteIssueCode.REQUEST_REJECTED, SiteIssueCode.LOGIN_REQUIRED,
    SiteIssueCode.VERIFICATION_REQUIRED,
])
def test_global_gate_stops_before_next_item_and_never_auto_retries(
    manager, monkeypatch, code,
):
    engine = SyntheticEngine({"A": [MediaDownloadError("Synthetic gate", issue_code=code)]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.issue_code == code
    assert result.auto_retry_round == result.auto_retry_total == 0
    assert result.items[1].status == ItemStatus.QUEUED


@pytest.mark.parametrize("failure", [
    AuthenticationRequiredError("Login required"),
    AuthenticationRequiredError("CAPTCHA required"),
    TemporaryAccessError("Synthetic temporary gate", issue_code=SiteIssueCode.REQUEST_REJECTED),
    TemporaryAccessError("Synthetic unclassified temporary gate"),
    DouyinMediaRefreshRequiredError("Synthetic source refresh", issue_code=SiteIssueCode.NETWORK_ERROR),
    DownloadCancelledError("Task cancelled"),
])
def test_control_failures_are_not_converted_to_item_retries(manager, monkeypatch, failure):
    engine = SyntheticEngine({"A": [failure]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A"]
    assert result.status in {JobStatus.NEEDS_AUTH, JobStatus.INTERRUPTED, JobStatus.CANCELLED}
    assert result.auto_retry_round == 0


@pytest.mark.parametrize("failure", [RuntimeError("Synthetic unknown error"), MediaDownloadError("Synthetic error")])
def test_unknown_item_error_is_reported_and_other_items_continue(manager, monkeypatch, failure):
    engine = SyntheticEngine({"A": [failure]})
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B"]
    assert result.status == JobStatus.PARTIAL
    assert result.items[0].issue_code == SiteIssueCode.UNKNOWN
    assert result.items[0].error
    assert result.items[0].retryable
    assert result.auto_retry_round == 0


@pytest.mark.parametrize("cancel_on", ["item_failed", "auto_retry_started", "last_completed"])
def test_cancellation_wins_at_round_boundaries(manager, monkeypatch, cancel_on):
    engine = SyntheticEngine({"A": [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)]})
    install_engine(manager, engine, monkeypatch)

    def listener(event, job):
        if event.event == cancel_on or (
            cancel_on == "last_completed" and event.event == "item_completed" and event.item_id == "B"
        ):
            manager.cancel_job(job.id)

    manager.add_listener(listener)
    result = run(manager)
    assert result.status == JobStatus.CANCELLED
    assert engine.calls == (["A"] if cancel_on == "item_failed" else ["A", "B"])
    assert result.items[0].attempts == 1


def test_tail_retry_keeps_partial_asset_receipts_and_output_paths(manager, monkeypatch):
    engine = SyntheticEngine({"A": [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)]})
    engine.partial_receipts = True
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert result.status == JobStatus.COMPLETED
    retried = engine.snapshots[-1]
    assert retried.id == "A"
    assert len(retried.output_paths) == 1
    assert Path(retried.output_paths[0]).read_bytes() == b"verified synthetic partial bytes"
    records = retried.metadata["kuaishou_saved_assets"]
    assert records[0]["local_sha256"] == "a" * 64
    assert records[0]["source_sha256"] == "b" * 64


@pytest.mark.parametrize("warning", ["Profile discovery may be incomplete", None])
def test_incomplete_discovery_warning_survives_successful_tail_retry(manager, monkeypatch, warning):
    engine = SyntheticEngine(
        {"A": [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)]},
        warning=warning,
    )
    engine.discovery_complete = False
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert result.status == JobStatus.PARTIAL
    assert result.completed_items == 2
    assert not result.discovery_complete
    assert result.warning == warning
    assert result.error == (warning or "Profile discovery may be incomplete")
    assert result.issue_message == result.error
    assert result.issue_code != SiteIssueCode.NETWORK_ERROR
    assert result.retryable


def test_active_retry_restores_as_interrupted_without_automatic_execution(
    manager, monkeypatch, tmp_path,
):
    engine = SyntheticEngine({"A": [MediaDownloadError("Synthetic timeout", issue_code=SiteIssueCode.NETWORK_ERROR)]})
    install_engine(manager, engine, monkeypatch)
    captured = []
    manager.add_listener(lambda event, job: captured.append(job) if event.event == "auto_retry_started" else None)
    run(manager)
    saved = captured[0]
    assert saved.status == JobStatus.DOWNLOADING
    assert saved.auto_retry_round == 1
    manager.store.save(saved)
    restored = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
        auto_retry_failed_items=True,
    )
    try:
        interrupted = restored.get_job(saved.id)
        assert interrupted.status == JobStatus.INTERRUPTED
        assert interrupted.auto_retry_round == 1
        assert not restored._futures
        assert engine.calls == ["A", "B", "A"]
    finally:
        restored.shutdown()


@pytest.mark.parametrize("failure_type", [MediaDownloadError, TemporaryAccessError])
@pytest.mark.parametrize("code", [
    SiteIssueCode.NETWORK_ERROR, SiteIssueCode.SITE_UNAVAILABLE,
    SiteIssueCode.MEDIA_LINK_EXPIRED,
])
def test_standalone_default_retains_original_queue_pause_policy(
    monkeypatch, tmp_path, failure_type, code,
):
    standalone = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "downloads",
    )
    try:
        assert not standalone.auto_retry_failed_items
        engine = SyntheticEngine({"A": [failure_type("Synthetic failure", issue_code=code)]})
        install_engine(standalone, engine, monkeypatch)
        result = run(standalone)
        assert engine.calls == ["A"]
        assert result.status == JobStatus.INTERRUPTED
        assert result.items[1].status == ItemStatus.QUEUED
        assert result.auto_retry_enabled is False
        assert result.auto_retry_round == result.auto_retry_total == 0
    finally:
        standalone.shutdown()


def test_all_successful_items_have_no_tail_pass(manager, monkeypatch):
    engine = SyntheticEngine()
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B"]
    assert result.status == JobStatus.COMPLETED
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_all_failed_items_stop_after_exactly_two_rounds(manager, monkeypatch):
    def error():
        return TemporaryAccessError("Synthetic network error", issue_code=SiteIssueCode.NETWORK_ERROR)

    engine = SyntheticEngine({key: [error(), error(), error()] for key in ("A", "B")})
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B", "A", "B"]
    assert result.status == JobStatus.FAILED
    assert result.failed_items == 2
    assert result.auto_retry_round == 1
    assert result.auto_retry_total == 2
    assert result.retryable
    assert [item.attempts for item in result.items] == [2, 2]
    assert [len(engine.errors[key]) for key in ("A", "B")] == [1, 1]


def test_gate_during_tail_keeps_other_failed_items_for_manual_continue(manager, monkeypatch):
    def timeout():
        return TemporaryAccessError("Synthetic network error", issue_code=SiteIssueCode.NETWORK_ERROR)

    engine = SyntheticEngine({
        "A": [timeout(), MediaDownloadError("Synthetic security gate", issue_code=SiteIssueCode.SECURITY_BLOCKED)],
        "B": [timeout()],
    })
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == ["A", "B", "A"]
    assert result.status == JobStatus.INTERRUPTED
    assert result.issue_code == SiteIssueCode.SECURITY_BLOCKED
    assert result.items[1].status == ItemStatus.FAILED
    assert result.items[1].issue_code == SiteIssueCode.NETWORK_ERROR
    assert result.items[1].attempts == 1


def test_discovery_transport_failure_does_not_loop_or_skip_validation(manager, monkeypatch):
    engine = SyntheticEngine()

    def failure(*args, **kwargs):
        raise TemporaryAccessError("Synthetic network error", issue_code=SiteIssueCode.NETWORK_ERROR)

    engine.discover = failure
    install_engine(manager, engine, monkeypatch)
    result = run(manager)
    assert engine.calls == []
    assert result.status == JobStatus.FAILED
    assert result.issue_code == SiteIssueCode.NETWORK_ERROR
    assert result.auto_retry_round == result.auto_retry_total == 0


def test_legacy_records_do_not_claim_to_have_used_native_retry_policy(manager, monkeypatch):
    engine = SyntheticEngine()
    install_engine(manager, engine, monkeypatch)
    current = run(manager)
    payload = current.model_dump(mode="json")
    for field in ("auto_retry_enabled", "auto_retry_round", "auto_retry_total"):
        payload.pop(field)
    legacy = DownloadJob.model_validate(payload)
    assert legacy.auto_retry_enabled is False
    assert legacy.auto_retry_round == legacy.auto_retry_total == 0


def test_transient_access_error_does_not_claim_native_queue_was_paused(manager, monkeypatch):
    engine = SyntheticEngine({"A": [TemporaryAccessError(
        "The task was paused before downloading later items; transfer timed out",
        issue_code=SiteIssueCode.NETWORK_ERROR,
    )]})
    install_engine(manager, engine, monkeypatch)
    failures = []
    manager.add_listener(lambda event, job: failures.append(job) if event.event == "item_failed" else None)
    run(manager)
    assert engine.calls == ["A", "B", "A"]
    assert failures[0].items[0].issue_code == SiteIssueCode.NETWORK_ERROR
    assert "paused" not in failures[0].items[0].error
