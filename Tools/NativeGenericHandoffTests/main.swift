import AppKit
import AVFoundation

var passes = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
  if value() { passes += 1; print("PASS: \(name)") }
  else { failures += 1; print("FAIL: \(name)") }
}
var cores = [PlayerCore]()
@discardableResult
func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    for core in cores { for _ in 0..<16 { core.mpv.pump() } }
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while Date() < deadline
  return condition()
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = fixtureDirectory.appendingPathComponent("red.mp4")
let blue = fixtureDirectory.appendingPathComponent("blue.mp4")
Preference.pauseWhenOpen = true

func makeCore() -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  check(core.openMediaURLs([red], shouldAutoLoad: false) == 1, "Single local input is admitted")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, "Actual single native Session reaches readiness")
  check(core.nativeQueue == nil && !core.hasPendingPermanentRotation && core.urlPlaylistBatch == nil && !core.hasPendingURLPlaylistRestore,
        "Generic test has no queue rotation or enqueue owner")
  return core
}
func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback }, "Generic fixture retires its real Session")
  core.mainWindow.videoView.uninit(); core.mainWindow.close()
}

let intent = makeCore()
intent.seek(absoluteSecond: 1.1)
check(wait { abs((intent.playbackPosition ?? -1) - 1.1) < 0.05 }, "Generic source seeks to a nonzero real clock")
var delivered = 0, busyDelivered = 0, sawLoading = false
intent.mpv.client.afterCommand = { args in
  guard args.first == "loadfile", !sawLoading else { return }
  sawLoading = true
  intent.setVolume(37, unmute: true); intent.setSpeed(1.5)
  check(intent.playbackVolume == 37, "Loading retains latest generic volume")
  check(intent.currentPlaybackSpeed == 1.5, "Loading retains latest generic speed")
  intent.requireMPVCompatibility(reason: "busy request") { busyDelivered += 1 }
  check(busyDelivered == 0, "Busy generic action never executes on partial MPV")
  let handler = GenericShortcutHarness(intent)
  check(intent.videoToolsLoopRange == nil, "Typed handoff commands are tested without an A-B fallback")
  check(handler.handleGuardedPlaybackCommand(["seek", "0.3", "relative+exact"]), "Typed seek is admitted during a generic load")
  check(abs((intent.nativeCompatibilityRestore?.position ?? -1) - 1.4) < 0.05,
        "Typed seek reaches the owned restoration target")
  check(handler.handleGuardedPlaybackCommand(["set", "speed", "1.25"]), "Typed speed is admitted during a generic load")
  check(intent.currentPlaybackSpeed == 1.25, "Typed speed reaches the owned restoration intent")
  // Restore the earlier scenario's expected final intent through the real Core.
  intent.setSpeed(1.5)
  check(!handler.handleGuardedPlaybackCommand(["frame-step"]), "Typed frame stepping remains rejected while generic handoff is busy")
}
intent.requireMPVCompatibility(reason: "single file fixture") { delivered += 1 }
check(wait(10) { delivered == 1 }, "Generic handoff completes after a real MPV restart")
check(sawLoading && intent.mpv.getDouble("volume") == 37, "Verified generic restore commits latest volume")
check(sawLoading && intent.mpv.getDouble("speed") == 1.5, "Verified generic restore commits latest speed")
check(intent.genericHandoffOwner == nil && intent.nativeCompatibilityRestore == nil,
      "Generic owner is consumed after verified restoration")
intent.seek(absoluteSecond: 1.4)
_ = wait(0.2) { false }
check(delivered == 1, "Further real MPV restart cannot repeat the action")
close(intent)

for source in ["volume", "speed"] {
  let core = makeCore()
  var intercepted = false
  core.mpv.client.afterCommand = { args in
    guard args.first == "loadfile", !intercepted else { return }
    intercepted = true
    core.setVolume(57, unmute: true); core.setSpeed(1.5)
  }
  if source == "volume" { core.setVolume(137, constrain: false, unmute: true) }
  else { core.setSpeed(3) }
  check(wait(10) { intercepted && core.genericHandoffOwner == nil && core.info.state.loaded }, "Actual \(source) setter finishes its owned handoff")
  check(core.mpv.getDouble("volume") == 57, "Actual \(source) fallback preserves the latest volume intent")
  check(core.mpv.getDouble("speed") == 1.5, "Actual \(source) fallback preserves the latest speed intent")
  close(core)
}

let retiringIntent = makeCore()
if let session = retiringIntent.nativePlaybackSession,
   let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  var completed = 0
  retiringIntent.requireMPVCompatibility(reason: "retirement controls") { completed += 1 }
  worker.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
  check(entered.wait(timeout: .now() + 2) == .success, "Intent retirement worker barrier entered")
  check(wait { retiringIntent.nativeRetiring }, "Intent update exercises actual stopping state")
  retiringIntent.setVolume(57, unmute: true); retiringIntent.setSpeed(1.5)
  check(retiringIntent.playbackVolume == 57, "Retirement retains legal pending volume")
  release.signal()
  check(wait(10) { completed == 1 }, "Retirement intent reaches verified restoration")
  check(retiringIntent.mpv.getDouble("volume") == 57, "Retirement commits the latest volume")
  check(retiringIntent.mpv.getDouble("speed") == 1.5, "Retirement commits the latest speed")
} else { check(false, "Retirement intent finds actual Session worker") }
close(retiringIntent)

let captureIntent = makeCore()
if let session = captureIntent.nativePlaybackSession,
   let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  worker.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
  check(entered.wait(timeout: .now() + 2) == .success, "Capture intent worker barrier entered")
  var completed = 0
  captureIntent.requireMPVCompatibility(reason: "capture controls cancellation") { completed += 1 }
  captureIntent.setVolume(55, unmute: true); captureIntent.setSpeed(1.5)
  captureIntent.pause()
  release.signal()
  check(wait { captureIntent.genericHandoffOwner == nil }, "Pause invalidates the old capture action")
  check(captureIntent.isUsingNativePlayback && completed == 0, "Cancelled capture keeps the original native media")
  print("DIAGNOSTIC: cancelled_capture_volume=\(captureIntent.playbackVolume) speed=\(captureIntent.currentPlaybackSpeed)")
  // Session volume is a Float in 0...1; converting it to percent is not exact.
  check(abs(captureIntent.playbackVolume - 55) < 0.0001, "Cancelled capture retains accepted native volume")
  check(captureIntent.currentPlaybackSpeed == 1.5, "Cancelled capture retains accepted native speed")
  var verifiedSnapshot: NativePlaybackSnapshot?
  var queryingSnapshot = false
  check(wait {
    if verifiedSnapshot == nil && !queryingSnapshot {
      queryingSnapshot = true
      captureIntent.nativeTransport?.captureCurrentState { result in
        queryingSnapshot = false
        if case .ready(let snapshot) = result { verifiedSnapshot = snapshot }
      }
    }
    return verifiedSnapshot != nil
  }, "Cancelled capture obtains a fresh worker snapshot")
  check(abs(Double(verifiedSnapshot?.volume ?? -1) * 100 - 55) < 0.0001,
        "Cancelled capture applies the volume on the actual Session")
  check(verifiedSnapshot?.rate == 1.5, "Cancelled capture applies the speed on the actual Session")
} else { check(false, "Capture intent finds actual Session worker") }
close(captureIntent)

let repeatedIntent = makeCore()
if let session = repeatedIntent.nativePlaybackSession,
   let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  worker.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
  check(entered.wait(timeout: .now() + 2) == .success, "Repeated capture intent barrier entered")
  repeatedIntent.setVolume(137, constrain: false, unmute: true)
  repeatedIntent.setVolume(123, constrain: false, unmute: true); repeatedIntent.setSpeed(2.5)
  check(repeatedIntent.playbackVolume == 123 && repeatedIntent.currentPlaybackSpeed == 2.5,
        "Capturing getters show the latest unsupported intent")
  release.signal()
  check(wait(10) { !repeatedIntent.isUsingNativePlayback && repeatedIntent.genericHandoffOwner == nil && repeatedIntent.info.state.loaded },
        "Repeated capture intent completes its original handoff")
  check(repeatedIntent.mpv.getDouble("volume") == 123 && repeatedIntent.mpv.getDouble("speed") == 2.5,
        "Repeated unsupported capture values reach actual MPV")
} else { check(false, "Repeated capture intent finds actual Session worker") }
close(repeatedIntent)

let seekingIntent = makeCore()
seekingIntent.seek(absoluteSecond: 1.2)
check(wait { abs((seekingIntent.playbackPosition ?? -1) - 1.2) < 0.05 }, "Seek intent source reaches its captured clock")
seekingIntent.mpv.holdRestart = true
var seekCompletions = 0
seekingIntent.requireMPVCompatibility(reason: "late seek intent") { seekCompletions += 1 }
check(wait { seekingIntent.mpv.heldRestart != nil }, "Actual restoration seek is held before commit")
seekingIntent.setVolume(63, unmute: true); seekingIntent.setSpeed(1.25)
seekingIntent.resume(); seekingIntent.pause(); seekingIntent.seek(absoluteSecond: 2.3)
let seekingHandler = GenericShortcutHarness(seekingIntent)
check(seekingHandler.handleGuardedPlaybackCommand(["seek", "0", "relative+exact"]),
      "Typed seek is admitted while waiting for the verified restart")
check(seekingHandler.handleGuardedPlaybackCommand(["set", "speed", "1.25"]),
      "Typed speed is admitted while waiting for the verified restart")
seekingIntent.mpv.holdRestart = false
let earlierRestart = seekingIntent.mpv.heldRestart; seekingIntent.mpv.heldRestart = nil
earlierRestart?()
check(wait(10) { seekCompletions == 1 }, "Updated exact seek intent completes once")
check(seekingIntent.playbackIsPaused && abs((seekingIntent.playbackPosition ?? -1) - 2.3) < 0.05,
      "Restoration commits the latest pause and exact seek intent")
check(seekingIntent.mpv.getDouble("volume") == 63 && seekingIntent.mpv.getDouble("speed") == 1.25,
      "Restoration commits audio changes made during its exact seek")
earlierRestart?(); check(seekCompletions == 1, "Repeated late restart delivery does not repeat the action")
close(seekingIntent)

for phase in ["capture", "retire"] {
  for reopen in [false, true] {
    let core = makeCore()
    guard let session = core.nativePlaybackSession,
          let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue else {
      check(false, "Fixture finds immutable Session worker"); close(core); continue
    }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var completions = 0
    let block = { worker.async { entered.signal(); _ = release.wait(timeout: .now() + 5) } }
    if phase == "capture" { block(); check(entered.wait(timeout: .now() + 2) == .success, "Capture worker barrier entered") }
    core.requireMPVCompatibility(reason: "cancel \(phase)") { completions += 1 }
    if phase == "retire" {
      block()
      check(entered.wait(timeout: .now() + 2) == .success, "Retirement worker barrier entered")
      check(wait { core.nativeRetiring }, "Actual capture enters asynchronous retirement")
    }
    let oldEpoch = core.genericPlaybackMediaEpoch
    if reopen { _ = core.openMediaURLs([red], shouldAutoLoad: false) }
    else { core.stop() }
    release.signal()
    check(core.genericPlaybackMediaEpoch != oldEpoch, "\(phase) cancellation replaces even a same-path media epoch")
    check(wait { !core.nativeRetiring && (reopen ? core.info.state.loaded : !core.isUsingNativePlayback) },
          "\(phase) cancellation leaves the old decoder")
    check(completions == 0 && core.genericHandoffOwner == nil, "\(phase) cancellation never resurrects old generic action")
    check(core.mpv.client.appendCalls == 0, "\(phase) cancellation never loads the stale MPV source")
    close(core)
  }
}

for phase in ["load", "seek"] {
  for reopen in [false, true] {
    let delayed = makeCore()
    delayed.seek(absoluteSecond: 1.2)
    check(wait { abs((delayed.playbackPosition ?? -1) - 1.2) < 0.05 }, "\(phase) source has a nonzero captured position")
    delayed.mpv.holdLoaded = phase == "load"; delayed.mpv.holdRestart = phase == "seek"
    var delayedCompletion = 0
    delayed.requireMPVCompatibility(reason: "delayed actual \(phase)") { delayedCompletion += 1 }
    check(wait { phase == "load" ? delayed.mpv.heldLoaded != nil : delayed.mpv.heldRestart != nil },
          "Actual MPV \(phase) delivery can be held")
    let oldEvent = phase == "load" ? delayed.mpv.heldLoaded : delayed.mpv.heldRestart
    delayed.mpv.heldLoaded = nil; delayed.mpv.heldRestart = nil
    delayed.mpv.holdLoaded = false; delayed.mpv.holdRestart = false
    let oldEpoch = delayed.genericPlaybackMediaEpoch
    if reopen { _ = delayed.openMediaURLs([red], shouldAutoLoad: false) }
    else { delayed.stop() }
    oldEvent?(); oldEvent?()
    check(delayed.genericPlaybackMediaEpoch != oldEpoch, "\(phase) cancellation replaces the media epoch")
    if reopen {
      check(wait { delayed.info.state.loaded && delayed.genericHandoffOwner == nil },
            "Same-path \(phase) reopen completes independently of the old event")
    } else { _ = wait(0.1) { false } }
    check(delayedCompletion == 0 && delayed.genericHandoffOwner == nil,
          "Late real \(phase) callback cannot complete a cancelled action")
    close(delayed)
  }
}

let duplicate = makeCore()
duplicate.mpv.holdLoaded = true
var duplicateCompletion = 0
duplicate.requireMPVCompatibility(reason: "duplicate start delivery") { duplicateCompletion += 1 }
check(wait { duplicate.mpv.heldLoaded != nil }, "Duplicate-start test holds an actual loaded event")
// Replay a start for the same path as an adversarial delivery, not as a second
// real libmpv event. A path match alone must never reacquire the old owner.
duplicate.fileStarted(path: red.path)
let duplicatedLoad = duplicate.mpv.heldLoaded
duplicate.mpv.heldLoaded = nil; duplicate.mpv.holdLoaded = false
duplicatedLoad?()
_ = wait(0.2) { false }
check(duplicate.genericHandoffOwner == nil && duplicateCompletion == 0,
      "Duplicate same-path start cannot reacquire a generic owner")
close(duplicate)

for source in ["nativeEOF", "nearEOF"] {
  let core = makeCore()
  core.seek(absoluteSecond: source == "nativeEOF" ? 4.85 : 4.7)
  check(wait { (core.playbackPosition ?? 0) > 4.65 }, "\(source) reaches its actual source position")
  if source == "nativeEOF" { core.resume(); check(wait { core.playbackAtEOF }, "Actual native source reaches EOF") }
  var completed = 0
  core.requireMPVCompatibility(reason: "\(source) restoration") { completed += 1 }
  check(wait(10) { completed == 1 }, "\(source) compatibility action completes on actual MPV")
  check(core.playbackIsPaused && (core.playbackPosition ?? 0) >= 4.65,
        "\(source) restoration retains the source position and pause")
  close(core)
}

for notification in [Notification.Name.chengyingMediaSourceChanged, .iinaTracklistChanged, .iinaFileLoaded] {
  let core = makeCore()
  var fired = false, completion = 0
  core.notificationHook = { name in
    guard name == notification, core.genericHandoffOwner != nil, !fired else { return }
    fired = true; core.stop()
  }
  core.requireMPVCompatibility(reason: "notification reentry") { completion += 1 }
  check(wait { fired }, "Synchronous \(notification.rawValue) reentry is exercised")
  _ = wait(0.15) { false }
  check(completion == 0 && core.genericHandoffOwner == nil && core.nativeCompatibilityRestore == nil,
        "Synchronous \(notification.rawValue) stop cannot restore the cancelled action")
  core.notificationHook = nil; close(core)
}

for event in [EventDouble.Name.fileStarted, .fileLoaded] {
  for reopen in [false, true] {
    let core = makeCore()
    var fired = false, completion = 0
    core.events.onEmit = { name in
      guard name == event, core.genericHandoffOwner != nil, !fired else { return }
      fired = true
      if reopen { _ = core.openMediaURLs([red], shouldAutoLoad: false) }
      else { core.stop() }
    }
    core.requireMPVCompatibility(reason: "event reentry") { completion += 1 }
    check(wait { fired }, "Synchronous \(event) reentry is exercised")
    _ = wait(0.2) { false }
    check(completion == 0 && core.genericHandoffOwner == nil && core.nativeCompatibilityRestore == nil,
          "Synchronous \(event) reentry cannot restore a cancelled action")
    if reopen { check(wait { core.info.state.loaded }, "Event reentry reopens the same file independently") }
    core.events.onEmit = nil; close(core)
  }
}

let completionReentry = makeCore()
var reentryDeliveries = 0
completionReentry.requireMPVCompatibility(reason: "completion reentry") {
  reentryDeliveries += 1
  _ = completionReentry.openMediaURLs([blue], shouldAutoLoad: false)
}
check(wait(10) { reentryDeliveries == 1 && completionReentry.info.currentURL == blue && completionReentry.info.state.loaded },
      "Verified completion may synchronously open a new file")
completionReentry.seek(absoluteSecond: 1)
_ = wait(0.2) { false }
check(reentryDeliveries == 1 && completionReentry.genericHandoffOwner == nil && completionReentry.playbackVolume == 0,
      "Completion reentry cannot repeat or carry audio intent into the new file")
close(completionReentry)
print("Generic handoff checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
