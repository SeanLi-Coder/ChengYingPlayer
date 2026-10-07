# Player close and render-lock regression tests

Run `python3 -B Tools/PlayerCloseTests/run.py --priority` for a deterministic
production-lock regression. It compiles the actual `MainThreadPriorityLock`
without rewriting its logic, then schedules the original lock cycle using a
real `NSRecursiveLock`: a background renderer owns the display lock, the main
thread announces a pending acquisition, and the renderer reenters display as
Core Animation can do from `CATransaction.flush`. The old implementation blocks
its own lock owner. A bounded acquisition lets that failure unwind rather than
hanging the test runner. Separate assertions retain main-thread priority over
an unrelated background contender and verify nested ownership is balanced.

The negative control
`python3 -B Tools/PlayerCloseTests/run.py --priority --layer-ref b380d660`
must fail at `A reentrant render owner cannot deadlock the waiting main thread`.
Historical source lacks the new balancing method, so the extracted comparison
gets a no-op method solely to compile against the same scheduling harness.

Run `python3 -B Tools/PlayerCloseTests/run.py` for actual playback. It compiles
the full production `ViewLayer` and native OpenGL/Core Animation drawing against
the shipped libmpv, generates a disposable 4K/60fps H.264 clip, and closes and
reopens a real `NSWindow` 30 times. Alternating iterations restore preview-like
rotation/loop/seek state before issuing synchronous pause and stop calls. It
requires actual drawing, not only decoder initialization. Application services
and the window delegate are small isolated boundaries; this is not the complete
player GUI, `PlayerCore.stop`, or a reproduction of an individual user's hang.

`CLOSE_TEST_HWDEC=videotoolbox python3 -B Tools/PlayerCloseTests/run.py` additionally
requests and verifies that VideoToolbox was actually selected. The default uses
software decoding with real OpenGL rendering. This test requires the repository's
FFmpeg/libmpv dependencies and an active macOS graphical session. Do not classify
an arbitrary hang or assertion failure as an unavailable-display skip.

There is no capability skip in this harness: the unmodified production factory
tries its complete core/legacy and accelerated/Generic Float fallback sequence,
and an inability to initialize remains a failure. This avoids skipping a viable
legacy context based on an incomplete test-only preflight. The existing
capability-policy wrapper can run it, but it never reports a capability status
of 77. `CHENGYING_TEST_SOFTWARE_GL=1` limits the production layer to Generic Float;
it cannot accompany hardware decoding. Assertions, timeouts, and cleanup errors
always remain failures.

Both modes use `TestAppWorkspace`; expanded test apps and generated clips are
owned, unregistered, and removed on exit. They do not launch the installed player,
change user preferences, or access personal videos. Native calls have a 60-second
outer watchdog. `Tools/RenderLifecycleTests/run.sh` separately verifies the real
Core Animation shadow constructor shares both display and priority ownership,
plus CGL reference balancing, callback shutdown, Intel typechecking, and ASan.
