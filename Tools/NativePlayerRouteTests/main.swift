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
  let layer = player.nativePlaybackOutput?.displayLayer
  player.stop()
  check(awaitCondition { !player.isUsingNativePlayback && player.info.state == .idle }, "Native stop completes asynchronously")
  check(layer?.superlayer == nil && player.mainWindow.videoView.nativeSurface?.displayLayer == nil,
    "Real session stop detaches presentation before terminal view uninit")
  check(player.mainWindow.videoView.isUsingNativeSurface && !player.mainWindow.videoView.isUninited &&
        !player.mainWindow.videoView.hasInitializedOpenGL,
    "Stopped real native route retains a reusable non-GL surface")
  player.mainWindow.videoView.uninit()
  player.mainWindow.close()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = directory.appendingPathComponent("red.mp4")
let blue = directory.appendingPathComponent("blue.mp4")

Preference.pauseWhenOpen = false
Preference.alwaysFloatOnTop = true
let autoplay = PlayerCore()
autoplay.testOpen(red)
check(awaitCondition { autoplay.info.state == .playing && (autoplay.playbackPosition ?? 0) > 0.25 }, "First native file automatically advances after loaded")
check(autoplay.isUsingNativePlayback, "First file remains on the real native backend")
check(autoplay.mainWindow.window?.isVisible == true && autoplay.mainWindow.showCount == 1, "Loaded route displays its actual AppKit window once")
check(autoplay.mainWindow.setupCount == 1, "Native loaded UI setup does not repeat per snapshot")
check(NowPlayingInfoManager.shared.titleUpdates.map(\.url) == [red] &&
      NowPlayingInfoManager.shared.titleUpdates.first?.title == "red" &&
      (NowPlayingInfoManager.shared.titleUpdates.first?.duration ?? 0) > 7,
      "First native ready publishes the complete Now Playing title and duration")
check(autoplay.getMediaTitle() == "red.mp4" && autoplay.mpv.titleReads == 0,
      "Native title uses the local file name without reading idle MPV metadata")
check(autoplay.mainWindow.isOntop, "Saved floating-window preference applies to native autoplay")
check(autoplay.playbackVolume == 0 && autoplay.info.volume == 0, "First autoplay file starts at zero volume")
check(autoplay.hasSelectedPlaybackAudio && autoplay.mainWindow.volumeEnabled, "Selected native audio enables the typed volume boundary")
check(autoplay.info.aid == nil, "Native audio does not fabricate an MPV track ID")
check(!autoplay.mainWindow.videoView.hasInitializedOpenGL && autoplay.mpv.renderInitializations == 0, "Native route never initializes compatibility GL")
check(autoplay.mainWindow.videoView.link == nil, "Native route never creates CVDisplayLink")
autoplay.testPause(true)
check(awaitCondition { autoplay.info.state == .paused }, "Typed pause reaches the real renderer clock")
check(!autoplay.mainWindow.isOntop, "Native pause restores the normal window level")
check(awaitCondition { checkPresentedPixel(autoplay, red: true) }, "Actual displayed pixel belongs to the loaded red file")
let pausedAt = autoplay.playbackPosition ?? -1
let floatingUpdates = autoplay.mainWindow.floatingChanges.count
pump(0.2)
check(abs((autoplay.playbackPosition ?? -2) - pausedAt) < 0.01, "Paused native time remains stable")
check(autoplay.mainWindow.floatingChanges.count == floatingUpdates,
      "Unchanged native snapshots do not repeatedly mutate the window level")
autoplay.testPause(false)
check(awaitCondition { autoplay.info.state == .playing && autoplay.mainWindow.isOntop },
      "Native resume reapplies floating-window preference")
autoplay.testPause(true)
check(awaitCondition { autoplay.info.state == .paused && !autoplay.mainWindow.isOntop },
      "A second native pause removes floating status again")
// Keep actual audio at zero throughout the test, including volume command paths.
autoplay.testSetVolume(0)
check(autoplay.playbackVolume == 0, "Typed zero-volume command remains silent")
let oldLayer = autoplay.nativePlaybackOutput!.displayLayer
let originalWindow = autoplay.mainWindow.window
let zoomed = VideoToolsViewport(zoom: 1, panX: 0.1, panY: -0.1)
check(autoplay.applyNativeViewport(zoomed) && autoplay.nativeViewport == zoomed,
      "Actual ready native route accepts shared viewport state")
autoplay.testOpen(blue)
check(awaitCondition { autoplay.isUsingNativePlayback && autoplay.info.currentURL == blue && autoplay.info.state == .playing }, "Same-window replacement loads a second native file")
check(autoplay.mainWindow.window === originalWindow &&
      NowPlayingInfoManager.shared.titleUpdates.map(\.url) == [red, blue] &&
      NowPlayingInfoManager.shared.titleUpdates.last?.title == "blue",
      "Same-window replacement publishes the new title without an activation callback")
check(autoplay.getMediaTitle() == "blue.mp4" && autoplay.getMediaTitle(withExtension: false) == "blue" &&
      autoplay.mpv.titleReads == 0, "Replacement native titles never query the idle compatibility core")
autoplay.testPause(true)
check(awaitCondition { autoplay.info.state == .paused && checkPresentedPixel(autoplay, red: false) }, "Second file displays blue rather than retaining the old red frame")
check(oldLayer.superlayer == nil, "Replacing the session detaches the retired display layer")
check(autoplay.nativeViewport.scale == 1 && autoplay.nativeViewport.panX == 0 && autoplay.nativeViewport.panY == 0 &&
      autoplay.mainWindow.videoView.nativeSurface?.zoom == 1 && autoplay.mainWindow.videoView.nativeSurface?.pan == .zero,
      "A new native media generation resets logical viewport and actual presentation together")
check(autoplay.playbackVolume == 0 && autoplay.info.volume == 0, "Replacement resets volume to zero")
retire(autoplay)

Preference.pauseWhenOpen = true
Preference.alwaysFloatOnTop = false
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
Preference.keepOpenOnFileEnd = false
let eofClose = PlayerCore()
eofClose.testOpen(red)
check(!eofClose.isUsingNativePlayback && eofClose.logs.contains("Native compatibility: close_window_on_eof"),
      "Unmigrated close-window-on-EOF preference explicitly selects compatibility playback")
check(eofClose.mpv.renderInitializations > 0,
      "EOF-close fallback selects the compatibility surface before loading media")
eofClose.mainWindow.videoView.uninit()
eofClose.mainWindow.close()
Preference.keepOpenOnFileEnd = true

func exactState(_ player: PlayerCore) -> NativePlaybackSnapshot? {
  var result: NativePlaybackQueryResult?
  player.nativePlaybackSession?.captureCurrentState { result = $0 }
  check(awaitCondition { result != nil }, "Exact opening query returns on the real worker")
  if case .ready(let value)? = result { return value }
  return nil
}
enum OpeningAction: String, CaseIterable {
  case none, pause, resume, space, doubleSpace, button, doubleButton, resumeThenPause, pauseThenResume
  func perform(_ player: PlayerCore) {
    switch self {
    case .none: break
    case .pause: player.pause()
    case .resume: player.resume()
    case .space: player.togglePause()
    case .doubleSpace: player.togglePause(); player.togglePause()
    case .button: player.mainWindow.playButtonAction(NSButton())
    case .doubleButton: player.mainWindow.playButtonAction(NSButton()); player.mainWindow.playButtonAction(NSButton())
    case .resumeThenPause: player.resume(); player.pause()
    case .pauseThenResume: player.pause(); player.resume()
    }
  }
  func expectedPause(preference: Bool) -> Bool {
    switch self {
    case .none, .doubleSpace, .doubleButton: return preference
    case .pause, .resumeThenPause: return true
    case .resume, .pauseThenResume: return false
    case .space, .button: return !preference
    }
  }
}
for preference in [false, true] {
  Preference.pauseWhenOpen = preference
  for action in OpeningAction.allCases {
    let candidate = PlayerCore()
    var gate: AdmissionGate?
    candidate.mainWindow.onWindowCreated = { gate = candidate.testHoldReadySnapshots() }
    candidate.testOpen(red)
    check(awaitCondition { gate?.held.first?.phase == .paused }, "Initial real paused snapshot reaches controlled admission boundary")
    let initial = exactState(candidate)
    check(candidate.info.state == .loading && candidate.mainWindow.setupCount == 0 && initial?.wantsPlayback == false,
          "No UI admission or autoplay has happened before the real snapshot is delivered")
    action.perform(candidate)
    let label = "preference=\(preference) action=\(action.rawValue)"
    check(candidate.playbackIsPaused == action.expectedPause(preference: preference), "Accepted opening intent matches \(label)")
    pump(0.1)
    let beforeAdmission = exactState(candidate)
    check(beforeAdmission?.phase == .paused && beforeAdmission?.wantsPlayback == false &&
          abs((beforeAdmission?.position ?? -1) - (initial?.position ?? -2)) < 0.000001,
          "Real clock cannot start before media admission: \(label)")
    gate?.release()
    check(awaitCondition { candidate.info.state.loaded && candidate.mainWindow.setupCount == 1 },
          "Original ready callback runs real media admission exactly once: \(label)")
    let admitted = exactState(candidate)
    check(admitted?.wantsPlayback == !action.expectedPause(preference: preference) &&
          candidate.playbackIsPaused == action.expectedPause(preference: preference),
          "Admitted native playback applies the last opening intent: \(label)")
    check(candidate.playbackVolume == 0 && candidate.info.volume == 0 &&
          !candidate.mainWindow.videoView.hasInitializedOpenGL && candidate.mpv.firstLoads == 0,
          "Initial intent does not change silent-open or native backend ownership")
    candidate.mainWindow.onWindowCreated = nil
    retire(candidate)
  }
}

for preference in [false, true] {
  Preference.pauseWhenOpen = preference
  for action in [OpeningAction.pause, .resume] {
    let candidate = PlayerCore()
    candidate.mainWindow.onSetup = {
      check(candidate.nativeInitialPlaybackPending && candidate.info.state == .loaded,
            "UI setup is still inside initial playback admission")
      action.perform(candidate)
    }
    candidate.testOpen(red)
    check(awaitCondition { candidate.info.state.loaded && candidate.mainWindow.setupCount == 1 }, "UI setup intent reaches real readiness")
    let state = exactState(candidate)
    check(state?.wantsPlayback == !action.expectedPause(preference: preference), "Latest UI-setup intent overrides the opening preference")
    candidate.mainWindow.onSetup = nil
    retire(candidate)
  }
}

// Queue an exact compatibility query during setup, before notify queues the
// accepted autoplay command. Its worker result still says paused, while the
// adapter already owns a newer resume intent when the main callback executes.
Preference.pauseWhenOpen = false
let setupCompatibility = PlayerCore()
setupCompatibility.mainWindow.onSetup = {
  setupCompatibility.requireMPVCompatibility(reason: "Synthetic setup handoff") {}
}
setupCompatibility.testOpen(red)
check(awaitCondition { setupCompatibility.mpv.firstLoads == 1 && !setupCompatibility.isUsingNativePlayback },
      "Setup handoff waits for real native retirement")
check(setupCompatibility.testCompatibilityPaused == false,
      "Compatibility retains accepted autoplay instead of its older paused worker snapshot")
setupCompatibility.mainWindow.onSetup = nil
setupCompatibility.mainWindow.videoView.uninit()
setupCompatibility.mainWindow.close()

Preference.pauseWhenOpen = true
let replacedOpening = PlayerCore()
var replacedGate: AdmissionGate?
replacedOpening.mainWindow.onWindowCreated = { replacedGate = replacedOpening.testHoldReadySnapshots() }
replacedOpening.testOpen(red)
check(awaitCondition { replacedGate?.held.first?.phase == .paused }, "Replacement starts with a real held admission callback")
let oldGeneration = replacedOpening.videoToolsMediaGeneration
let oldOpeningLayer = replacedOpening.nativePlaybackOutput?.displayLayer
replacedOpening.resume()
replacedOpening.testOpen(red)
check(awaitCondition { replacedOpening.videoToolsMediaGeneration > oldGeneration && replacedOpening.info.state == .paused },
      "Same-URL replacement admits a new paused generation")
replacedGate?.release()
let replacementState = exactState(replacedOpening)
check(replacementState?.wantsPlayback == false && replacedOpening.playbackVolume == 0 &&
      replacedOpening.mainWindow.setupCount == 1 && oldOpeningLayer?.superlayer == nil,
      "Old opening resume and delayed callback cannot leak into the new generation")
replacedOpening.mainWindow.onWindowCreated = nil
retire(replacedOpening)

for operation in ["stop", "close", "shutdown"] {
  let candidate = PlayerCore()
  var gate: AdmissionGate?
  candidate.mainWindow.onWindowCreated = { gate = candidate.testHoldReadySnapshots() }
  candidate.testOpen(red)
  check(awaitCondition { gate?.held.first?.phase == .paused }, "Cancellation starts with a held real initial callback")
  candidate.resume()
  var token: NSObjectProtocol?
  if operation == "shutdown" { candidate.shutdown() }
  else if operation == "close" {
    // The surrounding MainWindow delegate is a boundary. Forward a genuine
    // NSWindow close notification to the production Core stop implementation.
    token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
      object: candidate.mainWindow.window, queue: .main) { _ in candidate.stop() }
    candidate.mainWindow.window?.close()
  } else { candidate.stop() }
  gate?.release()
  check(awaitCondition { !candidate.isUsingNativePlayback }, "\(operation) retires the real pending native session")
  check(candidate.mainWindow.setupCount == 0 && candidate.mainWindow.showCount == 0 &&
        candidate.info.state == (operation == "shutdown" ? .shuttingDown : .idle),
        "Delayed initial callback cannot reopen or autoplay after \(operation)")
  if let token { NotificationCenter.default.removeObserver(token) }
  candidate.mainWindow.onWindowCreated = nil
  candidate.mainWindow.videoView.uninit()
  candidate.mainWindow.close()
}

let unsupportedTracks = PlayerCore()
var unsupportedGate: AdmissionGate?
unsupportedTracks.mainWindow.onWindowCreated = { unsupportedGate = unsupportedTracks.testHoldReadySnapshots() }
unsupportedTracks.testOpen(directory.appendingPathComponent("multi-audio.mp4"))
check(awaitCondition { unsupportedGate?.held.first?.media?.audioStreamCount == 2 }, "Real decoder reports both synthetic audio tracks")
unsupportedTracks.resume()
let unsupportedProbe = exactState(unsupportedTracks)
check(unsupportedProbe?.wantsPlayback == false && unsupportedTracks.mainWindow.setupCount == 0,
      "Early resume does not start unadmitted multi-track media")
unsupportedGate?.release()
check(awaitCondition { unsupportedTracks.mpv.firstLoads == 1 && !unsupportedTracks.isUsingNativePlayback },
      "Unmodified track admission routes unsupported media to compatibility")
check(unsupportedTracks.mainWindow.setupCount == 0 && unsupportedTracks.logs.contains("Native compatibility: unmigrated_container_tracks") &&
      unsupportedTracks.testCompatibilityPaused == false,
      "Unsupported track metadata cannot be disguised as successful native readiness")
unsupportedTracks.mainWindow.onWindowCreated = nil
unsupportedTracks.mainWindow.videoView.uninit()
unsupportedTracks.mainWindow.close()

print("Native route real-render checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
