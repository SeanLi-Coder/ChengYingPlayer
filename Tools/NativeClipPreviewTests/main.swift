import Foundation
import AVFoundation
import AppKit

var checks = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !value() { failures += 1; print("FAIL: \(message)") }
}
func wait(_ condition: () -> Bool, seconds: Double = 4) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  return condition()
}
func applied(_ result: PlayerCore.NativePreviewResult?) -> Bool {
  if case .applied? = result { return true }; return false
}
func superseded(_ result: PlayerCore.NativePreviewResult?) -> Bool {
  if case .superseded? = result { return true }; return false
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
_ = NSApplication.shared
let core = PlayerCore()
func ready() {
  check(wait { core.nativeTransport?.snapshot?.phase == .paused }, "Synthetic native media becomes paused")
}
func seek(_ position: Double) {
  core.nativeTransport!.setPaused(true)
  core.nativeTransport!.seek(.init(value: position, reference: .absoluteSeconds, exact: true))
  check(wait { core.nativeTransport?.snapshot?.phase == .paused && abs((core.nativeTransport?.snapshot?.position ?? -10) - position) < 0.002 },
    "Exact paused seek reaches \(position)")
}
func preview(_ start: Double, _ end: Double) {
  var result: PlayerCore.NativePreviewResult?
  var calls = 0
  core.requestNativePreview(start: start, end: end) { value in
    check(Thread.isMainThread, "Preview completion stays on main")
    calls += 1; result = value
  }
  check(result == nil, "Preview completion is asynchronous")
  check(wait { result != nil }, "Preview request completes within its bound")
  check(applied(result) && calls == 1, "Preview is applied exactly once")
  check(core.nativeLoopA == start && core.nativeLoopB == end, "Preview exposes its exact optional range")
}
func finish() {
  var result: PlayerCore.NativePreviewResult?
  core.finishNativePreview { result = $0 }
  check(result == nil, "Restore completion is asynchronous")
  check(wait { result != nil }, "Restore completes within its bound")
  check(applied(result), "Restore succeeds")
  check(!core.nativePreviewInProgress, "Restore releases temporary ownership")
}

core.open(url); ready(); seek(2.5)
core.nativeTransport!.setVolumePercent(70)
core.nativeTransport!.setRate(1.2)
ready()
preview(0, 1)
preview(1, 2)
finish()
check(abs((core.nativeTransport?.position ?? 0) - 2.5) < 0.002, "Repeated previews retain the first precise baseline")
check(core.nativeTransport?.isPaused == true, "Restore preserves original pause intent")
check(core.nativeLoopA == nil && core.nativeLoopB == nil, "Unset A/B remains unset")
check(abs((core.nativeTransport?.volumePercent ?? 0) - 70) < 0.001 && abs((core.nativeTransport?.rate ?? 0) - 1.2) < 0.001,
      "Preview leaves volume and speed unchanged")
preview(0, 1)
core.nativeTransport!.setVolumePercent(20)
core.nativeTransport!.setRate(1.5)
finish()
check(abs((core.nativeTransport?.volumePercent ?? 0) - 20) < 0.001 && abs((core.nativeTransport?.rate ?? 0) - 1.5) < 0.001,
      "Volume and speed chosen during preview survive restoration")

core.loop(0, 3); seek(2)
core.nativeTransport!.setLoop(core.nativeTransport!.loopInterval, repeatFile: true)
ready(); preview(0.2, 0.8)
core.suspendNativePreview()
check(core.nativePreviewInProgress && core.nativeLoopA == nil, "Incomplete input suspends the loop, retaining baseline")
preview(1, 1.5); finish()
check(core.nativeLoopA == 0 && core.nativeLoopB == 3, "Restore distinguishes A zero from unset")
check(abs((core.nativeTransport?.position ?? 0) - 2) < 0.002, "Original range is restored before return seek")

core.loop(1, nil); seek(2.5); preview(0, 1); finish()
check(core.nativeLoopA == 1 && core.nativeLoopB == nil, "A-only baseline restores without activating a loop")

var first: PlayerCore.NativePreviewResult?
var last: PlayerCore.NativePreviewResult?
core.requestNativePreview(start: 0, end: 1) { first = $0 }
core.requestNativePreview(start: 2, end: 3) { last = $0 }
check(wait { first != nil && last != nil }, "Rapid input completes both requests")
check(superseded(first) && applied(last), "Latest input wins; previous request is explicitly cancelled")
finish()

preview(0, 1)
core.cancelNativePreview(restoreLoop: true)
core.nativeTransport!.seek(.init(value: 3, reference: .absoluteSeconds, exact: true))
check(wait { abs((core.nativeTransport?.snapshot?.position ?? -1) - 3) < 0.1 }, "Explicit navigation escapes temporary range")
check(!core.nativePreviewInProgress && core.nativeLoopA == 1 && core.nativeLoopB == nil, "Navigation restores options without old-position restore")

var cancelled: PlayerCore.NativePreviewResult?
core.requestNativePreview(start: 0, end: 1) { cancelled = $0 }
core.open(url); ready()
check(wait { cancelled != nil }, "Same-URL replacement cancels pending capture")
check(superseded(cancelled), "Same URL is not mistaken for the same media generation")
check(core.nativeLoopA == nil && core.nativeLoopB == nil && core.nativeTransport!.isPaused && core.nativeTransport!.volumePercent == 0,
      "New media remains silent and paused without inherited preview state")

seek(2); preview(0, 1)
var restoreResult: PlayerCore.NativePreviewResult?
var replacementResult: PlayerCore.NativePreviewResult?
core.finishNativePreview { restoreResult = $0 }
core.requestNativePreview(start: 2, end: 3) { replacementResult = $0 }
check(wait { restoreResult != nil && replacementResult != nil }, "New input during restore completes deterministically")
check(superseded(restoreResult) && applied(replacementResult), "New preview supersedes an in-flight restore")
finish()

core.loop(nil, nil); seek(1.8)
let panel = Panel(core)
panel.startField.stringValue = "0"
panel.endField.stringValue = "0.5"
panel.scheduleRangePreview()
panel.startField.stringValue = "1"
panel.endField.stringValue = "1.5"
panel.scheduleRangePreview()
check(wait { core.nativeLoopA == 1 && !panel.nativePreviewPending && core.nativePreviewInProgress },
      "Production debounce previews only the newest typed interval")
panel.endField.stringValue = ""
panel.scheduleRangePreview()
check(core.nativeLoopA == nil && core.nativePreviewInProgress,
      "Production incomplete input removes temporary loop without losing baseline")
panel.startField.stringValue = "0"
panel.endField.stringValue = "1"
panel.previewRange(showValidationError: true)
check(wait { core.nativeLoopA == 0 && !panel.nativePreviewPending }, "Direct preview retries after incomplete input")
panel.prepareForUserSeek()
core.nativeTransport!.seek(.init(value: 3, reference: .absoluteSeconds, exact: true))
check(wait { abs((core.nativeTransport?.snapshot?.position ?? -1) - 3) < 0.1 }, "Production navigation exits preview before seeking")
check(!core.nativePreviewInProgress && panel.previewTimer == nil && !panel.automaticPreviewPending,
      "Production navigation leaves no pending automatic restart")

// The capture is deliberately still queued on main when the newer intent arrives.
panel.startField.stringValue = "unchanged"
panel.captureNativeRangeMarker(isEnd: false)
check(panel.nativeAnchorPending, "Marker capture is included in pending cancellation state")
core.pause()
check(wait { !panel.nativeAnchorPending }, "Cancelled marker capture completes")
check(panel.startField.stringValue == "unchanged" && panel.previewTimer == nil && panel.validationMessage == nil,
      "Later Space/pause intent cannot be overwritten by an old marker callback")
panel.captureNativeRangeMarker(isEnd: false)
panel.prepareForUserSeek()
core.nativeTransport!.seek(.init(value: 2, reference: .absoluteSeconds, exact: true))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(panel.startField.stringValue == "unchanged" && panel.previewTimer == nil,
      "Later user seek cancels marker fields and delayed automatic preview")
var clockCalls = 0
var clock: Double?
core.captureNativePreviewPosition { clockCalls += 1; clock = $0 }
core.cancelNativePreviewCapture()
check(wait { clockCalls == 1 } && clock == nil, "Direct exact-position cancellation returns nil once")

seek(2)
panel.rangeIsUntouched = true
panel.startField.stringValue = "0"
panel.automaticPreviewPending = true
panel.nativeAutomaticIntent = core.nativePreviewIntentRevision
panel.anchorUntouchedRangeToCurrentPosition()
core.pause()
check(wait { !panel.nativeAnchorPending }, "Opening-anchor cancellation completes")
check(!panel.automaticPreviewPending && panel.previewTimer == nil && panel.startField.stringValue == "0",
      "Explicit pause while opening tools cannot be replaced by automatic preview")

core.nativeTransport!.setLoop(nil, repeatFile: false)
seek(1.2)
core.nativeTransport!.setPaused(false)
check(wait { core.nativeTransport?.snapshot?.phase == .playing }, "Playing baseline becomes ready")
preview(0, 0.5); finish()
check(core.nativeTransport?.isPaused == false && (core.nativeTransport?.position ?? 0) >= 1.2,
      "Playing baseline resumes at its captured clock")
core.nativeTransport!.setRate(2)
core.nativeTransport!.seek(.init(value: 3.7, reference: .absoluteSeconds, exact: true))
check(wait { core.nativeTransport?.isAtEOF == true }, "Synthetic media reaches real EOF")
preview(0, 0.5); finish()
check(core.nativeTransport?.isPaused == true && (core.nativeTransport?.position ?? 0) > 3.99,
      "EOF baseline restores near end without replaying")
check(core.playbackAtEOF, "Restored EOF is visible through the production transport getter")
preview(0.5, 1); finish()
check(core.playbackAtEOF, "A second preview preserves the restored EOF intent")
core.resume()
check(wait { core.nativeTransport?.snapshot?.phase == .playing && (core.nativeTransport?.snapshot?.position ?? 4) < 1 },
      "One production Resume after restored EOF restarts from the beginning")
core.pause(); seek(3.7); preview(0, 0.5)
core.nativeTransport!.setLoop(core.nativeTransport!.loopInterval, repeatFile: true)
finish()
core.resume()
check(wait { core.nativeTransport?.snapshot?.phase == .playing && (core.nativeTransport?.snapshot?.position ?? 4) < 1 },
      "Changing persistent file-repeat during preview survives restoration and really wraps")
core.pause()
core.nativeTransport!.setLoop(nil, repeatFile: false)
seek(3.7); core.resume()
check(wait { core.nativeTransport?.isAtEOF == true }, "EOF is reachable after explicit file-repeat disable")
preview(0, 0.5); finish()
core.seek(absoluteSecond: 2)
check(!core.playbackAtEOF, "Explicit production seek clears restored EOF intent")
check(wait { core.nativeTransport?.snapshot?.phase == .paused && abs((core.nativeTransport?.snapshot?.position ?? 0) - 2) < 0.002 },
      "Explicit seek remains at the user's chosen paused position")
core.resume()
check(wait { core.nativeTransport?.snapshot?.phase == .playing && (core.nativeTransport?.snapshot?.position ?? 0) >= 2 },
      "Resume after explicit seek does not incorrectly jump back to zero")

core.pause(); core.loop(0, 3.5); seek(2.4); preview(0.5, 1)
var actionCount = 0
core.requireMPVCompatibility(reason: "Synthetic preview handoff") { actionCount += 1 }
check(actionCount == 0 && core.compatibilityLoads == 0, "Compatibility does not execute before preview restoration")
check(wait { core.compatibilityLoads == 1 }, "Production compatibility entry restores then retires native session")
check(core.nativeTransport == nil && core.mpv.preparations == 1, "Native output is retired before compatibility load boundary")
check(abs((core.compatibilityPosition ?? -1) - 2.4) < 0.002 && core.compatibilityPaused == true,
      "Compatibility captures the original clock and pause state, not the temporary preview")
check(core.compatibilityLoop.0 == 0 && core.compatibilityLoop.1 == 3.5, "Compatibility captures restored optional original markers")
check(actionCount == 0, "Requested action still waits for the compatibility backend boundary")
core.completeCompatibilityBoundary()
check(actionCount == 1, "Compatibility action is executed exactly once after its explicit boundary")

core.open(url); ready(); seek(2); preview(0, 1)
core.requireMPVCompatibility(reason: "Cancelled handoff") { actionCount += 10 }
core.open(url); ready()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(actionCount == 1 && core.compatibilityLoads == 1 && core.nativeTransport != nil,
      "Same-URL replacement cancels compatibility restore without replaying an old action")

// Hold the real serial worker before its exact query, then enqueue newer main
// intent without changing the media or session seek revision. No query is mocked.
func compatibilityCannotReplaceNewerIntent(previewRequested: Bool) {
  let candidate = PlayerCore()
  candidate.open(url)
  check(wait { candidate.nativeTransport?.snapshot?.phase == .paused }, "Compatibility race fixture is ready")
  let session = candidate.nativeTransport!.session
  let worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  worker.async { entered.signal(); release.wait() }
  check(entered.wait(timeout: .now() + 1) == .success, "Real worker barrier begins before the compatibility query")
  var actions = 0
  var previewResult: PlayerCore.NativePreviewResult?
  candidate.requireMPVCompatibility(reason: "Superseded same-generation handoff") { actions += 1 }
  if previewRequested {
    candidate.requestNativePreview(start: 0, end: 1) { previewResult = $0 }
  } else {
    candidate.pause()
  }
  release.signal()
  if previewRequested {
    check(wait { previewResult != nil }, "New preview completes after the old compatibility query")
    check(applied(previewResult), "New preview owns the media instead of the old compatibility request")
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.15))
  check(candidate.compatibilityLoads == 0 && candidate.nativeTransport != nil && actions == 0,
        previewRequested ? "New preview cancels the second compatibility capture" : "Explicit pause cancels the second compatibility capture")
  if !previewRequested { check(candidate.nativeTransport?.isPaused == true, "Latest explicit pause intent is retained") }
  candidate.close()
}
compatibilityCannotReplaceNewerIntent(previewRequested: true)
compatibilityCannotReplaceNewerIntent(previewRequested: false)

// The initial unsupported-media fallback has no ready native playback to keep.
// Model its failed exact-query boundary with a nonexistent synthetic source.
for unavailable in [true, false] {
  for intent in [nil, true, false] as [Bool?] {
    let initialFallback = PlayerCore()
    let source = unavailable ? url.deletingLastPathComponent().appendingPathComponent("missing-synthetic.mkv") : url
    initialFallback.open(source)
    initialFallback.nativeReady = false
    check(wait { initialFallback.nativeTransport?.snapshot?.phase == (unavailable ? .failed : .paused) },
          "Initial capture fixture reaches the intended exact-query state")
    var initialActions = 0
    initialFallback.requireMPVCompatibility(reason: "Initial capability boundary") { initialActions += 1 }
    if let intent {
      initialFallback.pause()
      if !intent { initialFallback.resume() }
    }
    check(wait { initialFallback.compatibilityLoads == 1 }, "Initial fallback remains viable before native readiness")
    check(initialFallback.nativeTransport == nil && initialActions == 0, "Initial fallback retires output before backend boundary")
    check(initialFallback.compatibilityPaused == (intent ?? false), "Initial fallback preserves explicit pause/resume or the unchanged autoplay preference")
    check(initialFallback.nativeInitialPauseIntent == nil, "Retirement clears opening pause intent after its capture")
    initialFallback.completeCompatibilityBoundary()
    check(initialActions == 1, "Initial fallback keeps its action exactly once")
    initialFallback.close()
  }
}
let becameReady = PlayerCore()
becameReady.open(url)
check(wait { becameReady.nativeTransport?.snapshot?.phase == .paused }, "Readiness transition fixture has real ready output")
becameReady.nativeReady = false
becameReady.requireMPVCompatibility(reason: "Pending initial capability boundary") {}
becameReady.nativeReady = true
becameReady.pause()
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
check(becameReady.compatibilityLoads == 0 && becameReady.nativeTransport != nil && becameReady.playbackTransport.isPaused,
      "A new intent after native readiness cancels an older initial handoff")
becameReady.close()

var shutdownResult: PlayerCore.NativePreviewResult?
core.requestNativePreview(start: 0, end: 1) { shutdownResult = $0; core.close() }
core.close()
check(wait { shutdownResult != nil }, "Close cancellation completion can safely reenter close")
check(superseded(shutdownResult) && core.nativeTransport == nil, "Late completion cannot resurrect closed media")
print("Native clip preview checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
