# Native A/B control regression tests

This focused harness exercises the opt-in native playback A/B controls. It does
not enable native playback by default, build the complete application, or claim
that the full application has passed acceptance testing.

## Requirements and commands

Run from the repository root on Apple Silicon macOS with the Command Line Tools,
the repository's FFmpeg headers and dynamic libraries in `deps`, and an FFmpeg
executable that can generate the synthetic fixture. The runner targets macOS 12;
this is not a deployment-target or Intel compatibility test. It defaults to
`/opt/homebrew/bin/ffmpeg` unless `FFMPEG_BIN` is set.

`NATIVE_AB_BUILD_ONLY=1` stops after compilation without generating media or
executing playback. It can be combined with a negative-control selector to
check extraction/compilation, but does not prove the corresponding assertion.

```sh
FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativeABLoopTests/run.sh

NATIVE_PLAYBACK_SANITIZER=thread FFMPEG_BIN="$PWD/deps/executable/ffmpeg" \
  bash Tools/NativeABLoopTests/run.sh
```

Both commands must exit successfully with zero failed checks. The runner also
accepts `NATIVE_PLAYBACK_SANITIZER=address`; both the Objective-C decoder and Swift
code receive the selected sanitizer flags. Unsupported sanitizer values exit
with status 2. Sanitizer diagnostics must not be suppressed or treated as a pass.

Each run retains its generated source, binary, synthetic media, and `results.log`
in a unique ignored `build/native-ab-loop-tests.*` directory. The test executable
has a 60-second watchdog. A compile failure, timeout, or crash is not a successful
test result.

## Negative controls

These deliberately corrupt only the generated test copy of production controls;
they never modify the production source. Run separately from passing tests:

```sh
NATIVE_AB_NEGATIVE_CONTROL=stale-capture \
  FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativeABLoopTests/run.sh

NATIVE_AB_NEGATIVE_CONTROL=reentrant-cancel \
  FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativeABLoopTests/run.sh

NATIVE_AB_NEGATIVE_CONTROL=pause-intent \
  FFMPEG_BIN="$PWD/deps/executable/ffmpeg" bash Tools/NativeABLoopTests/run.sh
```

Each negative control must exit with status 1 and report the intended failed
assertion after successfully compiling and running the harness. An arbitrary
nonzero exit is insufficient evidence.

- `stale-capture` removes cancellation when an explicit clear or marker move
  supersedes queued captures. It must fail
  `Explicit clear invalidates marker state before delivering deferred cancellation`.
- `reentrant-cancel` delivers canceled callbacks synchronously instead of after
  clearing the command identity and queue. It must fail
  `Reentrant cancellation completes each request exactly once without leaving a queued action`.
- `pause-intent` replaces the worker-intent query with the old phase-only
  paused check. It must fail
  `Automatic A/B preroll preserves worker playback intent instead of reporting paused`
  and `Space during a real automatic A/B wrap pauses the worker`.

Additional failed checks can follow the deliberately broken invariant; the
positive run must still pass without either environment override.

## Scope and limits

The extractor copies the current `PlayerCore` A/B controls and selected
`PlayerWindowController` slider/knob methods mechanically. The native transport is
also copied mechanically so the pause-intent negative control can corrupt only
its generated copy. The harness compiles
the real `VideoToolsPlayerBridge`, native transport, decoder, sample gate,
sample-buffer output, and playback session. A short SDR FFV1 video with silent
PCM audio is generated locally; no user media, browser data, preferences, or
permission settings are read or changed.

Covered behavior includes optional A = 0, ordered asynchronous captures, invalid
B rejection, canceled/reentrant callbacks, generation changes, explicit seek
cancellation, marker visibility and invalid-drag rollback, preservation of the
file-loop preference, timestamp bounds over repeated A/B loops, and the real
`togglePause` command during automatic loop and explicit seek preroll. It verifies
worker playback intent separately from decoder/output phase, rapid pause/resume
commands, new-media paused/muted state, and menu error/cancellation feedback. Compatibility
restoration of markers is checked against an explicit MPV property sink.

Application services, slider objects, the MPV property sink, and test open/close
entry points are controlled boundaries. They are not the real application
lifecycle. These tests do not certify actual nib loading, physical keyboard or
notification delivery, MPV playback restoration, rendered pixels, audible audio,
seamless loop presentation, performance, M4 hardware decoding, or a full-App
native route. Those need the separate lifecycle/transport tests and real-App,
target-machine acceptance. Enqueued samples are not proof of displayed frames.
