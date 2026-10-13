#!/usr/bin/env python3
"""Require the exact semantic failures produced by each single-variable control."""
import sys
from collections import Counter
from pathlib import Path

expected = {
    "deduplicate-plan": {
        "First native queue item reaches paused readiness",
        "Native projection preserves complete order and duplicates",
        "Manual navigation exposes draining intent instead of old snapshot",
        "Duplicate selection opens distinct native generation",
        "Real MPV readback preserves complete queue",
        "Real MPV selected duplicate is the third unique entry",
        "Real duplicate paths have distinct MPV entry IDs",
        "Unsupported fallback retains both prefix and suffix including repeated path",
        "Rotation compatibility action retains the complete real MPV queue",
    },
    "forget-eof-seek": {
        "Resume after accepted EOF seek does not issue a rewind",
        "Resume after accepted EOF marker seek does not issue another seek",
        "Accepted preview-cancelling seek adopts the current persistent playback intent",
        "Preview-cancelling seek can advance at EOF with pause-on-open",
    },
    "old-draining-toggle": {
        "Manual navigation exposes draining intent instead of old snapshot",
        "Second toggle restores draining pause intent",
    },
    "wrong-reopen-count": {"Explicit duplicate open reports full count while retiring the prior native selection"},
    "forget-eof-marker-seek": {
        "Resume after accepted EOF marker seek does not issue another seek",
    },
    "preview-pause-persistent": {
        "Temporary preview pause preserves the persistent playing queue intent",
        "Restored playing preview advances at EOF and honors pause-on-open",
    },
    "preview-resume-persistent": {
        "Temporary EOF preview resume preserves the queue generation and baseline",
        "Finishing temporary preview restores the paused EOF baseline",
        "Temporary preview does not consume the persistent terminal queue state",
        "Resume after finishing the EOF preview still performs ordinary replay",
    },
    "preview-pending-intent": {
        "Pause during capture still updates the persistent queue intent",
    },
    "preview-cancel-intent": {
        "Accepted preview-cancelling seek adopts the current persistent playback intent",
        "Preview-cancelling seek can advance at EOF with pause-on-open",
    },
    "auto-next-ignores-open-preference": {
        "Restored playing preview advances at EOF and honors pause-on-open",
        "Preview-cancelling seek can advance at EOF with pause-on-open",
        "Playlist repeat advances last real EOF and honors pause-on-open",
    },
    "stale-seek-eof": {
        "Accepted seek clears cached EOF before worker delivery",
        "Resume after accepted EOF seek does not issue a rewind",
    },
    "consume-stop-owner": {
        "Cancelled installation delegates stop with the exact retained owner",
        "Repeated stop preserves the owned keep-playlist stop protocol",
        "Background completion and repeated stop reuse one installation owner",
    },
    "missing-stop-prepare": {
        "Cancelled installation prepares event isolation before enabling MPV presentation",
        "Background-delayed stop prepares the event barrier before exposing the new route",
    },
    "rewind-reopens-session": {
        "Resume after finishing the EOF preview still performs ordinary replay",
        "EOF resume without an earlier seek rewinds the same queue item",
        "EOF replay seeks within the same media and Session identity",
        "EOF replay preserves volume and viewport",
        "EOF replay preserves the persistent A marker",
        "First previous preserves pause and clamps rewind to the existing A-B range",
        "First previous does not reload the current Session",
        "First previous retains both loop markers",
    },
    "stale-auto-advance-preference": {
        "Disabling automatic next during native playback is honored at actual EOF",
        "Enabling automatic next during native playback is honored at actual EOF",
    },
    "forget-pending-volume": {
        "Installation exposes latest owned volume and speed intent",
        "Loaded compatibility uses installation-time audio and speed intent",
        "Pending exact restore exposes the newest volume and speed",
        "Pending restore rejects nonfinite volume and speed without changing intent",
        "Owned compatibility accepts amplified volume and rates outside native limits",
        "Verified restore commits the latest volume speed unmute and UI values",
        "Cancelled installation first captures distinct audio and rate intent",
        "Volume UI synchronization preserves latest owned intent before restart",
    },
    "forget-pending-speed": {
        "Installation exposes latest owned volume and speed intent",
        "Loaded compatibility uses installation-time audio and speed intent",
        "Pending exact restore exposes the newest volume and speed",
        "Pending restore rejects nonfinite volume and speed without changing intent",
        "Pending restore preserves the existing minimum speed policy",
        "Owned compatibility accepts amplified volume and rates outside native limits",
        "Verified restore commits the latest volume speed unmute and UI values",
        "Cancelled installation first captures distinct audio and rate intent",
        "Delayed speed property cannot roll back owned presentation intent",
    },
    "forget-verified-audio-intent": {"Verified restore commits the latest volume speed unmute and UI values"},
}
expected = {mode: Counter(names) for mode, names in expected.items()}
expected["deduplicate-plan"].update({
    "Explicit duplicate queue is admitted": 1,
    "Explicit selection count remains intact": 7,
    "Explicit duplicate open reports full count while retiring the prior native selection": 1,
    "New explicit queue cancels prior pending selection and keeps all duplicate items": 1,
    "Reopened explicit queue installs its own complete native projection": 1,
})
mode, path = sys.argv[1:]
lines = Path(path).read_text().splitlines()
failures = [line.removeprefix("FAIL: ") for line in lines if line.startswith("FAIL: ")]
if mode not in expected or Counter(failures) != expected[mode]:
    raise SystemExit("Unexpected or missing negative-control failures: " + repr(failures))
print("EXPECTED NEGATIVE: " + mode + " (" + str(len(failures)) + " exact failures)")
