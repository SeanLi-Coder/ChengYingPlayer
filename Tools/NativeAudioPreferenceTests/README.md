# Audio-device preference routing

This fixture extracts the complete production `MPVController.observeValue`, its
audio-device preference scheduler, the actual preference-pane action/popup and
`PlayerCore.canSelectAudioDevice`. It uses real `UserDefaults` KVO, real AppKit
popup controls, the production atomic shutdown flag and production `Atomic`/`Lock`.
Each process owns a unique defaults suite, removed before normal exit. It never
reads or changes the installed player's defaults or launches an application bundle.

The `PlayerCore.setAudioDevice` service is an explicit delivery recorder: it does
not fabricate successful compatibility restoration, playback or physical sound.
The pre-existing `NativeAudioDeviceTests` separately checks the real Core method,
native Session and libmpv route. Neither fixture verifies an external speaker or
audible device switching. Global preference tests include two live cores,
off-main KVO, inventory, pending restoration, latest-value coalescing, native
request continuation, shutdown-before-UI delivery and controller destruction.

```sh
python3 -B Tools/NativeAudioPreferenceTests/run.py
python3 -B Tools/NativeAudioPreferenceTests/run.py --sanitizer address
python3 -B Tools/NativeAudioPreferenceTests/run.py --sanitizer thread
python3 -B Tools/NativeAudioPreferenceTests/run.py --negative direct-observer
python3 -B Tools/NativeAudioPreferenceTests/run.py --negative drop-ui-guard
python3 -B Tools/NativeAudioPreferenceTests/run.py --negative drop-inventory-guard
python3 -B Tools/NativeAudioPreferenceTests/run.py --negative drop-shutdown-guard
python3 -B Tools/NativeAudioPreferenceTests/run.py --negative retry-native
```

`--build-only` compiles without executing AppKit. Compilation has a 60-second
deadline, execution 20 seconds. A timeout kills only the fixture's own process
group. Compiler failures, sanitizer diagnostics, source/generated-file changes,
unexpected assertion sets or wrong child exits cannot count as negative success.
Every run preserves the actual compile/child/final exits and before/after hashes;
negative controls mutate generated copies only. Every positive run requires the
fixed complete 31-check label set, exactly one 31/0 summary and child exit 0.
Controls require the same 31 unique checks and respectively 18, 3, 2, 1 and 2
specific assertion failures and child exit 1. An empty early-success process is
not accepted. Only a single weak delayed work item is retained per controller.

## Evidence

Initial fixture compile `0n83n9hp` failed because two extracted methods lacked
a separator; `6gdpvzjs` compiled after fixing the generator only. Initial KVO
run `vcbpwmck` used a volatile initial default, so the first event had `NSNull`
old value and was ignored by the old production guard. It is not proof of the
first native delivery. After seeding the isolated suite before observation,
`vyarf7w0` produced **6 passed / 12 failed** from 18 checks against Core
`fbbc0af8` and Controller `42adfdc2`, with unchanged source/generated identities.
Native and idle cores both received direct observer MPV writes instead of Core
delivery; busy, inventory and terminal states also received direct writes.

Initial repaired observer `9c92e298` produced `3937uy0f` **18/0**. The final
candidate `7afa7834` adds the already-existing atomic reader-shutdown guard.
Expanded preliminary run `qk3qkmhh` was **25/0**. The first UI negative generator
`u8eb8pjg` incorrectly cut the multiline `allSatisfy` closure and did not compile;
its failure is retained, not accepted as a behavior control. The generator now
requires the exact end-of-guard landmark. Final same-source verification is
recorded below when complete; no full App or physical-output claim is made.

Review identified an automatic retry loop: a real Core capture timeout discards
its owner while leaving native playback alive. The original preference scheduler
would issue another handoff and repeat the timeout/OSD cycle. `eddc1ht0` uses real
KVO and an explicit Core cancellation boundary to reproduce repeated deliveries
from that scheduler (**27/1**); it does not claim to have induced a real Session
timeout. The new request flag is set before calling Core, allows only one native
attempt for each changed preference and resets for a new request or cancellation.
After failure the saved preference remains, the existing Core error stays visible
and a single warning is logged; no extra automatic OSD or repeated native request
is issued. A successful MPV transition still receives the latest saved value.

`ocez6ttg` / `ax5yvnvr` / `b_mbcn__` (ordinary / ASan / TSan) each retained a
**29/1** result when a test incorrectly expected equal-value `UserDefaults.set`
to emit another KVO event. The actual Foundation implementation emits none.
This is recorded as an invalid test assumption, not repaired by changing system
semantics. Final tests explicitly assert no equal-value event and separately
verify that a different selected value creates a fresh, bounded request. Merely
reselecting the saved preference is not promised to retry. Opening the next media
honors the saved non-default device via the existing compatibility-admission gate.

### Final frozen evidence

Controller `4af2e24de31130e033782dd371ba3027d052ae956001aa000bfac6e31b21d26d`,
Core `c0c69a4a99b0fd92a4bedda2aa86f453ca77a4f73b9073c477697004323a94e1`:

| Mode | Artifact suffix | Passed / failed | Child / validator / runner |
| --- | --- | --- | --- |
| Ordinary | `t3a1lzvj` | 31 / 0 | 0 / 0 / 0 |
| ASan | `wbpopkdz` | 31 / 0 | 0 / 0 / 0 |
| TSan | `kxsc2qpc` | 31 / 0 | 0 / 0 / 0 |
| `direct-observer` | `o3d1sit9` | 13 / 18 | 1 / 0 / 0 |
| `drop-ui-guard` | `eg8fdh4x` | 28 / 3 | 1 / 0 / 0 |
| `drop-inventory-guard` | `shd4wlyd` | 29 / 2 | 1 / 0 / 0 |
| `drop-shutdown-guard` | `t5d8mk__` | 30 / 1 | 1 / 0 / 0 |
| `retry-native` | `njfvsidt` | 29 / 2 | 1 / 0 / 0 |

Artifacts are under `build/native-audio-preference.<suffix>`. All eight runs have
the same compiled/test source manifest, SHA-256
`5f9813f5e6de3ca62ed4a3dd041e7d672424558046e2ab4f3446cdcc05a4562f`;
before/after source identity, generated Swift and executable identity, compiler
success, exact result validation and final exits were independently rechecked.
README is not a compilation input. No sanitizer diagnostic was accepted.

The unchanged existing real Session/libmpv device suite separately passed 90/0
in `build/native-audio-device.b1Uvqx` against Core `c0c69a4a`, including synchronous
idle startup, generic/queue device actions and cancellation/same-URL reopen.
That suite does not extract this new KVO observer; it is complementary evidence,
not a claim that the KVO-to-physical-output end-to-end path or full App passed.
Later unrelated shared-extractor adaptations are verified separately by the
integrating agent. No installed App, user audio settings, release or defaults
were changed by these tests.
