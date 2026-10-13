import Cocoa
import QuartzCore

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertions += 1
  if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func pump() {
  var finished = false
  DispatchQueue.main.async { finished = true }
  let deadline = Date().addingTimeInterval(2)
  while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
  check(finished, "Main event queue drains without blocking")
}
func route(_ player: PlayerCore, enabled: Bool) {
  player.$playbackEventRoute.withLock { $0.revision += 1; $0.acceptsMPV = enabled }
}
func event(_ controller: MPVController, _ id: mpv_event_id, data: UnsafeMutableRawPointer? = nil,
           reply: UInt64 = 0, error: Int32 = 0) {
  var value = mpv_event(event_id: id, error: error, reply_userdata: reply, data: data)
  // Inject on the production reader queue so synthetic and real events never
  // race on reader-owned state. Application main never uses this test fence.
  withUnsafePointer(to: &value) { pointer in controller.queue.sync { controller.handleEvent(pointer) } }
}
func property(_ controller: MPVController, name: String, format: mpv_format, data: UnsafeMutableRawPointer?) {
  name.withCString { name in
    var value = mpv_event_property(name: name, format: format, data: data)
    withUnsafeMutablePointer(to: &value) { event(controller, MPV_EVENT_PROPERTY_CHANGE, data: $0) }
  }
}
func allProperties(_ controller: MPVController) {
  for (name, format) in controller.observeProperties {
    switch format {
    case MPV_FORMAT_FLAG:
      var value: Int32 = 1
      withUnsafeMutablePointer(to: &value) { property(controller, name: name, format: format, data: $0) }
    case MPV_FORMAT_INT64:
      var value: Int64 = 25
      withUnsafeMutablePointer(to: &value) { property(controller, name: name, format: format, data: $0) }
    case MPV_FORMAT_DOUBLE:
      var value = 25.0
      withUnsafeMutablePointer(to: &value) { property(controller, name: name, format: format, data: $0) }
    case MPV_FORMAT_STRING:
      "synthetic".withCString { string in
        var value: UnsafePointer<CChar>? = string
        withUnsafeMutablePointer(to: &value) { property(controller, name: name, format: format, data: $0) }
      }
    default: property(controller, name: name, format: format, data: nil)
    }
  }
}
func lifecycle(_ controller: MPVController) {
  for id in [MPV_EVENT_START_FILE, MPV_EVENT_FILE_LOADED, MPV_EVENT_VIDEO_RECONFIG,
             MPV_EVENT_SEEK, MPV_EVENT_PLAYBACK_RESTART] { event(controller, id) }
  var reason = MPV_END_FILE_REASON_STOP
  withUnsafeMutablePointer(to: &reason) { event(controller, MPV_EVENT_END_FILE, data: $0) }
  event(controller, MPV_EVENT_COMMAND_REPLY, reply: MPVController.UserData.screenshot)
}

let player = PlayerCore()
let controller = MPVController(player)
allProperties(controller)
lifecycle(controller)
pump()
check(player.actions.contains("notification") && player.actions.contains("start") && player.actions.contains("pause"),
      "Default legacy route preserves lifecycle and property delivery")
check(player.actions.contains("screenshot") && player.events.calls > 80, "Default plugins and screenshot callback work")
let legacyCalls = player.actions.count
let legacyEvents = player.events.calls
let originalVolume = player.info.volume
let originalRotation = player.info.rotation

// Hold main delivery while the route changes. Returning to MPV must not make old
// closures eligible again even though the final boolean is true.
allProperties(controller)
lifecycle(controller)
route(player, enabled: false)
route(player, enabled: true)
pump()
check(player.actions.count == legacyCalls && player.events.calls == legacyEvents,
      "Old queued callbacks cannot alias a new MPV epoch")
check(player.info.volume == originalVolume && player.info.rotation == originalRotation,
      "Rejected callbacks cannot mutate cached properties")
route(player, enabled: false)
allProperties(controller)
lifecycle(controller)
pump()
check(player.actions.count == legacyCalls && player.events.calls == legacyEvents,
      "Native route suppresses every observed MPV property and media event")

// The first compatibility load must not accept mpv's startup idle/properties.
controller.prepareForFirstMPVMediaLoad()
route(player, enabled: true)
allProperties(controller)
event(controller, MPV_EVENT_VIDEO_RECONFIG)
event(controller, MPV_EVENT_FILE_LOADED)
pump()
check(player.actions.count == legacyCalls, "First-load barrier rejects startup properties before START_FILE")
event(controller, MPV_EVENT_START_FILE)
event(controller, MPV_EVENT_FILE_LOADED)
allProperties(controller)
pump()
check(player.actions.count > legacyCalls && player.actions.suffix(100).contains("loaded"),
      "First START_FILE reopens delivery for the new route")

// A property's C data is overwritten/freed before main runs, just as mpv does on
// the next mpv_wait_event call. The listener must receive the original scalar.
let pointer = UnsafeMutablePointer<Double>.allocate(capacity: 1)
pointer.initialize(to: 0.625)
property(controller, name: "custom-double", format: MPV_FORMAT_DOUBLE, data: pointer)
pointer.pointee = 999
pointer.deinitialize(count: 1)
pointer.deallocate()
let text = strdup("original-string")!
var textPointer: UnsafePointer<CChar>? = UnsafePointer(text)
withUnsafeMutablePointer(to: &textPointer) { property(controller, name: "custom-string", format: MPV_FORMAT_STRING, data: $0) }
free(text)
textPointer = nil
pump()
check(player.events.values[.init("mpv.custom-double.changed")] as? Double == 0.625,
      "Double payload is copied before asynchronous delivery")
check(player.events.values[.init("mpv.custom-string.changed")] as? String == "original-string",
      "String payload is copied from char pointer before asynchronous delivery")

// This explicitly supplies Core's pending-intent service boundary. The event
// branch is production code; these controlled C events do not prove Core owner
// validation or actual compatibility restoration.
let volumePlayer = PlayerCore()
let volumeController = MPVController(volumePlayer)
var reportedVolume = 17.25
withUnsafeMutablePointer(to: &reportedVolume) {
  property(volumeController, name: MPVOption.Audio.volume, format: MPV_FORMAT_DOUBLE, data: $0)
}
pump()
check(volumePlayer.info.volume == 17.25 && volumePlayer.syncedVolumeValues == [17.25] &&
      volumePlayer.volumeOSDValues == [17.25],
      "Without pending restore volume the ordinary MPV payload drives info UI and OSD")
volumePlayer.pendingPlaybackVolume = 21
reportedVolume = 0
withUnsafeMutablePointer(to: &reportedVolume) {
  property(volumeController, name: MPVOption.Audio.volume, format: MPV_FORMAT_DOUBLE, data: $0)
}
volumePlayer.pendingPlaybackVolume = 37
pump()
check(volumePlayer.info.volume == 37 && volumePlayer.syncedVolumeValues.last == 37 &&
      volumePlayer.volumeOSDValues.last == 37,
      "Pending restore volume is resolved at delivery for info UI and OSD")
volumePlayer.pendingPlaybackVolume = 0
reportedVolume = 81
withUnsafeMutablePointer(to: &reportedVolume) {
  property(volumeController, name: MPVOption.Audio.volume, format: MPV_FORMAT_DOUBLE, data: $0)
}
pump()
check(volumePlayer.info.volume == 0 && volumePlayer.syncedVolumeValues.last == 0 &&
      volumePlayer.volumeOSDValues.last == 0,
      "A pending zero volume remains an explicit intent")
reportedVolume = 42
withUnsafeMutablePointer(to: &reportedVolume) {
  property(volumeController, name: MPVOption.Audio.volume, format: MPV_FORMAT_DOUBLE, data: $0)
}
volumePlayer.pendingPlaybackVolume = nil
pump()
check(volumePlayer.info.volume == 42 && volumePlayer.syncedVolumeValues.last == 42 &&
      volumePlayer.volumeOSDValues.last == 42,
      "Retired pending volume restores ordinary MPV delivery without a stale override")

controller.addSavedLoopModeHook()
var continued = 0
let restoreCalls = player.actions.filter { $0 == "restoreLoop" }.count
for hook in controller.hooks.values { controller.queue.sync { hook.call { continued += 1 } } }
route(player, enabled: false)
route(player, enabled: true)
pump()
check(continued == 2 && player.actions.filter { $0 == "restoreLoop" }.count == restoreCalls,
      "Stale loop hooks skip state restoration but always continue")
for hook in controller.hooks.values { controller.queue.sync { hook.call { continued += 1 } } }
pump()
check(continued == 4 && player.actions.filter { $0 == "restoreLoop" }.count == restoreCalls + 2,
      "Current legacy hooks restore loops and continue")

route(player, enabled: false)
let logCount = controller.logs.count
event(controller, MPV_EVENT_QUEUE_OVERFLOW)
event(controller, MPV_EVENT_COMMAND_REPLY, reply: MPVController.UserData.screenshot, error: -12)
let alerts = Utility.alerts
pump()
check(controller.logs.count >= logCount + 2, "Native route retains queue overflow and command error diagnostics")
check(Utility.alerts == alerts, "Stale screenshot errors do not interrupt native playback")

for name in ["loadfile", "loadlist", "playlist-append", "playlist-play-index", "playlist-next", "playlist-prev",
             "script-binding", "keypress"] {
  player.hasIssuedMPVMediaCommand = false
  controller.noteMediaCommand(MPVCommand(name), args: [])
  check(player.hasIssuedMPVMediaCommand, "Media command invalidates fresh-core eligibility: \(name)")
}
player.hasIssuedMPVMediaCommand = false
controller.noteMediaCommand(.seek, args: ["1"])
check(!player.hasIssuedMPVMediaCommand, "Simple transport commands do not invent historical media loads")
controller.noteMediaCommand(.set, args: ["playlist-pos", "0"])
check(player.hasIssuedMPVMediaCommand, "Playlist writes through named commands are accounted for")
player.hasIssuedMPVMediaCommand = false
controller.setInt("playlist-pos", 0)
check(player.hasIssuedMPVMediaCommand, "Playlist writes through typed setters are accounted for")
player.hasIssuedMPVMediaCommand = false
_ = controller.command(rawString: "ignore")
check(player.hasIssuedMPVMediaCommand, "Raw commands conservatively close fresh-core admission")

// Exercise the production HOOK branch against libmpv's actual barrier. Receiving
// FILE_LOADED and END_FILE proves that suppression continued, rather than merely
// omitting the hook's application code and leaving the core blocked indefinitely.
func liveHookTest(enabled: Bool, registered: Bool) {
  let livePlayer = PlayerCore()
  let liveController = MPVController(livePlayer)
  route(livePlayer, enabled: enabled)
  let calls = Atomic(wrappedValue: 0)
  if registered {
    liveController.hooks = [77: MPVHookValue(withBlock: { next in
      calls.withLock { $0 += 1 }
      next()
    })]
  }
  check(mpv_hook_add(liveController.mpv, 77, "on_load", 100) == 0, "Register real libmpv hook")
  liveController.command(.loadfile, args: [CommandLine.arguments[1]])
  var loaded = false
  var ended = false
  var hooks = 0
  let deadline = Date().addingTimeInterval(5)
  while !ended && Date() < deadline {
    let pointer = mpv_wait_event(liveController.mpv, 0.01)!
    let id = pointer.pointee.event_id
    if id == MPV_EVENT_NONE { continue }
    if id == MPV_EVENT_HOOK { hooks += 1 }
    if id == MPV_EVENT_FILE_LOADED { loaded = true }
    if id == MPV_EVENT_END_FILE { ended = true }
    liveController.queue.sync { liveController.handleEvent(pointer) }
    pump()
  }
  check(loaded && ended && hooks == 1, "Real hook continuation completes load and EOF")
  check(calls.wrappedValue == (enabled && registered ? 1 : 0), "Only admitted hooks execute application code")
  pump()
}
liveHookTest(enabled: false, registered: true)
liveHookTest(enabled: true, registered: false)
liveHookTest(enabled: true, registered: true)

// A real log message must remain observable while the MPV media route is closed.
"synthetic".withCString { prefix in
  "warn".withCString { level in
    "synthetic warning".withCString { text in
      var message = mpv_event_log_message(prefix: prefix, level: level, text: text, log_level: MPV_LOG_LEVEL_WARN)
      withUnsafeMutablePointer(to: &message) { event(controller, MPV_EVENT_LOG_MESSAGE, data: $0) }
    }
  }
}
check(controller.logs.contains { $0.contains("synthetic warning") }, "Native route preserves MPV log diagnostics")

let concurrentPlayer = PlayerCore()
let group = DispatchGroup()
for _ in 0..<4 {
  group.enter()
  DispatchQueue.global().async {
    for _ in 0..<10000 {
      let revision = concurrentPlayer.captureMPVEventRevision()
      if let revision { _ = concurrentPlayer.acceptsMPVEventRevision(revision) }
      concurrentPlayer.noteMPVMediaCommand()
    }
    group.leave()
  }
}
for index in 0..<10000 { route(concurrentPlayer, enabled: index % 2 == 0) }
check(group.wait(timeout: .now() + 5) == .success, "Concurrent capture, validation and transitions finish without deadlock")
check(concurrentPlayer.hasIssuedMPVMediaCommand, "Concurrent media history remains recorded")

let shutdownPlayer = PlayerCore()
let shutdownController = MPVController(shutdownPlayer)
route(shutdownPlayer, enabled: false)
shutdownController.destroyHeadlessMPVAfterShutdown()
check(shutdownController.mpv != nil, "Native stop cannot destroy an idle live compatibility handle")
shutdownController.command(.quit)
let shutdownDeadline = Date().addingTimeInterval(5)
while shutdownController.mpv != nil && Date() < shutdownDeadline {
  shutdownController.readEvents()
  pump()
}
check(shutdownPlayer.actions.last == "shutdown", "Real SHUTDOWN always reaches lifecycle cleanup")
check(shutdownController.hasReceivedShutdown && shutdownController.mpv == nil,
      "Native-only real shutdown detaches the handle without creating OpenGL")
// Repeat queued wakeups and teardown calls after detachment. The serial fence is
// in this test only: application main never waits for mpv_destroy.
for _ in 0..<20 { shutdownController.readEvents() }
shutdownController.destroyHeadlessMPVAfterShutdown()
shutdownController.queue.sync {}
pump()
check(shutdownPlayer.actions.filter { $0 == "shutdown" }.count == 1,
      "Queued wakeups after SHUTDOWN cannot read or destroy the retired handle twice")

// Drive the production adapter, event reader and installer with real MPV. The
// surrounding App services remain explicit boundaries, not a whole-App proof.
let queuePlayer = PlayerCore()
let queueController = MPVController(queuePlayer)
queueController.realPropertyReadback = true
let queueOwner = UUID()
check(!queueController.beginNativeQueueInstallation(owner: queueOwner, receive: { _ in }),
      "Queue reservation rejects an enabled ordinary presentation route")
route(queuePlayer, enabled: false)
let queueURL = URL(fileURLWithPath: CommandLine.arguments[2])
check(queueController.setString("keep-open", "yes") >= 0, "Queue fixture retains the production keep-open policy")
var queueState = try NativeQueueState(plan: NativeQueuePlan(urls: [queueURL, queueURL]), selectedIndex: 1)
let checkpoint = queueState.handoffCheckpoint()!
let installation = queueState.beginHandoff(checkpoint)!
var queueOutcome: MPVQueueInstaller.Outcome?
var installationEvents: [String] = []
let queueInstaller = MPVQueueInstaller(backend: queueController, isCurrent: { $0 == installation })
check(queueController.beginNativeQueueInstallation(owner: queueOwner, receive: {
  installationEvents.append(String(describing: $0))
  if case .fileLoaded = $0 { print("QUEUE_LOADED_DIAGNOSTIC: \(String(describing: queueController.queueSnapshot()))") }
  queueInstaller.receive($0)
}), "Queue route reserves a main-owned sink")
check(!queueController.beginNativeQueueInstallation(owner: UUID(), receive: { _ in }),
      "Second queue route cannot steal the existing reservation")
check(mpv_hook_add(queueController.mpv, 99, "on_load", 100) == 0,
      "Queue load registers a real hook barrier")
check(queueInstaller.begin(checkpoint, installation: installation, completion: { queueOutcome = $0 }) == .accepted,
      "Real production adapter accepts an empty idle client")
let queueDeadline = Date().addingTimeInterval(5)
while queueOutcome == nil && Date() < queueDeadline {
  queueInstaller.advance()
  queueController.readEvents()
  pump()
}
guard case .installed(let receipt)? = queueOutcome else {
  print("QUEUE_BRIDGE_DIAGNOSTIC: outcome=\(String(describing: queueOutcome)) events=\(installationEvents) snapshot=\(String(describing: queueController.queueSnapshot())) logs=\(queueController.logs.suffix(8))")
  fputs("FAIL: Production queue bridge must install the real selected entry\n", stderr); exit(1)
}
check(receipt.entryIDs.count == 2 && Set(receipt.entryIDs).count == 2 && receipt.selectedIndex == 1,
      "Real duplicate URL entries retain distinct IDs and selected position")
check(queueController.queueSnapshot()?.entries.filter(\.playing).map(\.id) == [receipt.selectedEntryID],
      "Production node readback confirms the actual selected entry")
check(queuePlayer.hasIssuedMPVMediaCommand, "Installer commands retain production MPV media accounting")
check(queuePlayer.actions.isEmpty && queuePlayer.events.calls == 0,
      "Installation events never execute ordinary UI lifecycle or plugins")
check(installationEvents.contains { $0.hasPrefix("startFile") } &&
      installationEvents.contains { $0.hasPrefix("fileLoaded") },
      "Real START and FILE_LOADED reach the installer without a mocked readiness event")
check(queueController.awaitingFirstRoutedStart == false, "Actual queue START consumes the first-load barrier")
queueController.endNativeQueueInstallation(owner: UUID())
check(queueController.nativeQueueEventOwner == queueOwner, "Foreign cancellation leaves the current sink intact")
queueController.endNativeQueueInstallation(owner: queueOwner)
route(queuePlayer, enabled: true)
event(queueController, MPV_EVENT_FILE_LOADED)
pump()
check(queuePlayer.actions.contains("loaded"), "Receipt release allows the later normal lifecycle route")

// Pause main delivery, mutate the original C payload and replace the owner. An
// old envelope must neither borrow the new owner nor read recycled C memory.
route(queuePlayer, enabled: false)
let oldOwner = UUID(), newOwner = UUID()
var oldEnvelopes: [String] = [], newEnvelopes: [String] = []
check(queueController.beginNativeQueueInstallation(owner: oldOwner, receive: { oldEnvelopes.append(String(describing: $0)) }),
      "Controlled old event reservation starts")
var startPayload = mpv_event_start_file(playlist_entry_id: 41)
withUnsafeMutablePointer(to: &startPayload) { event(queueController, MPV_EVENT_START_FILE, data: $0) }
startPayload.playlist_entry_id = 99
event(queueController, MPV_EVENT_FILE_LOADED)
queueController.endNativeQueueInstallation(owner: oldOwner)
check(queueController.beginNativeQueueInstallation(owner: newOwner, receive: { newEnvelopes.append(String(describing: $0)) }),
      "New reservation starts after cancellation")
pump()
check(oldEnvelopes.isEmpty && newEnvelopes.isEmpty, "Queued old envelopes cannot borrow a new installation owner")
event(queueController, MPV_EVENT_FILE_LOADED)
pump()
check(newEnvelopes == ["queueOverflow"], "A new owner cannot inherit the previous START context")
startPayload.playlist_entry_id = 73
withUnsafeMutablePointer(to: &startPayload) { event(queueController, MPV_EVENT_START_FILE, data: $0) }
event(queueController, MPV_EVENT_FILE_LOADED)
startPayload.playlist_entry_id = 100
pump()
check(newEnvelopes.suffix(2).elementsEqual(["startFile(entryID: 73)", "fileLoaded(entryID: 73)"]),
      "Entry identity is copied before C event storage changes")
event(queueController, MPV_EVENT_QUEUE_OVERFLOW)
pump()
check(newEnvelopes.last == "queueOverflow", "Queue loss reaches the installer as an explicit failure event")
queueController.endNativeQueueInstallation(owner: newOwner)
let retainedHandle = queueController.mpv
queueController.mpv = nil
check(queueController.queueCommand(["playlist-clear"]) == nil && queueController.queueSetPaused() == nil &&
      queueController.queueSnapshot() == nil, "A missing production MPV handle cannot report queue success")
queueController.mpv = retainedHandle

// Cancel an actual partially appended list before any activation command. Stop
// begins from an already-idle MPV client, so no idle transition is guaranteed.
let stoppedPlayer = PlayerCore()
let stoppedController = MPVController(stoppedPlayer)
stoppedController.realPropertyReadback = true
check(mpv_observe_property(stoppedController.mpv, 0, "idle-active", MPV_FORMAT_FLAG) >= 0,
      "Cancelled queue fixture observes actual idle notifications")
route(stoppedPlayer, enabled: false)
let stoppedOwner = UUID()
var stoppedState = try NativeQueueState(plan: NativeQueuePlan(urls: Array(repeating: queueURL, count: 10)))
let stoppedCheckpoint = stoppedState.handoffCheckpoint()!
let stoppedInstallation = stoppedState.beginHandoff(stoppedCheckpoint)!
var stoppedCurrent = true
var stoppedOutcome: MPVQueueInstaller.Outcome?
let stoppedInstaller = MPVQueueInstaller(backend: stoppedController, isCurrent: { stoppedCurrent && $0 == stoppedInstallation })
check(stoppedController.beginNativeQueueInstallation(owner: stoppedOwner, receive: { stoppedInstaller.receive($0) }),
      "Cancelled queue reserves its actual production event bridge")
check(stoppedInstaller.begin(stoppedCheckpoint, installation: stoppedInstallation, completion: { stoppedOutcome = $0 }) == .accepted,
      "Cancelled queue starts from a fresh real MPV client")
stoppedInstaller.advance()
print("QUEUE_STOP_PREFIX_DIAGNOSTIC: \(String(describing: stoppedController.queueSnapshot()))")
check(stoppedController.queueSnapshot()?.entries.count == 8 && stoppedController.queueSnapshot()?.idle == true &&
      stoppedController.awaitingFirstRoutedStart,
      "Cancelled queue contains a real prefix without any START_FILE")
stoppedController.readEvents(); pump()
stoppedCurrent = false
stoppedController.endNativeQueueInstallation(owner: stoppedOwner)
stoppedInstaller.cancel(stoppedInstallation)
route(stoppedPlayer, enabled: true)
stoppedPlayer.info.state = .stopping
stoppedController.stopCancelledNativeQueue(owner: stoppedOwner)
check(stoppedController.nativeQueueStopEventOwner == stoppedOwner,
      "Cancelled queue submits its stop under a dedicated event owner")
route(stoppedPlayer, enabled: true)
stoppedController.stopCancelledNativeQueue(owner: stoppedOwner)
check(stoppedController.queueSnapshot()?.entries.count == 8,
      "Repeated owned stop preserves the retained prefix while refreshing its route")
stoppedPlayer.pendingUrl = queueURL
var reopenedAfterIdle = false
stoppedPlayer.onOpen = { url in
  reopenedAfterIdle = stoppedPlayer.info.state == .idle
  route(stoppedPlayer, enabled: true)
  stoppedPlayer.info.state = .loading
  stoppedController.command(.loadfile, args: [url.path])
}
let stoppedDeadline = Date().addingTimeInterval(2)
while !reopenedAfterIdle && Date() < stoppedDeadline {
  stoppedController.readEvents(); pump()
}
check(reopenedAfterIdle, "Pre-START cancellation reaches actual idle and releases pending reopen")
let reopenedDeadline = Date().addingTimeInterval(3)
while !stoppedPlayer.actions.contains("loaded") && Date() < reopenedDeadline {
  stoppedController.readEvents(); pump()
}
check(stoppedPlayer.actions.contains("start") && stoppedPlayer.actions.contains("loaded") &&
      stoppedController.queueSnapshot()?.activePath == queueURL.path,
      "Reopening after pre-START cancellation receives real START and FILE_LOADED")
check(stoppedOutcome == .superseded,
      "Cancelled installer cannot deliver success while the replacement opens")

// Hold MPV's real before-start hook after activation was submitted. Its path is
// still nil and stop sets idle-active immediately, but its selected entry must
// retire before an idle acknowledgement can authorize the pending replacement.
let activatingPlayer = PlayerCore()
let activatingController = MPVController(activatingPlayer)
activatingController.realPropertyReadback = true
route(activatingPlayer, enabled: false)
let activatingOwner = UUID()
check(activatingController.beginNativeQueueInstallation(owner: activatingOwner, receive: { _ in }),
      "Before-START cancellation reserves the production bridge")
check(mpv_hook_add(activatingController.mpv, 201, "on_before_start_file", 100) == 0,
      "Before-START cancellation registers an actual asynchronous MPV hook")
check(activatingController.queueSetPaused() == 0 &&
      activatingController.queueCommand(["loadfile", queueURL.path, "append"]) == 0 &&
      activatingController.queueCommand(["playlist-play-index", "0"]) == 0,
      "Before-START cancellation submits a real activation command")
var heldHookID: UInt64?
let hookDeadline = Date().addingTimeInterval(2)
while heldHookID == nil && Date() < hookDeadline {
  activatingController.queue.sync {
    guard let pending = mpv_wait_event(activatingController.mpv, 0.01), pending.pointee.event_id != MPV_EVENT_NONE else { return }
    if pending.pointee.event_id == MPV_EVENT_HOOK {
      heldHookID = pending.pointee.data.load(as: mpv_event_hook.self).id
    } else {
      activatingController.handleEvent(pending)
    }
  }
  pump()
}
check(heldHookID != nil && activatingController.awaitingFirstRoutedStart &&
      activatingController.queueSnapshot()?.activePath == nil,
      "Actual before-start hook is held before START_FILE and before path publication")
activatingController.endNativeQueueInstallation(owner: activatingOwner)
route(activatingPlayer, enabled: true)
activatingPlayer.info.state = .stopping
activatingController.stopCancelledNativeQueue(owner: activatingOwner)
let heldSnapshot = activatingController.queueSnapshot()
print("QUEUE_STOP_HELD_DIAGNOSTIC: \(String(describing: heldSnapshot))")
check(heldSnapshot?.idle == true && heldSnapshot?.activePath == nil &&
      heldSnapshot?.entries.contains(where: { $0.current || $0.playing }) == true,
      "Idle and absent path cannot prove a selected before-START entry has retired")
pump()
check(activatingPlayer.info.state == .stopping && !activatingPlayer.actions.contains("notification") &&
      activatingController.retiredNativeQueueEventOwner == activatingOwner,
      "Selected before-START entry prevents premature stop acknowledgement")
var activatingReopened = false
activatingPlayer.pendingUrl = queueURL
activatingPlayer.onOpen = { url in
  activatingReopened = activatingPlayer.info.state == .idle
  route(activatingPlayer, enabled: true)
  activatingPlayer.info.state = .loading
  activatingController.command(.loadfile, args: [url.path])
}
check(mpv_hook_continue(activatingController.mpv, heldHookID!) == 0,
      "Releasing the held before-start hook lets real MPV finish unloading")
let activatingDeadline = Date().addingTimeInterval(3)
while !activatingPlayer.actions.contains("loaded") && Date() < activatingDeadline {
  activatingController.readEvents(); pump()
}
check(activatingReopened && activatingPlayer.actions.contains("start") && activatingPlayer.actions.contains("loaded") &&
      activatingController.queueSnapshot()?.activePath == queueURL.path,
      "Submitted activation cancelled before START reaches idle and actually reopens")

let endingPlayer = PlayerCore()
let endingController = MPVController(endingPlayer)
endingController.realPropertyReadback = true
check(mpv_observe_property(endingController.mpv, 0, "idle-active", MPV_FORMAT_FLAG) >= 0 &&
      mpv_hook_add(endingController.mpv, 301, "on_after_end_file", 100) == 0,
      "After-end cancellation observes actual idle and registers a real unload hook")
route(endingPlayer, enabled: false)
let endingOwner = UUID()
var endingLoaded = false
check(endingController.beginNativeQueueInstallation(owner: endingOwner, receive: {
  if case .fileLoaded = $0 { endingLoaded = true }
}), "After-end cancellation reserves its installation owner")
check(endingController.queueSetPaused() == 0 &&
      endingController.queueCommand(["loadfile", queueURL.path, "append"]) == 0 &&
      endingController.queueCommand(["playlist-play-index", "0"]) == 0,
      "After-end cancellation activates a real paused file")
let endingLoadDeadline = Date().addingTimeInterval(3)
while !endingLoaded && Date() < endingLoadDeadline { endingController.readEvents(); pump() }
check(endingLoaded && !endingController.awaitingFirstRoutedStart,
      "After-end scenario has consumed its actual START and FILE_LOADED")
endingController.endNativeQueueInstallation(owner: endingOwner)
endingController.prepareCancelledNativeQueueStop(owner: endingOwner)
route(endingPlayer, enabled: true)
endingPlayer.info.state = .stopping
// A previously read idle property can be dispatched in the gap between Core
// enabling its stop route and submitting the actual owned stop command.
var queuedOldIdle: Int32 = 1
withUnsafeMutablePointer(to: &queuedOldIdle) {
  property(endingController, name: MPVProperty.idleActive, format: MPV_FORMAT_FLAG, data: $0)
}
endingController.stopCancelledNativeQueue(owner: endingOwner)
var heldEndHookID: UInt64?
let endHookDeadline = Date().addingTimeInterval(2)
while heldEndHookID == nil && Date() < endHookDeadline {
  endingController.queue.sync {
    guard let pending = mpv_wait_event(endingController.mpv, 0.01), pending.pointee.event_id != MPV_EVENT_NONE else { return }
    if pending.pointee.event_id == MPV_EVENT_HOOK {
      heldEndHookID = pending.pointee.data.load(as: mpv_event_hook.self).id
    } else { endingController.handleEvent(pending) }
  }
  pump()
}
let endingHeld = endingController.queueSnapshot()
check(heldEndHookID != nil && endingHeld?.idle == true && endingHeld?.activePath == nil &&
      endingHeld?.entries.contains(where: { $0.current }) == true,
      "Actual after-end hook retains current after END_FILE and path retirement")
check(endingPlayer.info.state == .stopping && endingPlayer.actions.isEmpty,
      "Special stop suppresses premature ordinary idle and media callbacks after START")
var endingReopened = false
endingPlayer.pendingUrl = queueURL
endingPlayer.onOpen = { url in
  endingReopened = endingPlayer.info.state == .idle
  route(endingPlayer, enabled: true)
  endingPlayer.info.state = .loading
  endingController.command(.loadfile, args: [url.path])
}
check(mpv_hook_continue(endingController.mpv, heldEndHookID!) == 0, "Release actual after-end hook")
let endingDeadline = Date().addingTimeInterval(3)
while !endingPlayer.actions.contains("loaded") && Date() < endingDeadline { endingController.readEvents(); pump() }
check(endingReopened && endingPlayer.actions.contains("loaded") && endingController.queueSnapshot()?.entries.count == 1,
      "After-end cancellation clears its old list before actual replacement loading")

// The MPV worker can finish unloading while this client's event reader is
// still delayed. Pending opens must wait for its old END/idle event backlog.
let backlogPlayer = PlayerCore()
let backlogController = MPVController(backlogPlayer)
backlogController.realPropertyReadback = true
check(mpv_observe_property(backlogController.mpv, 0, "idle-active", MPV_FORMAT_FLAG) >= 0,
      "Reader-backlog scenario observes actual idle changes")
route(backlogPlayer, enabled: false)
let backlogOwner = UUID()
var backlogLoaded = false
check(backlogController.beginNativeQueueInstallation(owner: backlogOwner, receive: {
  if case .fileLoaded = $0 { backlogLoaded = true }
}) && backlogController.queueSetPaused() == 0 &&
      backlogController.queueCommand(["loadfile", queueURL.path, "append"]) == 0 &&
      backlogController.queueCommand(["playlist-play-index", "0"]) == 0,
      "Reader-backlog scenario starts actual paused playback under its owner")
let backlogLoadDeadline = Date().addingTimeInterval(3)
while !backlogLoaded && Date() < backlogLoadDeadline { backlogController.readEvents(); pump() }
check(backlogLoaded && !backlogController.awaitingFirstRoutedStart,
      "Reader-backlog scenario consumed START and FILE_LOADED")
let readerEntered = DispatchSemaphore(value: 0)
let readerRelease = DispatchSemaphore(value: 0)
backlogController.queue.async {
  readerEntered.signal()
  readerRelease.wait()
}
check(readerEntered.wait(timeout: .now() + 1) == .success,
      "Only the test-owned reader is held while the MPV worker can unload")
backlogController.endNativeQueueInstallation(owner: backlogOwner)
route(backlogPlayer, enabled: true)
backlogPlayer.info.state = .stopping
backlogPlayer.pendingUrl = queueURL
var backlogReopened = false
backlogPlayer.onOpen = { url in
  backlogReopened = backlogPlayer.info.state == .idle
  route(backlogPlayer, enabled: true)
  backlogPlayer.info.state = .loading
  backlogController.command(.loadfile, args: [url.path])
}
backlogController.stopCancelledNativeQueue(owner: backlogOwner)
let backlogClearDeadline = Date().addingTimeInterval(1)
while backlogController.retiredNativeQueueEntryIDs?.isEmpty != true && !backlogReopened &&
      Date() < backlogClearDeadline { pump() }
check(backlogController.retiredNativeQueueEntryIDs?.isEmpty == true || backlogReopened,
      "The real worker reached the clear-list stage independently of its reader")
check(!backlogReopened && backlogPlayer.info.state == .stopping && backlogPlayer.actions.isEmpty &&
      backlogController.nativeQueueStopEventOwner == backlogOwner,
      "Actual idle cannot reopen until the old reader backlog is drained")
readerRelease.signal()
let backlogOpenDeadline = Date().addingTimeInterval(3)
while !backlogPlayer.actions.contains("loaded") && Date() < backlogOpenDeadline {
  backlogController.readEvents(); pump()
}
check(backlogReopened && backlogPlayer.actions.contains("start") && backlogPlayer.actions.contains("loaded") &&
      backlogController.queueSnapshot()?.activePath == queueURL.path &&
      backlogController.queueSnapshot()?.entries.count == 1,
      "Draining retired events allows the replacement to actually load without old idle delivery")

let foreignPlayer = PlayerCore()
let foreignController = MPVController(foreignPlayer)
foreignController.realPropertyReadback = true
route(foreignPlayer, enabled: false)
let foreignOwner = UUID()
check(foreignController.beginNativeQueueInstallation(owner: foreignOwner, receive: { _ in }) &&
      foreignController.queueCommand(["loadfile", queueURL.path, "append"]) == 0,
      "Foreign-list scenario reserves and appends its owned prefix")
foreignController.endNativeQueueInstallation(owner: foreignOwner)
route(foreignPlayer, enabled: true)
foreignPlayer.info.state = .stopping
foreignController.stopCancelledNativeQueue(owner: foreignOwner)
check(foreignController.queueCommand(["loadfile", queueURL.path, "append"]) == 0,
      "A separate writer appends a distinct entry before stop completion")
let foreignIDs = foreignController.queueSnapshot()?.entries.map(\.id)
pump()
check(foreignController.queueSnapshot()?.entries.map(\.id) == foreignIDs && foreignIDs?.count == 2 &&
      foreignPlayer.info.state == .stopping && foreignPlayer.actions.isEmpty &&
      foreignController.logs.contains { $0.contains("lost its exact playlist ownership") },
      "Cancelled stop cannot clear foreign entries or falsely acknowledge idle")

// A queued idle probe must not acknowledge a newer stop or queue owner, even
// when the shared backend currently satisfies every idle readback condition.
let retiredPlayer = PlayerCore()
let retiredController = MPVController(retiredPlayer)
retiredController.realPropertyReadback = true
route(retiredPlayer, enabled: false)
let retiredOwner = UUID()
check(retiredController.beginNativeQueueInstallation(owner: retiredOwner, receive: { _ in }),
      "Retired stop probe acquires its original owner")
retiredController.endNativeQueueInstallation(owner: retiredOwner)
route(retiredPlayer, enabled: true)
retiredPlayer.info.state = .stopping
retiredController.stopCancelledNativeQueue(owner: retiredOwner)
route(retiredPlayer, enabled: true)
pump()
check(retiredPlayer.info.state == .stopping && retiredPlayer.actions.isEmpty,
      "A queued stop acknowledgement cannot cross playback route revisions")
retiredController.stopCancelledNativeQueue(owner: retiredOwner)
route(retiredPlayer, enabled: false)
let replacementOwner = UUID()
check(retiredController.beginNativeQueueInstallation(owner: replacementOwner, receive: { _ in }),
      "New queue installation replaces retired stop ownership")
pump()
check(retiredPlayer.info.state == .stopping && retiredController.nativeQueueEventOwner == replacementOwner,
      "A retired stop acknowledgement cannot consume the replacement installation")
retiredController.endNativeQueueInstallation(owner: replacementOwner)
route(retiredPlayer, enabled: true)
retiredPlayer.info.state = .stopping
retiredController.stopCancelledNativeQueue(owner: replacementOwner)
retiredController.pollCancelledNativeQueueStop(owner: replacementOwner,
  revision: retiredPlayer.captureMPVEventRevision()!, deadline: ProcessInfo.processInfo.systemUptime - 1)
pump()
check(retiredPlayer.info.state == .stopping && retiredPlayer.actions.isEmpty &&
      retiredController.logs.contains { $0.contains("before the deadline") },
      "An expired stop proof logs failure without reporting idle")
print("PASS: \(assertions) production MPV backend routing checks")
