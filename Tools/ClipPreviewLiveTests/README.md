# Live clip preview admission checks

Run `python3 -B Tools/ClipPreviewLiveTests/run.py` for the existing real-libmpv
clip-preview suite. `--build-only` only compiles and does not open test windows.
The runner generates synthetic input and owns/unregisters its disposable app;
it never uses personal media unless an explicit `--media` path is supplied.

## Generic handoff admission

```sh
python3 -B Tools/ClipPreviewLiveTests/run.py --case handoff-busy
python3 -B Tools/ClipPreviewLiveTests/run.py --case handoff-busy --busy-negative-control controller
python3 -B Tools/ClipPreviewLiveTests/run.py --case handoff-busy --busy-negative-control bridge
```

The positive case uses real AppKit field editing, production panel/bridge code,
and shipped libmpv software decoding/rendering. Only the busy admission flag is
controlled: it represents native absent + MPV loaded while compatibility work
is pending. This does not establish the Core generic state machine or actual
handoff START/seek receipt behavior.

While busy it rejects snapshot and clock capture, direct/manual preview,
automatic input/sidebar scheduling, and a previously scheduled production timer.
Marker buttons preserve the typed range. It separately proves internal A-B and
viewport restoration still works. Clearing busy permits the same manual preview,
verified by actual seek/unpause submissions, advancing time, and changing rendered
RGB pixels. Existing cases and assertions remain unchanged; the new case runs
last when `--case all` is selected.

Each negative control removes only the new generic admission predicates from
one production surface in the disposable build. Exact predicate counts fail
closed when source landmarks change. They must exit nonzero at their admission
assertion, not compile or launch failures. They are scoped to this case, not a
claim that the complete live suite was rerun under mutation.

Local evidence is retained in `build/generic-preview-admission.8M2B2R`:
positive 42 assertions / 0 failed cases; Controller mutation reports 18 passed /
1 failed case and rejects at
`Busy native input cannot schedule an automatic preview`; Bridge mutation must
reject at `Busy bridge refuses a temporary preview snapshot` (14 passed / 1 failed
case). Both negative runs exited 1 after successful compile, load and rendering.
The paired AppKit + playback-stub `VideoToolsTests` case passed 17 checks.
This test does not claim GPU/HDR/audio or complete-App acceptance.
