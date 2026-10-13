# Real MPV queue installation tests

This suite exercises the independent `MPVQueueInstaller` against the bundled
`libmpv`. It does not enable native playback, modify the Xcode project, install an
application, or prove complete-window integration. All media are generated in an
owned `build/mpv-queue-installer-tests.*` directory. The real client uses `vo=null`
and `ao=null`; no rendered pixels or audible output are claimed.

## Run

```sh
env PATH=/usr/bin:/bin:/usr/sbin:/sbin bash Tools/MPVQueueInstallerTests/run.sh
env PATH=/usr/bin:/bin:/usr/sbin:/sbin NATIVE_PLAYBACK_SANITIZER=address bash Tools/MPVQueueInstallerTests/run.sh
env PATH=/usr/bin:/bin:/usr/sbin:/sbin NATIVE_PLAYBACK_SANITIZER=thread bash Tools/MPVQueueInstallerTests/run.sh
```

The default fixture encoder is `/opt/homebrew/bin/ffmpeg`; `FFMPEG_BIN` may name
another installed FFmpeg. The shell runner otherwise uses system tools, including
`/usr/bin/grep`, rather than requiring `rg`. Every test binary has a 75-second watchdog.
Source hashes, generated source/fixture hashes, exit statuses, and logs remain in
the owned directory, including when compilation or an assertion fails. A changed
source hash cannot produce a successful runner exit.

## Contract under test

- Admission requires an empty, idle real MPV playlist and a current installation
  owner. Every append has a real command status and a full playlist-node readback.
  Duplicate URLs remain separate entries with distinct actual MPV entry IDs.
- Append work is limited to eight commands per `advance()`. Installation has a
  ten-second monotonic deadline. Cleanup has a separate two-second deadline and
  checks ownership and elapsed time after external calls and before new commands.
- A receipt requires the selected real `START_FILE` and `FILE_LOADED`, a successful
  activation command status, the exact entire ordered list, selected entry ID,
  current path, and paused state. Acceptance or a command return alone is not a
  successful installation.
- Failure/cancellation uses `stop keep-playlist` and clears only a verified owned
  prefix. Foreign contents, lost ownership, missing statuses, shutdown, or expired
  cleanup remain explicitly unverified; they are never reported as cleaned.
- Each completion is consumed before invocation. Reentrant reads/commands cannot
  replace an existing operation or publish a cancelled/stale success.
- Actual old START/END events retained in the real MPV event queue cannot be
  applied to a subsequent installation. `FILE_LOADED` is associated with the real
  preceding START entry ID, copied before test hooks or further event reads.

The suite additionally covers 1/2/3/256 entries, selected-first/middle/last,
append/activation/pause/stop/clear failures, nonexistent files, cancellation at
multiple stages, synchronous owner replacement, foreign playlist mutations,
withheld/late loaded events, real shutdown, and controlled queue-overflow delivery.
The overflow case injects the typed event; it does not claim to exhaust MPV's real
event queue. Deliberately malformed event cases are separate from success proof.

## Exact negative controls

Each control mechanically removes exactly one protection from a private copy of
the production installer. The verifier requires the exact named failures, not
merely a nonzero exit:

| Control | Required failures |
| --- | ---: |
| Deadline gate | 14 |
| Activation acknowledgment | 2 |
| Loaded-readback cancellation gate | 1 |
| Current-owner gate | 2 |
| Old END entry-ID gate | 2 |
| Full-prefix validation | 1 |

The frozen installer `17a555f5db5e5654019ff8e2ad0ddabd423ce15d824b2e8d62cbb4c1a9ef10be`
passed 191 positive checks in ordinary, AddressSanitizer, and ThreadSanitizer
runs. Each mode also produced exactly the six expected negative-control failure
sets, with no sanitizer diagnostic. Evidence directories: ordinary `BS7e3M`,
AddressSanitizer `pjrJ0W`, ThreadSanitizer `Lve9IB` (all share the
`build/mpv-queue-installer-tests.` prefix). These runs precede the runner-only
addition that preserves hashes on failed exits; they do not prove later Core
integration. Earlier failed runs are retained rather than overwritten.

The final runner-only evidence-preservation change was then checked with another
ordinary 191/0 run plus all six exact negatives (`gO2qPJ`). A deliberately missing
fixture encoder (`02IZof`, exit 1) and invalid sanitizer (`H9NA2V`, exit 2) retained
their failure statuses, before/after source hashes, and any generated fixture
hashes without being treated as passing test runs.

## Required production integration boundaries

An empty/idle snapshot does **not** prove that an MPV handle has never played
media or has no old event backlog. Core must retain its pristine-media-command
admission and event/handle epoch gates. The installer is not yet connected to Core.

The eventual event bridge must copy START/END entry IDs immediately on the MPV
worker, and freeze the preceding START ID for FILE_LOADED before any external
callback. It must also capture the installation owner and reject stale envelopes
on the receiving main queue. Never attach the current operation to old events at
delivery time. Hook continuation, logging, and shutdown must not be suppressed by
media-presentation gating.

The backend must preserve MPVController command accounting. A missing command
callback/handle is failure, not status zero. Playlist writers must cooperate with
the single main-owned installation executor; no long-held playlist lock is needed.
Synchronous MPV calls cannot be preempted by these deadlines. The checks prevent
subsequent commands and late success after a call returns; they are not a
hard-real-time guarantee, and callers must schedule `advance()`.

A successful receipt proves list installation, not playback-state restoration.
Core must still restore the selected file's position, pause intent, volume, rate,
A/B range, and viewport, avoid AutoFileMatcher mutating the installed list, and
confirm restoration before delivering a pending action. Model-only `verified`
flags or controlled test boundaries cannot replace that real receipt.
