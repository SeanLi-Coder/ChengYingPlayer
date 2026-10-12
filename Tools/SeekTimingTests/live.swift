import Foundation
import QuartzCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  checks += 1
}

guard CommandLine.arguments.count == 2, let engine = mpv_create() else {
  fatalError("A synthetic fixture path and a live mpv instance are required")
}
defer { mpv_terminate_destroy(engine) }
for (key, value) in ["config": "no", "vo": "null", "ao": "null", "pause": "yes", "idle": "yes",
                     "keep-open": "yes", "input-default-bindings": "no", "input-terminal": "no",
                     "terminal": "no", "save-position-on-quit": "no", "resume-playback": "no"] {
  check(mpv_set_option_string(engine, key, value) >= 0, "The isolated engine option must be accepted")
}
check(mpv_initialize(engine) >= 0, "The isolated engine must initialize")

let controller = TimingController()
controller.player.info.state.loaded = false
controller.flagReader = { name in
  var flag: Int32 = 0
  return mpv_get_property(engine, name, MPV_FORMAT_FLAG, &flag) >= 0 && flag != 0
}
func command(_ arguments: [String]) {
  let storage = arguments.map { strdup($0)! }
  defer { storage.forEach { free($0) } }
  var pointers: [UnsafePointer<CChar>?] = storage.map { UnsafePointer($0) } + [nil]
  check(pointers.withUnsafeMutableBufferPointer { mpv_command(engine, $0.baseAddress) } >= 0,
        "The synthetic media command must be accepted")
}

struct ObservedEvent {
  let id: mpv_event_id
  let token: UInt64
  let timestamp: Double
}
var samples = 0
var restarts = 0
var seekStarts: [UInt64: Double] = [:]
func readEvent() -> ObservedEvent {
  let event = mpv_wait_event(engine, 0.05)!
  let id = event.pointee.event_id
  // Match production: capture scalar data while it is valid, before UI dispatch.
  return ObservedEvent(id: id, token: controller.seekTimingToken, timestamp: CACurrentMediaTime())
}
func deliver(_ event: ObservedEvent) {
  switch event.id {
  case MPV_EVENT_START_FILE:
    controller.cancelSeekTiming()
    controller.seekTimingReadyToken = nil
    controller.player.info.state.loaded = false
  case MPV_EVENT_FILE_LOADED:
    controller.player.info.state.loaded = true
  case MPV_EVENT_SEEK:
    seekStarts[event.token] = event.timestamp
    controller.observeSeekTiming(token: event.token, at: event.timestamp)
  case MPV_EVENT_PLAYBACK_RESTART:
    restarts += 1
    let wasArmed = controller.seekTiming.isArmed
    controller.finishSeekTiming(token: event.token, at: event.timestamp)
    if wasArmed, !controller.seekTiming.isArmed, let start = seekStarts[event.token] {
      samples += 1
      check(controller.player.useExactSeekForCurrentFile == (event.timestamp - start < 0.05),
            "The real event interval must determine the automatic policy")
      print(String(format: "REAL_SEEK_SAMPLE: %.6f seconds", event.timestamp - start))
    }
    controller.markSeekTimingPlaybackReady(token: event.token)
  case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN, MPV_EVENT_QUEUE_OVERFLOW:
    controller.cancelSeekTiming()
    controller.seekTimingReadyToken = nil
    controller.player.info.state.loaded = false
  default: break
  }
}
func pump(until condition: () -> Bool) {
  let deadline = CACurrentMediaTime() + 5
  while !condition() && CACurrentMediaTime() < deadline { deliver(readEvent()) }
  check(condition(), "The required real playback lifecycle events must arrive within five seconds")
}

controller.cancelSeekTiming()
command(["loadfile", CommandLine.arguments[1], "replace"])
pump { controller.seekTimingReadyToken == controller.seekTimingToken }
check(controller.player.info.state.loaded, "Initial load must complete before the first timing probe")
controller.beginSeekTiming(mediaGeneration: controller.player.videoToolsMediaGeneration)
check(controller.seekTiming.isArmed, "Normal initial playback must permit a real probe")
command(["seek", "2", "absolute+exact"])
pump { samples == 1 }
check(!controller.seekTiming.isArmed, "A real SEEK/RESTART completes the sample exactly once")

// Capture a genuine old seek/restart without delivering it, as if the UI queue
// were busy. A second command invalidates the captured generation before replay.
controller.beginSeekTiming(mediaGeneration: controller.player.videoToolsMediaGeneration)
check(controller.seekTiming.isArmed, "An observed restart restores current-generation readiness")
command(["seek", "1", "absolute+exact"])
var delayed: [ObservedEvent] = []
let delayedDeadline = CACurrentMediaTime() + 5
while !delayed.contains(where: { $0.id == MPV_EVENT_PLAYBACK_RESTART }) && CACurrentMediaTime() < delayedDeadline {
  let event = readEvent()
  if event.id == MPV_EVENT_SEEK || event.id == MPV_EVENT_PLAYBACK_RESTART { delayed.append(event) }
}
check(delayed.contains(where: { $0.id == MPV_EVENT_SEEK }) &&
      delayed.contains(where: { $0.id == MPV_EVENT_PLAYBACK_RESTART }), "Capture real delayed seek lifecycle events")
controller.cancelSeekTiming()
controller.player.useExactSeekForCurrentFile = true
command(["seek", "3", "absolute+exact"])
for event in delayed { deliver(event) }
check(samples == 1 && controller.player.useExactSeekForCurrentFile,
      "A second seek discards old real-event samples without changing policy")
check(controller.seekTimingReadyToken != controller.seekTimingToken,
      "An old delivered restart cannot re-enable current-generation readiness")
pump { controller.seekTimingReadyToken == controller.seekTimingToken }

controller.beginSeekTiming(mediaGeneration: controller.player.videoToolsMediaGeneration)
check(controller.seekTiming.isArmed, "The second seek's own restart restores readiness")
controller.cancelSeekTiming()
controller.player.videoToolsMediaGeneration += 1
controller.player.useExactSeekForCurrentFile = true
controller.player.info.state.loaded = false
command(["loadfile", CommandLine.arguments[1], "replace"])
for event in delayed { deliver(event) }
check(controller.seekTimingReadyToken != controller.seekTimingToken && samples == 1,
      "Old real events cannot prime a replacement media file")
pump { controller.seekTimingReadyToken == controller.seekTimingToken }
controller.beginSeekTiming(mediaGeneration: controller.player.videoToolsMediaGeneration)
check(controller.seekTiming.isArmed, "A replacement file can produce a new valid probe")
command(["seek", "4", "absolute+exact"])
pump { samples == 2 }
controller.cancelSeekTiming()
command(["stop"])
pump { !controller.player.info.state.loaded }
check(!controller.seekTiming.isArmed, "Stopping playback clears the final sample")
print("PASS: Real libmpv seek timing completed: \(checks) checks, \(samples) samples, \(restarts) restarts; vo=null is not rendered-playback validation")
