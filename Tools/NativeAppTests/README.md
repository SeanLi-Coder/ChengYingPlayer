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

Add `--include-queue` to also execute the separate 47-check queue scenario using
the same test build. The default still executes only the original 92-check
scenario. Both processes must succeed when the flag is present. The queue run
gets its own UUID, fixture marker and `queue/{app.log,result.json,summary.json}`;
it cannot overwrite or satisfy the baseline report. The disposable bundle is
still identified by the original build UUID. Both fixture roots must prove the
same managed workspace ownership, and the bundle's preferences remain isolated
from the installed application.

Both processes record and recheck SHA-256 inventories for the main App sources,
assets, build configuration and dependency headers, the actual built disposable
App bundle, and their own fixture/marker files. Source identity is first fixed
before the build; the queue process must match the same source and product
inventories as the baseline. Added, removed or changed inventoried inputs fail
the run. `process-status.json` retains the actual exit or timeout independently
of result validation; final identity checks also run on process failure/timeout.
`*-identity-validation.json` and `*-sha256{,-after}.json` remain diagnostic
artifacts. Only the outer summary can declare success after managed workspace
cleanup; a successful process alone does not prove successful cleanup.

The illustrative `/ci/` paths must be replaced by the existing workflow's
validated build outputs. Do not spoof the CI environment to execute this against
an installed app. Declaration-only `TypecheckBoundary.swift` is used solely for
local macOS 12 typechecking, never linked into the complete application.

## Loaded native-to-MPV handoff addition

The candidate requires 92 distinct successful checks: all previous 75 labels
remain required, plus 17 loaded-handoff checks. CI run `38329363769` at `7f7e4bcc`
executed the candidate: 66 checks passed and the close/detach check failed.
The later compatibility and quit stages were not executed. Test App cleanup
completed. This is not evidence that the complete 92-check App has passed.

Subsequent CI run `38337569102` at `e4369f41` passed 70 checks. It proved the
previous close/detach assertion and initial embedded-subtitle fallback, but
failed `handoff_native_paused_red_ready` approximately two milliseconds after
opening the new core. The driver's paused-wait helper rejected a nil Session
before its bounded poll began, despite production inventory being asynchronous.
The loaded handoff and final quit stages were not executed; application build
and owned cleanup succeeded. The candidate now waits for the first actual
Session within the original twelve-second deadline, then pins both its identity
and the media generation before every query and callback. It does not substitute
a ready flag, relax pixel/clock conditions, or adopt a replacement owner.

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

## Independent native queue candidate

The opt-in second process uses only the existing bounded synthetic fixtures and
public production commands. It does not construct, mutate or reflect private
`NativeQueueState` storage. This is a candidate test, not an already passing
complete-application result.

The first pristine Core opens `[red, blue, red]` with `openMediaURLs`. Duplicate
paths must remain distinct stable playlist objects. Next, previous and explicit
selection of the second red entry must present the expected real paused display
buffer and position zero. The real volume slider sets 37% before transitions;
each new item must reset actual worker volume and the slider to zero. Same-turn
resume/toggle/pause commands during retirement must leave the new item paused,
verified by two real worker clock queries.

Near-end seeks avoid sleeping through entire clips without replacing real EOF:
off mode must end paused on the last entry; seeking the ended item to 4.2 then
resuming must advance from that target, not rewind. File repeat must wrap the
same duplicate entry; list repeat must wrap to index zero. Playing positions are
queried from the real worker, never accepted from the UI's cached position.
Paused wrap images and volume are checked again. A new single-file open issued
during a queued selection must cancel the old queue, detach its layer and remain
on the replacement blue file after another 0.2 seconds.

A newly opened queue then selects duplicate index two, sets A=0/B=5.5 through
real bracket keys, pauses at green position 4.2, and applies the same nondefault
37%/1.25x/viewport state as the baseline handoff. The real audio-delay menu must
install the entire queue into MPV, preserve its selected duplicate, apply the
deferred delay, and restore transport, viewport and A/B values in the same
window. One actual `MPV_NODE` snapshot must contain the complete ordered paths,
distinct nonnegative IDs, and exactly the correct current and playing entry.
Native layers/resources must be detached. These MPV state reads are not a
claim of post-handoff physical-screen pixel verification.

After independently closing and shutting down that Core, a second pristine Core
opens `[red, embedded-subtitle, blue, red]`. Selecting the unsupported subtitle
item must install the whole ordered queue in real MPV, select index one, retain
paused position zero and silence, and detach the prior native layer. This Core
also closes and shuts down. The actual application termination notification must
find both expected Cores and every registered Core fully shut down. The baseline
process's separate two-active-Core quit scenario remains unchanged.

Each process independently retains the original 110/150-second limits; the flag
does not extend either. Every stage prints elapsed time. Actual complete-App
execution is CI-only, and is still required to establish timings and outcomes
for these new 47 assertions. No default backend, media export, download, user
file, installed App or permission configuration is changed by this harness.

## Focused asynchronous paused-wait probe

This optional local CLI probe compiles the actual driver wait/pixel/comparator
methods with real Session/Output/Decoder and a small owned AppKit display window.
It is not a complete App, nib, menu or PlayerCore test. Its narrow boundary maps
ready state only from actual worker snapshots; no test-created ready snapshot is
injected. Fixture audio is silent.

```sh
NATIVE_PLAYBACK_DEPS=/absolute/verified/dependencies \
  bash Tools/NativeAppTests/run_paused_probe.sh
```

The default dependency path is the repository's `deps`; an override is verified
by the shared native dependency helper without replacing that directory. Source,
generated fixture/source and dependency manifests are checked again on exit,
including failing controls. Logs and actual exits are retained under the printed
`build/native-app-paused-wait.*` directory. The normal case delays real Session
creation by 120ms and requires a genuine paused image/clock. Additional cases
reject replacing the pinned Session or changing its media generation. A
single-variable old-first-session-guard control must fail before Session
creation, and both modes must clean up all decoder/output resources and their
owned CLI window. This addresses the observed immediate test failure; it does
not establish that the complete loaded handoff has now passed.

Local focused evidence before the final queue-key focus setup:
`build/native-app-paused-wait.07yI8I` passed delayed real acquisition in 0.322s,
Session-replacement rejection, generation-change rejection and full cleanup.
Its exact old-guard control exited 1 in under 0.1ms with
`PROBE_EXPECTED_EARLY_REJECTION: true`. Source/generated/dependency post-checks
passed. The wait helper itself is unchanged by the later queue-key focus setup;
the final candidate is rechecked before commit. Preparation suite
`build/native-app-queue-preparation.DYu9hr` passed 42 tests, including the existing
73 pixel/volume, 46 Surface geometry and 20 handoff numeric assertions plus 30
new actual queue-node comparator assertions. Those are preparation/focused
results, not complete App 92 or queue 46 success claims.

Final driver SHA-256:
`4e030500deab00a0d98fd24efbd760e9dda29a697fdfd06f848bbe8ea3db6c17`.
Its focused evidence is `build/native-app-paused-wait.XFSltk`: real delayed
acquisition passed in 0.576s; both ownership rejection checks and cleanup passed;
the old-guard control exited 1 after about 0.07ms with the exact early-rejection
marker. Source/generated/dependency identities matched after both runs. Final
preparation output and seven-file pre/post manifests are retained separately at
`build/native-app-queue-final.trDWRE`. These local checks do not run the complete
application or the 46 new queue assertions.

The subsequent opening-preference correction retains the baseline 92 checks
and adds one queue check (47 total). Playlist wrap now requires the new first
item to remain paused at position zero without sending a test pause command,
matching `pauseWhenOpen=true`. A separate natural EOF advance sets that
preference false and requires the next item's actual blue frame and advancing
worker clock, then restores the isolated argument-domain preference. A file
loop remains a same-media operation and must keep playing. The preparation
suite passed 43 tests for driver SHA-256
`2749e03ee67293973092a7d8f04f528d97ef9e5e5c8634c8288da6c790df0516`;
the complete 92/47 App scenarios remain unexecuted for this revision.

The preview-close check captures a nonoptional real output layer before closing
the window. Its bounded diagnostic records preview/session/output ownership,
whether that captured layer still has a parent, native surface mode and GL
initialization. An absent output cannot accidentally satisfy a detach check.
No filename, user path or media data is included in that diagnostic.

The preparation boundary retains the production `MainWindowController!` type
instead of silently strengthening it to a nonoptional value. A diagnostic must
unwrap this property before storing a local alias. The preparation suite also
compiles the exact unguarded alias as a negative control; the macOS 12 typecheck
must reject it. This protects test-driver compilation, not window behavior.
