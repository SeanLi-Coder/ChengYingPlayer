# Native playback surface verification

Run `bash Tools/NativePlaybackSurfaceTests/run.sh` on Apple Silicon macOS 14.4+
with an active WindowServer and the locally installed FFmpeg. `FFMPEG_BIN` may
override `/opt/homebrew/bin/ffmpeg`. The runner compiles production surface,
decoder, session and output code; it creates a transient CLI-owned AppKit window,
not an application bundle. It never reads user media, initializes OpenGL or a
display link, changes permissions, captures the desktop, or installs an app.

`NativePlaybackSurface` is a main-thread NSView only. Its owner attaches the real
output display layer, supplies coded dimensions, validated sample aspect ratio
and clockwise quarter rotation, then sends linear zoom and point-based pan.
Positive pan Y points upward. This differs from logarithmic mpv zoom and
image-normalized mpv pan; a caller must explicitly translate those units.
The surface neither owns nor commands the decoder, renderer queue or playback
clock. Hide/show is presentation only. Detach restores the original layer's
geometry, gravity and scale, without flushing or shutting down a session.

The tests verify actual CALayer bounds, transforms, clipping, resize and bounds
origin changes; SAR before rotation; zoom/pan; current-window backing scale;
hide/show and missing geometry; finite/integer/dimension/range validation;
idempotent attachment, foreign-owner rejection and precise detachment; disabled
implicit animations; and mouse-event passthrough. An isolated negative child
intentionally mutates the surface on a worker and must hit its main-thread
assertion. The expected child crash does not alter another running application.

Rotation direction is checked with real four-quadrant H.264 files, not only with
axis-aligned rectangles. FFmpeg writes 0/90/180/270-degree display matrices, then
independently autorotates each file to reference YUV pixels. CYNMediaDecoder reads
the metadata and NativePlaybackSession displays the original decoded quadrants.
The actual displayed buffer is read only with the underlying clock paused. The
surface's real CALayer point conversion maps those quadrant centers to the same
colors in FFmpeg's reference image. Source quadrant bytes are independently
verified before testing. The tiny synthetic H.264 fixture may use the explicit
software fallback; this test makes no hardware-acceleration claim.

The first fixture run exposed two generator mistakes, not proven playback
defects: geq chroma uses subsampled plane coordinates, and current FFmpeg requires
`-display_rotation` rather than the old `rotate` metadata string. The generator
now uses per-plane W/H and real display matrices; assertions were not weakened.

Limits: `displayedPixelBuffer()` verifies displayed source pixels before the
layer transform. CALayer mapping plus FFmpeg references checks direction, but is
not a composited screenshot, physical screen/HDR certification, audible A/V sync
proof, or a real multi-monitor dragging test. No shipping UI migration is implied.
The CLI closes its window and asynchronously retires the production session.
It removes only its own executable/object, retaining fixtures and `results.log`
in the uniquely named build directory printed by the runner.

## VideoView integration boundary

Run `bash Tools/NativePlaybackSurfaceTests/run-video-view.sh` for the production
`VideoView` route boundary on macOS 12+. It uses production surface/output and
atomic primitives in a transient AppKit window. PlayerCore/MPV and the legacy
ViewLayer are counting doubles: the assertions prove that the native path never
requests that layer, invokes MPV, or starts CVDisplayLink, not that the real
compatibility renderer was exercised. Native resize, backing scale, HDR-query
isolation, explicit output replacement, teardown, and one-way MPV fallback are
checked. No installed app, user media or permissions are touched.

The native output is attached before playback initialization. Existing MPV
players cannot switch back into native mode in this first integration slice;
this keeps stale GL callbacks out of the new renderer. The full application
still requires its independent route/transport and real UI verification.
