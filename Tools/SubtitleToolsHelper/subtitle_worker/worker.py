"""Run one offline subtitle job. Standard output is reserved for JSONL events."""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import traceback
from pathlib import Path

# Set before importing Torch, Transformers, or any model processor.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
# Unsupported Metal operations may run on CPU with the identical full model.
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from subtitle_worker.common import Cancelled
from subtitle_worker.pipeline import run_pipeline


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", "--request-json", dest="request", required=True)
    args = parser.parse_args()
    started = time.monotonic()
    # Redirect file descriptor 1 as well as sys.stdout: native library prints must
    # never corrupt the supervisor protocol. The duplicate is the sole event sink.
    sink = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    request_id = None

    def emit(event):
        if request_id is not None:
            event["id"] = request_id
        sink.write(json.dumps(event, ensure_ascii=False, allow_nan=False) + "\n")
        sink.flush()

    def cancel(signum, frame):
        raise Cancelled("Subtitle generation was cancelled")

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        request = json.loads(Path(args.request).read_text(encoding="utf-8"))
        if not isinstance(request, dict):
            raise TypeError("The worker request must be a JSON object")
        request_id = request.get("id")
        emit(run_pipeline(request, emit))
        return 0
    except BaseException as exc:  # noqa: BLE001 - The process boundary must emit exactly one terminal event.
        traceback.print_exc(file=sys.stderr)
        emit({"type": "failed", "stage": "cancelled" if isinstance(exc, Cancelled) else "failed",
              "progress": 0.0, "message": str(exc) or type(exc).__name__,
              "error": str(exc) or type(exc).__name__, "cancelled": isinstance(exc, Cancelled),
              "elapsed_seconds": time.monotonic() - started})
        return 130 if isinstance(exc, Cancelled) else 1
    finally:
        sink.close()


if __name__ == "__main__":
    raise SystemExit(main())
