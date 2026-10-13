#!/usr/bin/env python3
"""Require the complete registered semantic failure set, never any nonzero exit."""
from collections import Counter
from pathlib import Path
import sys

owners = ["generic", "rotation", "enqueue", "queue"]
phases = ["capture", "retire", "loaded", "seek"]
def attachment_failures(kind):
    return ([f"{owner}-{phase} rejects a busy {kind} attachment" for owner in owners for phase in phases] +
            [f"{owner}-{phase} attachments issue no MPV commands" for owner in owners for phase in ["loaded", "seek"]] + [
                "rotation-capture attachments preserve the existing owner and route",
                "rotation-capture original action completes after restoration",
                "queue-capture attachments preserve the existing owner and route",
                "Queue prefix rejects both busy attachment types",
                "Queue prefix attachments issue no MPV command",
                f"Inventory rejects a {kind} attachment",
                f"Inventory {kind} issues no idle MPV command",
            ])

expected = {
    "early-invalidation": [
        "Subtitle-only admission preserves the retiring owner",
        "Busy retiring drop preserves owner and route",
        "Original retiring action completes after verified restoration",
        "Rejected subtitle drop leaves the original media loaded instead of idle",
        "Rejected subtitle drop retains the original volume and clock",
    ],
    "allow-busy-subtitle": attachment_failures("subtitle") + [
        "Busy retiring subtitle drop is explicitly rejected",
        "loaded busy subtitle drop is explicitly rejected",
        "loaded busy subtitle drop performs no MPV command",
        "seek busy subtitle drop is explicitly rejected",
        "seek busy subtitle drop performs no MPV command",
    ],
    "allow-busy-lut": attachment_failures("LUT"),
    "reject-new-media": [
        "Actual new-media drop remains accepted during handoff",
        "Actual new media invalidates the old owner",
        "Actual new-media drop loads the replacement",
        "Only the explicit single new-media drop requests folder matching exactly once",
        "Actual new media cancels the old compatibility action",
    ],
    "remove-inventory-gate": [
        "Inventory rejects a subtitle attachment",
        "Inventory subtitle issues no idle MPV command",
        "Inventory rejects a LUT attachment",
        "Inventory LUT issues no idle MPV command",
    ],
}
name, log = sys.argv[1:]
if name not in expected:
    raise SystemExit(f"Unregistered subtitle negative control: {name}")
lines = Path(log).read_text().splitlines()
case, checks = {"early-invalidation": ("retiring", 22), "remove-inventory-gate": ("inventory", 9)}.get(name, ("all", 408))
if [line for line in lines if line.startswith("CASE: ")] != [f"CASE: {case}"]:
    raise SystemExit("Unexpected or missing negative-control case")
if [line for line in lines if line.startswith("RESULT: ")] != [f"RESULT: {checks} checks, {len(expected[name])} failures"]:
    raise SystemExit("Unexpected or incomplete negative-control result")
actual = [line.removeprefix("FAIL: ") for line in lines if line.startswith("FAIL: ")]
if Counter(actual) != Counter(expected[name]):
    raise SystemExit(f"Unexpected failure set: {actual}")
if len([line for line in lines if line.startswith(("PASS: ", "FAIL: "))]) != checks:
    raise SystemExit("Incomplete assertion output")
for kind, command in [("subtitle", "sub-add"), ("lut", "vf")]:
    if name in [f"allow-busy-{kind}", "remove-inventory-gate"]:
        if f'DIAGNOSTIC: inventory {kind}Commands=["{command}"]' not in lines:
            raise SystemExit("Missing actual idle-MPV attachment command")
    if name == f"allow-busy-{kind}":
        for owner in owners:
            for phase in ["loaded", "seek"]:
                if f'DIAGNOSTIC: {owner}-{phase} attachmentCommands=["{command}"]' not in lines:
                    raise SystemExit("Missing actual partial-MPV attachment command")
print(f"PASS: exact subtitle negative control {name}")
