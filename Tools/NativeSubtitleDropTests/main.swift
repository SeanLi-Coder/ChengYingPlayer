import AppKit
import AVFoundation

setbuf(stdout, nil)
var passes = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
  if value() { passes += 1; print("PASS: \(name)") }
  else { failures += 1; print("FAIL: \(name)") }
}
var cores = [PlayerCore]()
final class WorkerBarrier {
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  @Atomic private var waiting = false
  @Atomic private var succeeded = false
  func install(on worker: DispatchQueue, label: String) {
    worker.async {
      self.waiting = true
      self.entered.signal()
      self.succeeded = self.release.wait(timeout: .now() + 5) == .success
      self.waiting = false
      self.exited.signal()
    }
    check(entered.wait(timeout: .now() + 2) == .success, "\(label) actual worker barrier entered")
    check(waiting, "\(label) worker is held before the operation")
  }
  func finish(_ label: String) {
    check(waiting, "\(label) worker remains held until explicit release")
    release.signal()
    check(exited.wait(timeout: .now() + 2) == .success, "\(label) worker barrier exits")
    check(succeeded, "\(label) worker release did not time out")
  }
}
@discardableResult
func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    for core in cores { for _ in 0..<16 { core.mpv.pump() } }
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
let subtitle = fixtureDirectory.appendingPathComponent("fixture.srt")
try! "1\n00:00:00,000 --> 00:00:04,000\nSynthetic subtitle\n".write(to: subtitle, atomically: true, encoding: .utf8)
let lut = fixtureDirectory.appendingPathComponent("identity.cube")
try! "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(to: lut, atomically: true, encoding: .utf8)
let emptyFolder = fixtureDirectory.appendingPathComponent("empty", isDirectory: true)
try! FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: false)
Preference.pauseWhenOpen = true
let selectedCase = ProcessInfo.processInfo.environment["NATIVE_SUBTITLE_CASE"] ?? "all"
precondition(["all", "retiring", "attachments", "inventory"].contains(selectedCase))
print("CASE: \(selectedCase)")

func makeCore(queued: Bool = false) -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  check(core.openMediaURLs(queued ? [red, blue] : [red], shouldAutoLoad: false) == (queued ? 2 : 1), "Explicit local input is admitted")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, "Actual native Session reaches readiness")
  check((core.nativeQueue != nil) == queued && !core.hasPendingPermanentRotation && core.urlPlaylistBatch == nil,
        "Subtitle fixture has only its requested media owner")
  var snapshot: NativePlaybackSnapshot?, querying = false
  check(wait {
    if snapshot == nil && !querying {
      querying = true
      core.nativeTransport?.captureCurrentState { result in
        querying = false
        if case .ready(let value) = result { snapshot = value }
      }
    }
    return snapshot != nil
  }, "Actual worker snapshot is ready before handoff")
  return core
}
func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback }, "Subtitle fixture retires its real Session")
  core.mainWindow.videoView.uninit(); core.mainWindow.close()
}
func drop(_ core: PlayerCore, _ urls: [URL]) -> Bool {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  precondition(board.setPropertyList(urls.map(\.path), forType: .nsFilenames))
  return core.openFromPasteboard(DragInfo(board))
}
func hasActualSubtitle(_ core: PlayerCore) -> Bool {
  let count = core.mpv.getInt("track-list/count")
  return (0..<count).contains { core.mpv.getString("track-list/\($0)/type") == "sub" }
}
func hasActualLUT(_ core: PlayerCore) -> Bool {
  var node = mpv_node()
  guard mpv_get_property(core.mpv.client.handle, "vf", MPV_FORMAT_NODE, &node) >= 0 else { return false }
  defer { mpv_free_node_contents(&node) }
  guard let filters = try? MPVNode.parse(node) as? [[String: Any?]] else { return false }
  return filters.contains { $0["label"] as? String == "iina_quickl3d" && $0["name"] as? String == "lavfi" }
}

if selectedCase == "all" || selectedCase == "inventory" {
  let inventory = PlayerCore(); cores.append(inventory); PlayerCore.lastActive = inventory
  check(inventory.openMediaURLs([red], shouldAutoLoad: false) == 1,
        "Inventory test admits an actual native candidate")
  let route = inventory.playbackEventRoute.revision
  check(inventory.nativeTransport == nil && !inventory.playbackEventRoute.acceptsMPV && inventory.nativeQueue == nil,
        "Inventory test observes actual pending native admission before its main callback")
  let subtitleCommands = inventory.mpv.client.commandNames
  check(!drop(inventory, [subtitle]), "Inventory rejects a subtitle attachment")
  print("DIAGNOSTIC: inventory subtitleCommands=\(Array(inventory.mpv.client.commandNames.dropFirst(subtitleCommands.count)))")
  check(inventory.mpv.client.commandNames == subtitleCommands, "Inventory subtitle issues no idle MPV command")
  let lutCommands = inventory.mpv.client.commandNames
  check(!drop(inventory, [lut]), "Inventory rejects a LUT attachment")
  print("DIAGNOSTIC: inventory lutCommands=\(Array(inventory.mpv.client.commandNames.dropFirst(lutCommands.count)))")
  check(inventory.mpv.client.commandNames == lutCommands, "Inventory LUT issues no idle MPV command")
  check(inventory.playbackEventRoute.revision == route, "Inventory attachments preserve the pending media route")
  check(wait { inventory.isUsingNativePlayback && inventory.info.state == .paused },
        "Inventory completes the original actual native admission")
  close(inventory)
}

if selectedCase == "all" || selectedCase == "retiring" {
let retiring = makeCore()
retiring.setVolume(37)
retiring.seek(absoluteSecond: 1.1)
check(wait { abs((retiring.playbackPosition ?? -1) - 1.1) < 0.05 }, "Retiring source reaches its real nonzero clock")
var readySnapshot: NativePlaybackSnapshot?
var queryingSnapshot = false
check(wait {
  if readySnapshot == nil && !queryingSnapshot {
    queryingSnapshot = true
    retiring.nativeTransport?.captureCurrentState { result in
      queryingSnapshot = false
      if case .ready(let snapshot) = result { readySnapshot = snapshot }
    }
  }
  return readySnapshot != nil
}, "Retiring source obtains an actual ready worker snapshot after the seek")
var retiringCompleted = 0
if let session = retiring.nativePlaybackSession,
   let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
  let barrier = WorkerBarrier()
  retiring.requireMPVCompatibility(reason: "subtitle retiring fixture") { retiringCompleted += 1 }
  // Capture is queued before this barrier; actual shutdown is queued behind it.
  barrier.install(on: worker, label: "Original retiring")
  check(wait(2) { retiring.nativeRetiring }, "Actual Core reaches retiring before the subtitle drop")
  let owner = retiring.genericHandoffOwner?.id
  let route = retiring.playbackEventRoute.revision
  check(owner != nil && retiring.info.state == .stopping, "Retiring test owns a real stopping handoff")
  check(retiring.openMediaURLs([subtitle], shouldAutoLoad: false) == 0, "Subtitle-only admission has no playable media")
  check(retiring.genericHandoffOwner?.id == owner, "Subtitle-only admission preserves the retiring owner")
  check(!drop(retiring, [subtitle]), "Busy retiring subtitle drop is explicitly rejected")
  check(retiring.genericHandoffOwner?.id == owner && retiring.playbackEventRoute.revision == route,
        "Busy retiring drop preserves owner and route")
  check(!retiring.mpv.client.commandNames.contains("sub-add"), "Retiring subtitle drop never writes idle MPV")
  print("DIAGNOSTIC: retiring=\(retiring.nativeRetiring) ownerPreserved=\(retiring.genericHandoffOwner?.id == owner) state=\(retiring.info.state)")
  barrier.finish("Original retiring")
  check(wait(10) { retiringCompleted == 1 }, "Original retiring action completes after verified restoration")
  check(retiring.mpv.getString("path") == red.path && retiring.info.state.loaded,
        "Rejected subtitle drop leaves the original media loaded instead of idle")
  check(retiring.mpv.getDouble("volume") == 37 && abs(retiring.mpv.getDouble("time-pos") - 1.1) < 0.05,
        "Rejected subtitle drop retains the original volume and clock")
} else { check(false, "Retiring fixture finds actual Session worker") }
close(retiring)
}

if selectedCase == "all" || selectedCase == "attachments" {
  for action in ["generic", "rotation", "enqueue", "queue"] {
    for phase in ["capture", "retire", "loaded", "seek"] {
      let core = makeCore(queued: action == "queue")
      let label = "\(action)-\(phase)"
      let barrier = WorkerBarrier()
      guard let session = core.nativePlaybackSession,
            let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue else {
        check(false, "\(label) finds actual Session worker"); close(core); continue
      }
      if phase == "capture" {
        barrier.install(on: worker, label: label)
      }
      core.mpv.holdLoaded = phase == "loaded"
      core.mpv.holdRestart = phase == "seek"
      let rotationsBefore = deliveredRotations.count
      var completed = 0
      if action == "rotation" { check(core.requestPermanentRotation(clockwiseQuarterTurns: 1), "\(label) rotation is admitted") }
      else if action == "enqueue" { core.enqueueURLPlaybackPaths([blue.path]) { completed += $0 } }
      else { core.requireMPVCompatibility(reason: "attachment busy fixture") { completed += 1 } }
      if phase == "retire" {
        barrier.install(on: worker, label: label)
        check(wait(2) { core.nativeRetiring }, "\(label) reaches actual retirement")
      } else if phase == "capture" {
        check(core.nativeCompatibilityCaptureID != nil && !core.nativeRetiring, "\(label) owns a pending real capture")
      } else {
        check(wait(10) { phase == "loaded" ? core.mpv.heldLoaded != nil : core.mpv.heldRestart != nil },
              "\(label) holds an actual MPV event")
        check(!core.isUsingNativePlayback && core.nativeCompatibilityRestore != nil,
              "\(label) exposes owned partial MPV")
      }
      let captureID = core.nativeCompatibilityCaptureID
      let restoreID = core.nativeCompatibilityRestore?.id
      let genericID = core.genericHandoffOwner?.id
      let route = core.playbackEventRoute.revision
      let commands = core.mpv.client.commandNames
      check(!drop(core, [subtitle]), "\(label) rejects a busy subtitle attachment")
      check(!drop(core, [lut]), "\(label) rejects a busy LUT attachment")
      print("DIAGNOSTIC: \(label) attachmentCommands=\(Array(core.mpv.client.commandNames.dropFirst(commands.count)))")
      check(core.mpv.client.commandNames == commands, "\(label) attachments issue no MPV commands")
      check(core.nativeCompatibilityCaptureID == captureID && core.nativeCompatibilityRestore?.id == restoreID &&
            core.genericHandoffOwner?.id == genericID && core.playbackEventRoute.revision == route,
            "\(label) attachments preserve the existing owner and route")
      if phase == "capture" || phase == "retire" { barrier.finish(label) }
      if phase == "loaded" {
        core.mpv.holdLoaded = false; let deliver = core.mpv.heldLoaded; core.mpv.heldLoaded = nil; deliver?()
      } else if phase == "seek" {
        core.mpv.holdRestart = false; let deliver = core.mpv.heldRestart; core.mpv.heldRestart = nil; deliver?()
      }
      check(wait(10) { action == "rotation" ? deliveredRotations.count == rotationsBefore + 1 : completed == 1 },
            "\(label) original action completes after restoration")
      check(core.mpv.getString("path") == red.path && core.info.state.loaded, "\(label) original media remains loaded")
      close(core)
    }
  }

  let installing = makeCore(queued: true)
  var observedPrefix = false, installed = 0
  installing.mpv.client.afterCommand = { args in
    guard args.first == "loadfile", args.last == "append", !observedPrefix else { return }
    observedPrefix = true
    check(installing.nativeQueueInstallation != nil && !installing.isUsingNativePlayback,
          "Queue prefix is installed by an actual retired native owner")
    let commands = installing.mpv.client.commandNames
    let subtitleRejected = !drop(installing, [subtitle])
    let lutRejected = !drop(installing, [lut])
    print("DIAGNOSTIC: queue-prefix attachmentCommands=\(Array(installing.mpv.client.commandNames.dropFirst(commands.count)))")
    check(subtitleRejected && lutRejected, "Queue prefix rejects both busy attachment types")
    check(installing.mpv.client.commandNames == commands, "Queue prefix attachments issue no MPV command")
  }
  installing.requireMPVCompatibility(reason: "queue prefix attachments") { installed += 1 }
  check(wait(10) { installed == 1 }, "Queue prefix continues to a verified installation")
  check(observedPrefix, "Queue prefix test observes a real append before activation")
  close(installing)
}

if selectedCase == "all" {
  for kind in ["empty", "remote", "subtitle", "empty-folder"] {
    let core = makeCore()
    if let session = core.nativePlaybackSession,
       let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
      let barrier = WorkerBarrier()
      barrier.install(on: worker, label: kind)
      var completed = 0
      core.requireMPVCompatibility(reason: "invalid input fixture") { completed += 1 }
      let owner = core.genericHandoffOwner?.id
      let urls: [URL]
      switch kind {
      case "empty": urls = []
      case "remote": urls = [URL(string: "https://example.invalid/not-requested.mp4")!]
      case "subtitle": urls = [subtitle]
      default: urls = [emptyFolder]
      }
      let count = core.openMediaURLs(urls, shouldAutoLoad: false)
      check(kind == "remote" ? count == nil : count == 0, "\(kind) admission rejects non-playable input")
      check(owner != nil && core.genericHandoffOwner?.id == owner, "\(kind) admission preserves the capturing owner")
      barrier.finish(kind)
      check(wait(10) { completed == 1 }, "\(kind) original action still completes")
    } else { check(false, "\(kind) fixture finds actual Session worker") }
    close(core)
  }

  for phase in ["loaded", "seek"] {
    let core = makeCore()
    var completed = 0
    core.mpv.holdLoaded = phase == "loaded"
    core.mpv.holdRestart = phase == "seek"
    core.requireMPVCompatibility(reason: "partial MPV subtitle fixture") { completed += 1 }
    check(wait(10) { phase == "loaded" ? core.mpv.heldLoaded != nil : core.mpv.heldRestart != nil },
          "\(phase) holds an actual MPV event")
    let owner = core.genericHandoffOwner?.id
    check(!core.isUsingNativePlayback && owner != nil, "\(phase) exposes partial MPV with a live owner")
    let previousCommands = core.mpv.client.commandNames
    check(!drop(core, [subtitle]), "\(phase) busy subtitle drop is explicitly rejected")
    check(core.genericHandoffOwner?.id == owner, "\(phase) subtitle drop preserves the restore owner")
    check(core.mpv.client.commandNames == previousCommands && !hasActualSubtitle(core),
          "\(phase) busy subtitle drop performs no MPV command")
    if phase == "loaded" {
      core.mpv.holdLoaded = false; let deliver = core.mpv.heldLoaded; core.mpv.heldLoaded = nil; deliver?()
    } else {
      core.mpv.holdRestart = false; let deliver = core.mpv.heldRestart; core.mpv.heldRestart = nil; deliver?()
    }
    check(wait(10) { completed == 1 }, "\(phase) original action completes exactly once")
    close(core)
  }

  let nativeDrop = makeCore()
  check(drop(nativeDrop, [subtitle]), "Idle native subtitle drop starts a compatibility handoff")
  check(wait(10) { !nativeDrop.hasPendingGenericPlaybackHandoff && hasActualSubtitle(nativeDrop) },
        "Idle native drop attaches a real MPV subtitle after restoration")
  check(nativeDrop.mpv.getString("path") == red.path, "Accepted native subtitle keeps the current media")
  close(nativeDrop)

  let legacyDrop = makeCore()
  var legacyReady = false
  legacyDrop.requireMPVCompatibility(reason: "legacy subtitle fixture") { legacyReady = true }
  check(wait(10) { legacyReady }, "Legacy subtitle fixture reaches fully restored MPV")
  check(drop(legacyDrop, [subtitle]), "Legacy subtitle drop stays accepted")
  check(wait { hasActualSubtitle(legacyDrop) }, "Legacy subtitle drop adds a real MPV track")
  close(legacyDrop)

  for native in [true, false] {
    let core = makeCore()
    if !native {
      var ready = false
      core.requireMPVCompatibility(reason: "settled LUT fixture") { ready = true }
      check(wait(10) { ready }, "Legacy LUT fixture reaches fully restored MPV")
    }
    check(drop(core, [lut]), "\(native ? "Native" : "Legacy") idle LUT drop stays accepted")
    check(wait(10) { !core.hasPendingGenericPlaybackHandoff && hasActualLUT(core) },
          "\(native ? "Native" : "Legacy") idle LUT drop installs the actual MPV filter")
    check(core.mpv.getString("path") == red.path, "Idle LUT attachment retains the current media")
    close(core)
  }

  let newMedia = makeCore()
  newMedia.expectedFolderMatchURL = blue
  if let session = newMedia.nativePlaybackSession,
     let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
    let barrier = WorkerBarrier()
    var oldCompleted = 0
    newMedia.requireMPVCompatibility(reason: "superseded by actual media") { oldCompleted += 1 }
    barrier.install(on: worker, label: "New-media")
    check(wait(2) { newMedia.nativeRetiring }, "New-media test reaches real retiring")
    check(drop(newMedia, [blue]), "Actual new-media drop remains accepted during handoff")
    check(newMedia.genericHandoffOwner == nil, "Actual new media invalidates the old owner")
    barrier.finish("New-media")
    check(wait(10) { newMedia.info.currentURL == blue && newMedia.info.state.loaded && !newMedia.backgroundTaskInUse },
          "Actual new-media drop loads the replacement")
    check(newMedia.folderMatchRequests == [blue] && newMedia.expectedFolderMatchURL == nil,
          "Only the explicit single new-media drop requests folder matching exactly once")
    check(oldCompleted == 0, "Actual new media cancels the old compatibility action")
  } else { check(false, "New-media fixture finds actual Session worker") }
  close(newMedia)
}
print("RESULT: \(passes + failures) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
