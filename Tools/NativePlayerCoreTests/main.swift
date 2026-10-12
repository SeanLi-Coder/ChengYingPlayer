import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func native() -> (PlayerCore, NativePlaybackTransport) {
  let core = PlayerCore()
  let transport = NativePlaybackTransport()
  core.nativeTransport = transport
  core.nativeReady = true
  core.info.state = .playing
  core.advancePlaybackRoute(acceptsMPV: false)
  return (core, transport)
}
@discardableResult
func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return condition()
}

do {
  let core = PlayerCore()
  core.stop()
  check(core.info.state == .idle && core.mpv.commands.isEmpty, "Default idle stop does not issue redundant MPV stop")
  core.info.state = .playing
  core.stop()
  check(core.info.state == .stopping && core.mpv.commands == ["stop"], "Default active stop keeps legacy MPV behavior")
  core.info.state = .idle
  core.shutdown()
  check(core.info.state == .shuttingDown && core.mpv.commands.last == "quit", "Default shutdown still uses real MPV quit")
}
do {
  let (core, transport) = native()
  core.stop()
  check(core.nativeRetiring && core.info.state == .stopping, "Native stop starts asynchronous retirement")
  check(core.mpv.commands.isEmpty && transport.session.shutdownCalls == 1, "Native stop never waits or sends premature MPV commands")
  let next = URL(fileURLWithPath: "/synthetic-b.mp4")
  core.pendingUrl = next
  transport.session.finish()
  check(core.nativeTransport == nil && core.info.state == .idle, "Native stop clears transport only after shutdown completes")
  check(core.opened.map { $0.0 } == [next] && core.stoppedNotifications == 1, "Queued media opens after stop acknowledgement")
}
do {
  let (core, transport) = native()
  core.shutdown()
  core.stop()
  core.open(URL(fileURLWithPath: "/synthetic-b.mp4"))
  var forbiddenAction = 0
  core.requireMPVCompatibility(reason: "after-shutdown") { forbiddenAction += 1 }
  core.shutdown()
  transport.session.finish()
  check(core.info.state == .shuttingDown && core.mpv.commands == ["quit"],
        "Shutdown intent cannot be replaced by a later window-close stop")
  check(core.opened.isEmpty && core.stoppedNotifications == 0, "Termination cannot publish a stopped-and-reopen callback")
  check(forbiddenAction == 0 && transport.session.shutdownCalls == 1,
        "Open, compatibility requests and duplicate shutdown cannot displace terminal intent")
}
do {
  let (core, transport) = native()
  core.stop()
  core.shutdown()
  transport.session.finish()
  check(core.info.state == .shuttingDown && core.mpv.commands == ["quit"],
        "Shutdown supersedes an outstanding native stop")
  check(transport.session.shutdownCalls == 1, "One native session has only one shutdown request")
}
do {
  let (core, transport) = native()
  let batch = [URL(fileURLWithPath: "/synthetic-b.mp4"), URL(fileURLWithPath: "/synthetic-c.mp4")]
  check(core.openMediaURLs(batch) == 2, "Batch open reports accepted media count")
  check(core.opened.isEmpty && core.mpv.appended.isEmpty && transport.session.shutdownCalls == 1,
        "A batch waits for native retirement before loading or appending any MPV media")
  transport.session.finish()
  check(core.opened.map { $0.0 } == [batch[0]] && core.mpv.appended == [batch[1].path],
        "A batch is loaded and appended together after native retirement")
}
do {
  let (core, transport) = native()
  let older = [URL(fileURLWithPath: "/synthetic-b.mp4"), URL(fileURLWithPath: "/synthetic-c.mp4")]
  let newer = [URL(fileURLWithPath: "/synthetic-d.mp4"), URL(fileURLWithPath: "/synthetic-e.mp4")]
  core.openMediaURLs(older)
  core.openMediaURLs(newer)
  transport.session.finish()
  check(core.opened.map { $0.0 } == [newer[0]] && core.mpv.appended == [newer[1].path],
        "Only the newest complete batch survives an asynchronous handoff")
}
do {
  let (core, transport) = native()
  let batch = [URL(fileURLWithPath: "/synthetic-b.mp4"), URL(fileURLWithPath: "/synthetic-c.mp4")]
  core.openMediaURLs(batch)
  core.shutdown()
  check(core.openMediaURLs(batch) == nil, "Termination rejects additional batch requests")
  transport.session.finish()
  check(core.opened.isEmpty && core.mpv.appended.isEmpty && core.mpv.commands == ["quit"],
        "Termination cancels the complete pending batch before any MPV media command")
}
do {
  let (core, transport) = native()
  var invoked = 0
  core.requireMPVCompatibility(reason: "fixture") { invoked += 1 }
  core.stop()
  transport.answer(.ready(.init(phase: .playing, position: 1.25)))
  transport.session.finish()
  check(core.nativeCompatibilityRestore == nil && core.opened.isEmpty && invoked == 0,
        "A capture returned after stop cannot revive compatibility playback")
}
do {
  let (core, transport) = native()
  var invoked = 0
  core.requireMPVCompatibility(reason: "fixture") { invoked += 1 }
  transport.answer(.ready(.init(phase: .playing, position: 1.25)))
  check(core.nativeRetiring && core.opened.isEmpty, "Fallback waits for the native session to release output")
  core.shutdown()
  transport.session.finish()
  check(core.mpv.commands == ["quit"] && core.opened.isEmpty && invoked == 0,
        "Shutdown supersedes a compatibility handoff without reopening media")
}
do {
  let (core, transport) = native()
  var invoked = 0
  core.requireMPVCompatibility(reason: "fixture") { invoked += 1 }
  transport.answer(.ready(.init(phase: .playing, position: 1.25)))
  let next = URL(fileURLWithPath: "/synthetic-b.mp4")
  core.open(next)
  transport.session.finish()
  check(core.opened.map { $0.0 } == [next] && core.nativeCompatibilityRestore == nil && invoked == 0,
        "A newer open during fallback retirement supersedes the old media and its action")
}
do {
  let (core, transport) = native()
  var invoked = 0
  core.requireMPVCompatibility(reason: "fixture") { invoked += 1 }
  transport.answer(.ready(.init(phase: .playing, position: 1.25)))
  transport.session.finish()
  check(core.nativeTransport == nil && core.mpv.prepared == 1 && core.captureMPVEventRevision() != nil,
        "Fallback prepares the first-start barrier before enabling compatibility playback")
  check(core.opened.count == 1 && core.opened[0].1 == false && invoked == 0,
        "Fallback opens MPV once and defers the action until restoration")
  let restore = core.nativeCompatibilityRestore
  check(restore?.position == 1.25 && restore?.volume == 70 && restore?.rate == 1.2 && restore?.paused == false,
        "Fallback snapshots the current position, volume, rate and pause state")
}
do {
  let (core, transport) = native()
  let first = VideoToolsViewport(zoom: log2(1.5), panX: 0.1, panY: -0.1)
  let latest = VideoToolsViewport(zoom: log2(2), panX: -0.2, panY: 0.15)
  check(core.applyNativeViewport(first), "Loaded native accepts a validated viewport before fallback")
  core.requireMPVCompatibility(reason: "viewport") {}
  check(core.applyNativeViewport(latest), "Viewport remains interactive during asynchronous clock capture")
  transport.answer(.ready(.init(phase: .paused, position: 1.25)))
  check(!core.applyNativeViewport(first), "Retirement freezes the accepted viewport before handoff")
  transport.session.finish()
  check(core.nativeCompatibilityRestore?.viewport == latest,
        "Compatibility snapshot preserves the latest accepted linear zoom and normalized pan")
}
do {
  let (core, transport) = native()
  core.nativeLoopA = 0
  core.nativeLoopB = 3
  core.requireMPVCompatibility(reason: "preroll") {}
  transport.answer(.unavailable)
  check(!core.nativeRetiring && core.opened.isEmpty,
        "A ready preroll never silently restores the file at zero")
  check(waitUntil { !transport.captures.isEmpty }, "Preroll compatibility capture retries without blocking main")
  transport.answer(.ready(.init(phase: .paused, position: 2.25)))
  transport.session.finish()
  check(core.nativeCompatibilityRestore?.position == 2.25 && core.nativeCompatibilityRestore?.loopA == 0 &&
        core.nativeCompatibilityRestore?.loopB == 3 && core.nativeCompatibilityRestore?.paused == true,
        "Precise compatibility retry preserves position, pause and optional zero A/B")
}
do {
  let (core, transport) = native()
  core.requireMPVCompatibility(reason: "obsolete-preroll") {}
  transport.answer(.unavailable)
  core.videoToolsMediaGeneration &+= 1
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  check(transport.captures.isEmpty && !core.nativeRetiring && core.opened.isEmpty,
        "A new media generation cancels scheduled compatibility retries")
}
do {
  let (core, transport) = native()
  core.requireMPVCompatibility(reason: "timeout") {}
  check(waitUntil(3) {
    transport.answer(.unavailable)
    return core.logs.contains { $0.contains("capture timed out") }
  }, "Unavailable exact capture terminates at its bounded deadline")
  check(core.nativeTransport === transport && !core.nativeRetiring && core.opened.isEmpty && core.osdCount == 1,
        "Capture timeout reports the failure and leaves native playback active")
  core.requireMPVCompatibility(reason: "recovered") {}
  transport.answer(.ready(.init(phase: .playing, position: 1.5)))
  transport.session.finish()
  check(core.opened.count == 1 && core.nativeCompatibilityRestore?.position == 1.5,
        "A later compatibility request can succeed after capture timeout")
}
do {
  let (core, transport) = native()
  var callbacks = 0
  core.nativeLoopRequests.append(.init(action: .captureA, completion: { result in
    guard result == .superseded else { return }
    callbacks += 1
    core.stop()
    core.open(URL(fileURLWithPath: "/synthetic-reentrant.mp4"))
  }))
  core.shutdown()
  check(callbacks == 0 && core.nativeLoopRequests.isEmpty,
        "Shutdown invalidates marker requests before invoking cancellation callbacks")
  check(waitUntil { callbacks == 1 }, "Shutdown delivers cancellation exactly once on a later main turn")
  transport.session.finish()
  check(core.mpv.commands == ["quit"] && core.opened.isEmpty && core.nativeRetirementCompletion == nil,
        "A cancelled marker callback cannot replace terminal retirement with stop or open")
}
do {
  let (core, transport) = native()
  var callbacks = 0
  core.nativeLoopRequests.append(.init(action: .captureB, completion: { result in
    if result == .superseded { callbacks += 1; core.shutdown() }
  }))
  core.stop()
  check(waitUntil { callbacks == 1 }, "A stop cancellation callback may request shutdown on the next main turn")
  transport.session.finish()
  check(core.mpv.commands == ["quit"] && core.info.state == .shuttingDown && core.stoppedNotifications == 0,
        "Reentrant cancellation preserves shutdown priority over an outstanding native stop")
}
print("PASS: \(checks) extracted PlayerCore lifecycle checks (controlled session boundaries)")
