# Pending rotation intent tests

Run `bash Tools/VideoToolsRotationIntentTests/run.sh` from the repository root.
Optional `ROTATION_INTENT_SANITIZER=address` or `thread` selects a sanitizer.

The CLI compiles the production `VideoToolsRotationIntent` value directly. It
checks bounded modulo-four accumulation, immutable request/media identity,
same-path reopen, stale success/failure callbacks, cancellation, one-time
consumption and extreme integer inputs. Accepted net-zero sequences are delivered
as four quarter-turns, preserving the existing coordinator's 360-degree behavior.
The reported count includes 50,000 deterministic mixed-input stress iterations;
it is not a count of different player integration scenarios.

Two mechanically generated, single-change negative controls remove consumption
or the matching-request guard. Each must fail the unchanged four-check ownership
probe with exit status 1 and the expected failure label. The source implementation
must pass the same probe. Production files are not modified for these controls.

It also uses the production rotation coordinator with an external task boundary,
then runs the existing, unchanged `RotationCoordinatorTests.swift`. This verifies
that consuming intent does not replace the coordinator's cumulative export logic,
re-encode exported output, cancel completed work or replay a consumed request.

The helper is integrated into `PlayerCore` pending native-to-MPV rotation.
Its owner resets the logical media epoch on an explicit new open (including
the same URL), retain it only for its own compatibility reload, and cancel pending
intent on close or explicit user navigation. An internal restore seek exemption
must match the owned handoff ID, not merely any active compatibility transition.
The helper does not decide when a backend is ready, call player commands, replay
events, or start a real export. These tests are not proof that actual window
shortcuts, asynchronous preview restoration or complete backend handoff work.
`Tools/NativeRotationHandoffTests` separately exercises production integration
methods with explicit controlled service boundaries; full App validation is
still distinct.

No app bundle, window, personal media, preferences or installed app are touched.
The runner preserves compiler/test artifacts, base commit, mode and input hashes
under `build/`, including generated hashes and source-stability checks on failure.
