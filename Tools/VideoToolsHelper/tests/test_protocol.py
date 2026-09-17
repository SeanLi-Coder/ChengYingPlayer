from __future__ import annotations

import hashlib
import json
import select
import subprocess
import sys
import threading
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

import helper as helper_module

HELPER_PATH = Path(__file__).resolve().parents[1] / "helper.py"


def _read_event(process: subprocess.Popen[str], *, timeout: float = 30.0) -> dict:
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select(
            [process.stdout],
            [],
            [],
            min(0.25, max(0.0, deadline - time.monotonic())),
        )
        if not readable:
            if process.poll() is not None:
                break
            continue
        line = process.stdout.readline()
        if line:
            return json.loads(line)
        if process.poll() is not None:
            break
    stderr = ""
    if process.poll() is not None and process.stderr is not None:
        stderr = process.stderr.read()
    raise AssertionError(
        f"Timed out waiting for helper event; exit={process.poll()} stderr={stderr!r}"
    )


def _send(process: subprocess.Popen[str], request: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
    process.stdin.flush()


def _events_until_terminal(
    process: subprocess.Popen[str],
    *,
    request_id: str,
    timeout: float = 60.0,
) -> list[dict]:
    events: list[dict] = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        event = _read_event(process, timeout=max(0.1, deadline - time.monotonic()))
        if event.get("id") != request_id:
            continue
        events.append(event)
        if event.get("type") in {"completed", "failed", "cancelled"}:
            return events
    raise AssertionError(f"No terminal event for {request_id}: {events}")


@pytest.fixture()
def helper_process(ffmpeg: str, ffprobe: str) -> Iterator[subprocess.Popen[str]]:
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER_PATH),
            "--ffmpeg",
            ffmpeg,
            "--ffprobe",
            ffprobe,
            "--stdio",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=HELPER_PATH.parent,
    )
    ready = _read_event(process)
    assert ready["type"] == "ready"
    assert ready["protocol_version"] == 1
    assert ready["operations"] == ["probe", "clip", "frames", "rotate", "convert"]
    assert ready["supported_conversion_formats"] == ["mkv", "mov", "mp4"]
    assert ready["supported_conversion_modes"] == ["copy", "h264", "hevc"]
    try:
        yield process
    finally:
        if process.poll() is None:
            try:
                _send(process, {"id": "test-shutdown", "command": "shutdown"})
            except (BrokenPipeError, OSError):
                pass
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=15)


def test_probe_round_trip_uses_structured_events(
    helper_process: subprocess.Popen[str],
    sample_video: Path,
) -> None:
    _send(
        helper_process,
        {
            "id": "probe-one",
            "command": "start",
            "operation": "probe",
            "input_path": str(sample_video),
        },
    )

    events = _events_until_terminal(helper_process, request_id="probe-one")

    assert events[0]["type"] == "accepted"
    assert events[-1]["type"] == "completed"
    assert events[-1]["operation"] == "probe"
    assert events[-1]["metadata"]["width"] == 320
    assert events[-1]["metadata"]["height"] == 180
    assert events[-1]["metadata"]["has_audio"] is True

    _send(
        helper_process,
        {
            "id": "probe-two",
            "command": "start",
            "operation": "probe",
            "input_path": str(sample_video),
        },
    )
    second_events = _events_until_terminal(helper_process, request_id="probe-two")
    assert second_events[0]["type"] == "accepted"
    assert second_events[-1]["type"] == "completed"


def test_frames_default_end_is_five_seconds_after_start(
    helper_process: subprocess.Popen[str],
    sample_video: Path,
    tmp_path: Path,
) -> None:
    _send(
        helper_process,
        {
            "id": "frames-default-end",
            "command": "start",
            "operation": "extract_frames",
            "input_path": str(sample_video),
            "start": 0.25,
            "output_directory": str(tmp_path),
        },
    )

    events = _events_until_terminal(
        helper_process,
        request_id="frames-default-end",
        timeout=90,
    )
    completed = events[-1]

    assert completed["type"] == "completed"
    assert completed["operation"] == "frames"
    assert completed["frame_count"] > 0
    output_path = Path(completed["output_path"])
    assert output_path.parent == tmp_path
    assert len(list(output_path.glob("frame_*.png"))) == completed["frame_count"]


def test_invalid_request_is_rejected_without_stopping_service(
    helper_process: subprocess.Popen[str],
) -> None:
    _send(helper_process, {"id": "bad-one", "command": "start", "operation": "clip"})
    events = _events_until_terminal(helper_process, request_id="bad-one")
    assert events[-1]["type"] == "failed"
    assert events[-1]["error_code"] == "invalid_request"

    _send(helper_process, {"id": "still-alive", "command": "ping"})
    event = _read_event(helper_process)
    assert event["id"] == "still-alive"
    assert event["type"] == "pong"


@pytest.mark.parametrize(
    ("target_format", "mode"),
    [(None, None), ("mkv", "copy"), ("mov", "h264"), ("mp4", "hevc")],
)
def test_conversion_round_trip_preserves_source_and_processes_full_video(
    helper_process: subprocess.Popen[str],
    sample_video: Path,
    ffprobe: str,
    target_format: str | None,
    mode: str | None,
) -> None:
    original_digest = hashlib.sha256(sample_video.read_bytes()).hexdigest()
    request = {
        "id": "convert-video",
        "command": "start",
        "operation": "convert",
        "input_path": str(sample_video),
    }
    if target_format is not None:
        request["target_format"] = target_format
    if mode is not None:
        request["conversion_mode"] = mode
    _send(helper_process, request)
    events = _events_until_terminal(helper_process, request_id="convert-video", timeout=120)
    assert events[0]["type"] == "accepted"
    assert events[-1]["type"] == "completed", events
    assert events[-1]["operation"] == "convert"
    assert events[-1]["progress"] == 100.0
    assert events[-1]["eta_seconds"] == 0.0
    output_path = Path(events[-1]["output_path"])
    assert output_path.is_absolute() and output_path.is_file()
    assert output_path.parent == sample_video.parent
    assert output_path != sample_video
    assert output_path.suffix == f".{target_format or 'mp4'}"
    assert hashlib.sha256(sample_video.read_bytes()).hexdigest() == original_digest
    metadata = helper_module.probe_video(output_path, ffprobe=ffprobe)
    assert metadata["duration"] == pytest.approx(6.0, abs=0.1)
    assert metadata["width"] == 320 and metadata["height"] == 180
    assert metadata["has_audio"] is True
    assert all(event["progress"] < 100.0 for event in events if event["type"] == "progress")


@pytest.mark.parametrize(
    "fields",
    [
        {"target_format": "avi"},
        {"target_format": "../mp4"},
        {"target_format": None},
        {"target_format": ["mp4"]},
        {"conversion_mode": "fast"},
        {"conversion_mode": True},
        {"start": 0},
        {"end": 1},
        {"degrees": 90},
    ],
)
def test_conversion_rejects_invalid_options_before_reading_media(
    monkeypatch: pytest.MonkeyPatch,
    fields: dict,
) -> None:
    server = helper_module.ProtocolServer(ffmpeg="/bin/echo", ffprobe="/bin/echo")
    events: list[dict] = []
    monkeypatch.setattr(server, "emit", lambda event: events.append(dict(event)))

    def unexpected_probe(*_args: object, **_kwargs: object) -> None:
        pytest.fail("Invalid conversion options must be rejected before media probing")

    monkeypatch.setattr(helper_module, "probe_video", unexpected_probe)
    task = helper_module.ActiveTask(
        request_id="bad-convert",
        operation="convert",
        request={"input_path": "/missing/video.mp4", **fields},
    )
    server._run_task(task)
    assert len(events) == 1
    assert events[0]["type"] == "failed"
    assert events[0]["error_code"] == "invalid_request"
    assert events[0]["operation"] == "convert"
    assert "output_path" not in events[0]


def test_conversion_defaults_are_lossless_mp4() -> None:
    assert helper_module._conversion_options({}) == ("mp4", "copy")


def test_multiple_requests_in_one_pipe_write_are_not_buffered(
    helper_process: subprocess.Popen[str],
) -> None:
    assert helper_process.stdin is not None
    requests = [
        {"id": "batch-ping-one", "command": "ping"},
        {"id": "batch-ping-two", "command": "ping"},
    ]
    helper_process.stdin.write(
        "".join(json.dumps(request) + "\n" for request in requests)
    )
    helper_process.stdin.flush()

    first = _read_event(helper_process)
    assert helper_process.stdout is not None
    second = json.loads(helper_process.stdout.readline())

    assert [first["id"], second["id"]] == ["batch-ping-one", "batch-ping-two"]
    assert first["type"] == second["type"] == "pong"


def test_startup_rejects_relative_tool_paths() -> None:
    completed = subprocess.run(
        [
            sys.executable,
            str(HELPER_PATH),
            "--ffmpeg",
            "ffmpeg",
            "--ffprobe",
            "ffprobe",
            "--stdio",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
        cwd=HELPER_PATH.parent,
    )

    assert completed.returncode == 2
    event = json.loads(completed.stdout)
    assert event["type"] == "failed"
    assert event["error_code"] == "startup_error"


def test_probe_subprocess_is_cancelled_promptly(
    ffmpeg: str,
    sample_video: Path,
    tmp_path: Path,
) -> None:
    blocking_probe = tmp_path / "blocking-ffprobe"
    blocking_probe.write_text("#!/bin/sh\nexec /bin/sleep 30\n", encoding="utf-8")
    blocking_probe.chmod(0o755)
    process = subprocess.Popen(
        [
            sys.executable,
            str(HELPER_PATH),
            "--ffmpeg",
            ffmpeg,
            "--ffprobe",
            str(blocking_probe),
            "--stdio",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=HELPER_PATH.parent,
    )
    assert _read_event(process)["type"] == "ready"
    started = time.monotonic()
    try:
        _send(
            process,
            {
                "id": "cancel-probe-process",
                "command": "start",
                "operation": "probe",
                "input_path": str(sample_video),
            },
        )
        assert _read_event(process)["type"] == "accepted"
        time.sleep(0.3)
        _send(process, {"id": "cancel-probe-process", "command": "cancel"})
        events = _events_until_terminal(process, request_id="cancel-probe-process", timeout=8)
        assert events[-1]["type"] == "cancelled"
        assert time.monotonic() - started < 5
    finally:
        if process.poll() is None:
            _send(process, {"id": "probe-cancel-shutdown", "command": "shutdown"})
            process.wait(timeout=15)


@pytest.mark.parametrize("operation", ["probe", "convert"])
def test_busy_and_cancel_requests_are_deterministic(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    operation: str,
) -> None:
    source = tmp_path / "source.mov"
    source.touch()
    probe_started = threading.Event()
    release_probe = threading.Event()

    def slow_probe(
        _path: Path,
        *,
        ffprobe: str,
        cancel_event: threading.Event | None = None,
    ) -> dict:
        del ffprobe, cancel_event
        probe_started.set()
        assert release_probe.wait(timeout=5)
        return {"duration": 10.0, "width": 320, "height": 180}

    monkeypatch.setattr(helper_module, "probe_video", slow_probe)
    server = helper_module.ProtocolServer(ffmpeg="/bin/echo", ffprobe="/bin/echo")
    events: list[dict] = []
    monkeypatch.setattr(server, "emit", lambda event: events.append(dict(event)))

    server.handle_request(
        {
            "id": "slow-probe",
            "command": "start",
            "operation": operation,
            "input_path": str(source),
        }
    )
    assert probe_started.wait(timeout=5)

    server.handle_request(
        {
            "id": "second-task",
            "command": "start",
            "operation": "probe",
            "input_path": str(source),
        }
    )
    assert any(
        event.get("id") == "second-task"
        and event.get("type") == "failed"
        and event.get("error_code") == "busy"
        for event in events
    )

    server.handle_request({"id": "slow-probe", "command": "cancel"})
    with server._active_lock:
        active = server._active
    assert active is not None
    assert active.worker is not None
    release_probe.set()
    active.worker.join(timeout=5)

    assert any(
        event.get("id") == "slow-probe" and event.get("type") == "cancelled"
        for event in events
    )
    cancel_ack_index = next(
        index
        for index, event in enumerate(events)
        if event.get("id") == "slow-probe"
        and event.get("type") == "accepted"
        and event.get("action") == "cancel"
    )
    cancelled_index = next(
        index
        for index, event in enumerate(events)
        if event.get("id") == "slow-probe" and event.get("type") == "cancelled"
    )
    assert cancel_ack_index < cancelled_index
    assert server._active is None
