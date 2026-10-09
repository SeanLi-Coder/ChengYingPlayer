# Live video viewport regression

Run with the actual fetched libmpv and source-built FFmpeg on a Mac:

```sh
bash Tools/VideoViewportTests/Live/run.sh
```

The test generates an isolated six-second 3840x2160 H.264 video with a red
reference rectangle on a white background, then repeats its encoded packets
without re-encoding to form a 180-second reference. This exceeds the ninety-second
process watchdog at the test's maximum 1.7x playback speed, preventing legitimate
end-of-file loops from invalidating time-progress assertions on a slow CPU
renderer. No user media, preferences, network,
or downloaded models are used. Its temporary fixture and executable are removed
at exit, and an external watchdog bounds a player or graphics-driver deadlock.

It compiles the actual shortcut resolver, the actual named mpv options, and the
mechanically extracted production `VideoToolsViewport` model and `PlayerCore`
viewport methods. The surrounding player-info shell is stubbed, but the bridge
reads and writes the actual libmpv properties. The test dispatches real `NSEvent`
objects through the production resolver, then runs the production bridge. It
does not copy the viewport arithmetic into a test implementation.

A real `NSOpenGLView` inside a real `NSWindow` presents decoded frames using the
libmpv OpenGL render API. GPU framebuffer reads measure reference-rectangle size
and position: equal/minus scaling, all four Command-Shift arrows including key
repeat, down/up coordinate direction, reset, and centering after zooming out.
Every sampled step verifies that the window frame, `window-scale`, and the
`dwidth`/`dheight` values used by app window-resize callbacks are unchanged. Non-default
paused position and playback speed are preserved; active playback continues;
an explicit later seek still works without losing the viewing transform. The
test also checks that production actions write only the three viewport properties.

Hardware decoding is required by default, and silent software fallback fails.
For a Mac environment without VideoToolbox, choose the explicitly labeled mode:

```sh
VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
```

Both modes retain the 3840x2160 decoder input and actual 640x360 framebuffer
pixel assertions. To reproduce Apple's real Generic Float CPU renderer instead
of allowing an accelerated context, add `CHENGYING_TEST_SOFTWARE_GL=1` in software
mode. This test-only option is rejected in hardware mode; it does not mock the
renderer or relax the watchdog or pixel expectations.

Viewport snapshots observe both the requested mpv properties and the actual
GPU marker until they agree with the existing two-pixel fixture expectations.
Each observation has a twenty-second deadline shared by all property queries
and the pixel readback; a late matching sample still fails. The whole-process
ninety-second watchdog remains unchanged. No-op/clamped pan operations need not
produce a new frame. Active-playback snapshots also observe the original time
progress conditions because a viewport-only redraw can reuse the current frame.
The final direction, dimensions, playback-state, and
window assertions are retained, and samples include their context, measured
coordinates, viewport properties, and rendered-frame count for diagnosis.

The test-only fault controls support isolated timing regressions. A delayed
readback copies the previous real GPU image to a separate framebuffer while
mpv's normal callbacks and live rendering continue; it does not fabricate
pixels or hold mpv's rendering loop until its own frame timeout expires.

```sh
# Positive: wait for the real updated image after a 350 ms readback delay.
CHENGYING_VIEWPORT_TEST_READBACK_DELAY=0.35 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
# Negative control: the former fixed 100 ms sampler can still read old pixels.
CHENGYING_VIEWPORT_TEST_LEGACY_SAMPLING=1 CHENGYING_VIEWPORT_TEST_READBACK_DELAY=0.35 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
# Negative: blocked delivery and reversed vertical pan must each fail, not skip.
CHENGYING_VIEWPORT_TEST_READBACK_DELAY=30 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
CHENGYING_VIEWPORT_TEST_INVERT_PAN_Y=1 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
```

The legacy negative control retains all independent final pixel assertions and
requires an explicit delay; it is not used by the normal test or CI command.
On a renderer taking longer than the configured delay, the legacy sampler may
already see the new pixels, so absence of that failure does not prove the old
fixed wait safe. These controlled tests establish a sampling race, not the
unique cause of a historical CI failure whose log lacks coordinates.

The render driver also retains a callback until it services the render API.
libmpv can move a pending paused redraw into its current frame after 200 ms,
removing the FRAME update bit while the host is still busy. A callback therefore
also triggers presentation, even if that bit has expired. The callback is consumed
before update/render, so notifications arriving during either operation survive.
Production `ViewLayer` has its own callback retention regression tests; this driver
does not substitute for those tests or claim a full AppKit layer reproduction.

The following controlled fault waits 400 ms after the final reset callback without
servicing the render API. It requires a callback with no FRAME bit and an increased
real VO drop count. The old gate must fail with a stale vertical position; the fixed
gate must render the centered frame within the same pixel tolerance and deadline.

```sh
CHENGYING_VIEWPORT_TEST_DROP_RESET_REDRAW=1 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
# Negative control: expected failure, never used to approve a release.
CHENGYING_VIEWPORT_TEST_DROP_RESET_REDRAW=1 CHENGYING_VIEWPORT_TEST_LEGACY_REDRAW=1 VIDEO_VIEWPORT_LIVE_MODE=software bash Tools/VideoViewportTests/Live/run.sh
```

For a separately verified playback build, set `CHENGYING_VIEWPORT_PLAYBACK_ROOT`
to its directory containing `include/` and `lib/`. The test reports the selected
library SHA-256 and actual loaded dylib path; it does not replace `deps/`.

This is a bounded live renderer/bridge test, not a full application UI automation.
It does not instantiate the complete application's `CAOpenGLLayer`, its actual
window-controller event dispatch, fullscreen transitions, user keyboard layouts,
HDR output, or multi-display lifecycle. Those remain covered separately where
available and must not be inferred from this fixture's success.

The coordinate expectations follow the official
[mpv video pan and zoom documentation](https://mpv.io/manual/stable/#options-video-pan-x):
pan units are fractions of the full scaled video; negative vertical pan moves
the picture upward. The live pixel checks independently verify that convention
in the bundled playback stack.
