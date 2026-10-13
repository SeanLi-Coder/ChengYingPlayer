import AppKit
import AVFoundation
import CoreVideo

// A CLI rendering boundary, not a substitute PlayerCore or a complete App.
// Ready state below comes exclusively from the real session's worker snapshots.
enum ProbeState { case idle, paused, playing }
final class ProbeInfo { var state = ProbeState.idle }
final class ProbeVideoView: NSView { let hasInitializedOpenGL = false }
final class ProbeMainWindow { let videoView = ProbeVideoView(frame: NSRect(x: 0, y: 0, width: 160, height: 96)) }
final class ProbeMPV { let mpvRenderContext: OpaquePointer? = nil }
final class PlayerCore {
  let info = ProbeInfo()
  let mainWindow = ProbeMainWindow()
  let mpv = ProbeMPV()
  var nativePlaybackSession: NativePlaybackSession?
  var videoToolsMediaGeneration: UInt64 = 0
  var isUsingNativePlayback: Bool { nativePlaybackSession != nil }
  var playbackIsPaused: Bool { info.state == .paused }
  var nativePlaybackOutput: NativeSampleBufferOutput? { nativePlaybackSession?.output }
}

final class PausedWaitProbe {
  private enum Color: String { case red }
  private var terminal = false
  private var pollRevision = 0
  private var pixelReferences: [String: [Int]] = [:]
  private(set) var succeeded = false
  private(set) var failed = false
  private(set) var recorded = 0

  init(reference: [Int]) { pixelReferences["red"] = reference }
  func begin(_ core: PlayerCore, extra: @escaping () -> Bool = { true }) {
    waitForNativePaused(core, position: 0, color: .red, label: "delayed_real_session", extra: extra) {
      self.succeeded = true
    }
  }
  private func record(_ label: String) { recorded += 1; print("PROBE_PASS: \(label)") }
  private func fail(_ label: String) { failed = true; terminal = true; print("PROBE_FAIL: \(label)") }
  // INSERT_PAUSED_WAIT
  // INSERT_PIXEL
  // INSERT_REFERENCE
}

let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [Int]
let negative = CommandLine.arguments[3] == "old-first-session"
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

func pump(_ predicate: () -> Bool, timeout: Double = 14) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
  }
  return predicate()
}

func installSession() {
  let session = NativePlaybackSession()
  sessions.append(session)
  core.videoToolsMediaGeneration &+= 1
  core.nativePlaybackSession = session
  session.output.displayLayer.frame = core.mainWindow.videoView.bounds
  core.mainWindow.videoView.layer!.addSublayer(session.output.displayLayer)
  session.onSnapshot = { [weak session] snapshot in
    guard core.nativePlaybackSession === session else { return }
    core.info.state = snapshot.phase == .paused ? .paused : snapshot.phase == .playing ? .playing : .idle
  }
  session.open(fixture, autoplay: false)
}

let delayed = PausedWaitProbe(reference: reference)
let began = ProcessInfo.processInfo.systemUptime
DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { installSession() }
delayed.begin(core)
let resolved = pump { delayed.succeeded || delayed.failed }
let elapsed = ProcessInfo.processInfo.systemUptime - began
var passed = resolved && delayed.succeeded && !delayed.failed && delayed.recorded == 1 && elapsed >= 0.12
print("PROBE_DELAYED: success=\(delayed.succeeded) failed=\(delayed.failed) elapsed=\(elapsed)")
print("PROBE_EXPECTED_EARLY_REJECTION: \(negative && resolved && delayed.failed && !delayed.succeeded && delayed.recorded == 0 && elapsed < 0.12 && sessions.isEmpty)")
if !negative && passed {
  // Pin a real ready owner, then replace it while the independent UI condition
  // is still false. The old wait must not silently adopt the new session.
  let replaced = PausedWaitProbe(reference: reference)
  replaced.begin(core, extra: { false })
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { installSession() }
  passed = pump { replaced.failed || replaced.succeeded } && replaced.failed && !replaced.succeeded && replaced.recorded == 0
  print("PROBE_OWNER_REPLACEMENT_REJECTED: \(passed)")
  let generation = PausedWaitProbe(reference: reference)
  generation.begin(core, extra: { false })
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { core.videoToolsMediaGeneration &+= 1 }
  let rejected = pump { generation.failed || generation.succeeded } && generation.failed && !generation.succeeded && generation.recorded == 0
  passed = passed && rejected
  print("PROBE_MEDIA_GENERATION_REJECTED: \(rejected)")
}
// Drain the scheduled installation even in the negative control, then release
// every real decoder/output before closing this owned CLI window.
_ = pump({ !sessions.isEmpty }, timeout: 1)
var closed = 0
for session in sessions { session.shutdown { closed += 1 } }
let cleanup = pump({ closed == sessions.count }, timeout: 5)
for session in sessions { session.output.displayLayer.removeFromSuperlayer() }
window.close()
print("PROBE_CLEANUP: \(cleanup)")
exit(passed && cleanup ? 0 : 1)
