import AppKit
import AVFoundation

var passes = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  if condition() { passes += 1; print("PASS: \(label)") }
  else { failures += 1; print("FAIL: \(label)") }
}
@discardableResult
func awaitCondition(_ timeout: Double = 5, _ body: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if body() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  return body()
}
func pump(_ seconds: Double) { _ = awaitCondition(seconds) { false } }
func checkPresentedPixel(_ player: PlayerCore, red: Bool) -> Bool {
  guard let layer = player.nativePlaybackOutput?.displayLayer,
        let buffer = layer.sampleBufferRenderer.displayedPixelBuffer(),
        CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) == 2 else { return false }
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
  let chroma = address.assumingMemoryBound(to: UInt8.self)
  // BT.709 limited-range red and blue have distinct U/V dominance. Inspect
  // displayed source bytes, never the desktop or a merely enqueued sample.
  return red ? chroma[1] > 210 && chroma[0] < 130 : chroma[0] > 210 && chroma[1] < 140
}
func retire(_ player: PlayerCore) {
  player.stop()
  check(awaitCondition { !player.isUsingNativePlayback && player.info.state == .idle }, "Native stop completes asynchronously")
  player.mainWindow.videoView.uninit()
  player.mainWindow.close()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = directory.appendingPathComponent("red.mp4")
let blue = directory.appendingPathComponent("blue.mp4")

Preference.pauseWhenOpen = false
let autoplay = PlayerCore()
autoplay.testOpen(red)
check(awaitCondition { autoplay.info.state == .playing && (autoplay.playbackPosition ?? 0) > 0.25 }, "First native file automatically advances after loaded")
check(autoplay.isUsingNativePlayback, "First file remains on the real native backend")
check(autoplay.mainWindow.window?.isVisible == true && autoplay.mainWindow.showCount == 1, "Loaded route displays its actual AppKit window once")
check(autoplay.mainWindow.setupCount == 1, "Native loaded UI setup does not repeat per snapshot")
check(autoplay.playbackVolume == 0 && autoplay.info.volume == 0, "First autoplay file starts at zero volume")
check(autoplay.hasSelectedPlaybackAudio && autoplay.mainWindow.volumeEnabled, "Selected native audio enables the typed volume boundary")
check(autoplay.info.aid == nil, "Native audio does not fabricate an MPV track ID")
check(!autoplay.mainWindow.videoView.hasInitializedOpenGL && autoplay.mpv.renderInitializations == 0, "Native route never initializes compatibility GL")
check(autoplay.mainWindow.videoView.link == nil, "Native route never creates CVDisplayLink")
autoplay.testPause(true)
check(awaitCondition { autoplay.info.state == .paused }, "Typed pause reaches the real renderer clock")
check(awaitCondition { checkPresentedPixel(autoplay, red: true) }, "Actual displayed pixel belongs to the loaded red file")
let pausedAt = autoplay.playbackPosition ?? -1
pump(0.2)
check(abs((autoplay.playbackPosition ?? -2) - pausedAt) < 0.01, "Paused native time remains stable")
// Keep actual audio at zero throughout the test, including volume command paths.
autoplay.testSetVolume(0)
check(autoplay.playbackVolume == 0, "Typed zero-volume command remains silent")
let oldLayer = autoplay.nativePlaybackOutput!.displayLayer
autoplay.testOpen(blue)
check(awaitCondition { autoplay.isUsingNativePlayback && autoplay.info.currentURL == blue && autoplay.info.state == .playing }, "Same-window replacement loads a second native file")
autoplay.testPause(true)
check(awaitCondition { autoplay.info.state == .paused && checkPresentedPixel(autoplay, red: false) }, "Second file displays blue rather than retaining the old red frame")
check(oldLayer.superlayer == nil, "Replacing the session detaches the retired display layer")
check(autoplay.playbackVolume == 0 && autoplay.info.volume == 0, "Replacement resets volume to zero")
retire(autoplay)

Preference.pauseWhenOpen = true
let paused = PlayerCore()
paused.testOpen(red)
check(awaitCondition { paused.info.state == .paused && paused.mainWindow.showCount == 1 }, "Pause-when-open displays the first native file without autoplay")
check(awaitCondition { checkPresentedPixel(paused, red: true) }, "Paused opening presents an actual first frame")
let openingTime = paused.playbackPosition ?? -1
pump(0.2)
check(abs((paused.playbackPosition ?? -2) - openingTime) < 0.01, "Pause-when-open does not silently start the clock")
paused.testOpen(red)
paused.testOpen(blue)
check(awaitCondition { paused.info.currentURL == blue && paused.info.state == .paused && checkPresentedPixel(paused, red: false) }, "Rapid opens retain only the newest native file")
let shutdownLayer = paused.nativePlaybackOutput?.displayLayer
paused.shutdown()
check(awaitCondition { !paused.isUsingNativePlayback && paused.mpv.quitCalls == 1 }, "Native shutdown retires the real session before quitting the compatibility service")
check(paused.info.state == .shuttingDown, "Only a real compatibility shutdown event may mark the app fully shut down")
paused.mainWindow.videoView.uninit()
check(shutdownLayer?.superlayer == nil, "Native-only view teardown detaches without a GL assertion")
paused.mainWindow.close()

let stopThenQuit = PlayerCore()
stopThenQuit.testOpen(red)
check(awaitCondition { stopThenQuit.info.state == .paused }, "Stop-then-quit case reaches a real paused native session")
stopThenQuit.stop()
stopThenQuit.shutdown()
check(awaitCondition { !stopThenQuit.isUsingNativePlayback && stopThenQuit.mpv.quitCalls == 1 }, "Immediate quit supersedes asynchronous native stop")
check(stopThenQuit.info.state == .shuttingDown, "Stop-then-quit obeys the real production state machine")
stopThenQuit.mainWindow.videoView.uninit()
stopThenQuit.mainWindow.close()

let quitThenStop = PlayerCore()
quitThenStop.testOpen(red)
check(awaitCondition { quitThenStop.info.state == .paused }, "Quit-then-stop case reaches a real paused native session")
quitThenStop.shutdown()
quitThenStop.stop()
check(awaitCondition { !quitThenStop.isUsingNativePlayback && quitThenStop.mpv.quitCalls == 1 }, "Window close cannot cancel an in-flight terminal native shutdown")
check(quitThenStop.info.state == .shuttingDown, "Quit-then-stop retains the terminal state")
quitThenStop.mainWindow.videoView.uninit()
quitThenStop.mainWindow.close()

let cancelled = PlayerCore()
cancelled.testOpen(red)
cancelled.shutdown()
pump(0.3)
check(!cancelled.isUsingNativePlayback && !cancelled.mainWindow.loaded, "Shutdown during admission prevents a late native window")
check(cancelled.mpv.quitCalls == 1, "Admission cancellation quits the idle compatibility service once")
check(ViewLayer.constructions == 0, "All native lifecycle cases created zero compatibility layers")
check(Utility.alerts.isEmpty, "Synthetic valid playback produces no generic error alerts")
print("Native route real-render checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
