import AppKit
import AVFoundation

var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  if value() { passed += 1; print("PASS: \(label)") }
  else { failed += 1; print("FAIL: \(label)") }
}
@discardableResult
func wait(_ seconds: Double = 3, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
func worker(_ session: NativePlaybackSession) -> DispatchQueue {
  // This reference is immutable. Worker-owned state is read only on this queue.
  Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
}
func unavailable(_ result: NativePlaybackQueryResult?) -> Bool {
  if case .unavailable? = result { return true }; return false
}
func superseded(_ result: NativePlaybackQueryResult?) -> Bool {
  if case .superseded? = result { return true }; return false
}
func ready(_ result: NativePlaybackQueryResult?) -> NativePlaybackSnapshot? {
  if case .ready(let snapshot)? = result { return snapshot }; return nil
}

final class Barrier {
  let release = DispatchSemaphore(value: 0)
  var entered = false
  var exited = false
  var explicitRelease = false
  var cancelledBeforeReset: Bool?
  init(_ session: NativePlaybackSession, inspectCancellation: Bool = false) {
    worker(session).async { [self] in
      DispatchQueue.main.async { self.entered = true }
      let result = release.wait(timeout: .now() + 4)
      var cancelled: Bool?
      if inspectCancellation {
        let decoder = Mirror(reflecting: session).children.first { $0.label == "decoder" }!.value as! CYNMediaDecoder?
        do { _ = try decoder?.readSample(); cancelled = false }
        catch {
          let error = error as NSError
          cancelled = error.domain == CYNMediaDecoderErrorDomain && error.code == CYNMediaDecoderError.cancelled.rawValue
        }
      }
      DispatchQueue.main.async {
        self.explicitRelease = result == .success
        self.cancelledBeforeReset = cancelled
        self.exited = true
      }
    }
  }
  func enter(_ label: String) { check(wait(1) { entered }, "\(label): worker barrier entered") }
  func finish(_ label: String) {
    release.signal()
    check(wait(1) { exited } && explicitRelease, "\(label): worker barrier explicitly released")
  }
}

final class Harness {
  var session: NativePlaybackSession?
  weak var released: NativePlaybackSession?
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
  var latest: NativePlaybackSnapshot?
  init() {
    let value = NativePlaybackSession()
    session = value; released = value
    host.wantsLayer = true
    value.output.displayLayer.frame = host.bounds
    host.layer!.addSublayer(value.output.displayLayer)
    value.onSnapshot = { [weak self] in self?.latest = $0 }
  }
  func settled(_ predicate: @escaping (NativePlaybackSnapshot) -> Bool) -> NativePlaybackSnapshot? {
    var pending = false
    var accepted: NativePlaybackSnapshot?
    _ = wait(4) {
      if accepted != nil { return true }
      if !pending {
        pending = true
        self.session!.captureCurrentState {
          if case .ready(let snapshot) = $0, predicate(snapshot) { accepted = snapshot }
          pending = false
        }
      }
      return false
    }
    return accepted
  }
  func open(_ url: URL, position: Double = 0.4) -> NativePlaybackSnapshot? {
    session!.open(url, autoplay: false)
    guard settled({ $0.phase == .paused }) != nil, session!.seek(to: position) else { return nil }
    return settled { $0.phase == .paused && abs($0.position - position) < 0.001 }
  }
  func dispose(_ label: String) {
    session?.output.displayLayer.removeFromSuperlayer()
    session = nil
    check(wait(2) { released == nil }, "\(label): session releases after shutdown")
  }
}
final class Receipt {
  var captures: [NativePlaybackQueryResult] = []
  var completionCount = 0
  var order: [String] = []
  var onMain = true
  func close(_ session: NativePlaybackSession) {
    session.shutdown(capturingState: { [self] in
      onMain = onMain && Thread.isMainThread
      captures.append($0); order.append("capture")
    }) { [self] in
      onMain = onMain && Thread.isMainThread
      completionCount += 1; order.append("completion")
    }
  }
  func verify(_ label: String) {
    check(wait { completionCount > 0 }, "\(label): shutdown completes")
    drain()
    check(captures.count == 1 && completionCount == 1 && onMain && order == ["capture", "completion"],
          "\(label): capture and completion run exactly once in order on main")
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let longURL = directory.appendingPathComponent("long.mkv")
let shortURL = directory.appendingPathComponent("short.mp4")

for mode in ["paused", "playing", "ended", "reopened"] {
  let h = Harness()
  var initial = h.open(mode == "ended" ? shortURL : longURL)
  if mode == "reopened" { initial = h.open(longURL, position: 1.1) }
  check(initial != nil, "\(mode): real decode and paused seek settle")
  h.session!.setVolume(0.37)
  check(h.session!.setRate(1.25), "\(mode): supported rate accepted")
  var before = h.settled { $0.phase == .paused && $0.rate == 1.25 && abs($0.volume - 0.37) < 0.0001 }
  if mode == "playing" || mode == "ended" {
    h.session!.setPaused(false)
    before = h.settled { mode == "ended" ? $0.phase == .ended : ($0.phase == .playing && $0.position > 0.6) }
  }
  check(before != nil, "\(mode): actual worker reaches requested final state")
  let receipt = Receipt(); receipt.close(h.session!); receipt.verify(mode)
  let final = ready(receipt.captures.first)
  check(final != nil && final?.generation == before?.generation && final?.revision == before?.revision &&
          final?.media === before?.media && final?.phase == before?.phase,
        "\(mode): final snapshot retains actual pre-shutdown media identity and phase")
  check(final.map { $0.position.isFinite && $0.position >= (before?.position ?? 100) - 0.001 &&
          $0.position <= $0.duration && $0.position > 0.3 && $0.duration == before?.duration &&
          abs($0.volume - 0.37) < 0.0001 && $0.rate == 1.25 && $0.videoSamples > 0 && $0.audioSamples > 0 } == true,
        "\(mode): final snapshot uses real nonzero clock and applied settings before reset")
  var after: NativePlaybackQueryResult?
  h.session!.captureCurrentState { after = $0 }
  check(wait { after != nil } && unavailable(after), "\(mode): terminal normal query stays unavailable")
  check(!h.session!.seek(to: 0.2) && !h.session!.setRate(0.8), "\(mode): terminal commands stay rejected")
  h.session!.open(shortURL, autoplay: true)
  drain()
  check(h.latest?.phase == .closed && h.latest?.media == nil && h.latest?.position == 0,
        "\(mode): terminal snapshot is closed and cannot reopen playback")
  h.dispose(mode)
}

for mode in ["pending-seek", "pending-same-open", "pending-other-open", "pending-stop", "pending-commands"] {
  let h = Harness()
  let before = h.open(longURL, position: 1.1)
  check(before != nil, "\(mode): real paused baseline settles")
  let barrier = Barrier(h.session!, inspectCancellation: mode == "pending-commands")
  barrier.enter(mode)
  var ordinary: NativePlaybackQueryResult?
  h.session!.captureCurrentState { ordinary = $0 }
  switch mode {
  case "pending-seek": check(h.session!.seek(to: 2.7), "\(mode): pending preview restore seek accepted")
  case "pending-same-open": h.session!.open(longURL, autoplay: false)
  case "pending-other-open": h.session!.open(shortURL, autoplay: false)
  case "pending-stop": h.session!.stop()
  default:
    h.session!.setVolume(0.83)
    check(h.session!.setRate(1.5), "\(mode): queued rate accepted before retirement")
    h.session!.setPaused(false)
    h.session!.setLoop(try! NativePlaybackInterval(start: 2, end: 4))
  }
  let receipt = Receipt(); receipt.close(h.session!)
  check(receipt.captures.isEmpty && receipt.completionCount == 0,
        "\(mode): shutdown does not block main or publish a cached receipt")
  barrier.finish(mode); receipt.verify(mode)
  check(wait { ordinary != nil } && superseded(ordinary), "\(mode): earlier normal query is superseded")
  if mode == "pending-commands" {
    let final = ready(receipt.captures.first)
    check(barrier.cancelledBeforeReset == true, "\(mode): decoder cancellation is immediate before worker reset")
    check(final?.phase == .paused && final?.rate == before?.rate && final?.volume == before?.volume &&
            abs((final?.position ?? -1) - 1.1) < 0.001,
          "\(mode): cancelled queued commands cannot fabricate applied playback intent")
  } else {
    check(unavailable(receipt.captures.first), "\(mode): uncommitted media intent cannot save stale worker position")
  }
  h.dispose(mode)
}

// Force a real seek to execute, but keep its scheduled pump behind a second barrier.
do {
  let label = "preroll"
  let h = Harness()
  check(h.open(longURL) != nil, "\(label): real paused baseline settles")
  let first = Barrier(h.session!); first.enter("\(label) first")
  check(h.session!.seek(to: 2.2), "\(label): restore seek accepted")
  let second = Barrier(h.session!)
  first.finish("\(label) first"); second.enter("\(label) second")
  check(h.latest?.phase == .seeking && h.latest?.position == 2.2,
        "\(label): actual seek entered worker preroll before shutdown")
  let receipt = Receipt(); receipt.close(h.session!)
  second.finish("\(label) second"); receipt.verify(label)
  check(unavailable(receipt.captures.first), "\(label): actual pending seek preroll is not a resume point")
  h.dispose(label)
}

for mode in ["idle", "opening", "failed", "stopped"] {
  let h = Harness()
  var barrier: Barrier?
  if mode == "opening" {
    barrier = Barrier(h.session!); barrier!.enter(mode)
    h.session!.open(longURL, autoplay: true)
  } else if mode == "failed" {
    h.session!.open(directory.appendingPathComponent("does-not-exist.mkv"), autoplay: false)
    check(wait { h.latest?.phase == .failed }, "\(mode): actual decoder open fails")
  } else if mode == "stopped" {
    check(h.open(longURL) != nil, "\(mode): real paused baseline settles")
    h.session!.stop()
    check(wait { h.latest?.phase == .idle }, "\(mode): actual worker reaches idle")
  }
  let receipt = Receipt(); receipt.close(h.session!)
  barrier?.finish(mode); receipt.verify(mode)
  check(unavailable(receipt.captures.first), "\(mode): unready session supplies no invented resume point")
  h.dispose(mode)
}

do {
  let label = "repeat"
  let h = Harness()
  check(h.open(longURL, position: 1.4) != nil, "\(label): real paused baseline settles")
  let barrier = Barrier(h.session!); barrier.enter(label)
  let first = Receipt(); let second = Receipt(); let reentrant = Receipt()
  var firstResult: NativePlaybackQueryResult?
  var firstCount = 0
  h.session!.shutdown(capturingState: {
    firstResult = $0; firstCount += 1
    reentrant.close(h.session!)
  }) { first.completionCount += 1 }
  second.close(h.session!)
  barrier.finish(label)
  check(wait { first.completionCount >= 1 && second.completionCount >= 1 && reentrant.completionCount >= 1 },
        "\(label): concurrent and reentrant retirements complete")
  second.verify("\(label) concurrent"); reentrant.verify("\(label) reentrant")
  let after = Receipt(); after.close(h.session!); after.verify("\(label) closed")
  check(firstCount == 1 && ready(firstResult)?.position == 1.4,
        "\(label): only the first retirement receives its stable snapshot")
  check(unavailable(second.captures.first) && unavailable(reentrant.captures.first) && unavailable(after.captures.first),
        "\(label): later retirements never duplicate the original receipt")
  h.dispose(label)
}

do {
  let label = "released-owner"
  let h = Harness()
  check(h.open(longURL, position: 1.6) != nil, "\(label): real paused baseline settles")
  let barrier = Barrier(h.session!); barrier.enter(label)
  let receipt = Receipt(); receipt.close(h.session!)
  h.session?.output.displayLayer.removeFromSuperlayer()
  h.session = nil
  check(h.released != nil, "\(label): in-flight retirement retains its worker owner")
  barrier.finish(label); receipt.verify(label)
  check(ready(receipt.captures.first)?.position == 1.6,
        "\(label): final receipt survives caller releasing the session")
  check(wait(2) { h.released == nil }, "\(label): completed retirement releases its worker owner")
}

// Existing callers keep trailing-closure source compatibility and async cleanup.
do {
  let h = Harness()
  var count = 0
  h.session!.shutdown { check(Thread.isMainThread, "legacy: completion stays on main"); count += 1 }
  check(wait { count == 1 }, "legacy: original shutdown call remains source compatible")
  h.dispose("legacy")
}
print("Resume session checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
