import AppKit
import AVFoundation

var checks = 0, failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  checks += 1
  if condition() { print("PASS: \(name)") }
  else { failures += 1; print("FAIL: \(name)") }
}
var cores = [PlayerCore]()
@discardableResult
func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    for core in cores { for _ in 0..<32 { core.mpv.pump() } }
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while Date() < deadline
  return condition()
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
Utility.watchLaterURL = fixtureDirectory.appendingPathComponent("watch-later", isDirectory: true)
try FileManager.default.createDirectory(at: Utility.watchLaterURL, withIntermediateDirectories: false)
let red = fixtureDirectory.appendingPathComponent("red.mp4")
let blue = fixtureDirectory.appendingPathComponent("blue.mp4")
Preference.pauseWhenOpen = true

// All records are produced by actual MPV, never by a fabricated Core restore.
func seedRecord(_ url: URL, position: Double, speed: Double) {
  let client = LiveQueueClient(directory: fixtureDirectory)
  var loaded = false, restarts = 0
  func pumpUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let event = mpv_wait_event(client.handle, 0.005) {
        client.noteQueueEvent(event.pointee.event_id)
        if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loaded = true }
        if event.pointee.event_id == MPV_EVENT_PLAYBACK_RESTART { restarts += 1 }
      }
      if condition() { return true }
    } while Date() < deadline
    return condition()
  }
  func number(_ name: String) -> Double {
    var result = Double.nan
    _ = mpv_get_property(client.handle, name, MPV_FORMAT_DOUBLE, &result)
    return result
  }
  check(pumpUntil { client.queueHasReachedInitialIdle }, "Seed client receives real initial idle")
  check(mpv_set_property_string(client.handle, "watch-later-options", "start,speed") >= 0, "Seed client uses explicit start and speed options")
  check(client.rawCommand(["loadfile", url.path]) >= 0 && pumpUntil { loaded && restarts > 0 }, "Seed client loads actual media")
  check(mpv_set_property_string(client.handle, "speed", String(speed)) >= 0, "Seed client applies actual speed")
  let previous = restarts
  check(client.rawCommand(["seek", String(position), "absolute+exact"]) >= 0 &&
        pumpUntil { restarts > previous && abs(number("time-pos") - position) < 0.05 }, "Seed client reaches exact saved clock")
  check(client.rawCommand(["write-watch-later-config"]) >= 0, "Actual MPV writes watch-later record")
  let record = Utility.watchLaterURL.appendingPathComponent(Utility.mpvWatchLaterMd5(url.path))
  let text = try? String(contentsOf: record)
  check(text?.hasPrefix("start=") == true && text?.contains("speed=") == true, "Production admission path resolves actual start and speed record")
  print("RECORD: \(text?.replacingOccurrences(of: "\n", with: ";") ?? "missing")")
}

func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback && core.nativeQueue == nil && core.mpv.getFlag("idle-active") }, "Close retires real playback and queue owner")
  core.mainWindow.videoView.uninit()
  core.mainWindow.close()
}

print("CASE: unopened-resume")
seedRecord(red, position: 2.25, speed: 1.5)
let resumed = PlayerCore(); cores.append(resumed); PlayerCore.lastActive = resumed
var loadedSpeed: Double?, loadedPosition: Double?
resumed.mpv.beforeLoaded = {
  loadedSpeed = resumed.mpv.getDouble("speed")
  loadedPosition = resumed.mpv.getDouble("time-pos")
  print("LOADED_BEFORE_CORE: position=\(loadedPosition!) speed=\(loadedSpeed!)")
}
check(resumed.openMediaURLs([red, blue, red], shouldAutoLoad: false) == 3, "Public open admits full explicit duplicate queue")
check(wait(10) { resumed.nativeCompatibilityRestore == nil && resumed.info.state.loaded && resumed.mpv.actualRestarts > 0 }, "Unopened queue completes actual MPV restoration")
check(resumed.logs.contains { $0.contains("existing_watch_later_configuration") }, "Actual saved record triggers inventory fallback")
check(!resumed.isUsingNativePlayback && resumed.nativeTransport == nil, "Unopened resume does not fabricate a native session")
check(loadedSpeed == 1.5, "Actual MPV loads saved speed before Core restoration")
check(abs(resumed.mpv.getDouble("time-pos") - 2.25) < 0.05, "Unopened queue preserves actual watch-later position")
check(abs(resumed.mpv.getDouble("speed") - 1.5) < 0.001, "Unopened queue preserves actual watch-later speed")
check(resumed.mpv.getDouble("volume") == 0 && resumed.mpv.getFlag("pause"), "Unopened resume retains silent paused-open policy")
check(resumed.mpv.queueSnapshot()?.entries.map(\.path) == [red.path, blue.path, red.path], "Unopened resume installs all ordered duplicate entries")
check(!resumed.hasPendingNativeQueueRestore && !resumed.hasNativePlaybackQueue, "Unopened resume releases owner after actual restart")
check(!FileManager.default.fileExists(atPath: Utility.watchLaterURL.appendingPathComponent(Utility.mpvWatchLaterMd5(red.path)).path), "Actual successful MPV load consumes saved record")
print("RESUMED: position=\(resumed.mpv.getDouble("time-pos")) speed=\(resumed.mpv.getDouble("speed")) commands=\(resumed.mpv.commandArguments)")
close(resumed)

print("CASE: unopened-speed-intent")
seedRecord(red, position: 2.25, speed: 1.5)
let changedSpeed = PlayerCore(); cores.append(changedSpeed); PlayerCore.lastActive = changedSpeed
changedSpeed.mpv.beforeLoaded = { changedSpeed.setSpeed(1.75) }
check(changedSpeed.openMediaURLs([red, blue], shouldAutoLoad: false) == 2, "Speed intent scenario admits full queue")
check(wait(10) { changedSpeed.nativeCompatibilityRestore == nil && changedSpeed.info.state.loaded && changedSpeed.mpv.actualRestarts > 0 }, "Speed intent scenario completes actual restart")
check(abs(changedSpeed.mpv.getDouble("time-pos") - 2.25) < 0.05, "Speed intent leaves MPV watch-later position intact")
check(changedSpeed.mpv.getDouble("speed") == 1.75, "Explicit loading speed intent supersedes saved speed")
check(changedSpeed.mpv.getDouble("volume") == 0 && changedSpeed.mpv.getFlag("pause"), "Loading speed intent retains silent paused policy")
close(changedSpeed)

print("CASE: unopened-seek-intent")
seedRecord(red, position: 2.25, speed: 1.5)
let changedPosition = PlayerCore(); cores.append(changedPosition); PlayerCore.lastActive = changedPosition
changedPosition.mpv.beforeLoaded = { changedPosition.seek(absoluteSecond: 1.0) }
check(changedPosition.openMediaURLs([red, blue], shouldAutoLoad: false) == 2, "Seek intent scenario admits full queue")
check(wait(10) { changedPosition.nativeCompatibilityRestore == nil && changedPosition.info.state.loaded && changedPosition.mpv.actualRestarts > 0 }, "Seek intent scenario completes exact actual restart")
check(abs(changedPosition.mpv.getDouble("time-pos") - 1.0) < 0.05, "Explicit loading seek replaces saved watch-later position")
check(changedPosition.mpv.getDouble("speed") == 1.5, "Explicit seek alone preserves independent saved speed")
check(changedPosition.mpv.commandArguments.contains { $0 == ["seek", "1.0", "absolute+exact"] }, "Explicit loading seek retains exact seek barrier")
check(changedPosition.mpv.getDouble("volume") == 0 && changedPosition.mpv.getFlag("pause"), "Loading seek intent retains silent paused policy")
close(changedPosition)

print("CASE: captured-native")
let captured = PlayerCore(); cores.append(captured); PlayerCore.lastActive = captured
check(captured.openMediaURLs([red, blue, red], shouldAutoLoad: false) == 3, "Captured control admits full native queue")
check(wait { captured.isUsingNativePlayback && captured.info.state == .paused }, "Captured control reaches real native ready")
captured.seek(absoluteSecond: 1.25)
captured.setSpeed(1.25)
check(wait { abs((captured.playbackPosition ?? -1) - 1.25) < 0.05 && captured.playbackTransport.rate == 1.25 }, "Captured control reaches actual native clock and speed")
seedRecord(red, position: 2.75, speed: 1.5)
var completed = 0, intentUpdated = false
captured.mpv.beforeRestart = {
  if captured.hasPendingNativeQueueRestore {
    check(captured.mpv.getDouble("speed") == 1.25, "Captured native speed supersedes older saved speed before new intent")
    captured.setSpeed(1.75)
    intentUpdated = true
  }
}
captured.requireMPVCompatibility(reason: "resume source control") { completed += 1 }
check(wait(10) { completed == 1 }, "Captured native owner completes exact actual restoration")
check(abs(captured.mpv.getDouble("time-pos") - 1.25) < 0.05, "Actual native snapshot supersedes older saved position")
check(intentUpdated && captured.mpv.getDouble("speed") == 1.75, "Latest handoff speed intent supersedes capture and saved record")
check(captured.mpv.getDouble("volume") == 0 && captured.mpv.getFlag("pause"), "Captured control retains silent paused intent")
check(captured.mpv.queueSnapshot()?.entries.map(\.path) == [red.path, blue.path, red.path], "Captured control preserves full duplicate queue")
check(captured.mpv.commandArguments.contains { $0.first == "seek" && $0.contains("absolute+exact") }, "Captured control still uses actual exact seek command")
close(captured)
print("RESULT: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
