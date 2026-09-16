from __future__ import annotations

import errno
import os
import shutil
import tempfile
import time
from pathlib import Path

from .asr import normalize_language, transcribe
from .common import (
    Cancelled,
    PipelineError,
    Progress,
    check_cancelled,
    require_translation_memory,
)
from .media import burn_subtitles, extract_audio, probe
from .subtitles import normalize_segments, write_ass, write_srt
from .translator import is_mandarin, translate


def resolve_model_paths(request: dict) -> dict:
    provided = request.get("model_paths", {})
    aliases = {"asr": "qwen-asr", "aligner": "qwen-aligner", "translator": "hy-mt"}
    result = {}
    for key, alias in aliases.items():
        value = provided.get(key) or provided.get(alias)
        if not value:
            if not request.get("data_dir"):
                raise PipelineError("A local model data directory is required")
            value = Path(request["data_dir"]) / "models" / key
        result[key] = str(Path(value).expanduser().resolve())
    return result


def publish_exclusive(source: Path, destination: Path) -> None:
    """Never replace an existing path, including on exFAT volumes without links."""
    try:
        os.link(source, destination)
        return
    except OSError as exc:
        if exc.errno not in {errno.EPERM, errno.EOPNOTSUPP, errno.ENOTSUP, errno.EXDEV}:
            raise
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    identity = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, "wb") as target, source.open("rb") as original:
            shutil.copyfileobj(original, target, length=1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
    except BaseException:
        # Remove only the output reserved by this invocation, never a replacement.
        try:
            current = destination.stat(follow_symlinks=False)
            if (identity.st_dev, identity.st_ino) == (current.st_dev, current.st_ino):
                destination.unlink()
        except FileNotFoundError:
            pass
        raise


def publish_sidecars(source: Path, temporary: Path) -> dict:
    """Reserve new names without ever replacing a user file."""
    for index in range(1, 10000):
        suffix = "" if index == 1 else f".{index}"
        base = source.with_name(f"{source.stem}.zh-CN{suffix}")
        targets = {extension: Path(str(base) + "." + extension) for extension in ("srt", "ass")}
        created = []
        try:
            for extension, target in targets.items():
                publish_exclusive(temporary / f"subtitles.{extension}", target)
                created.append(target)
            return {key: str(value) for key, value in targets.items()}
        except FileExistsError:
            for target in created:
                target.unlink()
        except BaseException:
            for target in created:
                target.unlink()
            raise
    raise PipelineError("Cannot allocate unique subtitle output names")


def publish_video(temporary: Path, subtitle: Path) -> Path:
    for index in range(1, 10000):
        suffix = "" if index == 1 else f".{index}"
        destination = subtitle.with_name(f"{subtitle.stem}.hardsub{suffix}.mkv")
        try:
            publish_exclusive(temporary, destination)
            return destination
        except FileExistsError:
            continue
    raise PipelineError("Cannot allocate a unique burned-video output name")


def run_pipeline(request: dict, emit, cancelled=lambda: False) -> dict:
    progress = Progress(emit)
    value = request.get("input_path")
    if not isinstance(value, str) or not value:
        raise PipelineError("Choose a local video file first")
    source = Path(value).expanduser().resolve()
    if not source.is_file():
        raise PipelineError("The selected local video does not exist")
    if not isinstance(request.get("burn_subtitles", False), bool):
        raise PipelineError("burn_subtitles must be a boolean")
    language = str(request.get("language", "auto"))
    normalized_language = normalize_language(language)
    if normalized_language and not is_mandarin(normalized_language):
        require_translation_memory()
    paths = resolve_model_paths(request)
    ffmpeg, ffprobe = request.get("ffmpeg"), request.get("ffprobe")
    if not all(isinstance(exe, str) and Path(exe).is_file() and os.access(exe, os.X_OK)
               for exe in (ffmpeg, ffprobe)):
        raise PipelineError("Bundled FFmpeg and FFprobe executables are required")
    check_cancelled(cancelled)
    progress.report("inspecting", 0.0, "Inspecting the selected local video")
    info = probe(source, ffprobe)
    outputs, warnings = {}, []
    with tempfile.TemporaryDirectory(prefix=".chengying-subtitles-", dir=source.parent) as temporary_name:
        temporary = Path(temporary_name)
        audio_path = temporary / "speech.wav"
        extract_audio(source, audio_path, info, ffmpeg, progress, cancelled)
        segments = transcribe(audio_path, paths, language, progress, cancelled)
        segments = translate(segments, paths, progress, cancelled)
        segments = normalize_segments(segments, info["duration"])
        check_cancelled(cancelled)
        progress.report("saving", 0.92, "Saving Simplified Chinese SRT and ASS beside the original video")
        write_srt(temporary / "subtitles.srt", segments)
        write_ass(temporary / "subtitles.ass", segments)
        outputs = publish_sidecars(source, temporary)
        if request.get("burn_subtitles", False):
            try:
                check_cancelled(cancelled)
                video = temporary / "burned.mkv"
                burn_subtitles(source, video, info, ffmpeg, ffprobe, progress, cancelled)
                check_cancelled(cancelled)
                outputs["video"] = str(publish_video(video, Path(outputs["ass"])))
            except Cancelled:
                raise
            except Exception as exc:  # noqa: BLE001 - Preserve complete sidecars on every optional burn failure.
                warnings.append(f"External subtitles are complete, but video burn-in failed: {exc}")
    return {"type": "completed", "stage": "completed", "progress": 1.0,
            "message": "External subtitles completed; video burn-in needs attention" if warnings else "Chinese subtitles are ready",
            "outputs": outputs, "warnings": warnings, "partial": bool(warnings),
            "elapsed_seconds": time.monotonic() - progress.started, "eta_seconds": 0}
