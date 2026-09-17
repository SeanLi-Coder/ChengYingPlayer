"""Exercise the installed summary-source protocol without accessing any website."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def events_until_exit(child: subprocess.Popen, timeout: float = 25) -> list[dict]:
    deadline = time.monotonic() + timeout
    pending = bytearray()
    events = []
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise AssertionError("Summary source helper did not finish in time")
            data = os.read(child.stdout.fileno(), 8192)
            if not data:
                break
            pending.extend(data)
            if len(pending) > 1024 * 1024:
                raise AssertionError("Summary source event exceeded its size limit")
            while b"\n" in pending:
                line, _, remainder = pending.partition(b"\n")
                pending = bytearray(remainder)
                if line.strip():
                    event = json.loads(line)
                    assert isinstance(event, dict), "Expected a JSON object event"
                    events.append(event)
                assert len(events) <= 100, "Unexpected repeated source events"
    assert not pending.strip(), "The helper returned an incomplete protocol line"
    child.wait(timeout=max(1, deadline - time.monotonic()))
    return events


def run(helper: Path, ffmpeg: Path, ffprobe: Path) -> None:
    command = [sys.executable, str(helper)] if helper.suffix == ".py" else [str(helper)]
    cases = [
        "https://example.invalid/watch?v=abcdefghijk",
        "file:///private/summary-smoke-no-such-input",
        "https://fixture-user:fixture-password@www.youtube.com/watch?v=abcdefghijk",
    ]
    with tempfile.TemporaryDirectory(prefix="chengying-summary-source-smoke-") as name:
        root = Path(name).resolve()
        for index, source_url in enumerate(cases):
            data_dir = root / f"data-{index}"
            job_dir = root / f"job-{index}"
            arguments = [
                *command, "--summary-source", "--stdio", "--data-dir", str(data_dir),
                "--download-dir", str(job_dir), "--ffmpeg", str(ffmpeg),
                "--ffprobe", str(ffprobe),
            ]
            with (root / f"diagnostics-{index}.log").open("wb") as diagnostics:
                child = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=diagnostics, start_new_session=True)
                try:
                    request_id = f"summary-source-smoke-{index}"
                    child.stdin.write(json.dumps({"id": request_id, "source_url": source_url}).encode() + b"\n")
                    child.stdin.flush()
                    # Keep the parent pipe open. A completed one-shot request must
                    # not wait for EOF; EOF instead means cancellation of live work.
                    events = events_until_exit(child)
                    terminal = [event for event in events if event.get("type") in {"completed", "failed", "cancelled"}]
                    assert len(terminal) == 1, "Expected exactly one terminal event"
                    assert terminal[0]["type"] == "failed", "An unsupported source was accepted"
                    assert terminal[0].get("id") == request_id, "The request identity was lost"
                    assert child.returncode != 0, "Rejected input returned a success exit code"
                    serialized = json.dumps(events)
                    for secret in ("fixture-user", "fixture-password"):
                        assert secret not in serialized, "Source credentials leaked into a protocol event"
                    assert not (data_dir / "desktop.lock").exists(), "Source mode acquired the live download-center lock"
                    assert not (data_dir / "state.json").exists(), "Source mode created a normal downloader job store"
                    assert not (job_dir / "source.json").exists(), "Rejected source produced a transcript"
                finally:
                    if child.poll() is None:
                        # This process group was created by this exact smoke test.
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
                    child.stdin.close()
                    child.stdout.close()
    print("Summary source installed-helper smoke passed: unsupported URLs, credential redaction, isolated state")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    arguments = parser.parse_args()
    run(arguments.helper.resolve(strict=True), arguments.ffmpeg.resolve(strict=True),
        arguments.ffprobe.resolve(strict=True))


if __name__ == "__main__":
    main()
