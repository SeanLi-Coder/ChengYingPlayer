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
import uuid
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
        if model.get("id") in model_ids or model.get("id") not in {"asr", "aligner", "translator", "summarizer"}:
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
    if not {"asr", "aligner", "translator"}.issubset(model_ids):
        raise AssetError("The manifest must contain the complete high-quality subtitle pipeline.")
    artifacts = [Artifact.from_dict(spec) for spec in specs]
    if len({item.path for item in artifacts}) != len(artifacts) or len({item.id for item in artifacts}) != len(artifacts):
        raise AssetError("The manifest contains duplicate artifact identifiers or paths.")
    paths = {item.path for item in artifacts}
    if any(item.path + suffix in paths for item in artifacts for suffix in (".part", ".invalid")):
        raise AssetError("An artifact collides with a managed temporary file.")
    return manifest, hashlib.sha256(raw).hexdigest()


class Supervisor:
    def __init__(self, manifest: dict, fingerprint: str, data_dir: Path, resources: Path, ffmpeg: str, ffprobe: str, emit: Callable[[dict], None], *, downloader_helper: str | None = None, downloader_data_dir: str | None = None) -> None:
        self.manifest = manifest
        self.store = ArtifactStore(data_dir)
        self.runtime = Runtime(self.store.root, manifest, fingerprint)
        self.resources = resources
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.emit = emit
        self.downloader_helper = downloader_helper
        self.downloader_data_dir = downloader_data_dir
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
             "stored_bytes": sum(self.store.stored(item) for item in artifacts),
             "needs_repair": any(self.store.needs_repair(item) for item in artifacts),
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
                if self._active_operation == "delete_model":
                    self.emit({"type": "failed", "id": identifier, "error": "Model removal cannot be cancelled once confirmed."})
                    return
                self._cancel.set()
            self.emit({"type": "accepted", "id": identifier, "message": "Cancellation requested."})
            return
        if command == "shutdown":
            self.close()
            self.emit({"type": "completed", "id": identifier, "message": "Subtitle tools stopped."})
            return
        if command not in {"prepare", "start", "summarize", "verify", "delete_model"}:
            self.emit({"type": "failed", "id": identifier, "error": "Unknown command."})
            return
        with self._lock:
            if self._closing or self._active_id is not None:
                self.emit({"type": "failed", "id": identifier, "error": "Another subtitle operation is already running."})
                return
            self._active_id = identifier
            self._active_operation = {"start": "subtitles", "summarize": "summary"}.get(command, command)
            self._cancel = threading.Event()
            self.emit({"type": "accepted", "id": identifier, "operation": self._active_operation})
            self._thread = threading.Thread(target=self._run, args=(identifier, command, dict(request)), daemon=True)
            self._thread.start()

    def _run(self, identifier: str, command: str, request: dict) -> None:
        operation = {"start": "subtitles", "summarize": "summary"}.get(command, command)
        last_emit = 0.0
        terminal_event: dict | None = None
        selected = self.artifacts
        total_bytes = self.total_bytes

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
            if command != "prepare":
                emit({"type": "progress", "stage": "verify", "artifact_id": artifact.id,
                      "progress": count / max(1, artifact.size), "message": f"Verifying {artifact.id}.",
                      "downloaded_bytes": count, "total_bytes": artifact.size, "bytes_per_second": rate,
                      "eta_seconds": (artifact.size - count) / rate if rate and rate > 0 else None,
                      "eta_scope": "current_file_verification"})
                return
            downloaded = sum(self.store.downloaded(item) for item in selected)
            verified = sum(item.size for item in selected if self.store.ready(item))
            done = downloaded if phase == "download" else min(total_bytes, verified + count)
            remaining = total_bytes - downloaded if phase == "download" else artifact.size - count
            emit({"type": "progress", "stage": phase, "artifact_id": artifact.id,
                  "progress": done / max(1, total_bytes), "message": f"{'Downloading' if phase == 'download' else 'Verifying'} {artifact.id}.",
                  "downloaded_bytes": downloaded, "total_bytes": total_bytes,
                  "bytes_per_second": rate, "eta_seconds": remaining / rate if rate and rate > 0 else None,
                  "eta_scope": "remaining_download" if phase == "download" else "current_file_verification"})

        try:
            with operation_lock(self.store.root):
                if command == "verify":
                    emit({"type": "progress", "stage": "verify", "message": "Checking existing local models; no files will be downloaded."})
                    for _, artifacts in self.models:
                        for artifact in artifacts:
                            self.store.verify(artifact, self._cancel, download_progress)
                    self.runtime.verify_existing(self._cancel, lambda event: emit({"type": "progress", **event}))
                    check_cancelled(self._cancel)
                    emit({**self.status(), "type": "completed", "stage": "complete", "progress": 1.0,
                          "message": "Local verification finished. Missing or invalid files were not downloaded."})
                elif command == "delete_model":
                    model_id = request.get("model_id")
                    if not isinstance(model_id, str):
                        raise AssetError("Select a bundled model to remove.")
                    selected_model = next((artifacts for model, artifacts in self.models if model["id"] == model_id), None)
                    if selected_model is None:
                        raise AssetError("Unknown model identifier.")
                    removed = self.store.remove(selected_model, lambda done, total: emit({
                        "type": "progress", "stage": "delete_model", "progress": done / max(1, total),
                        "message": "Removing the selected model and its partial downloads."}))
                    emit({**self.status(), "type": "completed", "stage": "complete", "progress": 1.0,
                          "model_id": model_id, "removed_bytes": removed,
                          "message": "The selected model was removed. Other models, runtime and generated files were preserved."})
                elif command == "prepare":
                    purpose = request.get("purpose", "subtitles")
                    if purpose not in {"subtitles", "summary"}:
                        raise AssetError("Unsupported model preparation purpose.")
                    identifiers = {"asr", "aligner", "summarizer" if purpose == "summary" else "translator"}
                    if not identifiers.issubset({model["id"] for model, _ in self.models}):
                        raise AssetError("The requested model pipeline is not bundled.")
                    runtime_ready = self.runtime.verify_existing(self._cancel, lambda event: emit({"type": "progress", **event}))
                    selected = []
                    if not runtime_ready:
                        selected = [Artifact.from_dict(self.manifest["runtime"]["archive"])]
                        selected += [Artifact.from_dict(item) for item in self.manifest["runtime"]["wheels"]]
                    selected += [item for model, artifacts in self.models if model["id"] in identifiers for item in artifacts]
                    total_bytes = sum(item.size for item in selected)
                    remaining = sum(item.size - self.store.downloaded(item) for item in selected)
                    install_space = 0 if runtime_ready else sum(item["size"] for item in self.manifest["runtime"]["wheels"]) * 3 + self.manifest["runtime"]["archive"]["size"] * 4
                    ensure_space(self.store.root, remaining + install_space)
                    for artifact in selected:
                        self.store.ensure(artifact, self._cancel, download_progress)
                    self.runtime.ensure(self._cancel, lambda event: emit({"type": "progress", **event}))
                    check_cancelled(self._cancel)
                    emit({**self.status(), "type": "completed", "stage": "complete", "progress": 1.0, "purpose": purpose, "message": "The requested models and offline runtime are verified and ready."})
                elif command == "summarize":
                    self._summarize(request, emit, download_progress)
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
                if terminal_event is not None and command in {"verify", "delete_model"}:
                    try:
                        terminal_event.update(self.status())
                    except (AssetError, OSError):
                        # Preserve the original failure if a managed path is unsafe.
                        pass
                    terminal_event["operation"] = operation
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
        for model, artifacts in self.models:
            if model["id"] not in {"asr", "aligner", "translator"}:
                continue
            for artifact in artifacts:
                if not self.store.verify(artifact, self._cancel, download_progress):
                    raise AssetError("A subtitle model is missing or unverified. Prepare the models first.")
        model_paths = {model["id"]: str(safe_path(self.store.root, model["directory"])) for model, _ in self.models}
        payload = {"input_path": str(video), "language": language, "burn_subtitles": burn,
                   "ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "data_dir": str(self.store.root),
                   "models": model_paths, "model_paths": {"qwen-asr": model_paths["asr"], "qwen-aligner": model_paths["aligner"], "hy-mt": model_paths["translator"]}}
        self._worker(payload, emit)

    def _summarize(self, request: dict, emit: Callable[[dict], None], download_progress: Callable) -> None:
        from subtitle_worker.common import physical_memory_bytes
        from subtitle_worker.summary import read_source

        source_url = request.get("source_url")
        if not isinstance(source_url, str) or not 8 <= len(source_url) <= 4096:
            raise AssetError("Enter one Bilibili or YouTube video link.")
        if physical_memory_bytes() < 96 * 1024**3:
            raise AssetError("Qwen3.8-27B BF16 summarization requires at least 96 GiB of unified memory.")
        if not self.runtime.ready():
            raise AssetError("Prepare the isolated AI runtime before starting a summary.")
        if (not self.downloader_helper or not Path(self.downloader_helper).is_absolute()
                or not os.access(self.downloader_helper, os.X_OK)
                or not self.downloader_data_dir or not Path(self.downloader_data_dir).is_absolute()):
            raise AssetError("The bundled summary source helper is unavailable.")
        def verify_models(identifiers: set[str]) -> None:
            if not identifiers.issubset({model["id"] for model, _ in self.models}):
                raise AssetError("The required local summary models are not bundled.")
            for model, artifacts in self.models:
                if model["id"] in identifiers:
                    for artifact in artifacts:
                        if not self.store.verify(artifact, self._cancel, download_progress):
                            raise AssetError("A required summary model is missing or unverified. Prepare summary models first.")
        verify_models({"summarizer"})
        identifier = request.get("id", "")
        try:
            if str(uuid.UUID(identifier)) != identifier.lower():
                raise ValueError("Not a canonical UUID")
        except (ValueError, AttributeError) as exc:
            raise AssetError("Summary requests require a canonical UUID identifier.") from exc
        folder = safe_path(self.store.root, f"summaries/{identifier}", parents=True)
        folder.mkdir(mode=0o700, exist_ok=False)
        source_folder = safe_path(folder, "source")
        source_folder.mkdir(mode=0o700)
        terminal: dict | None = None
        def source_event(line: str) -> None:
            nonlocal terminal
            try:
                event = json.loads(line)
            except ValueError:
                return
            if not isinstance(event, dict) or event.get("id") != identifier:
                return
            if event.get("type") in {"completed", "failed", "cancelled"}:
                terminal = event
            elif event.get("type") == "progress":
                emit(event)
        emit({"type": "progress", "stage": "reading_source", "message": "Reading video metadata and available subtitles."})
        command = [self.downloader_helper, "--summary-source", "--stdio", "--data-dir", self.downloader_data_dir,
                   "--download-dir", str(source_folder), "--ffmpeg", self.ffmpeg, "--ffprobe", self.ffprobe]
        code = run_process(command, self._cancel, source_event, on_stderr=lambda _: None,
                           stdin_payload=json.dumps({"id": identifier, "source_url": source_url}))
        check_cancelled(self._cancel)
        if terminal and (terminal.get("type") == "cancelled" or terminal.get("code") == "cancelled"):
            raise Cancelled("Summary source acquisition cancelled.")
        if code != 0 or not terminal or terminal.get("type") != "completed":
            raise AssetError(str((terminal or {}).get("message") or "The video source could not be prepared."))
        source_path = safe_path(source_folder, "source.json")
        if terminal.get("source_path") != str(source_path):
            raise AssetError("The source helper returned an unexpected output path.")
        source = read_source(source_path, folder)
        if source["content_source"] == "audio":
            verify_models({"asr", "aligner"})
        model_paths = {model["id"]: str(safe_path(self.store.root, model["directory"])) for model, _ in self.models}
        self._worker({"operation": "summary", "source_path": str(source_path), "output_dir": str(folder),
                      "data_dir": str(self.store.root), "ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe,
                      "model_paths": model_paths}, emit)

    def _worker(self, payload: dict, emit: Callable[[dict], None]) -> None:
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
            environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1", PYTHONNOUSERSITE="1", PYTHONUTF8="1", PYTHONUNBUFFERED="1", TOKENIZERS_PARALLELISM="false", HF_DEACTIVATE_ASYNC_LOAD="1")
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
    parser.add_argument("--downloader-helper")
    parser.add_argument("--downloader-data-dir")
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
        supervisor = Supervisor(manifest, fingerprint, Path(arguments.data_dir).expanduser(), resources, arguments.ffmpeg, arguments.ffprobe, emit,
                                downloader_helper=arguments.downloader_helper, downloader_data_dir=arguments.downloader_data_dir)
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
