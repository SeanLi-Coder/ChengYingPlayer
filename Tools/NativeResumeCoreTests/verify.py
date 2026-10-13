#!/usr/bin/env python3
"""Strict complete-label validation; controls are populated from preserved evidence."""
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
mode = sys.argv[2]
text = (directory / "results.log").read_text()
rows = re.findall(r"^(PASS|FAIL): (.+)$", text, re.M)
labels = [label for _, label in rows]
if len(labels) != len(set(labels)):
    raise SystemExit("Repeated check labels")
summary = re.findall(r"^SUMMARY: (\d+) checks, (\d+) failures$", text, re.M)
if len(summary) != 1 or tuple(map(int, summary[0])) != (len(rows), sum(status == "FAIL" for status, _ in rows)):
    raise SystemExit("Incomplete resume Core summary")
if re.search(r"AddressSanitizer|WARNING: ThreadSanitizer|runtime error:", text):
    raise SystemExit("Sanitizer diagnostics are not accepted")
expected = Path(__file__).with_name("labels.txt")
if not expected.exists() or labels != expected.read_text().splitlines():
    raise SystemExit("Resume Core label contract has not been met")
failures = {label for status, label in rows if status == "FAIL"}
controls = {
    "drop-preview-checkpoint": {
        "preview.finish-pending.checkpoint-before-worker",
        "preview.finish-pending.minimal-record",
        "preview.finish-pending.position",
        "preview.finish-pending.speed",
    },
    "drop-exit-save": {
        "normal.single-cache-update", "normal.last-played-owner",
        "normal.stop-then-quit-metadata-once", "reopen.real-mpv-loaded-record",
        "reopen.position", "reopen.speed", "late.clear-recent.progress-independent",
    } | {
        prefix + "." + suffix
        for prefix in (
            "normal", "preview.active", "preview.finish-pending", "preview.manual-seek",
            "partial.capture", "partial.retire", "partial.loaded", "partial.seek",
            "late.same-path.new", "late.clear-recent")
        for suffix in ("minimal-record", "position", "speed")
    } | {
        "late." + action + "." + suffix
        for action in ("clear", "optout", "same-path", "clear-recent")
        for suffix in ("publication-entered", "barrier-exited", "barrier-explicit-release")
    },
}
wanted = set() if mode == "none" else controls.get(mode)
if wanted is None or failures != wanted:
    raise SystemExit("Unexpected failure set: " + repr(sorted(failures)))
if (directory / "compile-status.txt").read_text().strip() != "0":
    raise SystemExit("Compile did not succeed")
if (directory / "execution-status.txt").read_text().strip() != ("0" if not wanted else "1"):
    raise SystemExit("Unexpected child exit status")
print("Resume Core exact checks verified")
