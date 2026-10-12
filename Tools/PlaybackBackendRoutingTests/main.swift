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
let worker = DispatchQueue(label: "routing-test-events")
func event(_ controller: MPVController, _ id: mpv_event_id, data: UnsafeMutableRawPointer? = nil,
           reply: UInt64 = 0, error: Int32 = 0) {
  var value = mpv_event(event_id: id, error: error, reply_userdata: reply, data: data)
  withUnsafePointer(to: &value) { pointer in worker.sync { controller.handleEvent(pointer) } }
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
check(player.actions.contains("idle") && player.actions.contains("start") && player.actions.contains("pause"),
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

controller.addSavedLoopModeHook()
var continued = 0
let restoreCalls = player.actions.filter { $0 == "restoreLoop" }.count
for hook in controller.hooks.values { worker.sync { hook.call { continued += 1 } } }
route(player, enabled: false)
route(player, enabled: true)
pump()
check(continued == 2 && player.actions.filter { $0 == "restoreLoop" }.count == restoreCalls,
      "Stale loop hooks skip state restoration but always continue")
for hook in controller.hooks.values { worker.sync { hook.call { continued += 1 } } }
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
    worker.sync { liveController.handleEvent(pointer) }
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
print("PASS: \(assertions) production MPV backend routing checks")
