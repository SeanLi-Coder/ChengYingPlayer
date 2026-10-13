# Standalone native queue state model

This candidate is deliberately **not** connected to PlayerCore, Session, MPV,
the Xcode project, default admission, or a release. It proves only bounded value
state decisions. A model completion marked `verified` is not real playlist
installation evidence.

```sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin bash Tools/NativePlaybackQueueTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativePlaybackQueueTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativePlaybackQueueTests/run.sh
bash Tools/NativePlaybackQueueTests/run_mpv_probe.sh
```

## Contract

- `NativeQueuePlan` preserves explicit order, including duplicate URLs with
  distinct item UUIDs. It accepts 1...256 local non-directory URL values and at
  most 1 MiB aggregate encoded URL bytes. It does not read files, resolve aliases,
  enumerate folders, grant access, or probe media eligibility.
- `NativeQueueState` is a single-owner value model. A plan replacement and stop
  invalidate its epoch. Each selection/reload/rewind creates a new media
  generation, including reselecting the identical URL/item. UInt64 counters use
  checked increments. It is not a lock, actor, or cross-thread storage primitive.
- Load completion checks media identity without overwriting newer pause intent.
  Natural EOF checks the same identity and is consumed once. Pause before a
  delayed current EOF records `ended` without advancing; explicit resume returns
  a rewind request, and another later pause still wins its completion.
  The integrating transport must first reject stale Session seek revisions;
  queue media identity does not authorize relabelling a pre-seek EOF as current.
- File repeat rewinds; ordinary automatic advance follows the list; playlist
  repeat wraps. Disabling automatic advance stops on EOF, except explicit file
  repeat. The model does not implement the App's EOF window-closing behavior.
- At a manual first-previous boundary, the model requests a rewind. At a manual
  last-next boundary, off/file pause without changing selection, while playlist
  mode wraps. For actual new-file loads, the Core adapter must explicitly map its
  opening preference and later user intent. The model does not simulate AppKit
  `notifyWindowVideoSizeChanged`, audible output, or a paused-preroll resume.
- Handoff snapshots include the complete ordered plan and selected item/index.
  `beginHandoff` checks epoch, generation, revision and live snapshot contents,
  consumes before effects, and issues an installation owner token. Native
  selection is explicitly busy while installation is in progress. New open/stop
  invalidate old acknowledgements. Latest pause/repeat/auto-advance changes are
  retained while installing; completion returns their latest values.
- The external installer must retire native, check **every actual MPV command**,
  read back the actual list/current item, and only then call verified completion.
  Failure retains the plan in `handoffFailed`; it never silently resumes native.
  Retry requires a fresh checkpoint and owner token. No MPV transaction, partial
  installation recovery, timeout, or transport capture has been implemented here.
  Exact position/volume/speed/viewport/A-B restore needs its separate real
  transport snapshot and user-intent fence; this model cannot replace it.

## Tests and negative controls

The 150 deterministic checks run the real standalone model, not a policy copy.
They cover count/byte limits, stable identities/order, invalid replacement,
latest opening intent, same-URL generations, EOF/mode combinations, both EOF-pause
orders, stale/duplicate callbacks, revision ABA, consume-before-effects,
installation-time intent, explicit failure/retry, stop, and replacement.

Each run also removes exactly one guard/change in an isolated source copy:
checkpoint revision checking (exactly 4 failures), generation advancement
(exactly 7 failures), or EOF token validation (exactly 1 failure). All three must
exit 1 with the complete named failure set; positive tests must exit 0. Logs,
source snapshots, and before/after hashes remain in the printed owned directory.
Sanitizers here do not prove concurrent access safety: mutations are intentionally
single-owner. Runners use only standard system tools, not `rg`.

Candidate SHA-256
`33c5ef9281e9027e052d0d4c24fdeaa4f9075e5570b78cc68b5b08c67dc268cd`
passed 150/0 in normal, AddressSanitizer, and ThreadSanitizer modes on 2026-10-13.
Each mode also produced exactly 4/7/1 negative-control failures with exit 1; each
overall runner exited 0, with unchanged source hashes and no sanitizer report.
All used the system-only PATH shown above. Evidence under `build/`:

| Mode | Directory |
| --- | --- |
| Normal | `native-queue-model-tests.1xpUCE` |
| AddressSanitizer | `native-queue-model-tests.t6fEOf` |
| ThreadSanitizer | `native-queue-model-tests.nouke6` |

## Real MPV boundary observation

`run_mpv_probe.sh` mechanically reuses `LiveMPV` from
`Tools/PlaybackModeLiveTests/main.swift` and extracts the actual production
`PlayerCore.navigateInPlaylist` body. It runs synthetic files with `vo=null` and
`ao=null`, isolated configuration, no window or private media. The current Core
pre-navigation pause is real; URL/rotation cancellation services are explicitly
empty because this MPV-only probe owns no such transactions.

At the last of two entries, the 2026-10-13 observation was:

| Repeat | MPV next return | Item after action | Pause | New FILE_LOADED |
| --- | --- | --- | --- | --- |
| off | -12 | Last | true | 0 |
| file | -12 | Last | true | 0 |
| playlist | 0 | First | true | 1 |

The probe passed six checks in `build/native-queue-mpv-probe.9maVvm`, with
unchanged source hashes. It does **not** exercise the subsequent real window
resume policy. The earlier probe failure in `native-queue-mpv-probe.l8uevX`
was a test wrapper incorrectly making `checkError:false` fatal; the wrapper now
records the actual result just as the production call requests. The earlier
model's universal last-next no-op assertion was changed to the observed behavior,
not accepted as existing App behavior based only on the MPV manual.
