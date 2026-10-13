import Cocoa

var checks = 0
var failures = 0
setbuf(stdout, nil)
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  checks += 1
  if !value() { failures += 1; print("FAIL: \(label)") }
}
func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
func prepare(_ core: PlayerCore) -> NativePlaybackTransport {
  let transport = core.nativeTransport!
  transport.answer(.ready(.init(phase: .playing, position: 2)))
  check(core.nativeRetiring, "Enqueue captures the worker state before retirement")
  return transport
}
func load(_ core: PlayerCore, _ transport: NativePlaybackTransport) {
  transport.session.finish()
  check(core.nativeTransport == nil && core.info.state == .loading, "Compatibility load waits for native retirement")
  core.info.state = .loaded
  core.fileStartedReceiptBoundary()
  core.fileLoadedBoundary()
}
func finish(_ core: PlayerCore) {
  core.playbackPosition = core.nativeCompatibilityRestore?.position ?? 2
  core.restartBoundary()
}
func cleanup(_ core: PlayerCore) { core.resetURLPlaylistEnqueue(); core.nativeTransport?.session.finish(); pump() }

do {
  let core = PlayerCore(); let transport = core.nativeTransport!
  transport.volumePercent = 37; transport.rate = 1.25
  core.nativeLoopA = 1; core.nativeLoopB = 8
  core.nativeViewport = .init(zoom: 1, panX: 0.2, panY: -0.1)
  var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  core.enqueueURLPlaybackPaths(["/synthetic/b.mp4", "/synthetic/c.mp4"]) { results.append($0) }
  check(transport.captureCalls == 1, "Continuous enqueue starts exactly one compatibility capture")
  check(core.mpv.commands.isEmpty, "No append reaches the idle MPV during native capture")
  _ = prepare(core)
  core.enqueueURLPlaybackPaths(["/synthetic/d.mp4"]) { results.append($0) }
  core.pause(); core.seek(absoluteSecond: 4)
  check(core.pendingRotationPlaybackRestore?.paused == true, "Latest pause intent remains owned during retirement")
  check(core.pendingRotationPlaybackRestore?.position == 4, "Latest seek intent is retained while retiring")
  check(core.nativeCompatibilityRestore?.volume == 37 && core.nativeCompatibilityRestore?.rate == 1.25 &&
        core.nativeCompatibilityRestore?.loopA == 1 && core.nativeCompatibilityRestore?.loopB == 8 &&
        core.nativeCompatibilityRestore?.viewport.panX == 0.2, "The same-media restore keeps volume rate A/B and viewport")
  load(core, transport)
  core.enqueueURLPlaybackPaths(["/synthetic/e.mp4"]) { results.append($0) }
  check(core.mpv.commands.isEmpty && results.isEmpty, "Enqueue while MPV loads never appends before the exact restore")
  let late = core.nativeCompatibilityRestore!.completion
  core.playbackPosition = 1; core.restartBoundary()
  check(core.mpv.commands.isEmpty, "Wrong restart position cannot deliver the batch")
  finish(core)
  check(results == [1, 2, 1, 1], "Every accepted request completes with its actual append count")
  check(core.mpv.commands == ["a", "b", "c", "d", "e"].map { "append:/synthetic/\($0).mp4" },
        "Requests remain ordered through capture retirement and loading")
  check(core.mpvPlaybackTransport.paused && core.mpvPlaybackTransport.seeks.last?.value == 4,
        "Restored MPV retains the latest paused seek target")
  late(); late()
  check(results.count == 4 && core.mpv.commands.count == 5, "A duplicate completion never appends twice")
  cleanup(core)
}

for phase in 0...2 {
  for action in 0...2 {
    let core = PlayerCore(); let transport = core.nativeTransport!; var results: [Int] = []
    core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
    if phase >= 1 { _ = prepare(core) }
    if phase >= 2 { load(core, transport) }
    let late = core.nativeCompatibilityRestore?.completion
    if action == 0 { core.open(core.info.currentURL) }
    else if action == 1 { core.stop() }
    else { core.shutdown() }
    pump()
    check(results == [0], action == 0 ? "Same-URL user reopen cancels the old enqueue exactly once" :
          "Stop and shutdown cancel the old enqueue exactly once")
    transport.answer(.ready(.init(phase: .playing, position: 2))); transport.session.finish()
    late?(); pump()
    check(!core.mpv.commands.contains(where: { $0.hasPrefix("append:") }) && results == [0],
          "Late capture retirement and completion cannot append into replacement media")
    cleanup(core)
  }
}

do {
  let core = PlayerCore(); let transport = core.nativeTransport!; var old: [Int] = []; var newer: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { old.append($0) }
  let staleCallbacks = transport.captures; transport.captures = []
  core.urlPlaylistTimeout?.fire(); pump()
  check(old == [0] && core.nativeCompatibilityCaptureID == nil, "Watchdog clears only its owned withheld capture")
  core.enqueueURLPlaybackPaths(["/synthetic/b.mp4"]) { newer.append($0) }
  let currentID = core.nativeCompatibilityCaptureID
  staleCallbacks.forEach { $0(.ready(.init(phase: .paused, position: 2))) }
  check(core.nativeCompatibilityCaptureID == currentID && core.hasPendingURLPlaylistEnqueue,
        "Late cancelled capture cannot clear the next batch owner")
  _ = prepare(core); load(core, transport); finish(core)
  check(old == [0] && newer == [1] && core.mpv.commands == ["append:/synthetic/b.mp4"],
        "A later batch can succeed without replaying a timed-out request")
  cleanup(core)
}

for termination in [false, true] {
  let core = PlayerCore(); var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  let transport = prepare(core)
  core.urlPlaylistTimeout?.fire(); pump()
  check(results == [0] && core.pendingRotationPlaybackRestore != nil,
        "Action timeout preserves same-media playback restoration")
  core.pause(); core.seek(absoluteSecond: 5)
  check(core.nativeCompatibilityRestore?.paused == true && core.nativeCompatibilityRestore?.position == 5,
        "Latest intent remains accepted after enqueue action cancellation")
  if termination {
    core.fileEnded(false)
    check(core.nativeCompatibilityRestore == nil && core.pendingRotationPlaybackRestore == nil,
          "Error or EOF clears an owned URL restore even without a pending batch")
  } else {
    load(core, transport); finish(core)
    check(core.mpv.commands.isEmpty && results == [0], "Cancelled enqueue never prevents a playback-only restore")
  }
  cleanup(core)
}

do {
  let core = PlayerCore(); var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { count in
    results.append(count)
    core.open(core.info.currentURL)
  }
  core.enqueueURLPlaybackPaths(["/synthetic/b.mp4"]) { results.append($0) }
  let transport = prepare(core); load(core, transport); finish(core)
  check(core.mpv.commands == ["append:/synthetic/a.mp4", "append:/synthetic/b.mp4"],
        "All append commands precede reentrant user callbacks")
  check(results == [1, 0], "A callback opening media suppresses later stale success receipts")
  cleanup(core)
}

do {
  let core = PlayerCore(); var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4", "/synthetic/reject.mp4", "/synthetic/no-callback.mp4"]) { results.append($0) }
  let transport = prepare(core); load(core, transport); finish(core)
  check(results == [1], "Failed MPV commands never count as success")
  cleanup(core)
}

do {
  let core = PlayerCore(); var accepted = 0; var rejected = 0
  core.enqueueURLPlaybackPaths([]) { if $0 == 0 { rejected += 1 } }
  core.enqueueURLPlaybackPaths(["https://example.invalid/a.mp4", "/synthetic/image.png"]) { if $0 == 0 { rejected += 1 } }
  check(!core.hasPendingURLPlaylistEnqueue && core.nativeTransport!.captureCalls == 0,
        "Empty and unsupported paths retain no callback or transition")
  for _ in 0..<64 { core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { if $0 > 0 { accepted += 1 } else { rejected += 1 } } }
  core.enqueueURLPlaybackPaths(["/synthetic/extra.mp4"]) { if $0 == 0 { rejected += 1 } }
  check(core.urlPlaylistBatch?.requests.count == 64 && rejected == 3, "Request budget rejects new callbacks without evicting prior requests")
  let transport = prepare(core); load(core, transport); finish(core)
  check(accepted == 64 && core.mpv.commands.count == 64, "Accepted capacity-bound requests all complete exactly once")
  cleanup(core)
}
for paths in [Array(repeating: "/synthetic/a.mp4", count: 257), ["/" + String(repeating: "a", count: 1_048_576)]] {
  let core = PlayerCore(); var result: Int?
  core.enqueueURLPlaybackPaths(paths) { result = $0 }
  check(result == 0 && !core.hasPendingURLPlaylistEnqueue && core.nativeTransport!.captureCalls == 0,
        "Path-count and UTF8-byte bounds reject before retaining a batch")
  cleanup(core)
}
do {
  let core = PlayerCore()
  check(core.validateURLPlaylistEnqueueOptions(["url", "enqueue"]), "Plain native URL enqueue options are supported")
  for key in ["new_window", "full_screen", "pip", "mpv_volume"] {
    check(!core.validateURLPlaylistEnqueueOptions(["url", "enqueue", key]), "Mixed native URL options are explicitly rejected")
  }
  check(core.nativeTransport!.captureCalls == 0 && core.opened.isEmpty && !core.hasPendingURLPlaylistEnqueue,
        "Rejected mixed options have no queued or opening side effects")
  core.nativeTransport = nil
  check(core.validateURLPlaylistEnqueueOptions(["url", "enqueue", "full_screen"]), "Legacy URL option validation remains unchanged")
  cleanup(core)
}
do {
  let core = PlayerCore(); var results: [Int] = []; var action = 0
  core.requireMPVCompatibility(reason: "Existing action") { action += 1 }
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  check(results == [0] && core.nativeTransport!.captureCalls == 1, "Enqueue cannot replace another compatibility capture")
  let transport = prepare(core); load(core, transport); finish(core)
  check(action == 1 && core.mpv.commands.isEmpty, "Rejected enqueue preserves the existing compatibility action")
  cleanup(core)
}

do {
  let core = PlayerCore(); urlFixtureActiveCore = core
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/a.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: false)
  let transport = prepare(core)
  transport.session.finish()
  check(core.info.state == .loading, "URL dispatch reaches the actual compatibility loading boundary")
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/b.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: true)
  check(core.urlFallbackOpens == 0 && core.urlPlaylistBatch?.requests.count == 2,
        "The actual URL branch queues during an empty compatibility playlist")
  core.info.state = .loaded; core.fileLoadedBoundary(); finish(core); pump()
  check(core.mpv.commands == ["append:/synthetic/a.mp4", "append:/synthetic/b.mp4"] && core.displayedOSDs == 2,
        "Actual URL completion callbacks report both successful appends")
  cleanup(core)
}
for reenterFromNotification in [true, false] {
  let core = PlayerCore(); urlFixtureActiveCore = core
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/a.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: false)
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/b.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: false)
  let transport = prepare(core); load(core, transport)
  if reenterFromNotification {
    core.testNotificationHook = { [weak core] in
      guard let core else { return }
      core.testNotificationHook = nil
      core.open(core.info.currentURL)
    }
  }
  finish(core)
  if !reenterFromNotification { core.open(core.info.currentURL) }
  pump()
  check(core.displayedOSDs == 0, "Final asynchronous OSD checks the receipt after notification reentry")
  if reenterFromNotification {
    check(core.notices == 1, "The tail URL callback never posts an old success notification into a new file")
  }
  check(core.mpv.commands.count == 2, "Notification reentry never replays already appended paths")
  cleanup(core)
}
do {
  let core = PlayerCore(); core.nativeTransport = nil
  urlFixtureActiveCore = core
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/reject.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: false)
  pump()
  check(core.notices == 0 && core.displayedOSDs == 0, "The actual URL branch never reports a failed MPV append as success")
  cleanup(core)
}
for sameURL in [false, true] {
  let core = PlayerCore(); urlFixtureActiveCore = core
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/a.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: false)
  let transport = prepare(core); load(core, transport); finish(core)
  if !sameURL { core.info.currentURL = URL(fileURLWithPath: "/synthetic/next.mp4") }
  core.fileStartedReceiptBoundary(); pump()
  check(core.displayedOSDs == 0, "A non-owned MPV file-start invalidates queued success OSD")
  check(core.mpv.commands.count == 1, "Changing playback does not replay completed appends")
  cleanup(core)
}
do {
  let core = PlayerCore(); urlFixtureActiveCore = core
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { _ in }
  let transport = prepare(core); transport.session.finish()
  core.urlPlaylistTimeout?.fire(); pump()
  check(core.hasPendingURLPlaylistEnqueue && core.urlPlaylistBatch == nil,
        "A playback-only restore still routes URL events through enqueue admission")
  check(!core.validateURLPlaylistEnqueueOptions(["url", "enqueue", "pip"]),
        "Mixed options remain rejected after action timeout during loading")
  dispatchURLPlaylistBranch(queryDict: ["url": "/synthetic/b.mp4", "enqueue": "1"],
    player: core, enqueueRecipient: core, fixturePlaylistEmpty: true)
  check(core.urlFallbackOpens == 0 && core.nativeCompatibilityRestore != nil,
        "A timed-out action cannot turn a later enqueue into an open")
  core.info.state = .loaded; core.fileLoadedBoundary(); finish(core)
  check(core.mpv.commands.isEmpty, "Playback-only restoration contains no cancelled enqueue command")
  cleanup(core)
}
urlFixtureActiveCore = nil

do {
  let core = PlayerCore(); var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  let transport = prepare(core); load(core, transport)
  let owner = UUID()
  check(UpdateWorkAdmission.shared.acquire(owner), "The real update admission can close before batch drain")
  let messages = core.osds
  finish(core)
  check(results == [0] && core.mpv.commands.isEmpty && core.osds > messages,
        "A newly blocked drain explicitly fails without appending")
  UpdateWorkAdmission.shared.release(owner)
  cleanup(core)
}
do {
  let core = PlayerCore(); var results: [Int] = []; var competingAction = 0
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  core.requireMPVCompatibility(reason: "Competing frame step") { competingAction += 1 }
  check(core.nativeTransport!.captureCalls == 1 && competingAction == 0 && core.hasPendingURLPlaylistEnqueue,
        "An unrelated compatibility action cannot replace an enqueue owner")
  let transport = prepare(core); load(core, transport); finish(core)
  check(results == [1] && competingAction == 0, "Busy rejection preserves the accepted enqueue completion")
  cleanup(core)
}
for superseded in [false, true] {
  let core = PlayerCore(); var results: [Int] = []
  core.enqueueURLPlaybackPaths(["/synthetic/a.mp4"]) { results.append($0) }
  if superseded { core.nativeTransport!.answer(.superseded) }
  else {
    core.pause()
    core.nativeTransport!.answer(.ready(.init(phase: .paused, position: 2)))
  }
  pump()
  check(results == [0] && !core.hasPendingURLPlaylistEnqueue && !core.nativeRetiring && core.mpv.commands.isEmpty,
        "A newer intent before capture explicitly cancels instead of silently replacing state")
  cleanup(core)
}
do {
  let core = PlayerCore(); var rejected = 0
  core.enqueueURLPlaybackPaths(Array(repeating: "/synthetic/a.mp4", count: 250)) { _ in }
  core.enqueueURLPlaybackPaths(Array(repeating: "/synthetic/b.mp4", count: 7)) { if $0 == 0 { rejected += 1 } }
  check(rejected == 1 && core.urlPlaylistBatch?.pathCount == 250 && core.urlPlaylistBatch?.requests.count == 1,
        "Aggregate path limit rejects a whole new request and preserves earlier order")
  cleanup(core)
}
do {
  let core = PlayerCore(); var rejected = 0
  let path = "/" + String(repeating: "a", count: 600_000)
  core.enqueueURLPlaybackPaths([path]) { _ in }
  core.enqueueURLPlaybackPaths([path]) { if $0 == 0 { rejected += 1 } }
  check(rejected == 1 && core.urlPlaylistBatch?.byteCount == 600_001 && core.urlPlaylistBatch?.requests.count == 1,
        "Aggregate UTF8 limit rejects a whole new request and preserves earlier payloads")
  cleanup(core)
}

print("RESULT: \(checks) checks; \(failures) failures")
exit(failures == 0 ? 0 : 1)
