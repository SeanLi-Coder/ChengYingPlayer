# Live video viewport regression

Run with the actual fetched libmpv and source-built FFmpeg on a Mac:

```sh
bash Tools/VideoViewportTests/Live/run.sh
```

The test generates an isolated six-second 3840x2160 H.264 video with a red
reference rectangle on a white background. No user media, preferences, network,
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
