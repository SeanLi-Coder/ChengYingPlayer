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
print("PASS: \(checks) extracted PlayerCore lifecycle checks (controlled session boundaries)")
