# Complete native playback application checks

`run.py` builds and runs a disposable, uniquely identified application only on a
GitHub-hosted macOS runner. It rejects local execution. The driver is included
only under `CHENGYING_NATIVE_APP_TESTS`; no test code is enabled in the release
executable. User media, browser data, installed application bundles and the
release preferences domain are not used.

The runner generates bounded SDR H.264/AAC fixtures and an embedded-subtitle
compatibility fixture in an owned disposable workspace. App startup validates
the run marker, file types, ownership and matching unique bundle identifier.
Cleanup uses the repository's managed test workspace. An assertion, process
timeout, incomplete report or cleanup failure cannot become a passing result.

## Preparation and execution

Local preparation (CLI probes and synthetic media only, not the complete App):

```sh
python3 -B Tools/NativeAppTests/test_runner.py
```

The existing CI build invokes the complete runner with its own paths:

```sh
python3 -B Tools/NativeAppTests/run.py \
  --source-packages /ci/source-packages \
  --report-directory /ci/unique-report-directory \
  --production-app /ci/assembled/ChengYing.app
```

The illustrative `/ci/` paths must be replaced by the existing workflow's
validated build outputs. Do not spoof the CI environment to execute this against
an installed app. Declaration-only `TypecheckBoundary.swift` is used solely for
local macOS 12 typechecking, never linked into the complete application.

## Loaded native-to-MPV handoff addition

The candidate requires 92 distinct successful checks: all previous 75 labels
remain required, plus 17 loaded-handoff checks. This is a prepared test candidate,
not evidence that the complete 92-check App has already passed.

After the original core has loaded the embedded-subtitle compatibility fixture,
the driver obtains another pristine core. It confirms that this core is not the
original, has no MPV media path or rendering context, and opens the existing
nine-second red/green/blue synthetic file through the native route.

The new core remains paused. Production bracket-key handling establishes A=0 and
B=5.5; an exact worker query and the displayed green sample verify position 4.2.
The real volume slider sets 37%, the speed menu sets 1.25x, and production viewport
keys select 1.5x with normalized pan `(+0.05/1.5, -0.05/1.5)`. Before handoff,
actual native worker state, visible markers and attached Surface geometry must
match these non-default values.

The real `menuChangeAudioDelay` action with `+0.25` triggers compatibility. The
driver never calls `requireMPVCompatibility` with a synthetic completion. It
requires all of the following:

- The same PlayerCore, local file and visible NSWindow survive the handoff.
- The captured native display layer is detached; native Session/Output/Surface
  references are gone and the real MPV rendering context has been initialized.
- Direct libmpv queries show position 4.2 within the production restore tolerance,
  paused playback, 37% volume and 1.25x speed; the actual volume slider also agrees.
- Direct libmpv viewport values equal `log2(1.5)` and the original normalized pan.
  A remains an enabled numeric zero, B remains 5.5, and loop count remains `inf`;
  the real slider's visible markers must agree.
- Actual `audio-delay=0.25` proves the deferred production menu action executed
  after restoration. A nonzero return from `sendAction` alone does not pass this.
- State and paused position stay stable for another 0.2 seconds.
- Real window close stops MPV. A subsequent explicit Core shutdown receives its
  genuine shutdown event and releases the rendering resources. Close alone is
  not incorrectly assumed to destroy the reusable MPV context.

The original two-active-core application-quit scenario then runs unchanged.
Its all-registered-cores shutdown check also includes the additional core, which
has already independently completed teardown.

## Evidence boundaries and deadlines

Post-handoff properties are read from the real MPV core, not from the retired
native model. They prove state restoration and same-window resource ownership;
they do not prove MPV physical-screen pixels, HDR color accuracy, audible sync,
arbitrary multi-track handoff or target-M4 hardware decoding. Native green-frame
readback uses the actual paused display buffer, not enqueue counts.

The 110-second driver deadline and 150-second process deadline remain unchanged.
Every recorded stage prints total elapsed time; the new handoff stages also print
their own elapsed time. Actual disposable-CI execution is required to establish
the total runtime. Partial reports are preserved on failure, and a timeout is a
failure, not permission to silently extend or disable the deadlines.

Preparation tests preserve the exact original label set, reject every missing
required check, typecheck against macOS 12, exercise the real numeric/geometry
comparators with wrong-state inputs, and retain the AppKit termination scheduling
positive/negative probe. These preparation checks are not a substitute for the
full application run.

The preparation boundary retains the production `MainWindowController!` type
instead of silently strengthening it to a nonoptional value. A diagnostic must
unwrap this property before storing a local alias. The preparation suite also
compiles the exact unguarded alias as a negative control; the macOS 12 typecheck
must reject it. This protects test-driver compilation, not window behavior.
