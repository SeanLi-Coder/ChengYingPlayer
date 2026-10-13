"""Validate actual long-GOP fixture evidence and exact regression failures."""
import json
import math
from pathlib import Path
import re
import statistics
import sys
from evidence import validate


def load_report(directory):
    value = json.loads((directory / "report.json").read_text())
    if (value.get("schema_version") != 2 or type(value.get("schema_version")) is not int
            or value.get("scope") != "real-decoder-session-controlled-output"
            or value.get("mode") not in ("baseline", "candidate")
            or type(value.get("instrumented")) is not bool
            or value.get("physical_display") != "not-tested"
            or value.get("framework_output") != "not-tested"):
        raise ValueError("Missing or unsupported benchmark report identity")
    rounds = value.get("rounds")
    if type(rounds) is not int or not 1 <= rounds <= 5:
        raise ValueError("Missing or invalid declared benchmark rounds")
    for key in ("passed", "failed"):
        if type(value.get(key)) is not int or value[key] < (1 if key == "passed" else 0):
            raise ValueError("Invalid benchmark assertion count")
    lines = (directory / "results.log").read_text().splitlines()
    summaries = [re.fullmatch(r"RESULT: ([0-9]+) passed / ([0-9]+) failed", line)
                 for line in lines if line.startswith("RESULT:")]
    if (len(summaries) != 1 or summaries[0] is None
            or tuple(map(int, summaries[0].groups())) != (value["passed"], value["failed"])
            or sum(line.startswith("PASS: ") for line in lines) != value["passed"]
            or sum(line.startswith("FAIL: ") for line in lines) != value["failed"]):
        raise ValueError("Result log and report assertion counts differ")

    def finite(number):
        return type(number) in (int, float) and math.isfinite(number)

    def record(row):
        if not isinstance(row, dict) or row.get("target") not in (1.2, 6.4, 8.7):
            raise ValueError("Unexpected measurement target")
        if not finite(row.get("delivery_ms")) or row["delivery_ms"] < 0:
            raise ValueError("Missing actual target video delivery time")
        samples = row.get("samples")
        if (not isinstance(samples, list) or len(samples) != 2
                or any(not isinstance(sample, dict) or type(sample.get("video")) is not bool for sample in samples)
                or {sample["video"] for sample in samples} != {True, False}):
            raise ValueError("Every measurement must contain exactly its first video and PCM sample")
        for sample in samples:
            if (not finite(sample.get("start")) or not finite(sample.get("end"))
                    or sample["start"] < row["target"] - 0.000001 or sample["end"] < sample["start"]
                    or type(sample.get("bytes")) is not int or sample["bytes"] <= 0
                    or not isinstance(sample.get("sha256"), str)
                    or re.fullmatch(r"[0-9a-f]{64}", sample["sha256"]) is None):
                raise ValueError("Incomplete sample timing, byte length or content identity")
        paths = row.get("decoder_paths")
        if (not isinstance(paths, dict) or paths.get("scope") != "delivered-target-samples-only"
                or any(type(paths.get(key)) is not int or paths[key] < 0
                       for key in ("video_samples", "hardware_samples", "videotoolbox_samples"))
                or paths["video_samples"] < 1 or paths["hardware_samples"] > paths["video_samples"]
                or paths["videotoolbox_samples"] > paths["hardware_samples"]):
            raise ValueError("Missing or inconsistent target decoder path observations")

    measurements = value.get("measurements")
    if not isinstance(measurements, list) or len(measurements) != rounds * 3:
        raise ValueError("Incomplete target-by-round measurements")
    expected = {(round_index, target) for round_index in range(rounds) for target in (1.2, 6.4, 8.7)}
    observed = set()
    for row in measurements:
        record(row)
        if type(row.get("round")) is not int:
            raise ValueError("Missing measurement round")
        key = (row["round"], row["target"])
        if key in observed:
            raise ValueError("Duplicated target-by-round measurement")
        observed.add(key)
    if observed != expected:
        raise ValueError("Target-by-round matrix differs from its declaration")
    playing = value.get("playback_measurements")
    if not isinstance(playing, list) or len(playing) != 2:
        raise ValueError("Missing playing forward/backward seek measurements")
    for row in playing:
        record(row)
    if [row["target"] for row in playing] != [8.7, 1.2]:
        raise ValueError("Playing seek must cover forward and backward targets in order")
    return value


def fixture(path):
    frames = json.loads(path.read_text())["frames"]
    if len(frames) != 360 or sum(row["pict_type"] == "B" for row in frames) < 100:
        raise ValueError("The fixture must contain 360 real decoded frames and B-frame reordering")
    keyframes = [float(row["best_effort_timestamp_time"]) for row in frames if row["key_frame"]]
    if len(keyframes) != 2 or abs(keyframes[0]) > 0.001 or abs(keyframes[1] - 10) > 0.001:
        raise ValueError("The fixture must have keyframes only at zero and ten seconds")
    print("Verified actual long-GOP frame inventory and reordering")
    dimensions = sorted({(row.get("width"), row.get("height")) for row in frames})
    print(f"Decoded frame dimensions: {dimensions}")


def negative(path, mode):
    validate(path, expected_child=1)
    result = load_report(path)
    failures = [line.removeprefix("FAIL: ") for line in (path / "results.log").read_text().splitlines()
                if line.startswith("FAIL: ")]
    expected = {
        "polling": ["Active preroll yields immediately instead of adding fixed ten-millisecond sleeps"] * 5,
        "busy-wait": ["backpressure: stalled retry remains bounded and delayed"],
        "quantum": ["Slow decoder yields between samples at the cooperative time budget"],
        "fifo": ["backpressure recovery: both stream samples are delivered"],
    }[mode]
    if failures != expected:
        raise ValueError(f"Unexpected negative-control failures: {failures!r}")
    if result["failed"] != len(expected) or (path / "exit-status.txt").read_text().strip() != "1":
        raise ValueError("Negative control did not exit with its exact assertion failures")
    print("Verified exact negative-control failures: " + mode)


def compare(old, new, known_aac=False):
    import hashlib
    for directory in (old, new):
        validate(directory, expected_child=1 if known_aac else 0)
    if hashlib.sha256((old / "long-gop.mkv").read_bytes()).digest() != hashlib.sha256((new / "long-gop.mkv").read_bytes()).digest():
        raise ValueError("Benchmark fixtures differ")
    reports = [load_report(directory) for directory in (old, new)]
    if reports[0]["rounds"] != reports[1]["rounds"]:
        raise ValueError("Baseline and candidate benchmark rounds differ")
    baseline_samples = {}
    for row in reports[0]["measurements"]:
        samples = sorted(row["samples"], key=lambda sample: sample["video"])
        if row["target"] in baseline_samples and baseline_samples[row["target"]] != samples:
            raise ValueError("Baseline sample contents vary between repeated seeks")
        baseline_samples[row["target"]] = samples
    for row in reports[1]["measurements"]:
        if baseline_samples[row["target"]] != sorted(row["samples"], key=lambda sample: sample["video"]):
            raise ValueError("Candidate changed exact sample timing, pixels or PCM")
    for report in reports:
        for row in report["playback_measurements"]:
            if baseline_samples[row["target"]] != sorted(row["samples"], key=lambda sample: sample["video"]):
                raise ValueError("Playing seek changed exact sample timing, pixels or PCM")
    if known_aac:
        failures = [[line for line in (directory / "results.log").read_text().splitlines()
                     if line.startswith("FAIL: ")] for directory in (old, new)]
        if failures[0] != failures[1] or not failures[0] or not all(
                "PCM bytes match origin decode without precision loss" in line for line in failures[0]):
            raise ValueError("AAC existing-behavior comparison includes a new or non-PCM failure")
        if any(report["failed"] != len(failures[0]) for report in reports):
            raise ValueError("AAC failure count does not match the preserved diagnostics")
        print(f"Verified identical existing AAC origin-PCM differences: {len(failures[0])}")
    for directory, result in zip((old, new), reports):
        if result["failed"] and not known_aac:
            raise ValueError("Cannot compare a failing positive run")
        for target in (1.2, 6.4, 8.7):
            values = [row["delivery_ms"] for row in result["measurements"] if row["target"] == target]
            print(f"{result['mode']} target={target} n={len(values)} median_ms={statistics.median(values):.3f} range_ms={min(values):.3f}..{max(values):.3f}")
        for row in result["playback_measurements"]:
            print(f"{result['mode']} playing target={row['target']} delivery_ms={row['delivery_ms']:.3f}")
        print(f"{result['mode']} delivered decoder paths: {result['measurements'][0]['decoder_paths']}")


if __name__ == "__main__":
    if sys.argv[1] == "fixture": fixture(Path(sys.argv[2]))
    elif sys.argv[1] == "negative": negative(Path(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "compare": compare(Path(sys.argv[2]), Path(sys.argv[3]))
    elif sys.argv[1] == "compare-aac": compare(Path(sys.argv[2]), Path(sys.argv[3]), known_aac=True)
    elif sys.argv[1] == "evidence":
        directory = Path(sys.argv[2])
        validate(directory)
        if load_report(directory)["failed"]:
            raise ValueError("Positive evidence contains failed assertions")
    else: raise ValueError("Unknown verification mode")
