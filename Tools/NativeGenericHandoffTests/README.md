# Generic single-file handoff regression

This suite opens exactly one local synthetic clip with the opt-in native route.
It asserts that queue, permanent-rotation and URL-enqueue owners are absent.
Production Core methods are extracted by the existing Core queue generator;
the single-file `fileEnded` and `frameStep` methods are additionally extracted
verbatim. The typed keyboard command handler is also extracted from
`PlayerWindowController`; only its no-active-preview UI service is a boundary. Private
visibility is removed for inspection, not behavior. The actual decoder, Session,
native output, VideoView, MPV transport and independent libmpv handle are used.

Application services and MPV event forwarding are explicit boundaries. The
adapter can delay a real FILE_LOADED delivery, retaining its captured route
revision. It never manufactures native readiness, a captured snapshot or MPV
seek success. A bounded semaphore on the real Session worker controls capture
and retirement races. This is not a full-app/nib, production MPVController,
audible-output or displayed-pixel acceptance test.

Run `bash Tools/NativeGenericHandoffTests/run.sh`. `NATIVE_GENERIC_BUILD_ONLY=1`
builds without running AppKit. `NATIVE_PLAYBACK_SANITIZER=address` or `thread`
selects sanitizers. The runner preserves input/generated hashes, logs and status;
only generated synthetic media is used, with no app installation or networking.
The production default remains unchanged. Negative controls mutate generated
copies only and must fail the exact registered semantic assertions.

## Ownership contract and coverage

Generic single-file work has its own action UUID, media epoch, actual backend
route revision, and capture/retire/start/restore phase. A matching URL is an
additional check, never sufficient ownership. The first matching MPV start binds
the restoration to the real Core media generation. Reopening the same path,
stop, shutdown and end-file revoke the owner. The verified seek consumes the
owner before calling user code; its continuation rechecks epoch/route/generation.

The suite covers real capture/retire/load/seek cancellation with stop and
same-path reopen; held real loaded/restart delivery; an explicitly adversarial
replayed same-path start; source/track/file notifications and event reentry;
completion reentry opening a different file; actual native EOF and near-EOF;
latest volume/rate/pause/seek while restoring; and typed seek/rate versus busy
frame actions. It starts handoff through actual amplification/rate setters, not
only a direct compatibility request. A fresh worker query verifies supported
volume/rate changes survive capture cancellation. Unsupported values remain
owned by their compatibility action; cancelling that action does not attempt an
unsupported native write.

This is not a full App acceptance result. It does not exercise real screenshot
files, panels/nibs, an audible output, native pixel readback, arbitrary custom
MPV scripts, M4 hardware decode or the production MPVController event queue.
Other suites cover those independent boundaries. The test adapter delays actual
events but does not pretend to be the complete controller.

## Retained discovery evidence (2026-10-13)

All artifact names below are under `build/`; failures remain unchanged.

| Run | Result | Meaning |
| --- | --- | --- |
| `vr4d14` | compile failed | Initial no-enqueue fixture referenced a property it did not extract; replaced with its explicit nil/no-owner boundary. No playback ran. |
| `VSsNdw` | 96 passed / 4 failed | Actual setters reproduced old completion overwriting the latest volume/rate; retirement dropped a legal volume change. Core `9513da01`. |
| `l7RiJO` | 107 / 2 | Previous four fixed. New cancellation case proved capture staging alone lost supported volume/rate when pause cancelled the action. Core `396875d0`. |
| `W1U4rx`, `zHSC8A` | each 196 / 1 | Actual value `55.000001192092896` established Float-to-percent conversion, not a lost intent. Only this native volume assertion uses a `0.0001` percentage-point tolerance. |
| `nOpDaY` | 207 / 3 | Newly added one-shot worker query correctly returned unavailable during rate-change preroll. Fixture now retries real queries within its original five-second budget; no snapshot is manufactured. |
| `aN8B2A` | 210 / 0 | Actual fresh worker volume/rate verification passed. |
| `DDXugx` | 218 / 0 | Added actual typed-command extraction and busy keyboard behavior. Core `bbd871b4`, window controller `2fe43106`; source/generated hashes verified unchanged. |
| `rpmA43` | ASan 218 / 0 | Same final production and generated inputs; no AddressSanitizer diagnostics. |
| `oUxbJF` | TSan 218 / 0 | Same final production and generated inputs; no ThreadSanitizer diagnostics. |

These three passing final modes are independent executions, not additional
functional assertions. Negative controls below have their own verification
records and cannot be inferred from the positive runs.

## Exact generated negative controls

Each mutation changes a unique production-source landmark in its disposable
generated copy. `verify_negative.py` compares the complete failure multiset;
a crash, timeout, compilation failure or unrelated failed assertion is not an
accepted negative control. No production guard is disabled by the runner.

| Control | Intended regression |
| --- | --- |
| `forget-volume`, `forget-speed` | Discard the latest owned restore value. |
| `allow-busy-action` | Execute another compatibility action before restoration. |
| `old-volume-completion`, `old-speed-completion` | Replay the original unsupported request after newer input. |
| `reject-retiring-volume` | Reject legal same-owner input merely because the old decoder is stopping. |
| `drop-capture-native-volume`, `drop-capture-native-speed` | Keep supported capture-time input only in cancellable staging. |
| `accept-duplicate-start` | Treat another same-path start as the first expected start. |
| `drop-typed-seek`, `drop-typed-speed` | Lose standard keyboard input in the busy handoff gate. |
