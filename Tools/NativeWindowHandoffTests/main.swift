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
      if core.pendingNativeQueueStopOwner != nil { _ = core.mpv.acknowledgeCancelledStopForCoreTest() }
    }
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while Date() < deadline
  return condition()
}
NSApplication.shared.setActivationPolicy(.prohibited)
fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = fixtureDirectory.appendingPathComponent("red.mp4")
let blue = fixtureDirectory.appendingPathComponent("blue.mp4")
Preference.pauseWhenOpen = true

func makeCore(queued: Bool) -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  _ = mpv_observe_property(core.mpv.client.handle, 762, "idle-active", MPV_FORMAT_FLAG)
  check(core.openMediaURLs(queued ? [red, blue] : [red], shouldAutoLoad: false) == (queued ? 2 : 1), "Window fixture admits explicit media")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, "Window fixture reaches actual native readiness")
  return core
}
func configure(_ core: PlayerCore, fullscreen: Bool, ontop: Bool) {
  // Exercise the actual production state producers; Spaces animations are not
  // asserted by this CLI fixture. The on-top setter changes a real NSWindow.
  core.mainWindow.fsState = .windowed
  core.mainWindow.setWindowFloatingOnTop(ontop)
  if fullscreen { core.mainWindow.fsState = .fullscreen(legacy: true, priorWindowedFrame: core.mainWindow.window!.frame) }
}
func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback }, "Window fixture retires its actual Session")
  core.mainWindow.videoView.uninit(); core.mainWindow.close()
}

final class WorkerBarrier {
  private let entered = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var started = false
  private var result: DispatchTimeoutResult?
  init(_ worker: DispatchQueue) {
    worker.async { [self] in
      lock.lock(); started = true; lock.unlock()
      entered.signal()
      let actual = released.wait(timeout: .now() + 4)
      lock.lock(); result = actual; lock.unlock()
      exited.signal()
    }
  }
  func acquire() -> Bool { entered.wait(timeout: .now() + 1) == .success }
  var isWaiting: Bool {
    lock.lock(); defer { lock.unlock() }
    return started && result == nil
  }
  func releaseAndVerify() -> Bool {
    released.signal()
    guard exited.wait(timeout: .now() + 1) == .success else { return false }
    lock.lock(); defer { lock.unlock() }
    return result == .success
  }
}

for action in ["generic", "queue", "rotation", "enqueue"] {
  let queued = action == "queue"
  for fullscreen in [false, true] {
    let ontop = !fullscreen
    let label = "\(action)-\(fullscreen ? "fullscreen" : "ontop")"
    let core = makeCore(queued: queued)
    configure(core, fullscreen: fullscreen, ontop: ontop)
    check(!core.mpv.getFlag("fullscreen") && !core.mpv.getFlag("ontop"), "\(label) native state leaves idle MPV untouched")
    var beforeLoad = false, completed = 0
    core.mpv.beforeCommand = { args in
      guard args.first == "loadfile", !beforeLoad else { return }
      beforeLoad = true
      check(core.mpv.getFlag("fullscreen") == fullscreen && core.mpv.getFlag("ontop") == ontop,
            "\(label) actual window flags are projected before MPV load")
    }
    let rotationsBefore = deliveredRotations.count
    if action == "rotation" { check(core.requestPermanentRotation(clockwiseQuarterTurns: 1), "Rotation action is admitted") }
    else if action == "enqueue" { core.enqueueURLPlaybackPaths([blue.path]) { completed += $0 } }
    else { core.requireMPVCompatibility(reason: "window state regression") { completed += 1 } }
    check(wait(10) { action == "rotation" ? deliveredRotations.count == rotationsBefore + 1 : completed == 1 }, "\(label) owned handoff completes")
    _ = wait(0.15) { false }
    check(beforeLoad && core.mainWindow.fullscreenToggleCount == 0, "\(label) reconciliation does not enqueue an unwanted fullscreen toggle")
    check(core.mainWindow.fsState.isFullscreen == fullscreen && core.mainWindow.isOntop == ontop,
          "\(label) current window state survives reconciliation")
    if !fullscreen {
      check(core.mainWindow.window?.level == .iinaFloating,
            "\(label) actual window level stays consistent with the on-top indicator")
    }
    check(core.mpv.getFlag("fullscreen") == fullscreen && core.mpv.getFlag("ontop") == ontop,
          "\(label) MPV agrees with the current window after restart")
    close(core)
  }
}

// Latest accepted AppKit state wins, even while a genuine decoder shutdown is
// queued behind its real worker. No output callback or snapshot is fabricated.
for queued in [false, true] {
  for reverse in [false, true] {
    let core = makeCore(queued: queued)
    configure(core, fullscreen: !reverse, ontop: reverse)
    guard let session = core.nativePlaybackSession,
          let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue else {
      check(false, "Window retirement finds actual worker"); close(core); continue
    }
    var completed = 0
    core.requireMPVCompatibility(reason: "latest retirement window intent") { completed += 1 }
    let barrier = WorkerBarrier(worker)
    check(barrier.acquire(), "Window retirement barrier enters actual worker")
    check(wait(2) { core.nativeRetiring }, "Window state changes during actual asynchronous retirement")
    check(barrier.isWaiting, "Window retirement worker remains blocked during the state change")
    configure(core, fullscreen: reverse, ontop: !reverse)
    check(!core.mpv.getFlag("fullscreen") && !core.mpv.getFlag("ontop"), "Retiring window changes do not write idle MPV")
    check(barrier.releaseAndVerify(), "Window retirement worker is explicitly released without timeout")
    check(wait(10) { completed == 1 }, "Latest window state reaches verified restoration")
    _ = wait(0.1) { false }
    check(core.mpv.getFlag("fullscreen") == reverse && core.mpv.getFlag("ontop") == !reverse,
          "Projection uses current window state rather than capture-time values")
    check(core.mainWindow.fullscreenToggleCount == 0, "Latest window state does not schedule an unwanted toggle")
    close(core)
  }
}

for queued in [false, true] {
  for phase in ["capture", "retire"] {
    for reopen in [false, true] {
      let core = makeCore(queued: queued)
      configure(core, fullscreen: true, ontop: false)
      guard let session = core.nativePlaybackSession,
            let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue else {
        check(false, "Cancelled window handoff finds actual worker"); close(core); continue
      }
      var barrier: WorkerBarrier?
      var completed = 0
      if phase == "capture" { barrier = WorkerBarrier(worker); check(barrier!.acquire(), "Window capture barrier enters actual worker") }
      core.requireMPVCompatibility(reason: "cancelled window owner") { completed += 1 }
      if phase == "retire" {
        barrier = WorkerBarrier(worker); check(barrier!.acquire(), "Cancelled retirement barrier enters actual worker")
        check(wait(2) { core.nativeRetiring }, "Cancelled window owner reaches retirement")
      }
      check(barrier?.isWaiting == true, "Cancelled window worker remains blocked at the claimed phase")
      core.stop()
      if reopen { _ = core.openMediaURLs([red], shouldAutoLoad: false) }
      check(barrier?.releaseAndVerify() == true, "Cancelled window worker is explicitly released without timeout")
      check(wait { !core.nativeRetiring && (reopen ? core.info.state.loaded : !core.isUsingNativePlayback) },
            "Cancelled window owner finishes without stale restoration")
      check(completed == 0 && core.mpv.client.appendCalls == 0,
            "Cancelled window handoff does not load a stale same-URL source")
      check(!core.mpv.getFlag("fullscreen") && !core.mpv.getFlag("ontop"),
            "Cancelled window handoff cannot project into idle or reopened media")
      close(core)
    }
  }
}

// A normal MPV open must honor MPV configuration, not inherit the incidental
// native-window projection policy. The real reconciliation is expected here.
let plain = PlayerCore(); cores.append(plain)
_ = plain.mainWindow.window
plain.mpv.setFlag("fullscreen", true)
plain.mpv.setFlag("ontop", true)
var plainFlagsPreserved = false
plain.mpv.beforeCommand = { args in
  if args.first == "loadfile" { plainFlagsPreserved = plain.mpv.getFlag("fullscreen") && plain.mpv.getFlag("ontop") }
}
plain.openMainWindow(path: red.path, url: red, isNetwork: false, allowNative: false)
check(wait { plain.info.state.loaded }, "Ordinary MPV source loads without a native owner")
check(plainFlagsPreserved, "Ordinary MPV open retains configured window options")
close(plain)

// Force the genuine asynchronous inventory fallback with a synthetic subtitle;
// the window exists but there has never been an admitted native Session.
let inventoryDirectory = fixtureDirectory.appendingPathComponent("inventory", isDirectory: true)
try FileManager.default.createDirectory(at: inventoryDirectory, withIntermediateDirectories: false)
let inventoryVideo = inventoryDirectory.appendingPathComponent("red.mp4")
try FileManager.default.copyItem(at: red, to: inventoryVideo)
try "1\n00:00:00,000 --> 00:00:01,000\nFixture\n".write(to: inventoryDirectory.appendingPathComponent("red.srt"), atomically: true, encoding: .utf8)
let inventory = PlayerCore(); cores.append(inventory)
_ = inventory.mainWindow.window
inventory.mpv.setFlag("fullscreen", true)
inventory.mpv.setFlag("ontop", true)
Preference.enableSubtitleInventory = true
var inventoryFlagsPreserved = false
inventory.mpv.beforeCommand = { args in
  if args.first == "loadfile" { inventoryFlagsPreserved = inventory.mpv.getFlag("fullscreen") && inventory.mpv.getFlag("ontop") }
}
_ = inventory.openMediaURLs([inventoryVideo], shouldAutoLoad: false)
check(wait { inventory.info.state.loaded && !inventory.isUsingNativePlayback }, "Actual inventory fallback opens directly in MPV")
Preference.enableSubtitleInventory = false
check(inventoryFlagsPreserved, "Initial inventory fallback does not overwrite MPV window options")
close(inventory)

// This fallback has a real Session and generic owner, but it never passes media
// admission. Having an owner alone must not replace the configured MPV flags.
let initial = PlayerCore(); cores.append(initial)
initial.mpv.setFlag("fullscreen", true)
initial.mpv.setFlag("ontop", true)
var initialFlagsPreserved = false
var initialHadOwnedRestore = false
initial.mpv.beforeCommand = { args in
  if args.first == "loadfile" {
    initialFlagsPreserved = initial.mpv.getFlag("fullscreen") && initial.mpv.getFlag("ontop")
    initialHadOwnedRestore = initial.nativeCompatibilityRestore?.genericOwnerID != nil
  }
}
_ = initial.openMediaURLs([fixtureDirectory.appendingPathComponent("two-audio.mp4")], shouldAutoLoad: false)
check(wait { initial.info.state.loaded && !initial.isUsingNativePlayback && !initial.hasPendingGenericPlaybackHandoff },
      "Unadmitted two-audio Session completes actual compatibility fallback")
check(initialHadOwnedRestore, "Unadmitted media fallback uses its real generic restore owner")
check(initialFlagsPreserved, "Unadmitted native media does not overwrite MPV window options")
close(initial)

print("Window handoff checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
