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
    for core in cores {
      for _ in 0..<16 { core.mpv.pump() }
      // Queue controller quiescence is an explicit boundary: the existing
      // service checks actual idle/path/playlist data before acknowledging it.
      if core.pendingNativeQueueStopOwner != nil { _ = core.mpv.acknowledgeCancelledStopForCoreTest() }
    }
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
let inactiveDevice = "coreaudio/test-device"
Preference.pauseWhenOpen = true

func makeCore(queue: Bool = false) -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  _ = mpv_observe_property(core.mpv.client.handle, 762, "idle-active", MPV_FORMAT_FLAG)
  check(core.openMediaURLs(queue ? [red, blue] : [red], shouldAutoLoad: false) == (queue ? 2 : 1), "Audio fixture admits explicit local input")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, "Audio fixture reaches real native readiness")
  core.mpv.setString(MPVProperty.audioDevice, inactiveDevice)
  check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Idle MPV has a distinct test configuration")
  return core
}
func choose(_ name: String, core: PlayerCore) {
  PlayerCore.lastActive = core
  let item = NSMenuItem(); item.representedObject = name
  AppDelegate.shared.menuSelectAudioDevice(item)
}
func menu(_ core: PlayerCore) -> NSMenu {
  PlayerCore.lastActive = core
  let harness = AudioMenuHarness(); harness.updateAudioDevice()
  return harness.audioDeviceMenu
}
func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback }, "Audio fixture retires the actual native Session")
  core.mainWindow.videoView.uninit(); core.mainWindow.close()
}

let idle = PlayerCore(); cores.append(idle)
idle.mpv.setString(MPVProperty.audioDevice, inactiveDevice)
idle.setAudioDevice("auto")
check(idle.info.state == .idle && idle.mpv.getString(MPVProperty.audioDevice) == "auto", "Idle startup auto fallback remains synchronous")
check(idle.genericHandoffOwner == nil && idle.mpv.firstLoads == 0, "Startup device fallback does not open media")

for queued in [false, true] {
  let core = makeCore(queue: queued)
  let nativeMenu = menu(core)
  check(nativeMenu.items.first { $0.representedObject as? String == "auto" }?.state == .on,
        "Native menu reports system default instead of idle MPV")
  check(nativeMenu.items.allSatisfy(\.isEnabled), "Ready native menu permits compatibility selection")
  var loadingObserved = false
  core.mpv.client.afterCommand = { args in
    guard args.first == "loadfile", !loadingObserved else { return }
    loadingObserved = true
    check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Selection does not write a half-loaded MPV")
    let pendingMenu = menu(core)
    pendingMenu.update()
    check(pendingMenu.items.allSatisfy { !$0.isEnabled && $0.state == .off }, "Pending handoff disables device choices and checkmarks")
    choose("auto", core: core)
    check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Reentrant device action is rejected during handoff")
  }
  choose("auto", core: core)
  check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Native device action does not immediately write idle MPV")
  check(wait(10) { loadingObserved && !core.isUsingNativePlayback && core.nativeCompatibilityRestore == nil && core.mpv.getString(MPVProperty.audioDevice) == "auto" },
        "Device action completes through verified native to MPV handoff")
  if queued { check(core.mpv.queueSnapshot()?.entries.count == 2, "Device selection preserves the explicit native queue") }
  check(menu(core).items.first { $0.representedObject as? String == "auto" }?.state == .on,
        "Restored MPV menu reports the committed selection")
  close(core)
}

for queued in [false, true] {
for phase in ["capture", "loaded", "seek"] {
  let stage = queued ? "queue-\(phase)" : phase
  let core = makeCore(queue: queued)
  var releaseWorker: DispatchSemaphore?
  if phase == "capture", let session = core.nativePlaybackSession,
     let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    releaseWorker = release
    worker.async { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    check(entered.wait(timeout: .now() + 2) == .success, "Device capture barrier reaches the real Session worker")
  } else if phase == "loaded" { core.mpv.holdLoaded = true }
  else if phase == "seek" { core.mpv.holdRestart = true }
  choose("auto", core: core)
  let held: Bool
  if phase == "capture" { held = core.nativeCompatibilityCaptureID != nil }
  else if phase == "loaded" { held = wait { core.mpv.heldLoaded != nil } }
  else { held = wait { core.mpv.heldRestart != nil } }
  check(held, "Device action owns its \(stage) cancellation boundary")
  check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Pending \(stage) device selection remains unapplied")
  let pendingMenu = menu(core); pendingMenu.update()
  check(pendingMenu.items.allSatisfy { !$0.isEnabled && $0.state == .off }, "Pending \(stage) menu does not advertise an accepted selection")
  choose("auto", core: core)
  check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Pending \(stage) action cannot bypass its owner")
  core.stop()
  _ = core.openMediaURLs([red], shouldAutoLoad: false)
  releaseWorker?.signal()
  core.mpv.holdLoaded = false; core.mpv.holdRestart = false
  core.mpv.heldLoaded?(); core.mpv.heldLoaded = nil
  core.mpv.heldRestart?(); core.mpv.heldRestart = nil
  check(wait(10) { core.info.state.loaded && core.info.currentURL == red && core.genericHandoffOwner == nil }, "Same URL reopens independently after \(stage) cancellation")
  check(core.mpv.getString(MPVProperty.audioDevice) == inactiveDevice, "Cancelled \(stage) action cannot change the reopened media device")
  close(core)
}
}

let imageMenu = AudioMenuHarness()
ImageViewerCoordinator.blocksPlaybackMenu = true
imageMenu.updateAudioDevice()
check(imageMenu.audioDeviceMenu.items.count == 1 && imageMenu.audioDeviceMenu.items[0].isEnabled == false, "Image-only menu keeps device selection disabled")
print("Audio device checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
