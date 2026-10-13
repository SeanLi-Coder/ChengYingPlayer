import AppKit
import AVFoundation
import CoreVideo

// The services below are a CLI boundary, not a complete PlayerCore or App.
// Playback state and pixels come only from the real production session/output.
enum ProbeState { case idle, paused, playing }
final class ProbeInfo { var state = ProbeState.idle; var currentURL: URL? }
final class ProbeVideoView: NSView { let hasInitializedOpenGL = false }
final class ProbeMainWindow {
  let videoView = ProbeVideoView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
  var window: NSWindow? { videoView.window }
}
final class ProbeMPV { let mpvRenderContext: OpaquePointer? = nil }
final class PlayerCore {
  let info = ProbeInfo()
  let mainWindow = ProbeMainWindow()
  let mpv = ProbeMPV()
  var nativePlaybackSession: NativePlaybackSession?
  var videoToolsMediaGeneration: UInt64 = 0
  var nativeRoute = true
  var isUsingNativePlayback: Bool { nativeRoute && nativePlaybackSession != nil }
  var playbackIsPaused: Bool { info.state == .paused }
  var nativePlaybackOutput: NativeSampleBufferOutput? { nativePlaybackSession?.output }
  func captureMPVEventRevision() -> UInt64? { nativeRoute ? nil : 1 }
}

final class HandoffWaitProbe {
  private enum Color: String { case red, green }
  private var terminal = false
  private var pollRevision = 0
  private var pixelReferences: [String: [Int]]
  private(set) var succeeded = false
  private(set) var failed = false
  private(set) var recorded = 0

  init(references: [String: [Int]]) { pixelReferences = references }
  func matchesGreen(_ core: PlayerCore) -> Bool { pixel(core, is: .green) }
  func begin(_ core: PlayerCore, extra: @escaping () -> Bool = { true }) {
    guard let session = core.nativePlaybackSession, let url = core.info.currentURL,
          let window = core.mainWindow.window, let layer = core.nativePlaybackOutput?.displayLayer else {
      fail("nondefault_state"); return
    }
    waitForHandoffState(core, session: session, generation: core.videoToolsMediaGeneration, url: url,
      window: window, layer: layer, label: "nondefault_state", extra: extra) {
        self.succeeded = true
      }
  }
  private func record(_ label: String) { recorded += 1; print("HANDOFF_PASS: \(label)") }
  private func fail(_ label: String) { failed = true; terminal = true; print("HANDOFF_FAIL: \(label)") }
  // INSERT_PAUSED_WAIT
  // INSERT_HANDOFF_WAIT
  // INSERT_PIXEL
  // INSERT_REFERENCE
}

let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let references = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: [Int]]
let mode = CommandLine.arguments[3]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let core = PlayerCore()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 96),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = core.mainWindow.videoView
core.mainWindow.videoView.wantsLayer = true
window.orderFrontRegardless()
var sessions: [NativePlaybackSession] = []

func pump(_ predicate: () -> Bool, timeout: Double = 12) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
  }
  return predicate()
}

func installSession() -> NativePlaybackSession {
  let session = NativePlaybackSession()
  sessions.append(session)
  core.videoToolsMediaGeneration &+= 1
  core.nativePlaybackSession = session
  core.info.currentURL = fixture
  session.output.displayLayer.frame = core.mainWindow.videoView.bounds
  core.mainWindow.videoView.layer!.addSublayer(session.output.displayLayer)
  session.onSnapshot = { [weak session] snapshot in
    guard core.nativePlaybackSession === session else { return }
    core.info.state = snapshot.phase == .paused ? .paused : snapshot.phase == .playing ? .playing : .idle
  }
  session.open(fixture, autoplay: false)
  return session
}

// Setup is deliberately independent of the extracted wait under test. There is
// at most one worker query in flight; no cached snapshot is accepted as ready.
func awaitState(_ session: NativePlaybackSession, matching predicate: @escaping (NativePlaybackSnapshot) -> Bool) -> Bool {
  var finished = false
  var matched = false
  let deadline = ProcessInfo.processInfo.systemUptime + 12
  func query() {
    session.captureCurrentState { result in
      if case .ready(let snapshot) = result, predicate(snapshot) { matched = true; finished = true }
      else if ProcessInfo.processInfo.systemUptime >= deadline { finished = true }
      else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: query) }
    }
  }
  query()
  return pump({ finished }, timeout: 12.2) && matched
}

// Inspect only the immutable serial queue, never mutable decoder/output state.
// Hold it before submitting the real rate command and query. This fixes command
// ordering even if main is descheduled between them: the query must precede the
// asynchronous refill that setRate schedules. Both positive and negative modes
// use the same barrier; no returned state or sample is replaced.
func withWorkerSubmissionBarrier(_ session: NativePlaybackSession, submit: () -> Void) -> Bool {
  let matches = Mirror(reflecting: session).children.filter { $0.label == "worker" }
  guard matches.count == 1, let queue = matches.first?.value as? DispatchQueue else { return false }
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let exited = DispatchSemaphore(value: 0)
  queue.async {
    entered.signal()
    let result = release.wait(timeout: .now() + 3)
    if result == .success { exited.signal() }
  }
  guard entered.wait(timeout: .now() + 1) == .success else { release.signal(); return false }
  submit()
  release.signal()
  return exited.wait(timeout: .now() + 1) == .success
}

func prepareSession() -> NativePlaybackSession? {
  let probe = HandoffWaitProbe(references: references)
  let session = installSession()
  guard awaitState(session, matching: { $0.phase == .paused && $0.position == 0 }) else { return nil }
  session.setLoop(try! NativePlaybackInterval(start: 0, end: 5.5))
  guard session.seek(to: 4.2), awaitState(session, matching: {
    $0.phase == .paused && !$0.wantsPlayback && abs($0.position - 4.2) < 0.0000001 && probe.matchesGreen(core)
  }) else { return nil }
  return session
}

func reproduceOriginalCapture() -> Bool {
  let probe = HandoffWaitProbe(references: references)
  guard let session = prepareSession() else { return false }
  var immediate: String?
  var rateAccepted = false
  let submitted = withWorkerSubmissionBarrier(session) {
    session.setVolume(0.37)
    rateAccepted = session.setRate(1.25)
    session.captureCurrentState { result in
      switch result {
      case .ready: immediate = "ready"
      case .unavailable: immediate = "unavailable"
      case .superseded: immediate = "superseded"
      }
    }
  }
  print("HANDOFF_WORKER_ORDERED: \(submitted && rateAccepted)")
  guard submitted && rateAccepted else { return false }
  guard pump({ immediate != nil }) else { return false }
  print("HANDOFF_IMMEDIATE_QUERY: \(immediate!)")
  let settled = awaitState(session, matching: {
    $0.phase == .paused && !$0.wantsPlayback && abs($0.position - 4.2) < 0.0000001 &&
      abs(Double($0.volume) - 0.37) < 0.000001 && abs(Double($0.rate) - 1.25) < 0.000001 && probe.matchesGreen(core)
  })
  print("HANDOFF_SETTLED_REAL_STATE: \(settled)")
  print("HANDOFF_ORIGINAL_CAPTURE_REJECTED: \(immediate == "unavailable" && settled)")
  return immediate == "ready" && settled
}

func exerciseBoundedWait() -> Bool {
  guard let session = prepareSession() else { return false }
  let probe = HandoffWaitProbe(references: references)
  var rateAccepted = false
  let submitted = withWorkerSubmissionBarrier(session) {
    session.setVolume(0.37)
    rateAccepted = session.setRate(1.25)
    probe.begin(core)
  }
  print("HANDOFF_WORKER_ORDERED: \(submitted && rateAccepted)")
  guard submitted && rateAccepted else { return false }
  let normal = pump { probe.succeeded || probe.failed } && probe.succeeded && !probe.failed && probe.recorded == 1
  print("HANDOFF_BOUNDED_READY: \(normal)")
  guard normal, mode != "old-one-shot" else { return normal }

  // A second real session is opened while the wait is pending. Both sources
  // are the same URL: a replacement cannot pass merely by matching its pixels.
  let replacement = HandoffWaitProbe(references: references)
  var replacementReady = false
  replacement.begin(core, extra: { replacementReady })
  guard let newSession = prepareSession() else { return false }
  newSession.setVolume(0.37)
  guard newSession.setRate(1.25), awaitState(newSession, matching: {
    $0.phase == .paused && !$0.wantsPlayback && abs($0.position - 4.2) < 0.0000001 &&
      abs(Double($0.volume) - 0.37) < 0.000001 && abs(Double($0.rate) - 1.25) < 0.000001 && replacement.matchesGreen(core)
  }) else { return false }
  replacementReady = true
  let rejected = pump { replacement.succeeded || replacement.failed } &&
    replacement.failed && !replacement.succeeded && replacement.recorded == 0
  print("HANDOFF_REPLACEMENT_REJECTED: \(rejected)")
  guard mode != "ignore-owner" else { return rejected }

  let generation = HandoffWaitProbe(references: references)
  generation.begin(core, extra: { false })
  core.videoToolsMediaGeneration &+= 1
  let generationRejected = pump { generation.succeeded || generation.failed } &&
    generation.failed && !generation.succeeded && generation.recorded == 0
  print("HANDOFF_GENERATION_REJECTED: \(generationRejected)")
  let route = HandoffWaitProbe(references: references)
  route.begin(core, extra: { false })
  core.nativeRoute = false
  let routeRejected = pump { route.succeeded || route.failed } && route.failed && !route.succeeded && route.recorded == 0
  print("HANDOFF_ROUTE_REJECTED: \(routeRejected)")
  return normal && rejected && generationRejected && routeRejected
}

let passed = mode == "old-handoff-capture" ? reproduceOriginalCapture() : exerciseBoundedWait()
var closed = 0
for session in sessions { session.shutdown { closed += 1 } }
let cleanup = pump({ closed == sessions.count }, timeout: 5)
for session in sessions { session.output.displayLayer.removeFromSuperlayer() }
window.close()
print("HANDOFF_CLEANUP: \(cleanup)")
exit(passed && cleanup ? 0 : 1)
