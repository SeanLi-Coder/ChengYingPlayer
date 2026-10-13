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
`NATIVE_PLAYBACK_DEPS` can select an isolated candidate dependency tree. The
default remains repository `deps`; the shared verifier checks all nine playback
libraries, SDK headers, install names, architectures, signatures and dependency
closure, rejects loader overrides, and verifies the same identities after execution.
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
  prefix after every current/playing entry has retired. Idle and missing path
  alone cannot acknowledge cancellation while a lifecycle hook still holds the
  playback worker. Foreign contents, lost ownership, missing statuses, shutdown,
  or expired cleanup remain explicitly unverified; they are never reported as cleaned.
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
| Cleanup unload barrier | 4 |
| Initial real IDLE fence | 1 (focused 6-check run) |

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

## Subsequent CI failure and bounded diagnostics

Development CI `38337569102` at `e4369f41` passed the ordinary 191 checks and six
negative controls, but its ThreadSanitizer positive run failed one of 191 checks:
`partial: current-owner cancellation verifies empty idle cleanup`. There was no
sanitizer race report. The original evidence remains at
`build/native-ci-38337569102.GQRT14/queue/mpv-queue-installer-tests.sKaHFN`.
The failure has not yet been reproduced locally or attributed to production or
the test harness; later passing runs do not close it.

The real client now retains a bounded 40-event trace of command return values and
actual playlist IDs/flags on failure. It does not log media paths, manufacture
readiness, retry failed assertions, or lengthen deadlines. A focused stress mode
can exercise up to 500 fresh real-client partial cancellations:

```sh
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" \
  MPV_QUEUE_PARTIAL_CANCELLATIONS=200 NATIVE_PLAYBACK_SANITIZER=thread \
  bash Tools/MPVQueueInstallerTests/run.sh
```

With that candidate tree, 200 cancellations produced 600 checks/0 failures
(`FtLwVq`). Full ordinary (`mAHRe0`), ASan (`jlKCQb`) and TSan (`pm09SF`) runs
each produced 191/0 and all six exact negatives. After moving the initial hash
collection behind the failure-evidence trap, final TSan (`8IDtyH`) again passed
191/0 and six exact negatives; missing encoder (`wfT6yq`) retained exit 1 and
before/after evidence. These directories share the prefix above. Source, generated
files and verified dependency identities remained unchanged. The production
installer itself was not changed to obtain these results. CI now collects the
bounded trace and a separate 200-cancellation run rather than hiding the prior
failure or treating a successful rerun as a fix.

## Lifecycle-hook cleanup barrier

Installer `ed5d25f9bfbbc534bf643d0fa0f91ce6c40f348c2248526b396c774a262cb5a4`
adds a current/playing retirement check before `playlist-clear`. Real
`on_before_start_file` and `on_after_end_file` hooks demonstrate that MPV can
already report idle with no path while its current entry and worker remain
inside a lifecycle hook. Each test holds the actual MPV hook, confirms no clear
or terminal acknowledgement occurs, releases the hook, and then verifies empty
cleanup. The original 191 assertions remain; these tests add 16 assertions.

Final ordinary (`NBPC1S`), ASan (`fGBBdQ`) and TSan (`NIgukp`) runners each passed
207/0 against the isolated `build/native-av1-playback.7FMHum` dependency tree.
The original six negative controls still run the full 207 checks and retain
their exact 14/2/1/2/2/1 failure sets. The new `cleanup-unload` control removes
only the retirement predicate and runs the focused 16-check hook suite; exactly
four named failures are required. It is not a claim that this new control runs
all 207 checks. All three final runners exited 0, with no sanitizer diagnostic
and unchanged source, generated-artifact and verified dependency identities.
Evidence directories share the `build/mpv-queue-installer-tests.` prefix.

An earlier ASan run (`etaauG`) passed its positive 207 checks and original six
controls, but the initial full-suite `cleanup-unload` control also failed
`Actual activation command error is not reported as loaded`, in addition to the
four expected hook failures. The exact verifier rejected the extra failure and
the runner exited 133. This evidence remains intact. The new control was then
limited to its hook scenarios; no original assertion or deadline was relaxed.
Activation-cleanup failures now include the existing bounded command/snapshot
trace. The extra ASan failure is not attributed to a unique cause, and this
hook-specific fix does not establish the cause or resolution of CI's earlier
191/1 partial-cancellation failure. These tests do not exercise complete-window
integration or establish the Controller's separate event-drain guarantee.

## Required production integration boundaries

An empty/idle snapshot does **not** prove that an MPV handle has never played
media or has no old event backlog. Core must retain its pristine-media-command
admission and event/handle epoch gates. Controller integration is committed and
Core integration is under verification; this standalone suite does not prove it.

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

## Initial idle-loop fence and CI evidence

Frozen development CI `38381002473` (`0455ab7c`) failed its ordinary positive
run at `Actual activation command error is not reported as loaded` (207/1,
`jMKL1y`). Its separate TSan 200-partial-cancellation run failed iterations
50/80/156/164 (600/4, `tw1TEx`), without a sanitizer report. Both original runs
are retained in `build/native-ci-38381002473-queue.pDioB2/`. Their bounded traces
show an exact owned list, idle and paused, no path or playing entry, but a
persistent first `current` entry. Complete-App 92+54 passing assertions do not
override these independent failures. Later local unchanged-source runs
`jbyp4M`, `1oN7ct` (207/0 and seven controls) and `APCnnD` (600/0) did not
reproduce or close the failures.

In the pinned MPV 0.38 source, `mpv_initialize` returns before the worker enters
`mp_play_files`. Its `prepare_playlist` can select the first newly appended entry
while the initial `PT_STOP` remains set. `stop keep-playlist` does not remove that
selection, and idle-loop execution need not pass through normal file-retirement
cleanup. Startup preparation can also overwrite an early non-first activation.
This sequence explains the observed state and supports a conservative startup
fence; the CI logs alone do not prove that exact interleaving occurred. The older
191/1 failure remains separately recorded above, not retrospectively resolved.

The backend now requires real initial `MPV_EVENT_IDLE` evidence before the first
append. Controller records this handle-lifetime fact atomically on its event
reader, before native/stop presentation gates. Installer waits within its
original ten-second budget; owner, shutdown, overflow, cancellation and the
separate two-second cleanup protocol remain intact. In pinned 0.38 this event
occurs after startup playlist preparation. This is a version-specific ordering
dependency, not a generic promise of MPV's deprecated IDLE API. An MPV upgrade
must recheck it. No current/playing unload predicate was removed.

The dedicated six scenarios retain an actual initial IDLE before acknowledging
it to the backend. They prove no append/activation before acknowledgement,
actual selected START/path after release, and bounded timeout/cancel/supersede/
overflow/shutdown semantics with no late mutation of a subsequent owner's real
replacement. Overflow/shutdown in these waiting scenarios are typed installer
event injections; their existing real lifecycle cases remain separate. This
does **not** hold the MPV worker before `prepare_playlist` and is not a
deterministic replay of the CI interleaving. A prior Lua gate attempt (`KG2W0h`)
compiled but exited 133 at setup because this distribution disables scripting
(`scripts` returned -5); it produced no startup behavior evidence. Its original
files and logs remain in that owned build directory. Draft compile failure
`rZ2CYC` is also retained.

The original 207 assertions start after actual IDLE readiness. Their six
original controls still run all 207 checks; `cleanup-unload` still runs 16/4.
The new `initial-idle` control removes only the production append fence and runs
the focused selected-last scenario, requiring exactly 6 checks/1 named failure.
The verifier now also requires the complete declared check count and summary.
The 200-cancellation mode explicitly requires eight actual appended entries
before each cancellation, so startup waiting cannot silently turn this into an
empty-list cancellation test. No existing deadline or assertion was relaxed.

Final installer SHA-256
`546115800bb54a895f3411bd2963e8ec099feca6913d8b8748db0da1d3c18511`
passed ordinary `Diy3Q1`, ASan `frYcbo`, and TSan `119MmG`: 253/0 positives,
all eight exact controls, and runner exit 0. TSan `fCkrU3` separately passed
200 actual eight-entry partial cancellations (600/0, runner 0). All four share
source-manifest SHA-256
`ad1a7e5a7dc66d4c42de8e91a9242a65da016c021e65c825c768b8c28f10eb14`
and verified dependency-manifest SHA-256
`9e6e108fbbf90d6da7a47728047f15da747b2042385cfe8463dbb9a73c97f25c`.
Source/generated/dependency postchecks passed, with no sanitizer diagnostic.
These are local conservative-fence regression results, not proof of the exact
historical CI scheduling interleaving or a substitute for the next same-source CI.
