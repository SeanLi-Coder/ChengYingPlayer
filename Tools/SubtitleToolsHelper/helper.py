#!/usr/bin/env python3
"""JSONL supervisor for ChengYing's isolated, local subtitle tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from pathlib import Path

from downloads import (
    Artifact,
    ArtifactStore,
    AssetError,
    Cancelled,
    check_cancelled,
    ensure_space,
    relative_path,
    safe_path,
)
from runtime import Runtime, operation_lock, run_process


def load_manifest(path: Path) -> tuple[dict, str]:
    raw = path.read_bytes()
    if len(raw) > 16 * 1024**2:
        raise AssetError("The bundled asset manifest is too large.")
    manifest = json.loads(raw)
    if manifest.get("schema_version") != 1 or not isinstance(manifest.get("models"), list):
        raise AssetError("Unsupported subtitle asset manifest.")
    runtime = manifest.get("runtime", {})
    if not isinstance(runtime.get("wheels"), list) or not runtime["wheels"]:
        raise AssetError("The manifest does not include a complete offline wheelhouse.")
    specs = [runtime.get("archive", {}), *runtime["wheels"]]
    model_ids: set[str] = set()
    for model in manifest["models"]:
        if model.get("id") in model_ids or model.get("id") not in {"asr", "aligner", "translator"}:
            raise AssetError("Invalid or duplicate model identifier.")
        model_ids.add(model["id"])
        relative_path(model.get("directory", ""))
        revision = model.get("revision", "")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise AssetError("Every model must use a fixed repository commit.")
        if not isinstance(model.get("artifacts"), list) or not model["artifacts"]:
            raise AssetError("A model is missing its artifact manifest.")
        for value in model["artifacts"]:
            artifact = Artifact.from_dict(value)
            if not artifact.path.startswith(model["directory"] + "/"):
                raise AssetError("A model artifact is outside its declared directory.")
            prefix = f"https://huggingface.co/{model.get('repository', '')}/resolve/{revision}/"
            if not artifact.url.startswith(prefix):
                raise AssetError("Model URLs must refer to their pinned official repository revision.")
        specs.extend(model["artifacts"])
    if model_ids != {"asr", "aligner", "translator"}:
        raise AssetError("The manifest must contain the complete high-quality subtitle pipeline.")
    artifacts = [Artifact.from_dict(spec) for spec in specs]
    if len({item.path for item in artifacts}) != len(artifacts) or len({item.id for item in artifacts}) != len(artifacts):
        raise AssetError("The manifest contains duplicate artifact identifiers or paths.")
    paths = {item.path for item in artifacts}
    if any(item.path + suffix in paths for item in artifacts for suffix in (".part", ".invalid")):
        raise AssetError("An artifact collides with a managed temporary file.")
    return manifest, hashlib.sha256(raw).hexdigest()


class Supervisor:
    def __init__(self, manifest: dict, fingerprint: str, data_dir: Path, resources: Path, ffmpeg: str, ffprobe: str, emit: Callable[[dict], None]) -> None:
        self.manifest = manifest
        self.store = ArtifactStore(data_dir)
        self.runtime = Runtime(self.store.root, manifest, fingerprint)
        self.resources = resources
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.emit = emit
        self.artifacts = [Artifact.from_dict(manifest["runtime"]["archive"])]
        self.artifacts += [Artifact.from_dict(item) for item in manifest["runtime"]["wheels"]]
        self.models = [(model, [Artifact.from_dict(item) for item in model["artifacts"]]) for model in manifest["models"]]
        self.artifacts += [artifact for _, artifacts in self.models for artifact in artifacts]
        self.total_bytes = sum(item.size for item in self.artifacts)
        self._lock = threading.RLock()
        self._thread: threading.Thread | None = None
        self._active_id: str | None = None
        self._active_operation: str | None = None
        self._cancel = threading.Event()
        self._closing = False

    def status(self) -> dict:
        models = [
            {"id": model["id"], "name": model["name"], "total_bytes": sum(item.size for item in artifacts),
             "downloaded_bytes": sum(self.store.downloaded(item) for item in artifacts),
             "ready": all(self.store.ready(item) for item in artifacts)}
            for model, artifacts in self.models
        ]
        with self._lock:
            return {"runtime_ready": self.runtime.ready(), "models": models,
                    "downloaded_bytes": sum(self.store.downloaded(item) for item in self.artifacts),
                    "total_bytes": self.total_bytes, "active_id": self._active_id,
                    "operation": self._active_operation}

    def request(self, request: dict) -> None:
        identifier = request.get("id")
        command = request.get("command")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 256:
            self.emit({"type": "failed", "error": "Every request must include a nonempty string id."})
            return
        if command == "status":
            try:
                self.emit({**self.status(), "type": "status", "id": identifier})
            except (AssetError, OSError) as exc:
                self.emit({"type": "failed", "id": identifier, "error": str(exc)})
            return
        if command == "cancel":
            with self._lock:
                if self._active_id is None or request.get("target_id") != self._active_id:
                    self.emit({"type": "failed", "id": identifier, "error": "The target operation is not active."})
                    return
                self._cancel.set()
            self.emit({"type": "accepted", "id": identifier, "message": "Cancellation requested."})
            return
        if command == "shutdown":
            self.close()
            self.emit({"type": "completed", "id": identifier, "message": "Subtitle tools stopped."})
            return
        if command not in {"prepare", "start"}:
            self.emit({"type": "failed", "id": identifier, "error": "Unknown command."})
            return
        with self._lock:
            if self._closing or self._active_id is not None:
                self.emit({"type": "failed", "id": identifier, "error": "Another subtitle operation is already running."})
                return
            self._active_id = identifier
            self._active_operation = "prepare" if command == "prepare" else "subtitles"
            self._cancel = threading.Event()
            self.emit({"type": "accepted", "id": identifier, "operation": self._active_operation})
            self._thread = threading.Thread(target=self._run, args=(identifier, command, dict(request)), daemon=True)
            self._thread.start()

    def _run(self, identifier: str, command: str, request: dict) -> None:
        operation = "prepare" if command == "prepare" else "subtitles"
        last_emit = 0.0
        terminal_event: dict | None = None

        def emit(event: dict) -> None:
            nonlocal terminal_event
            event = {**event, "id": identifier, "operation": operation}
            if event.get("type") in {"completed", "failed", "cancelled"}:
                terminal_event = event
            else:
                self.emit(event)

        def download_progress(artifact: Artifact, phase: str, count: int, rate: float | None) -> None:
            nonlocal last_emit
            now = time.monotonic()
            if now - last_emit < 0.2 and count < artifact.size:
                return
            last_emit = now
            downloaded = sum(self.store.downloaded(item) for item in self.artifacts)
            verified = sum(item.size for item in self.artifacts if self.store.ready(item))
            done = downloaded if phase == "download" else min(self.total_bytes, verified + count)
            remaining = self.total_bytes - downloaded if phase == "download" else artifact.size - count
            emit({"type": "progress", "stage": phase, "artifact_id": artifact.id,
                  "progress": done / self.total_bytes, "message": f"{'Downloading' if phase == 'download' else 'Verifying'} {artifact.id}.",
                  "downloaded_bytes": downloaded, "total_bytes": self.total_bytes,
                  "bytes_per_second": rate, "eta_seconds": remaining / rate if rate and rate > 0 else None,
                  "eta_scope": "remaining_download" if phase == "download" else "current_file_verification"})

        try:
            with operation_lock(self.store.root):
                if command == "prepare":
                    remaining = sum(item.size - self.store.downloaded(item) for item in self.artifacts)
                    install_space = 0 if self.runtime.ready() else sum(item["size"] for item in self.manifest["runtime"]["wheels"]) * 3 + self.manifest["runtime"]["archive"]["size"] * 4
                    ensure_space(self.store.root, remaining + install_space)
                    for artifact in self.artifacts:
                        self.store.ensure(artifact, self._cancel, download_progress)
                    self.runtime.ensure(self._cancel, lambda event: emit({"type": "progress", **event}))
                    check_cancelled(self._cancel)
                    emit({**self.status(), "type": "completed", "stage": "complete", "progress": 1.0, "message": "All subtitle models and the offline runtime are verified and ready."})
                else:
                    self._start(request, emit, download_progress)
        except Cancelled:
            emit({"type": "cancelled", "stage": "cancelled", "message": "Operation cancelled; partial downloads were retained."})
        except Exception as exc:  # noqa: BLE001 - Convert every background failure into a terminal IPC event.
            emit({"type": "failed", "stage": "failed", "message": "Subtitle operation failed.", "error": str(exc)})
        finally:
            with self._lock:
                self._active_id = None
                self._active_operation = None
            if terminal_event is not None:
                terminal_event["active_id"] = None
                self.emit(terminal_event)

    def _start(self, request: dict, emit: Callable[[dict], None], download_progress: Callable) -> None:
        raw_path = request.get("input_path")
        if not isinstance(raw_path, str) or not raw_path:
            raise AssetError("Select a local video before generating subtitles.")
        video = Path(raw_path).expanduser().resolve(strict=True)
        if not video.is_file():
            raise AssetError("The selected video is not a regular file.")
        language = request.get("language", "auto")
        if language not in {"auto", "zh", "yue", "en", "ja", "ko"}:
            raise AssetError("Unsupported subtitle source language.")
        burn = request.get("burn_subtitles", False)
        if type(burn) is not bool:
            raise AssetError("The subtitle burn option must be a boolean.")
        if not self.runtime.ready():
            raise AssetError("Prepare the isolated subtitle runtime before starting a task.")
        for _, artifacts in self.models:
            for artifact in artifacts:
                if not self.store.verify(artifact, self._cancel, download_progress):
                    raise AssetError("A subtitle model is missing or unverified. Prepare the models first.")
        model_paths = {model["id"]: str(safe_path(self.store.root, model["directory"])) for model, _ in self.models}
        payload = {"input_path": str(video), "language": language, "burn_subtitles": burn,
                   "ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "data_dir": str(self.store.root),
                   "models": model_paths, "model_paths": {"qwen-asr": model_paths["asr"], "qwen-aligner": model_paths["aligner"], "hy-mt": model_paths["translator"]}}
        folder = safe_path(self.store.root, "requests/.request-check", parents=True).parent
        descriptor, filename = tempfile.mkstemp(prefix="subtitle-", suffix=".json", dir=folder)
        path = Path(filename)
        terminal: dict | None = None
        tail: list[str] = []

        def diagnostic(line: str) -> None:
            tail.append(line[:2000])
            del tail[:-6]

        def output(line: str) -> None:
            nonlocal terminal
            try:
                event = json.loads(line)
            except ValueError:
                diagnostic(line)
                return
            if not isinstance(event, dict) or event.get("type") not in {"progress", "completed", "failed", "cancelled"}:
                return
            if event["type"] in {"completed", "failed", "cancelled"}:
                terminal = event
            else:
                emit(event)

        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
                json.dump(payload, destination, ensure_ascii=False)
            environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1", PYTHONNOUSERSITE="1", PYTHONUTF8="1", PYTHONUNBUFFERED="1", TOKENIZERS_PARALLELISM="false")
            for key in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
                environment.pop(key, None)
            code = run_process([str(self.runtime.python()), "-I", str(self.resources / "subtitle_worker" / "worker.py"), "--request-json", str(path)], self._cancel, output, env=environment, on_stderr=diagnostic)
            check_cancelled(self._cancel)
            if terminal and terminal.get("type") == "failed":
                raise AssetError(str(terminal.get("error") or terminal.get("message") or "Subtitle generation failed."))
            if terminal and terminal.get("type") == "cancelled":
                raise Cancelled("Subtitle generation cancelled.")
            if code != 0 or not terminal or terminal.get("type") != "completed":
                raise AssetError("The subtitle worker did not complete successfully. " + "\n".join(tail))
            emit(terminal)
        finally:
            path.unlink(missing_ok=True)

    def close(self) -> None:
        with self._lock:
            self._closing = True
            self._cancel.set()
            thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            # Network reads have a 15-second timeout; child processes poll cancellation.
            thread.join(timeout=25)


def main() -> int:
    parser = argparse.ArgumentParser(description="ChengYing subtitle tools supervisor")
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--stdio", action="store_true", required=True)
    arguments = parser.parse_args()
    output_lock = threading.Lock()

    def emit(event: dict) -> None:
        with output_lock:
            print(json.dumps(event, ensure_ascii=False, allow_nan=False), flush=True)

    supervisor: Supervisor | None = None

    def interrupted(signum, frame) -> None:
        # Raising through stdin iteration runs the supervisor's final cleanup.
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        resources = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
        manifest, fingerprint = load_manifest(resources / "assets.json")
        supervisor = Supervisor(manifest, fingerprint, Path(arguments.data_dir).expanduser(), resources, arguments.ffmpeg, arguments.ffprobe, emit)
        emit({"type": "ready", "message": "Local subtitle tools are ready.", "protocol_version": 1})
        for line in sys.stdin:
            if len(line) > 1024**2:
                emit({"type": "failed", "error": "The request is too large."})
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise TypeError("A request must be a JSON object.")
            except (TypeError, ValueError) as exc:
                emit({"type": "failed", "error": str(exc)})
                continue
            supervisor.request(request)
            if request.get("command") == "shutdown":
                break
        return 0
    except Exception as exc:  # noqa: BLE001 - Startup errors must reach the native client as JSONL.
        emit({"type": "failed", "error": str(exc)})
        return 1
    finally:
        if supervisor is not None:
            supervisor.close()


if __name__ == "__main__":
    raise SystemExit(main())
