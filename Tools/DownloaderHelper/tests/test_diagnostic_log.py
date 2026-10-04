"""Synthetic privacy, isolation, boundedness, and runtime instrumentation checks."""

from __future__ import annotations

import builtins
import errno
import gc
import json
import socket
import sqlite3
import subprocess
import sys
import threading
import weakref
from concurrent.futures import ThreadPoolExecutor
from enum import Enum
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import chrome_cookie_runtime as runtime
import diagnostic_log as diagnostics
from app.errors import DownloadCancelledError

SECRET = "PRIVATE_COOKIE_URL_PATH_PROFILE_TASK_ID_DO_NOT_EXPORT"
IDENTITY = {
    "player_version": "0.2.47", "player_build": "58", "helper_build_id": "a" * 16,
    "engine_version": "1.2.23", "engine_build_id": "b" * 12,
    "python_version": "3.13.2", "macos_version": "15.7", "architecture": "arm64",
    "yt_dlp_version": "2026.08.19", "identity_source": "bundled",
}


def make_job(identifier=SECRET, **changes):
    job = SimpleNamespace(
        id=identifier, platform="douyin", status="failed", total_items=1,
        completed_items=0, failed_items=1, issue_code="cookie_unavailable",
        diagnostic_code="cookie_access_unknown", items=[], error=SECRET, title=SECRET,
        source_url=f"https://invalid.example/{SECRET}", output_dir=f"/private/{SECRET}",
        cookie_profile=SECRET, activity_message=SECRET, author=SECRET,
    )
    for key, value in changes.items():
        setattr(job, key, value)
    return job


class Manager:
    def __init__(self, jobs=None, worker=None):
        self.jobs = jobs if jobs is not None else [make_job()]
        self.worker = worker
        self.notifications = []

    def get_job(self, job_id):
        for job in self.jobs:
            if job.id == job_id:
                return job
        raise KeyError(job_id)

    def list_jobs(self):
        return list(self.jobs)

    def _notify(self, job, event, item_id=None):
        self.notifications.append((job, event, item_id))
        return "notify-result"

    def _run_job(self, job_id, *args, **kwargs):
        if self.worker:
            return self.worker(self, job_id, *args, **kwargs)
        self._notify(self.get_job(job_id), "failed")
        return "run-result"


def report(manager, job_id=None, identity=None):
    result = diagnostics.diagnostic_report(manager, job_id=job_id, identity=identity or IDENTITY)
    assert set(result) == {"schema_version", "text"}
    assert result["schema_version"] == 1
    assert len(result["text"].encode("utf-8")) <= diagnostics.MAX_REPORT_BYTES
    assert SECRET not in result["text"]
    return json.loads(result["text"].split("\n", 1)[1])


def reject_external(*args, **kwargs):
    raise AssertionError("Unexpected file, browser, process, or network access")


@pytest.fixture(autouse=True)
def no_external_access(monkeypatch):
    monkeypatch.setattr(socket.socket, "connect", reject_external)
    monkeypatch.setattr(socket.socket, "connect_ex", reject_external)
    monkeypatch.setattr(subprocess, "Popen", reject_external)


def test_install_is_instance_only_idempotent_and_preserves_calls():
    manager, other = Manager(), Manager()
    original_other = other._run_job
    diagnostics.install_diagnostic_log(manager)
    installed = manager._run_job
    diagnostics.install_diagnostic_log(manager)
    assert manager._run_job is installed
    assert other._run_job == original_other
    assert manager._run_job(SECRET) == "run-result"
    assert len(manager.notifications) == 1
    assert manager._notify(manager.jobs[0], "failed", SECRET) == "notify-result"
    result = report(manager)
    assert result["identity"] == IDENTITY
    assert result["tasks"][0]["task"] == "task-01"
    assert [event["stage"] for event in result["tasks"][0]["events"]] == [
        "task_started", "manager_event", "task_finished", "manager_event",
    ]
    assert diagnostics._context.get() is None
    assert report(other)["tasks"][0]["events"] == []


def test_worker_args_return_and_exception_identity_are_preserved():
    failure = ValueError(SECRET)

    def worker(manager, job_id, *args, **kwargs):
        assert job_id == SECRET and args == ([SECRET], True) and kwargs == {"cancel_event": SECRET}
        raise failure

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    with pytest.raises(ValueError) as caught:
        manager._run_job(SECRET, [SECRET], True, cancel_event=SECRET)
    assert caught.value is failure
    assert report(manager)["tasks"][0]["events"][1]["exceptions"][0]["type"] == "ValueError"
    assert diagnostics._context.get() is None


@pytest.mark.parametrize("control", [KeyboardInterrupt, SystemExit, GeneratorExit, DownloadCancelledError])
def test_control_signals_propagate_and_context_resets(control):
    error = control(SECRET)

    def worker(*args):
        raise error

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    with pytest.raises(control) as caught:
        manager._run_job(SECRET)
    assert caught.value is error
    assert diagnostics._context.get() is None
    assert report(manager)["tasks"][0]["events"][1]["exceptions"][0]["type"] == control.__name__


def test_unbound_capture_is_noop_and_does_not_inspect_exception():
    class Hostile:
        def __getattribute__(self, key):
            raise AssertionError("Unbound logging inspected private data")

    diagnostics.record_cookie_event(Hostile(), error=Hostile(), diagnostic_code=Hostile())
    assert diagnostics._context.get() is None


def test_handled_directory_exception_keeps_safe_errno_without_private_text():
    from app.errors import MediaDownloadError, SiteIssueCode

    calls = []

    class HandledManager(Manager):
        def _record_issue_locked(self, job, message, *, cause=None):
            calls.append((job, message, cause))
            return "issue-result"

    def worker(manager, job_id):
        try:
            try:
                raise OSError(errno.EILSEQ, SECRET, "/private/" + SECRET)
            except OSError as cause:
                raise MediaDownloadError(
                    "The author download folder could not be prepared",
                    issue_code=SiteIssueCode.LOCAL_CONFIGURATION,
                ) from cause
        except MediaDownloadError as error:
            assert manager._record_issue_locked(manager.get_job(job_id), SECRET, cause=error) == "issue-result"
            return "handled-result"

    manager = HandledManager(worker=worker)
    other = HandledManager()
    original_other = other._record_issue_locked
    diagnostics.install_diagnostic_log(manager)
    installed = manager._record_issue_locked
    diagnostics.install_diagnostic_log(manager)
    assert manager._record_issue_locked is installed
    assert other._record_issue_locked == original_other
    assert manager._run_job(SECRET) == "handled-result"
    assert len(calls) == 1 and calls[0][1] == SECRET
    events = report(manager)["tasks"][0]["events"]
    errors = [event for event in events if event["stage"] == "task_exception"]
    assert len(errors) == 1
    assert [entry["type"] for entry in errors[0]["exceptions"]] == ["MediaDownloadError", "OSError"]
    assert errors[0]["exceptions"][1]["errno"] == errno.EILSEQ
    assert diagnostics._context.get() is None


def test_issue_adapter_preserves_underlying_exception_and_does_not_log_outside_worker():
    error = RuntimeError(SECRET)

    class HandledManager(Manager):
        def _record_issue_locked(self, *args, **kwargs):
            raise error

    manager = HandledManager()
    diagnostics.install_diagnostic_log(manager)
    with pytest.raises(RuntimeError) as caught:
        manager._record_issue_locked(manager.jobs[0], SECRET, cause=PermissionError(errno.EACCES, SECRET))
    assert caught.value is error
    assert report(manager)["tasks"][0]["events"] == []


def test_old_tasks_only_export_allowlisted_counts_and_unknown_original_version():
    class State(str, Enum):
        FAILED = "failed"

    manager = Manager([make_job(status=State.FAILED, items=[make_job(), make_job(status=SECRET)])])
    result = report(manager)
    task = result["tasks"][0]
    assert task["status_counts_including_job"] == {"failed": 2, "unknown": 1}
    assert task["diagnostic_counts"] == {"cookie_access_unknown": 3}
    assert task["issue_counts"] == {"cookie_unavailable": 3}
    assert task["original_version"] == "unknown"
    assert not task["runtime_events_available"]
    assert "Stored task original versions are unknown" in result["history_notice"]
    assert result["scope"] == "recent_tasks_up_to_10"


def test_legacy_snapshot_never_gets_sensitive_attributes():
    class Job:
        def __getattribute__(self, key):
            if key in {"error", "title", "source_url", "author", "output_paths"}:
                raise AssertionError("Sensitive task field was inspected")
            return object.__getattribute__(self, key)

    job = Job()
    job.id, job.status = SECRET, "failed"
    assert report(Manager([job]))["tasks"][0]["status"] == "failed"


def test_report_selection_and_missing_ids():
    manager = Manager([make_job(f"private-{index}") for index in range(20)])
    diagnostics.install_diagnostic_log(manager)
    for job in manager.jobs:
        manager._run_job(job.id)
    overview = report(manager)
    assert len(overview["tasks"]) == 10
    selected = report(manager, manager.jobs[-1].id)
    assert selected["scope"] == "selected_task"
    assert len(selected["tasks"]) == 1
    assert len(selected["tasks"][0]["events"]) == 3
    for invalid in (SECRET, "", 123, SECRET * 50):
        with pytest.raises(KeyError) as caught:
            diagnostics.diagnostic_report(manager, job_id=invalid, identity={})
        assert SECRET not in str(caught.value)


@pytest.mark.parametrize("invalid", [SECRET, "1.2.3/" + SECRET, "1.2\n", True, 12, None, {}, "1" * 10000])
def test_identity_is_strict_and_missing_values_are_unknown(invalid):
    identity = dict.fromkeys(IDENTITY, invalid)
    identity[SECRET] = SECRET
    result = diagnostics.diagnostic_report(Manager(), job_id=None, identity=identity)
    assert SECRET not in result["text"]
    fields = json.loads(result["text"].split("\n", 1)[1])["identity"]
    assert set(fields) == set(IDENTITY)
    assert all(value == "unknown" for value in fields.values())


def test_identity_rejects_string_subclass_and_accepts_long_hash():
    class HostileString(str):
        def __str__(self):
            raise AssertionError("Custom string formatting is forbidden")

    identity = dict(IDENTITY, player_version=HostileString("1.2.3"), helper_build_id="a" * 64)
    result = report(Manager(), identity=identity)["identity"]
    assert result["player_version"] == "unknown"
    assert result["helper_build_id"] == "a" * 64


def test_true_exception_graph_cycle_exc_info_and_privacy():
    inner = sqlite3.DatabaseError(SECRET)
    inner.sqlite_errorcode = sqlite3.SQLITE_CORRUPT
    middle = OSError(errno.ENOSPC, SECRET, f"/private/{SECRET}")
    outer = RuntimeError(SECRET)
    outer.__cause__, outer.__context__ = middle, inner
    middle.__cause__, inner.__context__ = inner, outer
    outer.exc_info = (ValueError, ValueError(SECRET), None)
    outer.diagnostic_code = SECRET
    outer.add_note(SECRET)

    def worker(*args):
        diagnostics.record_cookie_event("extract_failed", error=outer, diagnostic_code=SECRET)

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    event = report(manager)["tasks"][0]["events"][1]
    entries = event["exceptions"]
    assert [entry["type"] for entry in entries] == ["RuntimeError", "OSError", "sqlite3.DatabaseError", "ValueError"]
    assert entries[1]["errno"] == errno.ENOSPC
    assert entries[2]["sqlite_errorcode"] == sqlite3.SQLITE_CORRUPT
    assert event["diagnostic_code"] == "cookie_access_unknown"
    assert not event["chain_truncated"]


def test_unknown_exception_names_and_hostile_messages_never_format():
    def forbidden(*args):
        raise AssertionError("Raw exception formatting is forbidden")

    kind = type(SECRET, (ValueError,), {"__str__": forbidden, "__repr__": forbidden})
    error = kind(SECRET)
    error.diagnostic_code = SimpleNamespace(secret=SECRET)
    error.errno = SECRET
    error.sqlite_errorcode = True

    def worker(*args):
        diagnostics.record_cookie_event("extract_failed", error=error)

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    entry = report(manager)["tasks"][0]["events"][1]["exceptions"][0]
    assert entry == {"type": "unknown", "frames": [], "frames_truncated": False}


def test_traceback_uses_fixed_module_identity_not_filename_or_function_name():
    namespace = {"__name__": "yt_dlp.cookies"}
    exec(compile("def private_function():\n    raise ValueError('private')\n", f"/private/{SECRET}", "exec"), namespace)  # noqa: S102 - Fixed synthetic source, not input.
    try:
        namespace["private_function"]()
    except ValueError as error:
        assert diagnostics._exception_details(error)["exceptions"][0]["frames"] == []
    result = diagnostics.verify_diagnostic_log()
    assert result == {"schema_version": 1, "synthetic_capture": True, "privacy_verified": True}


def test_chain_and_frame_depth_are_bounded():
    error = ValueError(SECRET)
    for _ in range(100):
        wrapped = RuntimeError(SECRET)
        wrapped.__cause__ = error
        error = wrapped
    detail = diagnostics._exception_details(error)
    assert len(detail["exceptions"]) == diagnostics.MAX_CHAIN
    assert detail["chain_truncated"]


def test_export_revalidates_tampered_events_and_drops_unknown_fields():
    manager = Manager()
    diagnostics.install_diagnostic_log(manager)
    log = getattr(manager, diagnostics._ATTRIBUTE)
    log.events.append((SECRET, {
        "stage": "extract_failed", "url": SECRET, "message": SECRET, "status": SECRET,
        "event": SECRET, "sequence": SECRET, "exceptions": [{
            "type": SECRET, "message": SECRET, "errno": SECRET,
            "frames": [{"component": SECRET, "line": SECRET},
                       {"component": "yt_dlp.cookies", "line": 123, "path": SECRET}],
        }],
    }))
    log.events.append((SECRET, {"stage": SECRET, "message": SECRET}))
    result = report(manager)["tasks"][0]["events"]
    assert len(result) == 1
    assert result[0]["exceptions"][0]["frames"] == [{"component": "yt_dlp.cookies", "line": 123}]
    assert result[0]["exceptions"][0]["type"] == "unknown"


def test_ring_job_and_item_limits_and_rejected_event_count():
    manager = Manager([make_job(f"job-{index}") for index in range(50)])
    diagnostics.install_diagnostic_log(manager)
    for _ in range(3):
        for job in manager.jobs:
            manager._run_job(job.id)
    log = getattr(manager, diagnostics._ATTRIBUTE)
    assert len(log.events) == diagnostics.MAX_EVENTS
    assert len(log.jobs) == diagnostics.MAX_TRACKED_JOBS
    log.capture(manager.jobs[0].id, {"stage": SECRET})
    result = report(manager)
    assert result["limits"]["evicted_events"] > 0
    assert result["limits"]["evicted_job_contexts"] > 0
    assert result["limits"]["rejected_events"] == 1
    manager.jobs[0].items = [make_job()] * (diagnostics.MAX_ITEMS + 1)
    assert report(manager, manager.jobs[0].id)["tasks"][0]["item_counts_truncated"]


def test_progress_and_repeated_row_warnings_are_sampled_but_status_changes_are_not(monkeypatch):
    monkeypatch.setattr(diagnostics.time, "monotonic", lambda: 100.0)

    def worker(manager, job_id):
        for _ in range(100):
            manager._notify(manager.jobs[0], "activity")
        manager.jobs[0].status = "completed"
        manager._notify(manager.jobs[0], "activity")
        for _ in range(100):
            diagnostics.record_cookie_event("row_rejected", diagnostic_code="cookie_decryption_failed")

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    result = report(manager)
    assert result["limits"]["sampled_events"] == 198
    stages = [event["stage"] for event in result["tasks"][0]["events"]]
    assert stages.count("manager_event") == 2
    assert stages.count("row_rejected") == 1


def test_report_size_limit_truncates_events_not_json_or_privacy():
    manager = Manager()
    diagnostics.install_diagnostic_log(manager)
    log = getattr(manager, diagnostics._ATTRIBUTE)
    detail = {"stage": "extract_failed", "exceptions": [{
        "type": "RuntimeError", "frames": [
            {"component": "native.chrome_cookie_runtime", "line": 123456} for _ in range(8)
        ],
    } for _ in range(8)]}
    for _ in range(diagnostics.MAX_EVENTS):
        log.capture(SECRET, detail)
    result = report(manager)
    assert result["report_truncated"]
    assert result["limits"]["report_omitted_events"] > 0
    assert result["tasks"][0]["events"][-1]["sequence"] == diagnostics.MAX_EVENTS


def test_contexts_do_not_cross_threads_or_managers_and_export_is_concurrent():
    barrier = threading.Barrier(2)
    jobs = [make_job("thread-one"), make_job("thread-two")]

    def worker(manager, job_id):
        barrier.wait(timeout=5)
        number = 11 if job_id == "thread-one" else 22
        for _ in range(30):
            diagnostics.record_cookie_event("snapshot_failed", error=OSError(number, SECRET))
            report(manager, job_id)

    manager = Manager(jobs, worker)
    other = Manager()
    diagnostics.install_diagnostic_log(manager)
    diagnostics.install_diagnostic_log(other)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(manager._run_job, job.id) for job in jobs]
        for future in futures:
            future.result(timeout=10)
    for job, number in zip(jobs, (11, 22), strict=True):
        events = report(manager, job.id)["tasks"][0]["events"]
        assert [event["exceptions"][0]["errno"] for event in events if event["stage"] == "snapshot_failed"] == [number] * 30
    assert report(other)["tasks"][0]["events"] == []
    assert diagnostics._context.get() is None


def test_nested_manager_context_is_restored():
    second = Manager([make_job("second")])
    diagnostics.install_diagnostic_log(second)

    def worker(manager, job_id):
        second._run_job("second")
        diagnostics.record_cookie_event("extract_failed", error=ValueError(SECRET))

    first = Manager(worker=worker)
    diagnostics.install_diagnostic_log(first)
    first._run_job(SECRET)
    assert [event["stage"] for event in report(first)["tasks"][0]["events"]] == [
        "task_started", "extract_failed", "task_finished",
    ]
    assert [event["stage"] for event in report(second)["tasks"][0]["events"]] == [
        "task_started", "manager_event", "task_finished",
    ]


def test_snapshot_original_error_is_recorded_before_sanitized_raise(monkeypatch):
    failure = OSError(errno.ENOSPC, SECRET, f"/private/{SECRET}")

    def failed_mkstemp(**kwargs):
        raise failure

    monkeypatch.setattr(runtime.tempfile, "mkstemp", failed_mkstemp)

    def worker(*args):
        with pytest.raises(runtime.CookieSnapshotError) as caught:
            runtime._open_database_snapshot(f"/private/{SECRET}", f"/private/{SECRET}")
        assert caught.value.__suppress_context__

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    events = report(manager)["tasks"][0]["events"]
    failure_event = next(event for event in events if event["stage"] == "snapshot_failed")
    assert failure_event["diagnostic_code"] == "cookie_storage_failed"
    assert failure_event["exceptions"][0]["errno"] == errno.ENOSPC
    assert failure_event["exceptions"][0]["frames"][-1]["component"] == "native.chrome_cookie_runtime"


@pytest.mark.parametrize("kind", [ValueError, KeyboardInterrupt, SystemExit, DownloadCancelledError])
def test_extractor_hook_records_original_and_preserves_error(kind):
    error = kind(SECRET)

    def original(*args):
        raise error

    wrapped = runtime._chrome_extractor(original)

    def worker(*args):
        with pytest.raises(kind) as caught:
            wrapped("chrome", SECRET, None, None)
        assert caught.value is error

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    failure = next(event for event in report(manager)["tasks"][0]["events"] if event["stage"] == "extract_failed")
    assert failure["exceptions"][0]["type"] == kind.__name__


def test_optional_capture_failure_does_not_change_download(monkeypatch):
    manager = Manager()
    diagnostics.install_diagnostic_log(manager)
    log = getattr(manager, diagnostics._ATTRIBUTE)

    def failed_capture(*args):
        raise ValueError(SECRET)

    monkeypatch.setattr(log, "capture", failed_capture)
    assert manager._run_job(SECRET) == "run-result"
    assert report(manager)["limits"]["capture_failures"] == 3


def test_frozen_selftest_does_not_perform_file_or_network_io(monkeypatch):
    monkeypatch.setattr(builtins, "open", reject_external)
    monkeypatch.setattr(Path, "open", reject_external)
    assert diagnostics.verify_diagnostic_log()["privacy_verified"]


def test_real_manager_snapshot_path_does_not_clone_or_read_private_models():
    class InMemoryManager(Manager):
        def __init__(self):
            super().__init__([make_job(f"job-{index}", created_at=index) for index in range(50)])
            self._lock = threading.RLock()
            self._jobs = {job.id: job for job in self.jobs}

        def get_job(self, *args):
            raise AssertionError("Full job copies are forbidden")

        def list_jobs(self):
            raise AssertionError("Full history copies are forbidden")

    manager = InMemoryManager()
    manager.jobs[-1].status = "completed"
    result = report(manager)
    assert len(result["tasks"]) == 10
    assert result["tasks"][0]["status"] == "completed"
    assert report(manager, "job-0")["tasks"][0]["status"] == "failed"
    with pytest.raises(KeyError):
        diagnostics.diagnostic_report(manager, job_id=SECRET, identity={})


def test_real_engine_progress_listener_samples_and_ignores_normal_notifications(monkeypatch):
    monkeypatch.setattr(diagnostics.time, "monotonic", lambda: 100.0)

    class ListeningManager(Manager):
        def __init__(self):
            super().__init__()
            self.listeners = []

        def add_listener(self, listener):
            self.listeners.append(listener)

        def _notify(self, job, event, item_id=None):
            super()._notify(job, event, item_id)
            for listener in self.listeners:
                listener(SimpleNamespace(event=event, item_id=item_id), job)

    manager = ListeningManager()
    manager.jobs[0].items = [make_job(id=SECRET, progress=SimpleNamespace(percent=32.9, filename=SECRET))]
    diagnostics.install_diagnostic_log(manager)
    assert len(manager.listeners) == 1
    manager._notify(manager.jobs[0], "failed")
    for name in ("downloading", "postprocessing", "probing"):
        for _ in range(100):
            for listener in manager.listeners:
                listener(SimpleNamespace(event=name, item_id=SECRET, message=SECRET), manager.jobs[0])
    result = report(manager)
    assert result["limits"]["sampled_events"] == 297
    events = result["tasks"][0]["events"]
    assert [event["event"] for event in events] == ["failed", "downloading", "postprocessing", "probing"]
    assert [event["progress_percent"] for event in events[1:]] == [32, 32, 32]


@pytest.mark.parametrize("browser,profile,auto,mode,selection", [
    (None, SECRET, False, "disabled", "none"),
    ("chrome", None, False, "enabled", "auto"),
    ("chrome", SECRET, True, "enabled", "auto"),
    ("chrome", SECRET, False, "enabled", "explicit"),
    (SECRET, SECRET, False, "unknown", "none"),
])
def test_cookie_settings_are_only_fixed_modes(browser, profile, auto, mode, selection):
    job = make_job(cookie_browser=browser, cookie_profile=profile,
                   cookie_profile_auto_selected=auto, cookie_fallback_used=True)
    task = report(Manager([job]))["tasks"][0]
    assert task["cookie_mode"] == mode
    assert task["profile_selection"] == selection
    assert task["cookie_fallback_used"] is True


def test_exception_and_traceback_objects_are_not_retained():
    references = []

    class PrivateFailure(Exception):
        pass

    def worker(*args):
        try:
            raise PrivateFailure(SECRET)
        except PrivateFailure as error:
            references.append(weakref.ref(error))
            diagnostics.record_cookie_event("extract_failed", error=error)

    manager = Manager(worker=worker)
    diagnostics.install_diagnostic_log(manager)
    manager._run_job(SECRET)
    gc.collect()
    assert references[0]() is None
    assert report(manager)["tasks"][0]["events"][1]["exceptions"][0]["type"] == "unknown"


@pytest.mark.parametrize("control", [KeyboardInterrupt, SystemExit, DownloadCancelledError])
def test_hostile_exception_properties_cannot_swallow_controls(control):
    class HostileError(Exception):
        @property
        def errno(self):
            raise control(SECRET)

    with pytest.raises(control):
        diagnostics._exception_details(HostileError(SECRET))


def test_bad_attributes_and_non_numeric_system_codes_are_not_serialized():
    class HostileError(Exception):
        @property
        def errno(self):
            raise ValueError(SECRET)

        @property
        def diagnostic_code(self):
            raise RuntimeError(SECRET)

        @property
        def exc_info(self):
            raise TypeError(SECRET)

    error = HostileError(SECRET)
    error.sqlite_errorcode = SECRET
    details = diagnostics._exception_details(error)
    assert details == {"exceptions": [{"type": "unknown", "frames": [], "frames_truncated": False}], "chain_truncated": False}
