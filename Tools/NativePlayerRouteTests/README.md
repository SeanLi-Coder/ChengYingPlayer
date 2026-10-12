# Native route real-render verification

Run `bash Tools/NativePlayerRouteTests/run.sh` on Apple Silicon macOS 14.4+ with
WindowServer and FFmpeg. The runner creates red/blue SDR H.264 + AAC fixtures,
compiles the real decoder/session/output/surface/VideoView, and opens a transient
CLI-owned NSWindow. Audio remains zero throughout. It never opens user files,
creates an application bundle, installs an app, changes permissions, or captures
the desktop.

PlayerCore declarations and route methods, together with PlaybackInfo's actual
state-transition setter, are mechanically extracted from the current production
source. The extraction fails if its landmarks change. The
tests execute native admission/open/snapshot/retirement/stop/shutdown and the
real `notifyWindowVideoSizeChanged` method, rather than a separately implemented
route. Application services, MainWindow's surrounding UI, history/preferences,
and the MPV compatibility transport/layer are explicit boundary doubles.

Verified boundaries:

- First native opening shows a real window and automatically advances time.
- Pause-when-open shows a real first frame without starting the clock.
- Volume starts at zero, no MPV audio ID is fabricated, and typed native audio
  availability enables the boundary control.
- The native route never constructs the compatibility layer, initializes its
  render context, or starts CVDisplayLink.
- Replacing and rapidly opening files selects the newest actual displayed
  red/blue pixels; retired layers detach instead of retaining the old image.
- Stop and shutdown retire the actual session asynchronously; shutdown during
  admission cannot create a late native window. Stop-then-quit and quit-then-stop
  retain terminal shutdown priority under the production state machine.

Displayed pixels are read only from AVFoundation's displayedPixelBuffer while
the real native clock is paused. The chroma test distinguishes the two synthetic
files; this is not a physical-screen color accuracy or audible A/V-sync test.
MainWindow's nib, native user-event wiring, compatibility MPV rendering and real
MPV shutdown are not proven here and need separate full-app verification. The
compatibility boundary deliberately does not manufacture a shutdown event.

`NATIVE_ROUTE_NEGATIVE_CONTROL=skip-initial-resume bash
Tools/NativePlayerRouteTests/run.sh` removes only the autoplay command from the
extracted production notification method. This run must fail the first-opening
and replacement autoplay checks; it is never a successful acceptance run. The
normal run extracts unmodified method bodies.

The printed, unique `build/native-player-route-tests.*` directory retains the
synthetic files, extracted source and results. Only that run's executable and
object are removed by the exit trap.
