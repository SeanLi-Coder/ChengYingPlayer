# Native Core queue integration

Run `bash Tools/NativeCoreQueueTests/run.sh`. Optional modes:

- `NATIVE_PLAYBACK_SANITIZER=address` or `thread`.
- `NATIVE_QUEUE_NEGATIVE_CONTROL=deduplicate-plan`, `forget-eof-seek`,
  `old-draining-toggle`, `wrong-reopen-count`, `forget-eof-marker-seek`,
  `preview-pause-persistent`, `preview-resume-persistent`,
  `preview-pending-intent`, `preview-cancel-intent`,
  `auto-next-ignores-open-preference`, `rewind-reopens-session`,
  `stale-seek-eof`, `consume-stop-owner`, `missing-stop-prepare`,
  `stale-auto-advance-preference`, `forget-pending-volume`,
  `forget-pending-speed`, or `forget-verified-audio-intent`.

The runner synthesizes local H.264/AAC red/blue clips and a multi-audio clip in a
unique run directory. It preserves source/dependency hashes, generated-code and
fixture hashes, compiler output, test output and exit status, including failures.
It does not open user media, install an app, change user preferences or contact
the network. The process has a 120-second watchdog. The production default is
unchanged: the run explicitly enables `CHENGYING_NATIVE_PLAYBACK=1`.

## Real components and explicit service boundaries

`prepare.py` mechanically extracts production `PlayerCore` queue admission,
selection, EOF, pause/resume/seek, compatibility capture, retirement, installation,
`fileStarted`, `fileLoaded`, `onVideoReconfig`, and `playbackRestarted` methods.
It also extracts production `PlaybackInfo.state` and uses the actual queue model,
installer, transport adapters, decoder, Session, output, surface and VideoView.
The private-access modifier is removed for inspection; normal-mode function
bodies are otherwise unchanged. Negative controls alter one unique production
expression in the generated copy, never the repository source.

Installation commands, return codes, playlist NODE snapshots, entry IDs,
START_FILE/FILE_LOADED/PLAYBACK_RESTART events, pause and playback positions come
from a real independent libmpv handle. The test controller's event forwarding is
an explicit service boundary, not the production MPVController. The separate
`PlaybackBackendRoutingTests` cover that production controller bridge. The test
does not use the standalone installer's mocked receipt to complete Core.

Application services, preferences, history, subtitle matching, track-list/UI
notifications, and final rotation export are controlled boundaries. The generated
track-list boundary emits the actual notification name synchronously to expose
reentrancy. Rotation tests verify delivery only, not encoding/export. `MainWindow`
is a double holding an actual AppKit window and production VideoView, with no
`orderFront` or key-window acquisition. No real nib, menu event, AppleEvent,
speaker output, final displayed pixels or full application termination is claimed.
The separate complete-App tests must verify those application-level routes.

The cancelled-installation stop service is a controlled boundary: it records
the exact owner and issues real `stop keep-playlist`, but the test explicitly
delivers the terminal service acknowledgment. Core's duplicate-stop and
background-task/pending-open transitions are real extracted methods. This is
not proof that a held MPV hook has drained or that production event barriers
are correct; `PlaybackBackendRoutingTests` exercises that production protocol.

## Covered contracts

- Explicit ordered local lists preserve repeated paths and stable presentation
  identities; unsupported containers still use the original capability gate.
- Typed next/previous/selection use real native sessions and no idle-MPV loads.
- Repeated toggles during retirement use the new item intent, not the old frame's
  paused state; rapid selection gives the latest request ownership.
- Actual final-file EOF, seek-away/resume, replay-without-seek, native file-repeat
  and native playlist-repeat have one owner and never append to idle MPV.
- Same-item rewind is a real seek on the existing Session, preserving volume,
  viewport and A/B markers; first-previous preserves pause and clamps to A/B.
  Actual new items, including automatic next, honor `pauseWhenOpen`; later user
  intent still wins. Tests cover both values of that preference.
- Setting B at actual EOF consumes only the accepted real seek back to A, so
  resume keeps the media generation and both markers. Temporary clip previews
  preserve the persistent queue baseline: preview-local pause/resume does not
  consume EOF or overwrite a playing baseline. Finishing restores EOF replay or
  actual playing/automatic-next behavior. Cancelling a capture before its baseline
  exists still records the user's persistent pause intent.
  A public seek cancelling an established preview adopts the transport's actual
  intent for future queue EOF. Accepted seek clears the cached EOF immediately;
  rejected seek does not. A worker-observed real EOF callback held on main is
  rejected by the production Session revision gate after an accepted seek.
- Compatibility installs the complete ordered list, verifies distinct MPV IDs
  for repeated paths and the selected duplicate, and waits for actual precise
  position restoration before delivering the pending action.
- Installation-time pause/seek intent survives; mutable-list writes and navigation
  cannot alter an owned prefix or the selected duplicate before restore completes.
- The automatic-next preference is read at actual EOF, including changes in both
  directions after admission. Installation and exact-restore volume/rate changes
  are retained by their same-media owner, not sent to a partial backend. The real
  verified backend receives the latest value, including explicit amplification,
  unmute, and rates outside native limits. Nonfinite input and the existing speed
  floor retain their original policy. Delayed UI synchronization uses that intent;
  cancellation and replacement discard it.
- Partial-install stop invalidates the installer and event owner; synchronous
  source/track notifications cannot resurrect the old queue or completion.
- A pending permanent rotation still accumulates while its one whole-queue
  transition is in flight, and delivers the total only once after restoration.
- Every newly opened native item and compatibility load starts at volume 0 unless
  the user explicitly changes the owned handoff's volume. Synthetic audio is
  silent even when these tests exercise nonzero volume properties.

## Production integration boundary

`PlayerCore.openMediaURLs` admits only an explicitly validated 2–256-item local
video selection with `CHENGYING_NATIVE_PLAYBACK=1` and a pristine MPV handle. The
same plan determines both asynchronous return count and eventual installation;
repeated URLs remain separate items even while a previous native session retires.
Ordinary directory expansion and mixed input continue on the compatibility route.
Stream count, subtitle, HDR, pixel geometry, advanced configuration, plugin and
previous-MPV-use admission gates are retained.

`PlayerCore` owns the main-thread model, item generation and installation receipt.
`nativeQueueOwnsPlaylist` is the atomic read gate for legacy mutation callers.
Native next/previous/exact selection and EOF use Session revision plus captured
queue media identity. Global file-repeat remains Session-owned; list-repeat is
queue-owned. The native playlist projection preserves object identity but does
not invent MPV entry IDs.

The existing compatibility action performs one real full-list installation on
the untouched MPV handle, verifies its selected actual entry, commits normal
file lifecycle once, and restores transport before delivering its action.
Synchronous source/track/file notifications recheck ownership before continuing.
Source replacement and stop invalidate pending callbacks; pause and seek update
the same-media restore while editing/navigation are rejected until it completes.
Volume and rate restoration here covers explicit queue, rotation and URL enqueue
owners. A generic single-file compatibility action without any such owner remains
a separately identified migration gap; URL equality is not treated as ownership.
Keyboard next/previous enter the typed Core path; sidebars and unsupported menu
actions still require full-list compatibility. No native editor is implied.

The new fixed-list path does not implement native playlist editing, folder
enumeration, automatic sibling discovery, audio/subtitle switching or HDR support.
The existing sidebars/menu actions transfer the whole queue to compatibility;
editing/navigation are rejected while that bounded handoff is busy. A failed
installation does not report success or deliver its action; reopening is the
available recovery UI. Existing installer cleanup timing failures remain separate
release gates and are not resolved by this integration test.

## Recorded candidate runs

The following 87-check runs are historical, before review found same-media
rewind, automatic-next preference, preview-intent and stop-cancellation defects.
They are not evidence that the current integrated candidate passed.

Production Core SHA-256:
`84f79683231266dcf59d402279b37420fb017ae12ce6ad7009c762d713b4196d`.
Queue SHA-256:
`81a1b73dd67d10255bd075ca06b5cdd2cc19139b28d684127578dbcdf9ca94c0`.

- Normal: `build/native-core-queue-tests.lQ7Z09`, 87 checks / 0 failures.
- AddressSanitizer: `build/native-core-queue-tests.ILVfRg`, 87 / 0.
- ThreadSanitizer: `build/native-core-queue-tests.wW15HN`, 87 / 0.
- Deduplicated-plan control: `build/native-core-queue-tests.xj6Pbu`, exactly
  9 expected failures, child exit 1.
- Missing-EOF-seek control: `build/native-core-queue-tests.c3qvrC`, exactly
  1 expected failure, child exit 1.
- Old-draining-intent control: `build/native-core-queue-tests.RK1qds`, exactly
  2 expected failures, child exit 1. An earlier `6pJurO` run preserved the same
  two failures but its wrapper expected the wrong toggle label and exited 1;
  only that label was corrected. No production fix or assertion was removed.

`verify_negative.py` independently checks the complete expected failure sets,
rejecting extra, missing or duplicate failures. It was also applied to all three
preserved negative results above. The final runner invokes it automatically and
requires child exit 1 and no sanitizer diagnostics.

All recorded source/dependency hashes stayed unchanged during each run, with no
sanitizer reports. Earlier `Dz06kQ` retained a real 10-failure discovery: legacy
file enumeration deduplicated explicit selections before native admission. The
native plan now preserves validated original input order; legacy enumeration is
not changed. No complete-App or public release result is implied by these runs.

## Integration-review regressions

The preserved `vaSeKP` run reproduced eight actual semantic failures: temporary
preview cancellation lost the queue's playing intent; replay recreated the
Session and discarded persistent state; first-previous changed paused playback
and lost its interval. The model/adapter now distinguish new-item load from
same-media seek. New-item auto-advance uses the opening pause preference, and
explicit seek cancelling a preview adopts the accepted transport intent.

`LkfFQl` retained 167 passing / 2 failing checks while the adapter still exposed
cached EOF after accepting a seek. The adapter now masks EOF only while that
accepted seek is pending; invalid seeks retain EOF, and later real EOF becomes
visible again. The original transport regression also passed 145/0 normally
(`BROJG9`) and under TSan (`hDfmFJ`).

`TrKpJS` retained 183/1: the marker test compared a cached pre-seek revision
because Core's paused UI state and pending target were insufficient to prove
worker completion. It now waits for the real transport snapshot's paused phase
and A timestamp before comparing revisions, with the original time/position
limits. No production behavior was changed to satisfy that observation.

Earlier ordinary Core candidate `98ff0c4cf304201eb481f40a14b80ff23d7a654a5d80986358a62272937714f7`
passed 186/0 in `build/native-core-queue-tests.SwHtXq`, including current-owner
stop preparation before exposing a new route, repeated stop ownership, and a
background-delayed stop followed by a queued replacement. The runner's own
exit status and all source/dependency/generated integrity checks were 0. A
separate outer zsh display command incorrectly assigned its reserved `status`
variable after the runner completed; that shell error is not silently presented
as a successful wrapper.

The first seven expanded negative runs in `native-core-queue-negative-suite.FtodaF`
also failed the unrelated delayed-EOF setup observation. They are preserved and
were rejected by the exact-failure validator, not counted as successful controls.
The observation formerly slept for 0.55 seconds and issued one worker query with
a one-second wait; it now observes actual worker output in the same total
1.55-second budget while main remains blocked, so no main callback can be consumed
early. There is no synthetic EOF injection or extended deadline.

`u5y6I9` then reproduced five new regressions (194 pass / 5 fail): both live
automatic-next changes and three stale handoff audio/rate checks. `3uKEs2` passed
199/0 after the minimal fix, before the extended finite/bounds/replacement and UI
checks. The first real UI-method extraction (`kBl4mX`) failed compilation because
the test retained its old `syncVolumeFromMPV` service stub; the stub was removed
and the actual production method is now compiled. No production check was removed.

Latest frozen Core SHA-256:
`a30bcd0004517da6e55bd6cef80140d6f875dc7ad8269c3e53c7fa30b10297dc`.
Ordinary `build/native-core-queue-tests.8TH6bc`, AddressSanitizer `RD4anl`, and
ThreadSanitizer `HRuQt2` each passed 206/0, exit 0, with matching
source/dependency/generated hashes and no sanitizer diagnostics. Expanded
negative-control results are pending; the earlier 87/0 results do not verify this source.
Full App, new default routing, and release validation remain outside this result.
