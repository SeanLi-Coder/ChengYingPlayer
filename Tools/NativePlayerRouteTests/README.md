# Native route real-render verification

Run `bash Tools/NativePlayerRouteTests/run.sh` on Apple Silicon macOS 14.4+ with
WindowServer and FFmpeg. The runner creates red/blue SDR H.264 + AAC fixtures
and a real two-audio-stream fixture,
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
- Initial pause/resume, repeated toggle and the mechanically extracted production
  play-button action preserve the latest accepted intention under both opening
  preferences. A controlled gate delays only real ready snapshots before the
  production receiver; it does not rewrite session state, timestamps or metadata.
  Exact worker queries prove that these commands cannot start the probe clock
  before the production capability and geometry checks finish.
- An action during the surrounding `setupUI` boundary is applied before startup;
  compatibility capture preserves an accepted autoplay command even when its
  exact query was queued before that command reached the worker.
- Same-URL replacement resets initial intent and volume; stop, close and shutdown
  reject a delayed previous-generation callback. The close test forwards a real
  owned `NSWindow.willCloseNotification` to the extracted `stop()` method using an
  explicit boundary observer, not MainWindow's production delegate.
- Early resume does not bypass the actual multi-audio-stream admission rejection.
  The real decoder reports two audio streams; production routes this to the
  compatibility boundary and preserves the explicit resume intent.

Displayed pixels are read only from AVFoundation's displayedPixelBuffer while
the real native clock is paused. The chroma test distinguishes the two synthetic
files; this is not a physical-screen color accuracy or audible A/V-sync test.
MainWindow's nib, actual key-event dispatch, compatibility MPV rendering and real
MPV shutdown are not proven here and need separate full-app verification. The
compatibility boundary deliberately does not manufacture a shutdown event.
Direct calls to the extracted play-button action prove its production routing,
not its nib connection. Existing native session/output/surface code is compiled
unchanged. This does not enable native playback by default or claim equivalence
to a proprietary player's playback engine.

Commands (run one at a time while no other GUI verification is using its window):

```sh
bash Tools/NativePlayerRouteTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativePlayerRouteTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativePlayerRouteTests/run.sh
NATIVE_ROUTE_NEGATIVE_CONTROL=start-before-admission bash Tools/NativePlayerRouteTests/run.sh
NATIVE_ROUTE_NEGATIVE_CONTROL=ignore-opening-intent bash Tools/NativePlayerRouteTests/run.sh
NATIVE_ROUTE_NEGATIVE_CONTROL=ignore-opening-getter bash Tools/NativePlayerRouteTests/run.sh
```

Sanitizer modes apply matching flags to the real Objective-C decoder and Swift
sources. They do not instrument the prebuilt FFmpeg dylibs. Optional
`FFMPEG_BIN=/path/to/ffmpeg` selects the fixture generator.

The three initial-control negative modes respectively remove only the early
command return, ignore the accepted intent at final startup, and read the paused
probe instead of the initial playback intention. Each must exit nonzero with the
corresponding unchanged assertions failing. Existing `skip-initial-resume` removes
the native startup command and must fail first-opening/replacement autoplay;
`skip-native-title-update` removes the initial Now Playing update and must fail
the title assertion. These modes patch the temporary extraction only. Unknown
negative or sanitizer names exit 2. None is a successful acceptance run.

The printed, unique `build/native-player-route-tests.*` directory retains the
synthetic files, extracted source and results. Source and linked-library hashes
are saved before and after the run; generated-source/fixture hashes are validated
at the end. A source change, generated-input change, or failed log capture fails
the run independently of its assertions. The outer watchdog is 180 seconds;
individual transition deadlines are unchanged. Only that run's executable and
object are removed by the exit trap.

## Initial admission regression evidence

The unmodified old implementation failed 16 of the first 246 assertions in
`build/native-player-route-tests.7Erktm/results.log`; the original 48 assertions
still passed. Failures included advancing the real clock before admission and
losing the latest explicit opening intention. This failed evidence is retained.

The final expanded candidate keeps those 48 assertions and has 287 assertions:

| Mode | Passed / failed | Evidence directory under `build/` |
| --- | --- | --- |
| Normal | 287 / 0 | `native-player-route-tests.xqvmka` |
| AddressSanitizer | 287 / 0 | `native-player-route-tests.qLp3Ga` |
| ThreadSanitizer | 287 / 0 | `native-player-route-tests.PSbmjJ` |
| `start-before-admission` | 278 / 9, expected exit 1 | `native-player-route-tests.Qs9f2K` |
| `ignore-opening-intent` | 277 / 10, expected exit 1 | `native-player-route-tests.4XweOT` |
| `ignore-opening-getter` | 274 / 13, expected exit 1 | `native-player-route-tests.yIafyf` |

All six runs passed the source and generated-input integrity checks. The normal
and sanitizer runs used Core SHA-256
`3b62c01141c646931dc434e61bd7a7158495a871dcfe6040f6183138c10f49b0`
and Window SHA-256
`3f55adba31ab41a6bf7f0c0b249af3a3f8a7585fa488806da3d18ef334ec45b4`.
The negative modes change only the generated extraction. Unknown negative and
sanitizer names were also checked to exit 2 before creating a test directory.
These are local controlled-window results, not a completed full-App or target-M4
acceptance, and do not claim unrelated prior rendering failures are resolved.
