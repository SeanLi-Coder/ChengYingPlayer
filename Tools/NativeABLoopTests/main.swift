import AppKit
import AVFoundation

var passes = 0
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ text: String) {
  if value() { passes += 1; print("PASS: \(text)") }
  else { failures += 1; print("FAIL: \(text)") }
}
@discardableResult
func waitUntil(_ seconds: Double = 4, _ condition: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return condition()
}
final class Observations {
  let lock = NSLock()
  var samples: [NativePlaybackSampleObservation] = []
  func append(_ sample: NativePlaybackSampleObservation) { lock.lock(); samples.append(sample); lock.unlock() }
  func clear() { lock.lock(); samples.removeAll(); lock.unlock() }
  func snapshot() -> [NativePlaybackSampleObservation] { lock.lock(); defer { lock.unlock() }; return samples }
}
let observations = Observations()
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let player = PlayerCore()
player.testOpen(url, observer: { observations.append($0) })
check(waitUntil { player.nativeTransport?.snapshot?.phase == .paused }, "Real native decoder opens a synthetic paused file")
func action(_ action: PlayerCore.NativeLoopAction) -> PlayerCore.NativeLoopActionResult? {
  var outcome: PlayerCore.NativeLoopActionResult?
  var calls = 0
  player.requestNativeLoopAction(action) { outcome = $0; calls += 1; check(Thread.isMainThread, "Marker callback executes on main") }
  check(waitUntil { outcome != nil }, "Marker request completes without blocking")
  check(calls == 1, "Marker callback completes exactly once")
  return outcome
}
func seek(_ seconds: Double) {
  let revision = player.nativeTransport!.snapshot!.revision
  player.seek(absoluteSecond: seconds)
  check(waitUntil { player.nativeTransport!.snapshot!.revision > revision && player.nativeTransport!.snapshot!.phase == .paused },
        "Production navigation finishes paused preroll")
}
func settle() {
  var done = false
  _ = waitUntil {
    if done { return true }
    player.nativeTransport!.captureCurrentState { if case .ready = $0 { done = true } }
    return false
  }
  check(done, "Loop edit settles to an exact readable worker state")
}

check(action(.captureB) == .invalid, "B without A is rejected")
check(action(.captureA) == .applied && player.playbackLoopA == 0 && player.playbackLoopB == nil,
      "A at zero is set rather than mistaken for an absent marker")
let slider = SliderController(player)
slider.syncSlider()
check(!slider.playSlider.abLoopA.isHidden && slider.playSlider.abLoopA.doubleValue == 0 && slider.playSlider.abLoopB.isHidden,
      "Production slider shows zero A and hides absent B")
check(action(.captureB) == .invalid && player.info.abLoopStatus == .aSet, "B equal to A preserves the pending start")
seek(1)
check(action(.captureB) == .applied && player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 1),
      "Valid B activates an exact zero-start loop")
settle()
check(player.playbackIsPaused && abs(player.playbackPosition ?? -1) < 0.001,
      "Activating B returns to A and preserves paused playback")
slider.syncSlider()
check(!slider.playSlider.abLoopB.isHidden && abs(slider.playSlider.abLoopB.doubleValue - 25) < 0.001,
      "Production slider maps B to the media duration")
slider.playSlider.abLoopB.doubleValue = 0
let messagesBeforeDrag = player.messages.count
check(slider.handleNativeLoopKnob(start: false, seconds: 0), "Native knob handler owns the notification")
check(slider.playSlider.abLoopB.doubleValue == 25 && player.playbackLoopB == 1,
      "Rejected knob drag rolls visual position back to the accepted boundary")
if player.messages.count == messagesBeforeDrag + 1, case .custom = player.messages.last! {
  check(true, "Invalid knob drag displays an error rather than success feedback")
} else { check(false, "Invalid knob drag displays an error rather than success feedback") }
for invalid in [Double.nan, .infinity, -1, 1, 2] {
  player.abLoopA = invalid
  check(player.playbackLoopA == 0 && player.playbackLoopB == 1, "Invalid dragged A cannot damage the current range")
}
for invalid in [Double.nan, .infinity, -1, 0, 5] {
  player.abLoopB = invalid
  check(player.playbackLoopA == 0 && player.playbackLoopB == 1, "Invalid dragged B cannot damage the current range")
}
player.abLoopA = 0.2
player.abLoopB = 0.8
settle()
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0.2, end: 0.8), "Dragged markers update the real session interval")
player.seek(relativeSecond: 50, option: .exact)
player.seek(relativeSecond: -0.1, option: .exact)
let expected = NativePlaybackSession.clampedSeekTarget(50, duration: 4, loop: player.nativeTransport!.loopInterval) - 0.1
check(abs((player.playbackPosition ?? -1) - expected) < 1e-8,
      "Rapid native relative seeks accumulate from the loop-clamped accepted target")
check(player.videoToolsLoopRecovery.pendingTarget == nil, "Native navigation never pollutes legacy pending seek recovery")
settle()
player.testRepeat(.file)
check(player.nativeTransport!.loopInterval == (try? NativePlaybackInterval(start: 0.2, end: 0.8)),
      "Changing whole-file repetition preserves the native A/B interval")
check(action(.clear) == .applied && player.nativeLoopMode == .file, "Clearing A/B preserves the file-repeat selection")
settle()
player.testRepeat(.off)
seek(0)
check(action(.captureA) == .applied, "A can be captured again after clearing")
seek(3.9)
player.resume()
check(waitUntil { player.nativeTransport?.snapshot?.phase == .ended }, "The real native session reaches EOF")
check(action(.captureB) == .applied && player.playbackLoopB == 4,
      "An EOF capture uses exact duration as B rather than a rounded final frame")
settle()
player.pause()
check(waitUntil { player.nativeTransport?.snapshot?.phase == .paused }, "EOF loop activation remains controllable")
check(action(.clear) == .applied, "EOF loop can be cleared")
settle()
seek(0)
check(action(.captureA) == .applied, "A is reset after the EOF case")
seek(0.9)
check(action(.captureB) == .applied, "Another valid B activates normally")
settle()
seek(0.5)
check(action(.captureA) == .applied && player.playbackLoopB == nil && player.videoToolsLoopRange == nil,
      "Replacing A clears B and the previous loop")
settle()
var cancelled: PlayerCore.NativeLoopActionResult?
var cancellationCalls = 0
player.requestNativeLoopAction(.captureA) { cancelled = $0; cancellationCalls += 1 }
player.requestNativeLoopAction(.clear)
check(player.playbackLoopA == nil && player.playbackLoopB == nil && cancelled == nil,
      "Explicit clear invalidates marker state before delivering deferred cancellation")
check(waitUntil { cancelled != nil } && cancelled == .superseded && cancellationCalls == 1,
      "Explicit clear reports an outstanding capture as superseded exactly once")
settle()
check(player.playbackLoopA == nil && player.playbackLoopB == nil && cancellationCalls == 1,
      "An old worker callback cannot resurrect a cleared marker")
seek(0)
var ordered: [PlayerCore.NativeLoopActionResult] = []
player.requestNativeLoopAction(.captureA) { ordered.append($0) }
player.requestNativeLoopAction(.captureB) { ordered.append($0) }
check(waitUntil { ordered.count == 2 }, "Rapid A then B requests both complete in order")
check(ordered == [.applied, .invalid] && player.playbackLoopA == 0,
      "Rapid commands do not drop the pending A or treat zero as absent")
check(action(.clear) == .applied, "Rapid menu-cycle setup clears prior A")
settle()
player.abLoop()
player.abLoop()
check(waitUntil { player.info.abLoopStatus == .aSet && player.testPendingLoopRequests == 0 },
      "Rapid menu invocations establish A and finish both commands in order")
settle()
check(player.playbackLoopB == nil, "The second same-frame menu invocation cannot invent a valid B")
seek(0.65)
check(action(.captureA) == .applied, "Nonzero loop start is captured precisely")
seek(0.95)
check(action(.captureB) == .applied, "Short loop end is captured precisely")
settle()

observations.clear()
player.nativeTransport!.setRate(2)
player.resume()
check(waitUntil(5) {
  let videos = observations.snapshot().filter(\.video)
  return zip(videos, videos.dropFirst()).filter { $0.start > $1.start }.count >= 3
}, "Real decoded samples wrap through multiple A/B cycles at 2x")
player.pause()
settle()
let samples = observations.snapshot()
let outOfBounds = samples.filter { $0.start < 0.65 || $0.end > 0.95 }
if !outOfBounds.isEmpty {
  print("BOUNDARY: A=\(String(describing: player.playbackLoopA)) B=\(String(describing: player.playbackLoopB))")
  for sample in outOfBounds.prefix(5) { print("SAMPLE: video=\(sample.video) start=\(sample.start) end=\(sample.end) revision=\(sample.revision)") }
}
check(!samples.isEmpty && samples.allSatisfy { $0.start >= 0.65 && $0.end <= 0.95 },
      "Every observed audio/video sample remains inside the exact half-open range")
check(player.mpv.reads == 0 && player.mpv.writes == 0 && player.compatibilityRequests == 0,
      "Native markers, menu controls and navigation never touch the idle MPV core")
player.abLoop()
check(waitUntil { player.playbackLoopA == nil }, "The real menu cycle clears an active loop")
settle()
seek(0)
player.abLoop()
check(waitUntil { player.playbackLoopA != nil }, "Menu cycle begins with A")
seek(0.8)
player.abLoop()
check(waitUntil { player.playbackLoopB != nil }, "Menu cycle next establishes B")
settle()
var stale: PlayerCore.NativeLoopActionResult?
player.requestNativeLoopAction(.captureA) { stale = $0 }
player.seek(absoluteSecond: 0.4)
check(waitUntil { stale != nil } && stale == .superseded, "A same-turn explicit seek supersedes a marker capture")
settle()
var closed: PlayerCore.NativeLoopActionResult?
player.requestNativeLoopAction(.captureA) { closed = $0 }
player.testClose()
check(waitUntil { closed != nil } && closed == .superseded && player.playbackLoopA == nil,
      "Closing cancels pending capture without writing into the next media")
player.testOpen(url)
check(waitUntil { player.nativeTransport?.snapshot?.phase == .paused }, "A replacement native session opens")
check(player.playbackLoopA == nil && player.playbackLoopB == nil, "No marker survives into another media generation")
player.nativeReady = false
check(action(.captureA) == .unavailable, "A not-yet-ready native route rejects capture explicitly")
player.nativeReady = true
var reentrantCount = 0
var clearCount = 0
player.requestNativeLoopAction(.captureA) { result in
  if result == .superseded { reentrantCount += 1; player.testClose() }
}
player.requestNativeLoopAction(.clear) { result in
  if result == .applied { clearCount += 1 }
}
check(waitUntil { !player.isUsingNativePlayback }, "A cancelled capture callback may close without reentering the clear transaction")
check(reentrantCount == 1 && clearCount == 1 && player.testPendingLoopRequests == 0,
      "Reentrant cancellation completes each request exactly once without leaving a queued action")

// The bridge uses a controlled legacy property sink: this proves exact option
// restoration, not a claim of real MPV rendering or the complete tools panel.
player.info.videoDuration = VideoTime(4)
player.restoreNativeLoopToMPV(start: 0, end: 1)
check(player.mpv.getDouble(MPVOption.PlaybackControl.abLoopA) == 0 &&
      player.mpv.getString(MPVOption.PlaybackControl.abLoopCount) == "inf" &&
      player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 1),
      "Compatibility restoration preserves zero A and active loop count")
player.restoreNativeLoopToMPV(start: 0, end: nil)
check(player.mpv.getString(MPVOption.PlaybackControl.abLoopA) == "0.0" &&
      player.mpv.getString(MPVOption.PlaybackControl.abLoopB) == "no" && player.info.abLoopStatus == .aSet,
      "Compatibility restoration preserves A-only without inventing B")
player.restoreNativeLoopToMPV(start: nil, end: nil)
check(player.info.abLoopStatus == .cleared, "Absent optional markers restore as cleared, not a zero loop")
print("Native A/B loop controls: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
