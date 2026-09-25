from __future__ import annotations

import argparse
import json
import math
import os
import select
import signal
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from conversion import (
    SUPPORTED_CONVERSION_FORMATS,
    SUPPORTED_CONVERSION_MODES,
    ConversionManager,
)
from media import (
    MAX_FRAME_EXTRACTION_SECONDS,
    SUPPORTED_FRAME_FORMATS,
    SUPPORTED_ROTATION_DEGREES,
    ExportManager,
    FrameExtractionManager,
    MediaError,
    RotationManager,
    VideoSource,
    parse_timecode,
    probe_video,
)

PROTOCOL_VERSION = 1
HELPER_VERSION = "1.1.0"
HELPER_NAME = "chengying-video-tools-helper"
MAX_REQUEST_BYTES = 1024 * 1024
POLL_INTERVAL_SECONDS = 0.2
SHUTDOWN_GRACE_SECONDS = 12.0


class RequestError(ValueError):
    """Raised when a protocol request is malformed."""


class OutputClosed(RuntimeError):
    """Raised when the parent process stops reading protocol events."""


class TaskCancelled(RuntimeError):
    """Raised when a task is cancelled before a media manager owns it."""


@dataclass
class ActiveTask:
    request_id: str
    operation: str
    request: dict[str, Any]
    cancel_event: threading.Event = field(default_factory=threading.Event)
    lock: threading.RLock = field(default_factory=threading.RLock)
    manager: Any | None = None
    job: Any | None = None
    worker: threading.Thread | None = None


def _validate_executable(raw_path: str, *, label: str) -> str:
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise MediaError(f"{label} path is required")
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        raise MediaError(f"{label} path must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise MediaError(f"{label} does not exist: {path}") from exc
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise MediaError(f"{label} is not executable: {resolved}")
    return str(resolved)


def _request_id(request: dict[str, Any]) -> str:
    value = request.get("id")
    if not isinstance(value, str):
        raise RequestError("Request id must be a string")
    value = value.strip()
    if not value or len(value.encode("utf-8")) > 256:
        raise RequestError("Request id must contain between 1 and 256 UTF-8 bytes")
    if any(ord(character) < 32 for character in value):
        raise RequestError("Request id must not contain control characters")
    return value


def _required_string(request: dict[str, Any], key: str) -> str:
    value = request.get(key)
    if not isinstance(value, str) or not value.strip():
        raise RequestError(f"{key} must be a non-empty string")
    return value


def _optional_output_directory(request: dict[str, Any], source_path: Path) -> Path:
    value = request.get("output_directory")
    if value is None:
        return source_path.parent
    if not isinstance(value, str) or not value.strip():
        raise RequestError("output_directory must be a non-empty string")
    return Path(value).expanduser().resolve()


def _conversion_options(request: dict[str, Any]) -> tuple[str, str]:
    target_format = request.get("target_format", "mp4")
    mode = request.get("conversion_mode", "copy")
    if not isinstance(target_format, str) or target_format not in SUPPORTED_CONVERSION_FORMATS:
        raise RequestError("target_format must be mp4, mkv, or mov")
    if not isinstance(mode, str) or mode not in SUPPORTED_CONVERSION_MODES:
        raise RequestError("conversion_mode must be copy, h264, or hevc")
    if any(request.get(key) is not None for key in ("start", "end", "degrees")):
        raise RequestError("convert processes the complete video; range and rotation fields are not supported")
    return target_format, mode


def _frame_format(request: dict[str, Any]) -> str:
    value = request.get("frame_format", "jpg")
    if not isinstance(value, str) or value not in SUPPORTED_FRAME_FORMATS:
        raise RequestError("frame_format must be jpg or png")
    return value


def _json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, Path):
        return str(value)
    return value


class ProtocolServer:
    def __init__(self, *, ffmpeg: str, ffprobe: str) -> None:
        self.ffmpeg = _validate_executable(ffmpeg, label="FFmpeg")
        self.ffprobe = _validate_executable(ffprobe, label="FFprobe")
        self._active_lock = threading.RLock()
        self._output_lock = threading.Lock()
        self._active: ActiveTask | None = None
        self._terminate_event = threading.Event()
        self._exit_code = 0

    def emit(self, event: dict[str, Any]) -> None:
        event.setdefault("protocol_version", PROTOCOL_VERSION)
        payload = json.dumps(
            _json_safe(event),
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        )
        try:
            with self._output_lock:
                sys.stdout.buffer.write((payload + "\n").encode("utf-8"))
                sys.stdout.buffer.flush()
        except (BrokenPipeError, OSError) as exc:
            self._terminate_event.set()
            raise OutputClosed("Protocol output was closed") from exc

    def _emit_failure(
        self,
        *,
        request_id: str | None,
        error_code: str,
        error: str,
        operation: str | None = None,
    ) -> None:
        event: dict[str, Any] = {
            "id": request_id,
            "type": "failed",
            "error_code": error_code,
            "error": error,
        }
        if operation is not None:
            event["operation"] = operation
        self.emit(event)

    def _emit_terminal(self, task: ActiveTask, event: dict[str, Any]) -> None:
        with self._active_lock:
            try:
                self.emit(event)
            finally:
                if self._active is task:
                    self._active = None

    def _emit_terminal_failure(
        self,
        task: ActiveTask,
        *,
        error_code: str,
        error: str,
    ) -> None:
        self._emit_terminal(
            task,
            {
                "id": task.request_id,
                "type": "failed",
                "operation": task.operation,
                "error_code": error_code,
                "error": error,
            },
        )

    def _normalize_operation(self, request: dict[str, Any]) -> str:
        operation = _required_string(request, "operation").lower()
        aliases = {
            "probe": "probe",
            "clip": "clip",
            "frames": "frames",
            "extract_frames": "frames",
            "rotate": "rotate",
            "convert": "convert",
        }
        normalized = aliases.get(operation)
        if normalized is None:
            raise RequestError(f"Unsupported operation: {operation}")
        return normalized

    def _handle_start(self, request: dict[str, Any], request_id: str) -> None:
        operation = self._normalize_operation(request)
        with self._active_lock:
            if self._active is not None:
                self._emit_failure(
                    request_id=request_id,
                    operation=operation,
                    error_code="busy",
                    error=f"Task {self._active.request_id} is still running",
                )
                return
            task = ActiveTask(
                request_id=request_id,
                operation=operation,
                request=request,
            )
            worker = threading.Thread(
                target=self._run_task,
                args=(task,),
                name=f"video-tools-{operation}-{request_id}",
                daemon=False,
            )
            task.worker = worker
            self._active = task

        try:
            self.emit(
                {
                    "id": request_id,
                    "type": "accepted",
                    "operation": operation,
                }
            )
            worker.start()
        except OutputClosed:
            with self._active_lock:
                if self._active is task:
                    self._active = None
            raise
        except RuntimeError as exc:
            with self._active_lock:
                if self._active is task:
                    self._active = None
            self._emit_failure(
                request_id=request_id,
                operation=operation,
                error_code="internal_error",
                error=f"Could not start media task: {exc}",
            )

    def _request_cancel(self, task: ActiveTask) -> None:
        task.cancel_event.set()
        with task.lock:
            manager = task.manager
            job = task.job
        if manager is not None and job is not None:
            try:
                manager.cancel(job.id)
            except MediaError:
                pass

    def _handle_cancel(self, request: dict[str, Any], request_id: str) -> None:
        target_value = request.get("target_id", request_id)
        if not isinstance(target_value, str) or not target_value.strip():
            raise RequestError("target_id must be a non-empty string")
        target_id = target_value.strip()
        with self._active_lock:
            task = self._active
            if task is None or task.request_id != target_id:
                self._emit_failure(
                    request_id=request_id,
                    error_code="task_not_found",
                    error=f"Active task was not found: {target_id}",
                )
                return
            self.emit(
                {
                    "id": request_id,
                    "target_id": target_id,
                    "type": "accepted",
                    "action": "cancel",
                    "operation": task.operation,
                }
            )
            self._request_cancel(task)

    def handle_request(self, request: Any) -> None:
        request_id: str | None = None
        try:
            if not isinstance(request, dict):
                raise RequestError("Each request must be a JSON object")
            request_id = _request_id(request)
            command = _required_string(request, "command").lower()
            if command == "start":
                self._handle_start(request, request_id)
            elif command == "cancel":
                self._handle_cancel(request, request_id)
            elif command == "ping":
                self.emit({"id": request_id, "type": "pong"})
            elif command == "shutdown":
                self.emit({"id": request_id, "type": "accepted", "action": "shutdown"})
                self._terminate_event.set()
            else:
                raise RequestError(f"Unsupported command: {command}")
        except RequestError as exc:
            self._emit_failure(
                request_id=request_id,
                error_code="invalid_request",
                error=str(exc),
            )

    def _source_for_task(self, task: ActiveTask) -> VideoSource:
        source_value = _required_string(task.request, "input_path")
        source_path = Path(source_value).expanduser().resolve()
        if task.cancel_event.is_set():
            raise TaskCancelled
        metadata = probe_video(
            source_path,
            ffprobe=self.ffprobe,
            cancel_event=task.cancel_event,
        )
        if task.cancel_event.is_set():
            raise TaskCancelled
        return VideoSource(task.request_id, source_path, metadata)

    def _set_runtime(self, task: ActiveTask, manager: Any, job: Any) -> None:
        with task.lock:
            task.manager = manager
            task.job = job
        if task.cancel_event.is_set():
            manager.cancel(job.id)

    @staticmethod
    def _progress_signature(snapshot: dict[str, Any]) -> tuple[Any, ...]:
        return (
            snapshot.get("status"),
            snapshot.get("progress"),
            snapshot.get("message"),
            snapshot.get("frame_count"),
            snapshot.get("estimated_remaining_seconds"),
        )

    def _progress_event(
        self,
        task: ActiveTask,
        snapshot: dict[str, Any],
    ) -> dict[str, Any]:
        event: dict[str, Any] = {
            "id": task.request_id,
            "type": "progress",
            "operation": task.operation,
            "status": snapshot.get("status"),
            "progress": snapshot.get("progress", 0.0),
            "message": snapshot.get("message", ""),
            "elapsed_seconds": snapshot.get("elapsed_seconds", 0.0),
            "eta_seconds": snapshot.get("estimated_remaining_seconds"),
        }
        if "frame_count" in snapshot:
            event["frame_count"] = snapshot["frame_count"]
        return event

    def _wait_for_job(self, task: ActiveTask, manager: Any, job: Any) -> None:
        last_signature: tuple[Any, ...] | None = None
        while True:
            if task.cancel_event.is_set():
                manager.cancel(job.id)
            snapshot = job.snapshot()
            status = str(snapshot.get("status") or "")
            signature = self._progress_signature(snapshot)
            if status in {"queued", "running"} and signature != last_signature:
                self.emit(self._progress_event(task, snapshot))
                last_signature = signature
            if status not in {"queued", "running"}:
                break
            worker = job.worker
            if worker is None:
                raise MediaError("Media worker was not started")
            worker.join(timeout=POLL_INTERVAL_SECONDS)
            if not worker.is_alive() and job.snapshot().get("status") in {"queued", "running"}:
                raise MediaError("Media worker exited without a final status")

        worker = job.worker
        if worker is not None and worker is not threading.current_thread():
            worker.join(timeout=SHUTDOWN_GRACE_SECONDS)
            if worker.is_alive():
                task.cancel_event.set()
                raise MediaError("Media worker did not finish final cleanup")
        snapshot = job.snapshot()
        status = str(snapshot.get("status") or "")
        if status == "completed":
            output_path = snapshot.get("output_path")
            if not isinstance(output_path, str) or not Path(output_path).is_absolute():
                raise MediaError("Completed task did not return an absolute output path")
            event: dict[str, Any] = {
                "id": task.request_id,
                "type": "completed",
                "operation": task.operation,
                "progress": 100.0,
                "message": snapshot.get("message", ""),
                "elapsed_seconds": snapshot.get("elapsed_seconds", 0.0),
                "eta_seconds": 0.0,
                "output_path": output_path,
                "output_name": snapshot.get("output_name"),
            }
            if "frame_count" in snapshot:
                event["frame_count"] = snapshot["frame_count"]
                event["frame_format"] = snapshot["frame_format"]
            self._emit_terminal(task, event)
            return
        if status == "cancelled":
            self._emit_terminal(
                task,
                {
                    "id": task.request_id,
                    "type": "cancelled",
                    "operation": task.operation,
                    "progress": snapshot.get("progress", 0.0),
                    "message": snapshot.get("message", "Task cancelled"),
                    "elapsed_seconds": snapshot.get("elapsed_seconds", 0.0),
                }
            )
            return
        error = str(snapshot.get("error") or "Media processing failed")
        self._emit_terminal_failure(
            task,
            error_code="processing_failed",
            error=error,
        )

    def _run_task(self, task: ActiveTask) -> None:
        try:
            conversion_options = (
                _conversion_options(task.request) if task.operation == "convert" else None
            )
            frame_format = _frame_format(task.request) if task.operation == "frames" else None
            source = self._source_for_task(task)
            if task.operation == "probe":
                if task.cancel_event.is_set():
                    raise TaskCancelled
                self._emit_terminal(
                    task,
                    {
                        "id": task.request_id,
                        "type": "completed",
                        "operation": "probe",
                        "progress": 100.0,
                        "metadata": source.metadata,
                    }
                )
                return

            if task.operation == "clip":
                if "start" not in task.request or "end" not in task.request:
                    raise RequestError("clip requires start and end")
                manager = ExportManager(
                    ffmpeg=self.ffmpeg,
                    ffprobe=self.ffprobe,
                    cancel_event=task.cancel_event,
                )
                output_directory = _optional_output_directory(task.request, source.path)
                job = manager.create(
                    source,
                    start=task.request["start"],
                    end=task.request["end"],
                    output_directory=output_directory,
                )
            elif task.operation == "frames":
                if "start" not in task.request:
                    raise RequestError("frames requires start")
                start = task.request["start"]
                end = task.request.get("end")
                if end is None:
                    start_seconds = parse_timecode(start)
                    end = min(
                        start_seconds + MAX_FRAME_EXTRACTION_SECONDS,
                        float(source.metadata["duration"]),
                    )
                manager = FrameExtractionManager(
                    ffmpeg=self.ffmpeg,
                    ffprobe=self.ffprobe,
                    cancel_event=task.cancel_event,
                )
                output_directory = _optional_output_directory(task.request, source.path)
                job = manager.create(
                    source,
                    start=start,
                    end=end,
                    output_directory=output_directory,
                    frame_format=frame_format,
                )
            elif task.operation == "rotate":
                if "degrees" not in task.request:
                    raise RequestError("rotate requires degrees")
                if "output_directory" in task.request:
                    raise RequestError("rotate always writes beside the source video")
                manager = RotationManager(
                    ffmpeg=self.ffmpeg,
                    ffprobe=self.ffprobe,
                    cancel_event=task.cancel_event,
                )
                job = manager.create(source, degrees=task.request["degrees"])
            elif task.operation == "convert":
                assert conversion_options is not None
                target_format, mode = conversion_options
                manager = ConversionManager(
                    ffmpeg=self.ffmpeg,
                    ffprobe=self.ffprobe,
                    cancel_event=task.cancel_event,
                )
                job = manager.create(
                    source,
                    target_format=target_format,
                    mode=mode,
                    output_directory=_optional_output_directory(task.request, source.path),
                )
            else:
                raise RequestError(f"Unsupported operation: {task.operation}")

            self._set_runtime(task, manager, job)
            self._wait_for_job(task, manager, job)
        except TaskCancelled:
            self._emit_terminal(
                task,
                {
                    "id": task.request_id,
                    "type": "cancelled",
                    "operation": task.operation,
                    "progress": 0.0,
                    "message": "Task cancelled",
                    "elapsed_seconds": 0.0,
                }
            )
        except RequestError as exc:
            self._emit_terminal_failure(
                task,
                error_code="invalid_request",
                error=str(exc),
            )
        except MediaError as exc:
            if task.cancel_event.is_set():
                self._emit_terminal(
                    task,
                    {
                        "id": task.request_id,
                        "type": "cancelled",
                        "operation": task.operation,
                        "progress": 0.0,
                        "message": "Task cancelled",
                        "elapsed_seconds": 0.0,
                    }
                )
            else:
                self._emit_terminal_failure(
                    task,
                    error_code="media_error",
                    error=str(exc),
                )
        except OutputClosed:
            self._request_cancel(task)
        except Exception as exc:  # noqa: BLE001 - protocol boundaries must return structured errors
            if task.cancel_event.is_set():
                try:
                    self._emit_terminal(
                        task,
                        {
                            "id": task.request_id,
                            "type": "cancelled",
                            "operation": task.operation,
                            "progress": 0.0,
                            "message": "Task cancelled",
                            "elapsed_seconds": 0.0,
                        }
                    )
                except OutputClosed:
                    pass
            else:
                try:
                    self._emit_terminal_failure(
                        task,
                        error_code="internal_error",
                        error=str(exc) or exc.__class__.__name__,
                    )
                except OutputClosed:
                    pass
        finally:
            if self._terminate_event.is_set():
                self._request_cancel(task)
                with task.lock:
                    job = task.job
                worker = job.worker if job is not None else None
                if worker is not None and worker is not threading.current_thread():
                    worker.join(timeout=SHUTDOWN_GRACE_SECONDS)
            with self._active_lock:
                if self._active is task:
                    self._active = None

    def _cancel_active(self) -> ActiveTask | None:
        with self._active_lock:
            task = self._active
        if task is not None:
            self._request_cancel(task)
        return task

    def _handle_protocol_line(self, raw_line: bytes) -> None:
        try:
            request = json.loads(raw_line.decode("utf-8"))
        except UnicodeDecodeError:
            self._emit_failure(
                request_id=None,
                error_code="invalid_json",
                error="Request must be UTF-8",
            )
            return
        except json.JSONDecodeError as exc:
            self._emit_failure(
                request_id=None,
                error_code="invalid_json",
                error=f"Invalid JSON: {exc.msg}",
            )
            return
        self.handle_request(request)

    def _signal_handler(self, signum: int, _frame: Any) -> None:
        self._exit_code = 128 + signum
        self._terminate_event.set()

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)
        self.emit(
            {
                "type": "ready",
                "helper": HELPER_NAME,
                "helper_version": HELPER_VERSION,
                "operations": ["probe", "clip", "frames", "rotate", "convert"],
                "max_frame_extraction_seconds": MAX_FRAME_EXTRACTION_SECONDS,
                "default_frame_extraction_seconds": MAX_FRAME_EXTRACTION_SECONDS,
                "default_frame_format": "jpg",
                "supported_frame_formats": sorted(SUPPORTED_FRAME_FORMATS),
                "supported_rotation_degrees": sorted(SUPPORTED_ROTATION_DEGREES),
                "supported_conversion_formats": sorted(SUPPORTED_CONVERSION_FORMATS),
                "supported_conversion_modes": sorted(SUPPORTED_CONVERSION_MODES),
            }
        )

        input_fd = sys.stdin.fileno()
        pending_input = bytearray()
        try:
            while not self._terminate_event.is_set():
                try:
                    readable, _, _ = select.select(
                        [input_fd],
                        [],
                        [],
                        POLL_INTERVAL_SECONDS,
                    )
                except (OSError, ValueError):
                    self._terminate_event.set()
                    break
                if not readable:
                    continue
                try:
                    chunk = os.read(input_fd, 64 * 1024)
                except InterruptedError:
                    continue
                if not chunk:
                    if pending_input.strip():
                        if len(pending_input) > MAX_REQUEST_BYTES:
                            self._emit_failure(
                                request_id=None,
                                error_code="request_too_large",
                                error=f"Request exceeds {MAX_REQUEST_BYTES} bytes",
                            )
                        else:
                            self._handle_protocol_line(bytes(pending_input))
                    self._terminate_event.set()
                    break
                pending_input.extend(chunk)
                while b"\n" in pending_input:
                    raw_line, _, remainder = pending_input.partition(b"\n")
                    pending_input = bytearray(remainder)
                    if len(raw_line) > MAX_REQUEST_BYTES:
                        self._emit_failure(
                            request_id=None,
                            error_code="request_too_large",
                            error=f"Request exceeds {MAX_REQUEST_BYTES} bytes",
                        )
                        self._terminate_event.set()
                        break
                    if raw_line.strip():
                        self._handle_protocol_line(raw_line)
                    if self._terminate_event.is_set():
                        break
                if len(pending_input) > MAX_REQUEST_BYTES:
                    self._emit_failure(
                        request_id=None,
                        error_code="request_too_large",
                        error=f"Request exceeds {MAX_REQUEST_BYTES} bytes",
                    )
                    self._terminate_event.set()
        finally:
            task = self._cancel_active()
            if (
                task is not None
                and task.worker is not None
                and task.worker.ident is not None
            ):
                task.worker.join(timeout=SHUTDOWN_GRACE_SECONDS)
        return self._exit_code


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=HELPER_NAME)
    parser.add_argument("--ffmpeg", required=True, help="Absolute FFmpeg executable path")
    parser.add_argument("--ffprobe", required=True, help="Absolute FFprobe executable path")
    parser.add_argument(
        "--stdio",
        action="store_true",
        help="Read JSON Lines requests from stdin and write events to stdout",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _argument_parser().parse_args(argv)
    if not arguments.stdio:
        _argument_parser().error("--stdio is required")
    try:
        server = ProtocolServer(ffmpeg=arguments.ffmpeg, ffprobe=arguments.ffprobe)
        return server.run()
    except MediaError as exc:
        event = {
            "protocol_version": PROTOCOL_VERSION,
            "id": None,
            "type": "failed",
            "error_code": "startup_error",
            "error": str(exc),
        }
        payload = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
        sys.stdout.buffer.write(payload.encode("utf-8"))
        sys.stdout.buffer.flush()
        return 2
    except OutputClosed:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
