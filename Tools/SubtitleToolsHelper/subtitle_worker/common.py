from __future__ import annotations

import gc
import math
import os
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


class PipelineError(RuntimeError):
    pass


class Cancelled(PipelineError):
    pass


@dataclass
class Segment:
    start: float
    end: float
    source_text: str
    text: str = ""
    language: str = ""


class Progress:
    """Monotonic overall progress; ETA is only for the currently measured stage."""

    def __init__(self, emit: Callable[[dict], None]):
        self.emit = emit
        self.started = time.monotonic()
        self.last = 0.0

    def report(self, stage: str, progress: float, message: str,
               eta: float | None = None) -> None:
        if not math.isfinite(progress):
            raise ValueError("Progress must be finite")
        self.last = max(self.last, min(0.999, max(0.0, progress)))
        event = {"type": "progress", "stage": stage, "progress": self.last,
                 "message": message, "elapsed_seconds": time.monotonic() - self.started}
        if eta is not None and math.isfinite(eta) and eta >= 0:
            event.update(eta_seconds=eta, eta_scope="stage")
        self.emit(event)

    def chunks(self, stage: str, index: int, count: int, started: float,
               lower: float, upper: float) -> None:
        fraction = index / max(count, 1)
        eta = ((time.monotonic() - started) / index * (count - index)) if index else None
        self.report(stage, lower + (upper - lower) * fraction,
                    f"{stage.capitalize()} chunk {index}/{count}", eta)


def check_cancelled(cancelled: Callable[[], bool]) -> None:
    if cancelled():
        raise Cancelled("Subtitle generation was cancelled")


def model_path(paths: dict, key: str) -> Path:
    path = Path(paths[key]).expanduser().resolve()
    if not path.is_dir() or not (path / "config.json").is_file():
        raise PipelineError(f"The local {key} model is incomplete. Prepare it in AI Models first.")
    return path


def local_options() -> dict:
    return {"local_files_only": True, "trust_remote_code": False}


def model_options(torch, device: str) -> dict:
    return {**local_options(), "dtype": torch.bfloat16, "device_map": {"": device},
            "low_cpu_mem_usage": True, "use_safetensors": True,
            "attn_implementation": "sdpa"}


def torch_device(torch) -> str:
    if torch.backends.mps.is_available():
        return "mps"
    raise PipelineError("Apple Metal is unavailable. This runtime requires Apple Silicon and macOS 14 or later.")


def release_memory(torch) -> None:
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()


def physical_memory_bytes() -> int:
    try:
        return int(os.sysconf("SC_PAGE_SIZE")) * int(os.sysconf("SC_PHYS_PAGES"))
    except (ValueError, OSError):
        try:
            return int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], timeout=5))
        except (OSError, ValueError, subprocess.SubprocessError):
            raise PipelineError("Cannot verify system memory required by the full translation model")


def require_translation_memory() -> None:
    if physical_memory_bytes() < 96 * 1024**3:
        raise PipelineError("Hy-MT2-30B-A3B BF16 translation requires at least 96 GiB of unified memory. "
                            "Chinese transcription is available without translation; no smaller model is substituted.")


def cancellation_criteria(torch, transformers, cancelled):
    class CancellationCriteria(transformers.StoppingCriteria):
        def __call__(self, input_ids, scores, **kwargs):
            return torch.full((input_ids.shape[0],), bool(cancelled()),
                              device=input_ids.device, dtype=torch.bool)
    return transformers.StoppingCriteriaList([CancellationCriteria()])
