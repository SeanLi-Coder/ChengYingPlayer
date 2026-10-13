import AppKit
import AVFoundation

var passes = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  if value() { passes += 1; print("PASS: \(label)") }
  else { failures += 1; print("FAIL: \(label)") }
}
var cores = [PlayerCore]()
@discardableResult func wait(_ seconds: Double = 4, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    for core in cores { for _ in 0..<16 { core.mpv.pump() } }
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.003))
  } while Date() < deadline
  return condition()
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
Utility.watchLaterURL = fixtureDirectory.appendingPathComponent("native-resume-records", isDirectory: true)
try FileManager.default.createDirectory(at: Utility.watchLaterURL, withIntermediateDirectories: false,
  attributes: [.posixPermissions: 0o700])
Preference.pauseWhenOpen = true
let service = NativePlaybackResumeService.shared
check(Preference.bool(for: .resumeLastPosition), "setup.isolated-resume-enabled")
check(Utility.watchLaterURL.path.hasPrefix(fixtureDirectory.path + "/"), "setup.artifact-owned-root")

func media(_ name: String, color: String = "red") -> URL {
  let url = fixtureDirectory.appendingPathComponent(name + ".mp4")
  try! FileManager.default.copyItem(at: fixtureDirectory.appendingPathComponent(color + ".mp4"), to: url)
  return url
}
func recordURL(_ url: URL) -> URL {
  Utility.watchLaterURL.appendingPathComponent(Utility.mpvWatchLaterMd5(url.path).uppercased())
}
func record(_ url: URL) -> [String: Double] {
  guard let text = try? String(contentsOf: recordURL(url), encoding: .utf8) else { return [:] }
  return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
    let pieces = line.split(separator: "=", maxSplits: 1)
    guard pieces.count == 2, let value = Double(pieces[1]) else { return nil }
    return (String(pieces[0]), value)
  })
}
func assertRecord(_ url: URL, position: Double, speed: Double, _ name: String) {
  let data = record(url)
  check(Set(data.keys) == Set(["start", "speed"]), name + ".minimal-record")
  check(abs((data["start"] ?? -100) - position) < 0.055, name + ".position")
  check(abs((data["speed"] ?? -100) - speed) < 0.0001, name + ".speed")
}
func makeCore(_ url: URL, _ name: String, queue: [URL]? = nil) -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  check(core.openMediaURLs(queue ?? [url], shouldAutoLoad: false) == (queue?.count ?? 1), name + ".admission")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, name + ".native-ready")
  check(core.nativeResumeReceipt?.url == url, name + ".receipt-owner")
  return core
}
func settled(_ core: PlayerCore, position: Double, speed: Double, _ name: String) {
  core.seek(absoluteSecond: position); core.setSpeed(speed); core.pause()
  var snapshot: NativePlaybackSnapshot?, pending = false
  check(wait {
    if !pending && snapshot == nil {
      pending = true
      core.nativeTransport?.captureCurrentState { result in
        pending = false
        if case .ready(let value) = result,
           abs(value.position - position) < 0.05, abs(Double(value.rate) - speed) < 0.0001,
           !value.wantsPlayback { snapshot = value }
      }
    }
    return snapshot != nil
  }, name + ".real-worker-settled")
}
func drain(_ name: String) {
  var complete = false; service.store.drain { complete = true }
  check(wait { complete }, name + ".writer-drained")
}
func retired(_ core: PlayerCore, _ name: String) {
  check(wait { core.nativeTransport == nil && !core.nativeRetiring }, name + ".retired")
  drain(name)
}
func cleanWindow(_ core: PlayerCore) { core.mainWindow.videoView.uninit(); core.mainWindow.close() }
final class WorkerBarrier {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var result: DispatchTimeoutResult?
  func block() {
    entered.signal()
    let value = release.wait(timeout: .now() + 5)
    lock.lock(); result = value; lock.unlock(); exited.signal()
  }
  func enter(_ name: String) { check(entered.wait(timeout: .now() + 1) == .success, name + ".barrier-entered") }
  func finish(_ name: String) {
    release.signal()
    check(exited.wait(timeout: .now() + 1) == .success, name + ".barrier-exited")
    lock.lock(); let value = result; lock.unlock()
    check(value == .success, name + ".barrier-explicit-release")
  }
}
func worker(_ core: PlayerCore) -> DispatchQueue {
  let session = core.nativePlaybackSession!
  return Mirror(reflecting: session).children.first(where: { $0.label == "worker" })!.value as! DispatchQueue
}

let normalURL = media("normal")
let normal = makeCore(normalURL, "normal")
settled(normal, position: 1.3, speed: 1.25, "normal")
let normalCache = cachedResumeWrites.count, normalRecent = Preference.resumePathWrites.count
normal.stop(); retired(normal, "normal")
assertRecord(normalURL, position: 1.3, speed: 1.25, "normal")
check(cachedResumeWrites.count == normalCache + 1, "normal.single-cache-update")
check(Preference.resumePathWrites.count == normalRecent + 1 && Preference.resumePathWrites.last == normalURL,
  "normal.last-played-owner")
let stoppedRecord = try? Data(contentsOf: recordURL(normalURL))
normal.shutdown()
check(wait { normal.mpv.actualShutdownReceived }, "normal.stop-then-quit-real-shutdown")
check(normal.mpv.quitCalls == 1, "normal.stop-then-quit-once")
check((try? Data(contentsOf: recordURL(normalURL))) == stoppedRecord, "normal.stop-then-quit-record-unchanged")
check(cachedResumeWrites.count == normalCache + 1 && Preference.resumePathWrites.count == normalRecent + 1,
  "normal.stop-then-quit-metadata-once")
cleanWindow(normal)

let reopen = PlayerCore(); cores.append(reopen); PlayerCore.lastActive = reopen
check(reopen.openMediaURLs([normalURL], shouldAutoLoad: false) == 1, "reopen.admission")
check(wait { reopen.nativeTransport == nil && reopen.info.state.loaded && reopen.mpv.getDouble("time-pos") > 1 },
  "reopen.real-mpv-loaded-record")
check(abs(reopen.mpv.getDouble("time-pos") - 1.3) < 0.055, "reopen.position")
check(abs(reopen.mpv.getDouble("speed") - 1.25) < 0.0001, "reopen.speed")
check(reopen.mpv.getDouble("volume") == 0, "reopen.remains-silent")
check(!FileManager.default.fileExists(atPath: recordURL(normalURL).path), "reopen.mpv-consumed-record")
reopen.stop(); cleanWindow(reopen)

let quitURL = media("quit")
let quit = makeCore(quitURL, "quit")
settled(quit, position: 1.4, speed: 1.5, "quit")
quit.shutdown()
check(wait { quit.mpv.actualShutdownReceived }, "quit.real-shutdown-after-save")
assertRecord(quitURL, position: 1.4, speed: 1.5, "quit")
check(quit.mpv.quitCalls == 1 && quit.nativeTransport == nil, "quit.output-before-real-mpv-quit")
quit.shutdown(); check(quit.mpv.quitCalls == 1, "quit.repeated-shutdown-once")
cleanWindow(quit)

let stopQuitURL = media("stop-quit-pending")
let stopQuit = makeCore(stopQuitURL, "stop-quit-pending")
settled(stopQuit, position: 1.7, speed: 1.25, "stop-quit-pending")
let stopQuitCache = cachedResumeWrites.count, stopQuitRecent = Preference.resumePathWrites.count
let stopQuitBarrier = WorkerBarrier()
worker(stopQuit).async { stopQuitBarrier.block() }; stopQuitBarrier.enter("stop-quit-pending")
stopQuit.stop(); stopQuit.shutdown()
check(stopQuit.nativeRetiring && stopQuit.nativeTerminationRequested, "stop-quit-pending.terminal-intent-kept")
stopQuitBarrier.finish("stop-quit-pending")
check(wait { stopQuit.mpv.actualShutdownReceived }, "stop-quit-pending.real-shutdown-after-drain")
assertRecord(stopQuitURL, position: 1.7, speed: 1.25, "stop-quit-pending")
check(stopQuit.mpv.quitCalls == 1 && stopQuit.nativeTransport == nil, "stop-quit-pending.quit-once")
check(cachedResumeWrites.count == stopQuitCache + 1 && Preference.resumePathWrites.count == stopQuitRecent + 1,
  "stop-quit-pending.metadata-once")
cleanWindow(stopQuit)

let oldURL = media("replace-old"), newURL = media("replace-new", color: "blue")
let replacement = makeCore(oldURL, "replacement")
settled(replacement, position: 1.2, speed: 1.5, "replacement")
let beforeReplacementRecent = Preference.resumePathWrites.count
check(replacement.openMediaURLs([newURL], shouldAutoLoad: false) == 1, "replacement.new-admission")
check(wait { replacement.info.currentURL == newURL && replacement.info.state.loaded && replacement.nativeResumeReceipt?.url == newURL },
  "replacement.new-owner-loaded")
assertRecord(oldURL, position: 1.2, speed: 1.5, "replacement.old-record")
check(Preference.resumePathWrites.count == beforeReplacementRecent, "replacement.old-recent-not-resurrected")
check(!FileManager.default.fileExists(atPath: recordURL(newURL).path), "replacement.new-owner-not-saved-early")
replacement.stop(); retired(replacement, "replacement.cleanup"); cleanWindow(replacement)

let queueA = media("queue-a"), queueB = media("queue-b", color: "blue")
let queued = makeCore(queueA, "queue", queue: [queueA, queueB])
settled(queued, position: 1.1, speed: 1.25, "queue")
queued.navigateInPlaylist(nextMedia: true)
check(wait { queued.info.currentURL == queueB && queued.info.state.loaded && queued.nativeResumeReceipt?.url == queueB },
  "queue.next-real-native-loaded")
drain("queue")
check(!FileManager.default.fileExists(atPath: recordURL(queueA).path), "queue.navigation-does-not-save")
queued.stop(); retired(queued, "queue.cleanup"); cleanWindow(queued)

let compatURL = media("compat")
let compat = makeCore(compatURL, "compat")
settled(compat, position: 1.15, speed: 1.25, "compat")
var compatFinished = 0
compat.requireMPVCompatibility(reason: "resume test") { compatFinished += 1 }
check(wait { compatFinished == 1 && compat.nativeTransport == nil }, "compat.actual-handoff-completed")
drain("compat")
check(!FileManager.default.fileExists(atPath: recordURL(compatURL).path), "compat.handoff-does-not-save")
compat.stop(); cleanWindow(compat)

for mode in ["active", "finish-pending", "manual-seek"] {
  let prefix = "preview." + mode, url = media("preview-" + mode)
  let core = makeCore(url, prefix)
  settled(core, position: 1.1, speed: 1.25, prefix)
  var previewApplied = false
  core.requestNativePreview(start: 2.2, end: 3.3) { result in
    if case .applied = result { previewApplied = true }
  }
  check(wait { previewApplied }, prefix + ".temporary-preview-applied")
  check(core.nativePreviewBaseline != nil && (core.playbackPosition ?? -1) >= 2.1, prefix + ".temporary-clock-distinct")
  if mode == "finish-pending" {
    let barrier = WorkerBarrier(); worker(core).async { barrier.block() }; barrier.enter(prefix)
    core.finishNativePreview()
    check(core.nativeResumePreviewCheckpoint != nil && core.nativePreviewBaseline == nil, prefix + ".checkpoint-before-worker")
    core.stop(); barrier.finish(prefix)
  } else if mode == "manual-seek" {
    settled(core, position: 3.7, speed: 1.5, prefix + ".manual")
    check(core.nativeResumePreviewCheckpoint == nil && core.nativePreviewBaseline == nil, prefix + ".manual-clears-checkpoint")
    core.stop()
  } else { core.stop() }
  retired(core, prefix)
  assertRecord(url, position: mode == "manual-seek" ? 3.7 : 1.1,
    speed: mode == "manual-seek" ? 1.5 : 1.25, prefix)
  cleanWindow(core)
}

for stage in ["capture", "retire", "loaded", "seek"] {
  let prefix = "partial." + stage, url = media("partial-" + stage)
  let core = makeCore(url, prefix)
  settled(core, position: 1.2, speed: 1.25, prefix)
  var completion = 0
  let barrier = WorkerBarrier()
  if stage == "capture" { worker(core).async { barrier.block() }; barrier.enter(prefix) }
  core.mpv.holdLoaded = stage == "loaded"; core.mpv.holdRestart = stage == "seek"
  let sessionWorker = worker(core)
  core.requireMPVCompatibility(reason: "resume partial " + stage) { completion += 1 }
  if stage == "retire" {
    sessionWorker.async { barrier.block() }; barrier.enter(prefix)
    check(wait(1) { core.nativeRetiring }, prefix + ".actual-retiring")
  } else if stage == "loaded" {
    check(wait { core.mpv.heldLoaded != nil }, prefix + ".actual-event-held")
  } else if stage == "seek" {
    check(wait { core.mpv.heldRestart != nil }, prefix + ".actual-event-held")
  } else {
    check(core.genericHandoffOwner != nil && !core.nativeRetiring, prefix + ".actual-capturing")
  }
  if stage != "capture" {
    core.seek(absoluteSecond: 2.7); core.setSpeed(1.5)
    check(core.nativeCompatibilityRestore?.position == 2.7 && core.nativeCompatibilityRestore?.rate == 1.5,
      prefix + ".latest-owned-intent")
  }
  core.stop()
  if stage == "capture" || stage == "retire" { barrier.finish(prefix) }
  retired(core, prefix)
  let lateLoaded = core.mpv.heldLoaded, lateRestart = core.mpv.heldRestart
  core.mpv.heldLoaded = nil; core.mpv.heldRestart = nil
  core.mpv.holdLoaded = false; core.mpv.holdRestart = false
  lateLoaded?(); lateRestart?()
  check(completion == 0 && core.genericHandoffOwner == nil, prefix + ".late-action-cancelled")
  assertRecord(url, position: stage == "capture" ? 1.2 : 2.7,
    speed: stage == "capture" ? 1.25 : 1.5, prefix)
  cleanWindow(core)
}

for action in ["clear", "optout", "same-path", "clear-recent"] {
  let prefix = "late." + action, url = media("late-" + action)
  let core = makeCore(url, prefix)
  settled(core, position: 1.6, speed: 1.25, prefix)
  let cacheCount = cachedResumeWrites.count, recentCount = Preference.resumePathWrites.count
  let barrier = WorkerBarrier()
  service.store.testStage = { _ in barrier.block() }
  core.stop()
  check(wait(2) { barrier.entered.wait(timeout: .now()) == .success }, prefix + ".publication-entered")
  var clearCompleted = false
  var newCore: PlayerCore?
  if action == "clear" {
    service.clearPlaybackProgress(operation: {}, completion: { _ in clearCompleted = true })
  } else if action == "optout" {
    resumeFixtureDefaults.set(false, forKey: "resumeLastPosition")
  } else if action == "same-path" {
    newCore = makeCore(url, prefix + ".new")
  } else { service.invalidateRecentRecords() }
  barrier.finish(prefix)
  retired(core, prefix)
  service.store.testStage = nil
  if action == "clear-recent" {
    assertRecord(url, position: 1.6, speed: 1.25, prefix)
    check(cachedResumeWrites.count == cacheCount + 1, prefix + ".progress-independent")
  } else {
    check(!FileManager.default.fileExists(atPath: recordURL(url).path), prefix + ".stale-record-rejected")
    check(cachedResumeWrites.count == cacheCount, prefix + ".stale-cache-rejected")
  }
  check(Preference.resumePathWrites.count == recentCount, prefix + ".stale-recent-rejected")
  if action == "clear" { check(wait { clearCompleted }, prefix + ".clear-completed") }
  if action == "optout" { resumeFixtureDefaults.set(true, forKey: "resumeLastPosition") }
  if let newCore {
    settled(newCore, position: 2.3, speed: 1.5, prefix + ".new")
    newCore.stop(); retired(newCore, prefix + ".new")
    assertRecord(url, position: 2.3, speed: 1.5, prefix + ".new")
    cleanWindow(newCore)
  }
  cleanWindow(core)
}
check(cores.allSatisfy { $0.nativeTransport == nil && !$0.nativeRetiring }, "cleanup.all-native-retired")
resumeFixtureDefaults.removePersistentDomain(forName: resumeFixtureDomain)
check(resumeFixtureDefaults.persistentDomain(forName: resumeFixtureDomain) == nil, "cleanup.owned-defaults-removed")
print("SUMMARY: \(passes + failures) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
