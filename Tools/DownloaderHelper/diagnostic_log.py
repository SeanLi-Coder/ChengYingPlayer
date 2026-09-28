"""Bounded, process-local diagnostics with an allowlist at capture and export."""

from __future__ import annotations

import builtins
import contextvars
import functools
import heapq
import json
import math
import re
import sqlite3
import sys
import threading
import time
from collections import Counter, OrderedDict, deque
from enum import Enum
from types import SimpleNamespace

MAX_REPORT_BYTES = 64 * 1024
MAX_EVENTS = 256
MAX_TRACKED_JOBS = 32
MAX_REPORT_JOBS = 10
MAX_CHAIN = 8
MAX_FRAMES = 8
MAX_ITEMS = 1000
PROGRESS_SAMPLE_SECONDS = 2.0
_context = contextvars.ContextVar("download_diagnostic_context", default=None)
_install_lock = threading.Lock()
_ATTRIBUTE = "_chengying_diagnostic_log"

_DIAGNOSTICS = frozenset({
    "cookie_decryption_failed", "cookie_permission_denied", "cookie_database_locked",
    "cookie_database_invalid", "cookie_storage_failed", "cookie_reader_failed",
    "chrome_data_directory_missing", "chrome_profile_invalid", "chrome_profile_missing",
    "cookie_database_missing", "cookie_access_unknown",
})
_ISSUES = frozenset({
    "rate_limited", "verification_required", "login_required", "request_rejected",
    "site_processing", "content_unavailable", "region_restricted", "site_response_changed",
    "media_link_expired", "site_unavailable", "network_error", "cookie_unavailable",
    "security_blocked", "local_configuration", "unknown",
})
_STATUSES = frozenset({
    "queued", "discovering", "downloading", "postprocessing", "needs_auth", "completed",
    "partial", "failed", "cancelled", "interrupted", "skipped", "unknown",
})
_PLATFORMS = frozenset({"xiaohongshu", "douyin", "kuaishou", "bilibili", "youtube"})
_EVENTS = frozenset({
    "created", "cancel_requested", "started", "discovered", "item_started", "item_completed",
    "interrupted", "needs_auth", "item_failed", "cancelled", "failed", "media_refreshed",
    "activity", "finished", "downloading", "postprocessing", "probing", "metadata",
    "warning", "asset_completed", "completed",
})
_DIRECT_EVENTS = frozenset({"downloading", "postprocessing", "probing", "metadata",
                            "warning", "asset_completed", "completed"})
_STAGES = frozenset({
    "task_started", "task_finished", "task_exception", "manager_event", "snapshot_start",
    "snapshot_complete", "snapshot_failed", "snapshot_timeout", "row_rejected",
    "extract_start", "extract_complete", "extract_failed",
})
_COMPONENTS = {
    "diagnostic_log": "native.diagnostics",
    "chrome_cookie_runtime": "native.chrome_cookie_runtime",
    "app.browser": "engine.browser", "app.douyin_signing": "engine.douyin_signing",
    "app.douyin": "engine.douyin", "app.downloader": "engine.downloader",
    "app.task_manager": "engine.task_manager", "yt_dlp.cookies": "yt_dlp.cookies",
    "yt_dlp.YoutubeDL": "yt_dlp.YoutubeDL", "yt_dlp.utils._utils": "yt_dlp.utils",
    "Cryptodome.Cipher._mode_cbc": "cryptodome.cbc",
    "Cryptodome.Cipher.AES": "cryptodome.aes",
}
_BUILTIN_TYPES = (
    "Exception", "RuntimeError", "ValueError", "TypeError", "AttributeError", "KeyError",
    "IndexError", "ImportError", "ModuleNotFoundError", "NotImplementedError", "MemoryError",
    "OSError", "PermissionError", "FileNotFoundError", "IsADirectoryError",
    "NotADirectoryError", "BlockingIOError", "TimeoutError", "ConnectionError",
    "UnicodeError", "UnicodeDecodeError", "UnicodeEncodeError", "AssertionError",
    "KeyboardInterrupt", "SystemExit", "GeneratorExit",
)
_LOADED_TYPES = {
    "app.browser": ("ChromeCookieAccessError",),
    "chrome_cookie_runtime": ("CookieSnapshotError",),
    "app.douyin_signing": ("_CookieAccessSigningFailure",),
    "app.errors": ("DownloadCancelledError", "DownloaderCoreError", "MediaDownloadError",
                   "AuthenticationRequiredError", "TemporaryAccessError"),
    "yt_dlp.cookies": ("CookieLoadError",),
    "yt_dlp.utils": ("DownloadError",),
    "asyncio.exceptions": ("CancelledError",),
    "concurrent.futures._base": ("CancelledError",),
}
_SQLITE_TYPES = ("Error", "DatabaseError", "OperationalError", "IntegrityError",
                 "ProgrammingError", "InterfaceError", "DataError", "NotSupportedError")
_TYPE_LABELS = frozenset(
    (*_BUILTIN_TYPES, *("sqlite3." + name for name in _SQLITE_TYPES),
     *(name for names in _LOADED_TYPES.values() for name in names), "unknown")
)
_VERSION = re.compile(r"[0-9]{1,5}(?:\.[0-9]{1,5}){1,3}\Z", re.ASCII)
_IDENTITY_RULES = {
    "player_version": _VERSION, "player_build": re.compile(r"[0-9]{1,10}\Z", re.ASCII),
    "helper_build_id": re.compile(r"(?:[0-9a-f]{16}|[0-9a-f]{64})\Z", re.ASCII),
    "engine_version": _VERSION, "engine_build_id": re.compile(r"[0-9a-f]{12}\Z", re.ASCII),
    "python_version": _VERSION, "macos_version": _VERSION, "yt_dlp_version": _VERSION,
    "architecture": frozenset({"arm64", "x86_64", "unknown"}),
    "identity_source": frozenset({"bundled", "development", "unavailable"}),
}


def _enum(value, allowed, default="unknown"):
    # Return the constant from the allowlist, never the caller's string object.
    if isinstance(value, str):
        for candidate in allowed:
            if str.__eq__(value, candidate) is True:
                return candidate
    elif isinstance(value, Enum):
        return _enum(value.value, allowed, default)
    return default


def _integer(value, maximum=1_000_000_000):
    return min(max(value, 0), maximum) if type(value) is int else 0


def _identity(identity):
    identity = identity if type(identity) is dict else {}
    result = {}
    for key, rule in _IDENTITY_RULES.items():
        value = dict.get(identity, key)
        if isinstance(rule, frozenset):
            result[key] = _enum(value, rule)
        else:
            result[key] = value if type(value) is str and len(value) <= 64 and rule.fullmatch(value) else "unknown"
    return result


def _attribute(value, name, default=None):
    try:
        return getattr(value, name, default)
    except Exception as error:  # noqa: BLE001 - Hostile optional diagnostic attributes are untrusted.
        _preserve_cancellation(error)
        return default


def _preserve_cancellation(error):
    module = sys.modules.get("app.errors")
    kind = vars(module).get("DownloadCancelledError") if module is not None else None
    if isinstance(kind, type) and isinstance(error, kind):
        raise error


def _exception_type(error):
    kind = type(error)
    for name in _BUILTIN_TYPES:
        if kind is getattr(builtins, name):
            return name
    for name in _SQLITE_TYPES:
        if kind is getattr(sqlite3, name):
            return "sqlite3." + name
    for module_name, names in _LOADED_TYPES.items():
        module = sys.modules.get(module_name)
        for name in names:
            if module is not None and kind is vars(module).get(name):
                return name
    return "unknown"


def _exception_details(error):
    """Never format an exception, source line, function name, path, or local."""
    pending = deque([error])
    seen = set()
    entries = []
    truncated = False
    while pending and len(entries) < MAX_CHAIN:
        current = pending.popleft()
        if not isinstance(current, BaseException) or id(current) in seen:
            continue
        seen.add(id(current))
        entry = {"type": _exception_type(current), "frames": []}
        for name, limit in (("errno", 4095), ("sqlite_errorcode", 65535)):
            value = _attribute(current, name)
            if type(value) is int and 0 <= value <= limit:
                entry[name] = value
        diagnostic = _enum(_attribute(current, "diagnostic_code"), _DIAGNOSTICS, None)
        if diagnostic is not None:
            entry["diagnostic_code"] = diagnostic
        traceback = BaseException.__traceback__.__get__(current)
        visited = trusted_frames = 0
        while traceback is not None and visited < 64:
            visited += 1
            globals_ = traceback.tb_frame.f_globals
            component = next((label for module_name, label in _COMPONENTS.items()
                              if (module := sys.modules.get(module_name)) is not None
                              and globals_ is vars(module)), None)
            if component is not None:
                trusted_frames += 1
                entry["frames"].append({"component": component, "line": _integer(traceback.tb_lineno, 1_000_000)})
                entry["frames"] = entry["frames"][-MAX_FRAMES:]
            traceback = traceback.tb_next
        entry["frames_truncated"] = traceback is not None or trusted_frames > MAX_FRAMES
        entries.append(entry)
        for name in ("__cause__", "__context__"):
            linked = getattr(BaseException, name).__get__(current)
            if isinstance(linked, BaseException) and id(linked) not in seen:
                pending.append(linked)
        exc_info = _attribute(current, "exc_info")
        if (type(exc_info) is tuple and len(exc_info) == 3
                and isinstance(exc_info[1], BaseException) and id(exc_info[1]) not in seen):
            pending.append(exc_info[1])
    truncated = any(id(value) not in seen for value in pending)
    return {"exceptions": entries, "chain_truncated": truncated}


def _clean_event(value):
    """The same serializer gates captured events and potentially tampered exports."""
    value = value if type(value) is dict else {}
    result = {"stage": _enum(value.get("stage"), _STAGES)}
    for key in ("sequence", "elapsed_ms"):
        if key in value:
            result[key] = _integer(value[key])
    for key, allowed in (("event", _EVENTS), ("status", _STATUSES),
                         ("diagnostic_code", _DIAGNOSTICS)):
        if key in value:
            result[key] = _enum(value[key], allowed, "cookie_access_unknown" if key == "diagnostic_code" else "unknown")
    for key in ("total_items", "completed_items", "failed_items"):
        if key in value:
            result[key] = _integer(value[key])
    if "progress_percent" in value:
        number = value["progress_percent"]
        if type(number) in (int, float) and math.isfinite(number) and 0 <= number <= 100:
            result["progress_percent"] = int(number)
    if type(value.get("exceptions")) is list:
        result["exceptions"] = []
        for entry in value["exceptions"][:MAX_CHAIN]:
            if type(entry) is not dict:
                continue
            clean = {"type": _enum(entry.get("type"), _TYPE_LABELS), "frames": []}
            for name, limit in (("errno", 4095), ("sqlite_errorcode", 65535)):
                number = entry.get(name)
                if type(number) is int and 0 <= number <= limit:
                    clean[name] = number
            if "diagnostic_code" in entry:
                clean["diagnostic_code"] = _enum(entry["diagnostic_code"], _DIAGNOSTICS, "cookie_access_unknown")
            frames = entry.get("frames")
            for frame in frames[:MAX_FRAMES] if type(frames) is list else ():
                if type(frame) is dict:
                    component = _enum(frame.get("component"), _COMPONENTS.values(), None)
                    if component is not None:
                        clean["frames"].append({"component": component, "line": _integer(frame.get("line"), 1_000_000)})
            clean["frames_truncated"] = entry.get("frames_truncated") is True
            result["exceptions"].append(clean)
        result["chain_truncated"] = value.get("chain_truncated") is True
    return result


def _job_summary(job):
    statuses, issues, diagnostics = Counter(), Counter(), Counter()
    items = _attribute(job, "items", [])
    items = items if type(items) in (list, tuple) else []
    for item in [job, *items[:MAX_ITEMS]]:
        statuses[_enum(_attribute(item, "status"), _STATUSES)] += 1
        for field, choices, counts in (("issue_code", _ISSUES, issues),
                                        ("diagnostic_code", _DIAGNOSTICS, diagnostics)):
            value = _attribute(item, field)
            if value is not None:
                counts[_enum(value, choices, "cookie_access_unknown" if field == "diagnostic_code" else "unknown")] += 1
    browser = _attribute(job, "cookie_browser", "unknown")
    cookie_mode = "enabled" if _enum(browser, {"chrome"}, None) else "disabled" if browser is None else "unknown"
    profile_selection = "none"
    if cookie_mode == "enabled":
        if _attribute(job, "cookie_profile_auto_selected") is True:
            profile_selection = "auto"
        else:
            profile = _attribute(job, "cookie_profile")
            profile_selection = "explicit" if isinstance(profile, str) and str.__len__(profile) else "auto"
    return {
        "platform": _enum(_attribute(job, "platform"), _PLATFORMS),
        "status": _enum(_attribute(job, "status"), _STATUSES),
        "total_items": _integer(_attribute(job, "total_items")),
        "completed_items": _integer(_attribute(job, "completed_items")),
        "failed_items": _integer(_attribute(job, "failed_items")),
        "status_counts_including_job": dict(statuses), "issue_counts": dict(issues),
        "diagnostic_counts": dict(diagnostics), "item_counts_truncated": len(items) > MAX_ITEMS,
        "cookie_mode": cookie_mode, "profile_selection": profile_selection,
        "cookie_fallback_used": _attribute(job, "cookie_fallback_used") is True,
    }


def _selected_summaries(manager, job_id):
    """Production takes only safe scalar snapshots under the manager's lock."""
    stored, lock = getattr(manager, "_jobs", None), getattr(manager, "_lock", None)
    if type(stored) is dict and lock is not None:
        with lock:
            if job_id is not None:
                if job_id not in stored:
                    raise KeyError("Unknown diagnostic task")
                jobs = [stored[job_id]]
            else:
                jobs = heapq.nlargest(MAX_REPORT_JOBS, stored.values(), key=lambda job: job.created_at)
            return [(_attribute(job, "id"), _job_summary(job)) for job in jobs]
    # Small synthetic managers and embedders may expose only the public methods.
    try:
        jobs = [manager.get_job(job_id)] if job_id is not None else manager.list_jobs()[:MAX_REPORT_JOBS]
    except KeyError:
        raise KeyError("Unknown diagnostic task") from None
    return [(_attribute(job, "id"), _job_summary(job)) for job in jobs]


def _manager_event_snapshot(job, event, item_id=None):
    snapshot = {"stage": "manager_event", "event": event}
    for name in ("status", "total_items", "completed_items", "failed_items"):
        snapshot[name] = _attribute(job, name)
    code = _attribute(job, "diagnostic_code")
    if code is not None:
        snapshot["diagnostic_code"] = code
    items = _attribute(job, "items", [])
    if item_id is not None and type(items) in (list, tuple):
        item = next((item for item in items[:MAX_ITEMS] if _attribute(item, "id") == item_id), None)
        snapshot["progress_percent"] = _attribute(_attribute(item, "progress"), "percent")
    return snapshot


class _DiagnosticLog:
    def __init__(self):
        self.lock = threading.RLock()
        self.started = time.monotonic()
        self.events = deque(maxlen=MAX_EVENTS)
        self.jobs = OrderedDict()
        self.sequence = self.dropped_events = self.evicted_jobs = self.sampled_events = 0
        self.rejected_events = self.capture_failures = 0

    def capture(self, job_id, event):
        if type(job_id) is not str or not 0 < len(job_id) <= 256:
            return
        clean = _clean_event(event)
        if clean["stage"] not in _STAGES:
            with self.lock:
                self.rejected_events += 1
            return
        now = time.monotonic()
        with self.lock:
            state = self.jobs.pop(job_id, {})
            self.jobs[job_id] = state
            if len(self.jobs) > MAX_TRACKED_JOBS:
                self.jobs.popitem(last=False)
                self.evicted_jobs += 1
            status = clean.get("status")
            sampled = clean.get("event") in {"activity", "downloading", "postprocessing", "probing"} or clean["stage"] == "row_rejected"
            sample_key = clean.get("event", clean["stage"])
            if sampled and status == state.get("status") and now - state.get(sample_key, -float("inf")) < PROGRESS_SAMPLE_SECONDS:
                self.sampled_events += 1
                return
            state[sample_key] = now
            state["status"] = status
            self.sequence += 1
            clean["sequence"] = self.sequence
            clean["elapsed_ms"] = _integer(int((now - self.started) * 1000))
            if len(self.events) == MAX_EVENTS:
                self.dropped_events += 1
            self.events.append((job_id, clean))


def record_cookie_event(stage, *, error=None, diagnostic_code=None):
    """Record only within a manager worker context; never retain the error object."""
    binding = _context.get()
    if binding is None:
        return
    try:
        event = {"stage": stage}
        if error is not None:
            event.update(_exception_details(error))
        if diagnostic_code is not None:
            event["diagnostic_code"] = diagnostic_code
        binding[0].capture(binding[1], event)
    except Exception as capture_error:  # noqa: BLE001 - Optional telemetry must not fail a download.
        _preserve_cancellation(capture_error)
        # Diagnostics are optional. Interpreter-exit signals are not intercepted.
        with binding[0].lock:
            binding[0].capture_failures += 1
        return


def install_diagnostic_log(manager):
    """Install instance-only wrappers before the manager accepts any tasks."""
    with _install_lock:
        if isinstance(getattr(manager, _ATTRIBUTE, None), _DiagnosticLog):
            return
        log = _DiagnosticLog()
        original_run, original_notify = manager._run_job, manager._notify

        @functools.wraps(original_run)
        def run(job_id, *args, **kwargs):
            token = _context.set((log, job_id))
            try:
                record_cookie_event("task_started")
                try:
                    return original_run(job_id, *args, **kwargs)
                except BaseException as error:
                    record_cookie_event("task_exception", error=error)
                    raise
            finally:
                try:
                    record_cookie_event("task_finished")
                finally:
                    _context.reset(token)

        @functools.wraps(original_notify)
        def notify(job, event, item_id=None):
            try:
                log.capture(_attribute(job, "id"), _manager_event_snapshot(job, event, item_id))
            except Exception as error:  # noqa: BLE001 - No private error may be logged here.
                _preserve_cancellation(error)
                with log.lock:
                    log.capture_failures += 1
            return original_notify(job, event, item_id)

        def progress_listener(event, job):
            # _on_engine_event bypasses _notify. Ignore normal notifications here
            # so each state transition is captured exactly once.
            name = _enum(_attribute(event, "event"), _DIRECT_EVENTS, None)
            if name is not None:
                try:
                    log.capture(_attribute(job, "id"), _manager_event_snapshot(job, name, _attribute(event, "item_id")))
                except Exception as error:  # noqa: BLE001 - Optional telemetry must not fail a download.
                    _preserve_cancellation(error)
                    with log.lock:
                        log.capture_failures += 1

        manager._run_job, manager._notify = run, notify
        setattr(manager, _ATTRIBUTE, log)
        add_listener = getattr(manager, "add_listener", None)
        if callable(add_listener):
            add_listener(progress_listener)


def diagnostic_report(manager, *, job_id: str | None, identity: dict) -> dict:
    """Export at most ten anonymous tasks; IDs select records but are never emitted."""
    if job_id is not None and (type(job_id) is not str or not 0 < len(job_id) <= 256):
        raise KeyError("Unknown diagnostic task")
    summaries = _selected_summaries(manager, job_id)
    log = getattr(manager, _ATTRIBUTE, None)
    events, tracked = [], set()
    stats = {"evicted_events": 0, "evicted_job_contexts": 0, "sampled_events": 0,
             "rejected_events": 0, "capture_failures": 0}
    if isinstance(log, _DiagnosticLog):
        with log.lock:
            events = list(log.events)
            tracked = set(log.jobs)
            stats = {"evicted_events": _integer(log.dropped_events),
                     "evicted_job_contexts": _integer(log.evicted_jobs),
                     "sampled_events": _integer(log.sampled_events),
                     "rejected_events": _integer(log.rejected_events),
                     "capture_failures": _integer(log.capture_failures)}
    report = {
        "schema_version": 1, "identity": _identity(identity),
        "scope": "selected_task" if job_id is not None else "recent_tasks_up_to_10",
        "capture_scope": "Current helper process only; no persistent log is read or written.",
        "history_notice": "Stored task original versions are unknown. Current identity describes this helper only.",
        "privacy": "No raw messages, URLs, cookies, paths, profile values, or real task IDs are collected.",
        "limits": stats, "report_truncated": False, "tasks": [],
    }
    for index, (identifier, summary) in enumerate(summaries, 1):
        task_events = [_clean_event(event) for key, event in events if key == identifier
                       and type(event) is dict and _enum(event.get("stage"), _STAGES, None) is not None]
        summary.update({"task": f"task-{index:02d}", "original_version": "unknown",
                        "runtime_events_available": bool(task_events),
                        "runtime_context_retained": identifier in tracked,
                        "events": task_events})
        report["tasks"].append(summary)
    while True:
        text = "ChengYing safe download diagnostics\n" + json.dumps(report, ensure_ascii=True, indent=2)
        if len(text.encode("utf-8")) <= MAX_REPORT_BYTES:
            return {"schema_version": 1, "text": text}
        report["report_truncated"] = True
        candidates = [task for task in report["tasks"] if task["events"]]
        if not candidates:
            raise RuntimeError("Safe diagnostic report exceeds its fixed capacity")
        oldest = min(candidates, key=lambda task: task["events"][0].get("sequence", 0))
        oldest["events"].pop(0)
        report["limits"]["report_omitted_events"] = report["limits"].get("report_omitted_events", 0) + 1


def verify_diagnostic_log():
    """Exercise the shipped collector entirely in memory using synthetic data."""
    secret = "synthetic-private-cookie-path-url"
    job = SimpleNamespace(id=secret, status="failed", platform="douyin", items=[],
                          issue_code="cookie_unavailable", diagnostic_code="cookie_access_unknown")

    class SyntheticManager:
        def get_job(self, job_id):
            if job_id != job.id:
                raise KeyError("Unknown task")
            return job

        def list_jobs(self):
            return [job]

        def _notify(self, job, event, item_id=None):
            return None

        def _run_job(self, job_id):
            try:
                raise ValueError(secret)
            except ValueError as error:
                record_cookie_event("extract_failed", error=error, diagnostic_code="cookie_access_unknown")
            self._notify(job, "failed")

    manager = SyntheticManager()
    install_diagnostic_log(manager)
    manager._run_job(job.id)
    result = diagnostic_report(manager, job_id=job.id, identity={"player_version": secret})
    text = result["text"]
    if secret in text or '"type": "ValueError"' not in text or '"stage": "extract_failed"' not in text:
        raise RuntimeError("Safe diagnostic self-test failed")
    if len(text.encode("utf-8")) > MAX_REPORT_BYTES:
        raise RuntimeError("Safe diagnostic self-test exceeded capacity")
    return {"schema_version": 1, "synthetic_capture": True, "privacy_verified": True}
