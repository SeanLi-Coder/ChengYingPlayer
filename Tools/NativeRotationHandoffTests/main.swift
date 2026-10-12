import Cocoa
import IOKit.hidsystem

var checks = 0
var failures = 0
setbuf(stdout, nil)
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  checks += 1
  if !value() { failures += 1; print("FAIL: \(label)") }
}
func pump(_ seconds: Double = 0.03) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
func until(_ condition: () -> Bool) {
  let end = ProcessInfo.processInfo.systemUptime + 1
  while !condition(), ProcessInfo.processInfo.systemUptime < end { pump(0.005) }
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
let window = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 180, height: 80),
  styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
let focusDeadline = ProcessInfo.processInfo.systemUptime + 3
while NSApp.keyWindow !== window, ProcessInfo.processInfo.systemUptime < focusDeadline {
  while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
  if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
  pump(0.005)
}
check(NSApp.keyWindow === window, "The controlled CLI window becomes key")
if NSApp.keyWindow !== window { window.close(); exit(1) }
func event(_ key: UInt16, right: Bool = false, repeated: Bool = false, plain: Bool = false) -> NSEvent {
  let cg = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
  if !plain {
    cg.flags = CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue) |
      UInt64(right ? NX_DEVICERCMDKEYMASK : NX_DEVICELCMDKEYMASK))
  }
  if repeated { cg.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
  return NSEvent(cgEvent: cg)!
}
func press(_ core: PlayerCore, _ key: UInt16 = 37, right: Bool = false, repeated: Bool = false, plain: Bool = false) -> Bool {
  PlayerWindowController(core, window: window).handleVideoToolsShortcutEvent(event(key, right: right, repeated: repeated, plain: plain))
}
func panel(_ core: PlayerCore) -> Panel { core.mainWindow.quickSettingView.videoToolsViewController! }
func enterRetirement(_ core: PlayerCore) -> NativePlaybackTransport {
  let transport = core.nativeTransport!
  transport.answer(.ready(.init(phase: .paused, position: 2)))
  check(core.nativeRetiring && core.info.state == .stopping, "Capture reaches real asynchronous retirement arbitration")
  return transport
}
func finishLoad(_ core: PlayerCore, _ transport: NativePlaybackTransport) {
  transport.session.finish()
  check(core.nativeTransport == nil && core.info.state == .loading, "Retirement completes before controlled MPV load")
  core.fileStartedBoundary()
  core.info.state = .loaded
  core.fileLoadedBoundary()
}
func finishRestore(_ core: PlayerCore) {
  core.playbackPosition = 2
  core.restartBoundary()
  until { !panel(core).tasks.requests.isEmpty }
}
func clean(_ core: PlayerCore) {
  core.cancelPendingPermanentRotation()
  panel(core).coordinator.reset(cancelActive: false)
  core.nativeTransport?.session.finish()
}

// Actual NSEvent resolution and production window entry, not OS key injection.
do {
  let core = PlayerCore()
  check(press(core), "The first physical left-command rotation is accepted")
  let ticket = core.permanentRotationIntent.pendingTicket!
  check(press(core), "Second rotation before capture is accumulated")
  check(core.nativeTransport!.captureCalls == 1 && panel(core).previewCancellations == 1,
        "Repeated presses start exactly one capture and one preview cancellation")
  let transport = enterRetirement(core)
  check(press(core), "Rotation during stopping is accumulated")
  check(!press(core, 8, plain: true), "Unrelated speed shortcut retains its loaded gate")
  check(press(core, repeated: true), "Auto-repeat rotation is consumed without another quarter turn")
  check(!press(core, right: true), "Right-command rotation remains rejected")
  transport.session.finish()
  check(core.info.state == .loading, "The loaded gate really is false while MPV is loading")
  check(press(core), "Rotation during loading is accumulated")
  check(core.nativeCompatibilityRestore?.rotationRequestID == ticket.requestID, "Owned restore keeps its unique request")
  core.fileStartedBoundary()
  check(core.permanentRotationIntent.mediaEpoch == ticket.mediaEpoch, "Owned compatibility reload preserves logical media epoch")
  core.info.state = .loaded
  core.fileLoadedBoundary()
  check(core.hasPendingPermanentRotation && panel(core).tasks.requests.isEmpty,
        "Internal exact restore seek cannot cancel or prematurely submit rotation")
  let completion = core.nativeCompatibilityRestore!.completion
  core.playbackPosition = 1
  core.restartBoundary()
  check(panel(core).tasks.requests.isEmpty && core.hasPendingPermanentRotation, "Wrong MPV restart position does not export")
  finishRestore(core)
  check(panel(core).tasks.requests.count == 1 && panel(core).tasks.requests.first?.degrees == 360,
        "All four left presses produce one cumulative full-turn export request")
  completion(); pump()
  check(panel(core).deliveries == 1 && !core.hasPendingPermanentRotation, "A repeated completion cannot submit again")
  check(panel(core).tasks.requests.first?.inputURL == core.info.currentURL, "Coordinator receives the original source")
  clean(core)
}
do {
  let core = PlayerCore(); core.nativePreviewInProgress = true
  panel(core).requestPermanentRotation(clockwiseQuarterTurns: 1)
  check(core.hasPendingPermanentRotation && core.previewRestoreCalls == 1, "The real panel request starts one preview restore")
  check(press(core), "Shortcut can join a panel-owned transition")
  panel(core).requestPermanentRotation(clockwiseQuarterTurns: 1)
  check(core.previewRestoreCalls == 1 && core.nativeTransport!.captureCalls == 0 && panel(core).errors == 0,
        "Panel and shortcut share one pending restore rather than cancelling each other")
  core.answerPreview(.applied)
  let transport = enterRetirement(core); finishLoad(core, transport); finishRestore(core)
  check(panel(core).tasks.requests.count == 1 && panel(core).tasks.requests.first?.degrees == 90,
        "Mixed panel and shortcut presses retain their exact net orientation")
  clean(core)
}
// Cancellation is sampled at every asynchronous boundary, including closing.
for phase in 0..<3 {
  for navigation in 0..<3 {
    let core = PlayerCore(); _ = press(core)
    let transport = core.nativeTransport!
    if phase >= 1 { _ = enterRetirement(core) }
    if phase >= 2 { finishLoad(core, transport) }
    switch navigation {
    case 0: core.seek(absoluteSecond: 5)
    case 1: core.seek(relativeSecond: 1, option: .exact)
    default: core.seek(percent: 40, forceExact: true)
    }
    let expectedPosition = [5.0, 3.0, 4.0][navigation]
    check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore?.rotationRequestID == nil,
          "User navigation discards the pending rotation action at phase \(phase)")
    check(phase == 0 ? core.nativeCompatibilityRestore == nil : core.nativeCompatibilityRestore?.position == expectedPosition,
          "Accepted navigation retains the latest target during handoff phase \(phase)")
    transport.answer(.ready(.init(phase: .paused, position: 2)))
    transport.session.finish()
    check(core.nativeCompatibilityRestore?.rotationRequestID == nil,
          "Cancelled action is not resurrected by retirement completion")
    check(phase == 0 || core.nativeCompatibilityRestore?.position == expectedPosition,
          "Retirement does not overwrite a newer seek target")
    core.info.state = .loaded; core.fileLoadedBoundary(); core.restartBoundary(); pump()
    check(panel(core).tasks.requests.isEmpty, "Late navigation callbacks never export phase \(phase)")
    clean(core)
  }
}
do {
  let core = PlayerCore(); _ = press(core)
  let transport = enterRetirement(core); finishLoad(core, transport)
  check(core.hasPendingPermanentRotation, "Matching internal restore seek retains pending intent")
  core.seek(absoluteSecond: 2, preservingRotationHandoff: UUID())
  check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore?.rotationRequestID == nil,
        "An unrelated restore ID cannot exempt a seek from cancellation")
  core.restartBoundary(); pump()
  check(panel(core).tasks.requests.isEmpty, "Wrong-ID seek leaves no late export")
  clean(core)
}
// Real pause/resume entry and production play-button action during both sides
// of the handoff. The command transport is an explicit recording boundary.
for phase in 1...3 {
  let core = PlayerCore()
  let transport = core.nativeTransport!
  transport.volumePercent = 37; transport.rate = 1.25
  core.nativeViewport = VideoToolsViewport(zoom: 1, panX: 0.2, panY: -0.1)
  core.nativeLoopA = 1; core.nativeLoopB = 8
  _ = press(core)
  transport.answer(.ready(.init(phase: .playing, position: 2)))
  if phase >= 2 { transport.session.finish() }
  if phase >= 3 { core.fileStartedBoundary(); core.info.state = .loaded; core.fileLoadedBoundary() }
  let oldSeekCount = core.playbackTransport.seeks.count
  core.pause() // The same production entry is used by willSleep.
  check(core.playbackIsPaused && !core.hasPendingPermanentRotation,
        "Pause during handoff is retained without exporting at phase \(phase)")
  let controller = PlayerWindowController(core, window: window)
  controller.playButtonAction(NSButton())
  check(!core.playbackIsPaused, "Play button sees the retained pause intent during handoff")
  controller.playButtonAction(NSButton())
  check(core.playbackIsPaused, "Consecutive play-button actions preserve the latest pause intent")
  check(core.nativeCompatibilityRestore?.volume == 37 && core.nativeCompatibilityRestore?.rate == 1.25 &&
        core.nativeCompatibilityRestore?.viewport.panX == 0.2 && core.nativeCompatibilityRestore?.loopA == 1 &&
        core.nativeCompatibilityRestore?.loopB == 8, "Cancelling export retains same-media volume speed viewport and A/B")
  core.seek(absoluteSecond: 5); core.seek(relativeSecond: 1, option: .exact)
  check(core.nativeCompatibilityRestore?.position == 6, "Relative handoff seeks accumulate from the newest accepted target")
  core.seek(absoluteSecond: 100)
  check((core.nativeCompatibilityRestore?.position ?? 100) < 8 && (core.nativeCompatibilityRestore?.position ?? 0) >= 7,
        "Handoff targets remain below the captured A/B end")
  core.seek(relativeSecond: -100, option: .exact)
  check(core.nativeCompatibilityRestore?.position == 1, "Handoff targets remain at or above the captured A/B start")
  core.seek(percent: 70, forceExact: true)
  check(core.nativeCompatibilityRestore?.position == 7, "Percent handoff seeks use the captured duration")
  check(phase == 3 || core.playbackTransport.seeks.count == oldSeekCount,
        "Draining or loading queues do not receive playback commands")
  if phase == 1 { transport.session.finish() }
  if phase < 3 { core.fileStartedBoundary(); core.info.state = .loaded; core.fileLoadedBoundary() }
  check(core.playbackTransport.seeks.last?.value == 7 && core.playbackTransport.paused,
        "Loaded MPV receives the latest exact target while remaining paused")
  core.playbackPosition = 2; core.restartBoundary()
  check(core.nativeCompatibilityRestore != nil && panel(core).tasks.requests.isEmpty,
        "An old-position restart neither completes restoration nor exports")
  core.playbackPosition = 7; core.restartBoundary()
  check(core.nativeCompatibilityRestore == nil && core.playbackTransport.paused &&
        core.playbackTransport.volume == 37 && core.playbackTransport.rate == 1.25,
        "Final restoration preserves updated pause and captured playback parameters")
  pump(); check(panel(core).tasks.requests.isEmpty, "Transport restoration never revives a cancelled export")
  clean(core)
}
for phase in 1...3 {
  let core = PlayerCore(); _ = press(core)
  let transport = enterRetirement(core)
  let oldCompletion = core.nativeCompatibilityRestore!.completion
  if phase >= 2 { transport.session.finish() }
  if phase >= 3 { core.fileStartedBoundary(); core.info.state = .loaded; core.fileLoadedBoundary() }
  core.pause(); core.seek(absoluteSecond: 5)
  let accepted = press(core)
  check(accepted == (phase == 3), "A new request after cancellation requires a loaded media, not merely a retained restore")
  check(!core.hasPendingPermanentRotation && transport.captureCalls == 1,
        "A new loaded MPV rotation never starts another native handoff")
  if accepted { until { !panel(core).tasks.requests.isEmpty } }
  let delivered = panel(core).deliveries
  oldCompletion()
  check(panel(core).deliveries == delivered && !core.hasPendingPermanentRotation,
        "An abandoned completion cannot replay the old rotation alongside a new MPV action")
  check(core.nativeCompatibilityRestore?.position == 5 && core.nativeCompatibilityRestore?.paused == true,
        "The new MPV action does not replace pending playback restoration")
  if phase == 1 { transport.session.finish() }
  if phase < 3 { core.fileStartedBoundary(); core.info.state = .loaded; core.fileLoadedBoundary() }
  core.playbackPosition = 2; core.restartBoundary()
  check(core.nativeCompatibilityRestore != nil && panel(core).deliveries == delivered,
        "An old restart cannot complete the updated playback restoration")
  core.playbackPosition = 5; core.restartBoundary()
  check(panel(core).tasks.requests.count == (phase == 3 ? 1 : 0) &&
        (phase != 3 || panel(core).tasks.requests.first?.degrees == 270) && core.playbackTransport.paused,
        "Only the explicitly new loaded-MPV request exports, with updated pause retained")
  clean(core)
}
do {
  let core = PlayerCore(); _ = press(core)
  let transport = enterRetirement(core)
  core.pause()
  check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore != nil, "Cancelled action still owns a playback restore")
  core.open(core.info.currentURL)
  check(core.nativeCompatibilityRestore == nil, "Same-URL reopen clears origin restore even after its action was cancelled")
  transport.session.finish(); pump()
  check(panel(core).tasks.requests.isEmpty, "Reopening an abandoned handoff never exports")
  clean(core)
}
for phase in 0..<3 {
  let core = PlayerCore(); _ = press(core)
  let old = core.permanentRotationIntent.pendingTicket!
  let transport = core.nativeTransport!
  if phase >= 1 { _ = enterRetirement(core) }
  if phase >= 2 { finishLoad(core, transport) }
  core.open(core.info.currentURL)
  check(core.permanentRotationIntent.mediaEpoch != old.mediaEpoch && !core.hasPendingPermanentRotation,
        "Same-path explicit open changes ownership synchronously at phase \(phase)")
  transport.answer(.ready(.init(phase: .paused, position: 2))); transport.session.finish()
  core.info.state = .loaded; core.fileStartedBoundary(); core.fileLoadedBoundary(); core.restartBoundary(); pump()
  check(panel(core).tasks.requests.isEmpty, "Same-path user replacement rejects an old completion")
  clean(core)
}
for terminal in [false, true] {
  let core = PlayerCore(); _ = press(core)
  let transport = enterRetirement(core)
  if terminal { core.shutdown(); core.stop() } else { core.stop() }
  check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore == nil, "Terminal operation synchronously cancels pending export")
  transport.session.finish(); pump()
  check(core.opened.isEmpty && panel(core).tasks.requests.isEmpty, "Terminal completion replaces compatibility reload without exporting")
  check(terminal ? core.mpv.commands == ["quit"] : core.notices == 1, "The correct terminal completion remains authoritative")
  clean(core)
}
for result in [CoreBoundary.NativePreviewResult.unavailable, .superseded] {
  let core = PlayerCore(); core.nativePreviewInProgress = true; _ = press(core)
  core.answerPreview(result)
  check(!core.hasPendingPermanentRotation && core.nativeTransport!.captureCalls == 0,
        "Failed or superseded preview restoration cancels immediately")
  clean(core)
}
do {
  let core = PlayerCore(); _ = press(core)
  let old = core.permanentRotationIntent.pendingTicket!
  core.nativeTransport!.answer(.superseded)
  check(!core.hasPendingPermanentRotation, "Superseded exact clock capture cancels immediately")
  _ = press(core, 15)
  check(!core.cancelPendingPermanentRotation(requestID: old.requestID) && core.hasPendingPermanentRotation,
        "An old timeout cannot cancel a newer request")
  core.permanentRotationTimeout!.fire()
  check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore == nil && core.osds == 1,
        "The real bounded watchdog action cancels and reports only its owner")
  clean(core)
}
do {
  let core = PlayerCore(); _ = press(core)
  let transport = enterRetirement(core); finishLoad(core, transport)
  core.fileEnded(false)
  check(!core.hasPendingPermanentRotation && core.nativeCompatibilityRestore == nil,
        "A failed MPV file load discards its owned restore and rotation")
  core.restartBoundary(); pump()
  check(panel(core).tasks.requests.isEmpty, "Load failure cannot later submit an export")
  clean(core)
}
do {
  let core = PlayerCore(); core.nativeTransport = nil
  panel(core).requestPermanentRotation(clockwiseQuarterTurns: 1)
  until { panel(core).tasks.requests.count == 1 }
  check(panel(core).tasks.requests.first?.degrees == 90 && !core.hasPendingPermanentRotation,
        "Existing MPV panel rotation goes directly to the unchanged coordinator")
  check(press(core), "Existing MPV shortcut remains accepted while export runs")
  check(panel(core).coordinator.state.hasQueuedRotation, "The existing coordinator still queues later MPV presses")
  clean(core)
}
window.orderOut(nil); window.close()
print("Controlled rotation handoff: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
