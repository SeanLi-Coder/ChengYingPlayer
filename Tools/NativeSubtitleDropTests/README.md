# Native attachment admission and handoff regression

This standalone suite exercises the production `openURLs`, `openMediaURLs`,
complete file-list drop method, attachment admission getter, subtitle loader,
filter creation/application, generic/rotation/enqueue/queue owners and restore
methods. Only private visibility is removed for inspection. It uses the actual
native decoder, Session, transport, VideoView, an independent libmpv handle,
real subtitle/filter commands and private AppKit pasteboards. No full app is
installed or launched, and no user media or preferences are opened.

The existing generic and Core queue generators provide application/UI services
and explicit MPV event forwarding. Real FILE_LOADED and PLAYBACK_RESTART events
may be held with their original route revision. Queue events are delivered to
the real queue installer until ownership returns to Core. Image-window UI,
filter preset UI, track metadata presentation, hardware-decoder prompts and
non-file-list drags are explicit out-of-scope boundaries, not fake successful
operations. The fixture does not claim to exercise production MPVController,
subtitle rendering pixels, AppKit drag animations or audible output.
Folder matching is an explicitly counted application-service boundary. Only
the single new-media case authorizes one request for its synthetic `blue.mp4`;
the adapter verifies the current URL, auto-load intent and actual test preference
values, consumes that authorization, and records exactly one request. Any other
request traps. It does not run folder discovery or fabricate sibling/subtitle
insertion; those behaviors belong to the existing folder-playlist suites.

## Running

```sh
python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_PLAYBACK_SANITIZER=address python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_PLAYBACK_SANITIZER=thread python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_BUILD_ONLY=1 python3 Tools/NativeSubtitleDropTests/run.py
```

The default is the complete 408-check suite. `NATIVE_SUBTITLE_CASE=retiring`,
`NATIVE_SUBTITLE_CASE=attachments` and `NATIVE_SUBTITLE_CASE=inventory` are subsets and must not be
reported as a complete positive run. The opt-in native policy and default MPV
route are unchanged. Only generated, silent local SDR clips, a synthetic SRT
and an identity LUT are used.

The runner derives its compilation/linking recipe from the existing generic
runner, retains the expanded driver, and hashes every recipe, production,
fixture and library input. It records source-before/source-after comparison,
generated Core/transport/service/adapter/driver/media hashes, compiler output,
test output, child/tee exit status and final runner status. A build-only success
does not claim any executed playback checks. Sanitizer diagnostics, crashes,
timeouts, source drift and an unexpected negative failure set all fail the run.

## Contract

An empty or rejected non-playable input is not a new media request. It must not
revoke a generic handoff owner. A subtitle or LUT attachment is rejected while
capture, retirement, installation or restoration is busy, independently of
whether the current transport still reports native. A genuinely new media
drop must still cancel the old owner and load its replacement.

An immediate drop in the same main-thread turn as a real native candidate open
also covers pending inventory admission: the MPV route is disabled and the
native transport does not exist yet. Both attachments must be rejected without
an idle-MPV command, and the original native admission must still complete.
The suite covers all four owner kinds across capture, retirement, real held
loaded delivery and the verified-seek wait, plus a real queue append prefix
before activation. It checks unchanged owner/route and absence of actual MPV
commands, then releases the existing work and requires successful completion.
Independent normal native and settled MPV subtitle/LUT drops must create a real
MPV subtitle track or an actual `iina_quickl3d` filter. The original retirement reproduction also checks preserved
volume and media time. New-media replacement has a separate positive case.

Worker barriers use the existing five-second bounded worker wait, an explicit
two-second phase wait, and assertions that the worker is waiting before and
after the controlled operation, is released successfully rather than timing
out, and exits. Native readiness after seek is confirmed through a fresh real
worker query within the original five-second budget, not cached UI state.

## Retained discovery evidence

All paths below are under `build/`; failed output is retained unchanged.

| Artifact | Result | Interpretation |
| --- | --- | --- |
| `native-subtitle-drop.vZIJlN` | 16 checks / 6 failures | Initial fixture did not reach retirement: a seek was still in preroll and the worker barrier prevented capture retry. Not accepted as the claimed retirement reproduction. |
| `native-subtitle-drop.PJXTe1` | 17 / 6 | Core `14d8d140`: a fresh real worker snapshot and actual retiring/stopping preconditions passed. Subtitle-only admission revoked the owner; shutdown reached idle and the original media never loaded into MPV. The final fixture adds stronger barrier release-result checks. |
| `native-subtitle-drop.EoXIfY` | 254 / 41 | Separate adjacent-gap reproduction after the initial generic-only fix, Core `17b804df`: busy LUTs and non-generic subtitles reached partial MPV, including successful real `vf` commands. All explicit barrier entry/wait/release-success/exit assertions passed. This is not a final-suite positive result. |
| `native-subtitle-drop.euGW0F` | child 133, tee 0 | First complete run reached an inherited explicit-queue-only folder-matcher boundary during genuine new-media admission. This crash is not a passing run. |
| `native-subtitle-drop.4YwLBI` | child 133, tee 0 | A proposed disabled-service boundary correctly trapped because the inherited automatic-playlist preference is actually enabled. The final boundary instead authorizes and counts only the one expected ordinary-media service request; it does not silently disable the preference or change the original queue fixture. |
| `native-subtitle-drop.kuAD4p` | 9 / 4 | Core `f5a3df8a`, after the handoff-phase fix: a real open followed immediately by drops reached idle MPV during inventory (`sub-add` and successful `vf`). The actual pending-inventory precondition and subsequent native admission both passed. |
| `native-subtitle-drop.MwLmr9` | 382 / 0 | Earlier positive fixture before the final LUT and inventory cases; not the final execution identity. |
| `native-subtitle-drop.JZhW5a`, `.2GtAKD`, `.48ArVy` | 399 / 34, 399 / 29, 399 / 33 | Exploratory subtitle-gate, LUT-gate and early-invalidation controls exited child 1, but the deliberately unregistered verifier rejected them. They are retained observations, not accepted final controls. |

Initial compiler/fixture-development artifacts are retained as well; they are
not counted as playback evidence. The older `NativeDropRoutingTests` suite is
also retained: all original 104 checks remain, with four native/MPV busy
attachment cases adding twelve checks (116 total).

## Exact generated negative controls

Set `NATIVE_SUBTITLE_NEGATIVE_CONTROL` to `early-invalidation`,
`allow-busy-subtitle`, `allow-busy-lut`, `reject-new-media` or
`remove-inventory-gate`. Each mutates one
unique production landmark in the generated copy only. The verifier requires
normal child exit 1 and the complete registered failed-assertion multiset;
nonzero alone is not success. In particular, the missing attachment gates
must expose real partial-MPV commands, not merely a different drag return value.
The verifier also requires the exact case, total assertion count and one complete
result line. The runner automatically selects the original 22-check retirement
case for `early-invalidation` (exactly five failures), and the nine-check
inventory case for `remove-inventory-gate` (exactly four failures). These are
targeted negative runs, not full-suite positives. The other three controls run
all 408 checks. No deadline or positive assertion is relaxed for a control.

```sh
NATIVE_SUBTITLE_NEGATIVE_CONTROL=early-invalidation python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=allow-busy-subtitle python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=allow-busy-lut python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=reject-new-media python3 Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=remove-inventory-gate python3 Tools/NativeSubtitleDropTests/run.py
```

## Final frozen verification

All final runs use the same 57-input `source-before.sha256` manifest, SHA-256
`994dc3ce338350418445b1a849a766a3037c40691b3508c8f2711f5e4699164d`.
Its production Core is
`fbbc0af832e9525d1ad96ede021bcf6000f28362499cb7f775906d074b6c5c46`
and DraggingDetect is
`bda1fc35092fdc3bf954fcda0a5c3309b2bc8808cf4c3a6803928a7a288b0306`.
The README is descriptive and is not a compiled input. Every artifact retains
the full manifest and the generated-copy checksums rather than only these two
production hashes.

| Mode | Artifact suffix | Checks / failures | Child / tee / runner | Approx. seconds |
| --- | --- | --- | --- | --- |
| Normal | `VizmOm` | 408 / 0 | 0 / 0 / 0 | 16 |
| ASan | `xV8jC5` | 408 / 0 | 0 / 0 / 0 | 19 |
| TSan | `mco2oW` | 408 / 0 | 0 / 0 / 0 | 21 |
| Early invalidation, retirement only | `jnwQUb` | 22 / 5, exact | 1 / 0 / 0 | 24 |
| Missing subtitle gate | `08GtaI` | 408 / 36, exact | 1 / 0 / 0 | 25 |
| Missing LUT gate | `AuafNg` | 408 / 31, exact | 1 / 0 / 0 | 25 |
| Incorrect rejection of new media | `Wf9MJ9` | 408 / 5, exact | 1 / 0 / 0 | 26 |
| Missing inventory gate, inventory only | `pTVk3Q` | 9 / 4, exact | 1 / 0 / 0 | 13 |

Artifact paths use `build/native-subtitle-drop.<suffix>`. Source-before/after
is identical and all generated-file validations pass. Sanitized positives
contain no sanitizer diagnostic. Counts denote actual executed assertions;
accepted negative runs intentionally retain every expected `FAIL` line.

## Non-deferred media actions during handoff

The additional `NATIVE_SUBTITLE_CASE=actions` suite has **406 checks**, separate
from the unchanged default 408 attachment checks. It extracts the complete
production `toggleMute` and `frameStep` methods and the screenshot admission /
owned-handoff prefix. Screenshot export/clipboard presentation is a counted
boundary: this suite does not create screenshots or prove their pixel contents.

Inventory, all four owners at capture/retire/loaded/seek, and an actual queue
append prefix must reject these actions without changing the real MPV mute
flag, issuing real forward/backward frame commands, admitting screenshot export,
or cancelling the existing owner. After release, the original operation must
still complete. Six separate settled native/MPV cases require the same methods
to remain usable, with actual mute readback/frame commands, one screenshot
boundary delivery and the original real media path after restoration.

Before the production guards, `95G3mE` ran 353 checks with 52 failures (before the
53 settled-action checks were added). Core was `fbbc0af8`; source/generated
identities remained unchanged and child exited 1. Actual frame-step commands
during inventory initialized MPV rendering early and prevented native admission.
Busy rotation could also be cancelled by the old `frameStep` implementation.
This is retained failure evidence, not a successful negative-control run.

Each new guard is the first line of its production method, before any owner
mutation or compatibility request. The pre-existing admission getter still
allows settled native and MPV operation and rejects partial ownership/termination.
Negative controls `busy-mute`, `busy-frame-step` and `busy-screenshot` remove only
that method's guard from a generated copy and run all 406 action checks. Required
failure counts are exactly 11, 18 and 29, with full case/count/multiset/child-exit
validation and actual MPV command/mute or screenshot-boundary diagnostics.

Final Core is
`c0c69a4a99b0fd92a4bedda2aa86f453ca77a4f73b9073c477697004323a94e1`.
The following artifacts share source manifest SHA-256
`545985af672827dce3981e3f4b8a0fb1c7d100a02320384ff77f168d715df93b`:

| Scope | Artifact suffix | Checks / failures | Runner exit |
| --- | --- | --- | --- |
| Actions normal | `rDqkAf` | 406 / 0 | 0 |
| Actions ASan | `9Cl4n6` | 406 / 0 | 0 |
| Actions TSan | `ZSCUDj` | 406 / 0 | 0 |
| Original complete attachment regression | `wle1B8` | 408 / 0 | 0 |
| Missing mute guard | `vLpvjn` | 406 / 11, exact | 0 |
| Missing frame-step guard | `yVyice` | 406 / 18, exact | 0 |
| Missing screenshot guard | `n9amKy` | 406 / 29, exact | 0 |

All source-after/generated checks pass; positive children exit 0, negative
children exit 1 and tee exits 0. No sanitizer diagnostic was observed. Initial
exploratory controls `qBJAeV`, `aB5opc`, `5kPR4E` were correctly rejected while
their exact failure sets were unregistered; `aB5opc` also records verifier source
drift during development. They are not substituted for the final runs above.
The original 408-check sanitizer and five-control results remain tied to their
earlier `fbbc0af8` source; this table does not relabel them as current-source runs.

```sh
NATIVE_SUBTITLE_CASE=actions python3 -B Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_CASE=actions NATIVE_PLAYBACK_SANITIZER=thread python3 -B Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=busy-mute python3 -B Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=busy-frame-step python3 -B Tools/NativeSubtitleDropTests/run.py
NATIVE_SUBTITLE_NEGATIVE_CONTROL=busy-screenshot python3 -B Tools/NativeSubtitleDropTests/run.py
```

### Shared extractor follow-up

The standalone Generic regression subsequently failed compilation in `nIIZs8`:
the newly extracted gate referenced `hasPendingURLPlaylistEnqueue`, which that
focused no-enqueue boundary did not expose. The shared generator now extracts
the real production accessor against the existing nil-only, fail-fast enqueue
service. Audio avoids extracting it twice; Subtitle removes the separate accessor
before inserting the actual enqueue implementation. No production or assertion
was changed to fix this fixture integration failure.

Final same-source reruns use manifest
`8c3e07f8b61bfc84f680141ac182f7b4bee37af95e31980ff5809b82fd346b3d`:
normal actions `JhkugU`, ASan `5ByvNO`, TSan `BiJGKC` each 406/0; default
attachments `m5ZzPw` 408/0; exact controls `FjdqZa` 406/11, `vCkxoH` 406/18,
`KmclQL` 406/29. All final runners exited 0, source/generated checks passed and
the positive sanitizer logs are clean. The original Generic suite `w1GNPh`
also passed 218/0, Audio `IRkJEA` 90/0, Window `M6DV70` 208/0 and CoreQueue
`bkZiPh` 206/0. These latter suites have their own input manifests. The earlier
table remains valid for its own frozen extractor, not silently relabelled.
