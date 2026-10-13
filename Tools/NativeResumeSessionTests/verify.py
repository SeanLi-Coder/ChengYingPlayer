"""Verify normal results and exact single-mutation failures, never crashes/timeouts."""
import pathlib
import re
import sys

STABLE = ["paused", "playing", "ended", "reopened"]
PENDING = ["pending-seek", "pending-same-open", "pending-other-open", "pending-stop", "pending-commands"]
CALLBACK = "capture and completion run exactly once in order on main"
IDENTITY = "final snapshot retains actual pre-shutdown media identity and phase"
CLOCK = "final snapshot uses real nonzero clock and applied settings before reset"
STALE = "uncommitted media intent cannot save stale worker position"
INTENT = "cancelled queued commands cannot fabricate applied playback intent"


def expected_labels():
    labels = set()

    def add(mode, *suffixes):
        labels.update(f"{mode}: {suffix}" for suffix in suffixes)

    def close(mode):
        add(mode, "shutdown completes", CALLBACK)

    def dispose(mode):
        add(mode, "session releases after shutdown")

    for mode in STABLE:
        add(mode, "real decode and paused seek settle", "supported rate accepted",
            "actual worker reaches requested final state", IDENTITY, CLOCK,
            "terminal normal query stays unavailable", "terminal commands stay rejected",
            "terminal snapshot is closed and cannot reopen playback")
        close(mode)
        dispose(mode)
    for mode in PENDING:
        add(mode, "real paused baseline settles", "worker barrier entered",
            "shutdown does not block main or publish a cached receipt", "worker barrier explicitly released",
            "earlier normal query is superseded")
        close(mode)
        dispose(mode)
        if mode == "pending-seek":
            add(mode, "pending preview restore seek accepted")
        if mode == "pending-commands":
            add(mode, "queued rate accepted before retirement",
                "decoder cancellation is immediate before worker reset", INTENT)
        else:
            add(mode, STALE)
    add("preroll", "real paused baseline settles", "restore seek accepted",
        "actual seek entered worker preroll before shutdown",
        "actual pending seek preroll is not a resume point")
    for stage in ["first", "second"]:
        add(f"preroll {stage}", "worker barrier entered", "worker barrier explicitly released")
    close("preroll")
    dispose("preroll")
    for mode in ["idle", "opening", "failed", "stopped"]:
        close(mode)
        dispose(mode)
        add(mode, "unready session supplies no invented resume point")
    add("opening", "worker barrier entered", "worker barrier explicitly released")
    add("failed", "actual decoder open fails")
    add("stopped", "real paused baseline settles", "actual worker reaches idle")
    add("repeat", "real paused baseline settles", "worker barrier entered", "worker barrier explicitly released",
        "concurrent and reentrant retirements complete", "only the first retirement receives its stable snapshot",
        "later retirements never duplicate the original receipt")
    for stage in ["concurrent", "reentrant", "closed"]:
        close(f"repeat {stage}")
    dispose("repeat")
    add("released-owner", "real paused baseline settles", "worker barrier entered",
        "in-flight retirement retains its worker owner", "worker barrier explicitly released",
        "final receipt survives caller releasing the session", "completed retirement releases its worker owner")
    close("released-owner")
    add("legacy", "completion stays on main", "original shutdown call remains source compatible")
    dispose("legacy")
    assert len(labels) == 148
    return labels


def expected_failures(mode):
    if mode == "none":
        return set()
    if mode == "drop-owner":
        return {f"{case}: {STALE}" for case in PENDING[:-1]}
    if mode == "allow-preroll":
        return {"preroll: actual pending seek preroll is not a resume point"}
    if mode == "drop-cancellation":
        return {"pending-commands: decoder cancellation is immediate before worker reset",
                f"pending-commands: {INTENT}"}
    if mode == "duplicate-callback":
        cases = STABLE + PENDING + ["preroll", "idle", "opening", "failed", "stopped", "released-owner", "repeat reentrant"]
        return {f"{case}: {CALLBACK}" for case in cases} | {
            "repeat: only the first retirement receives its stable snapshot"}
    if mode == "capture-after-reset":
        return {f"{case}: {suffix}" for case in STABLE for suffix in [IDENTITY, CLOCK]} | {
            f"pending-commands: {INTENT}", "repeat: only the first retirement receives its stable snapshot",
            "released-owner: final receipt survives caller releasing the session"}
    raise AssertionError("Unsupported negative control")


directory = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
text = (directory / "results.log").read_text()
rows = re.findall(r"^(PASS|FAIL): (.+)$", text, re.M)
assert rows and len(rows) == len({label for _, label in rows}), "Missing or duplicated checks"
assert {label for _, label in rows} == expected_labels(), "Exact check inventory mismatch"
summary = re.findall(r"^Resume session checks: (\d+) passed, (\d+) failed$", text, re.M)
assert len(summary) == 1, "Missing final summary"
assert tuple(map(int, summary[0])) == (sum(s == "PASS" for s, _ in rows), sum(s == "FAIL" for s, _ in rows))
assert (directory / "compile-status.txt").read_text().strip() == "0"
assert {label for status, label in rows if status == "FAIL"} == expected_failures(mode), "Unexpected failure set"
assert (directory / "execution-status.txt").read_text().strip() == ("0" if mode == "none" else "1")
print("Verified resume session contract")
