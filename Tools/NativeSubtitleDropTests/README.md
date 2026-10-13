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
