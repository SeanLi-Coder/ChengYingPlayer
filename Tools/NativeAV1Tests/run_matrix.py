"""Run native AV1 positive/negative controls and validate failures precisely."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
NEGATIVES = ("disable-fallback", "drop-current")
REQUIRED_FAILURES = (
    "FAIL: Boundary mode 1: every AV1 frame appears exactly once",
    "FAIL: Boundary mode 3: exact YUV bytes equal independent dav1d output",
)


def manifest(path):
    rows = {}
    for line in path.read_text().splitlines():
        digest, name = line.split("  ", 1)
        if not re.fullmatch(r"[0-9a-f]{64}", digest) or name in rows:
            raise ValueError("Invalid or duplicate checksum record")
        rows[name] = digest
    if not rows:
        raise ValueError("Empty checksum evidence")
    return rows


def verify_hashes(rows):
    for name, expected in rows.items():
        path = Path(name)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Input hash no longer matches: " + name)


def validate_result(artifacts, returncode, mode):
    expected_exit = 1 if mode else 0
    if returncode != expected_exit:
        raise ValueError(f"Unexpected process status: {returncode}, expected {expected_exit}")
    if json.loads((artifacts / "hash-validation.json").read_text()) != {"changed": []}:
        raise ValueError("Source/library/generated evidence changed")
    source = manifest(artifacts / "source.sha256")
    generated = manifest(artifacts / "generated.sha256")
    verify_hashes({**source, **generated})
    provenance = json.loads((artifacts / "provenance.json").read_text())
    if provenance["negative_control"] != mode or provenance["require_hardware"]:
        raise ValueError("Unexpected mode or hardware-only child")
    log = (artifacts / "results.log").read_text()
    if re.search(r"AddressSanitizer|ThreadSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|runtime error:", log):
        raise ValueError("Sanitizer failure is never an expected negative control")
    summaries = re.findall(r"^Native AV1 checks=(\d+) failures=(\d+) strict_hardware=0$", log, re.MULTILINE)
    if len(summaries) != 1:
        raise ValueError("Expected one completed test summary, not a compile error or timeout")
    checks, failures = map(int, summaries[0])
    if checks <= 0 or (failures <= 0 if mode else failures != 0):
        raise ValueError("Unexpected assertion summary")
    runner_errors = [line for line in log.splitlines() if line.startswith("RUNNER ERROR:")]
    if mode:
        if any(label not in log.splitlines() for label in REQUIRED_FAILURES):
            raise ValueError("Negative control missed the required packet/frame failure labels")
        expected_error = ("RUNNER ERROR: CalledProcessError: Command '['" + str(artifacts / "native-av1-tests")
                          + "', '" + str(artifacts) + "', 'automatic']' returned non-zero exit status 1.")
        if runner_errors != [expected_error]:
            raise ValueError("Negative control failed outside the completed test executable")
    elif runner_errors or re.search(r"^FAIL:", log, re.MULTILINE):
        raise ValueError("Positive control has unexpected failures")
    return {"mode": mode or "normal", "checks": checks, "failures": failures,
            "artifacts": str(artifacts), "source": source, "provenance": provenance}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deps", type=Path, default=ROOT / "deps")
    parser.add_argument("--source-cache", type=Path, default=ROOT / "deps/sources")
    args = parser.parse_args()
    matrix = Path(tempfile.mkdtemp(prefix="native-av1-matrix.", dir=ROOT / "build"))
    print(f"Matrix artifacts: {matrix}", flush=True)
    results = []
    started = time.monotonic()
    status = 0
    try:
        for mode in (None, *NEGATIVES):
            command = [sys.executable, "-B", str(ROOT / "Tools/NativeAV1Tests/run.py"),
                       "--deps", str(args.deps.resolve(strict=True)),
                       "--source-cache", str(args.source_cache.resolve(strict=True))]
            if mode:
                command += ["--negative-control", mode]
            # Each child already bounds and kills its own native/tool process
            # group. Do not turn a killed test into an expected failure here.
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            output = result.stdout + result.stderr
            (matrix / ((mode or "normal") + ".log")).write_text(output)
            paths = re.findall(r"^Artifacts: (.+)$", result.stdout, re.MULTILINE)
            if len(paths) != 1:
                raise ValueError("Child did not identify one fresh artifact directory")
            artifacts = Path(paths[0]).resolve(strict=True)
            if artifacts.parent != (ROOT / "build").resolve() or not artifacts.name.startswith("native-av1-tests."):
                raise ValueError("Unexpected child artifact location")
            verified = validate_result(artifacts, result.returncode, mode)
            if results and verified["source"] != results[0]["source"]:
                raise ValueError("Positive and negative controls did not use identical source/library inputs")
            results.append(verified)
            print(f"Verified {verified['mode']}: checks={verified['checks']} failures={verified['failures']} artifacts={artifacts}", flush=True)
        for result in results:
            verify_hashes(result["source"])
    except Exception as error:
        status = 1
        print(f"Matrix failed: {type(error).__name__}: {error}", flush=True)
    (matrix / "result.json").write_text(json.dumps({"passed": status == 0,
        "elapsed_seconds": time.monotonic() - started, "results": results}, indent=2) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
