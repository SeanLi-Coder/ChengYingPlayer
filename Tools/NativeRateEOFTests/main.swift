import AppKit
import AVFoundation

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  if condition() { passed += 1; print("PASS: \(label)") }
  else { failed += 1; print("FAIL: \(label)") }
}

@discardableResult
func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return condition()
}

struct OutputState {
  let position: Double
  let rate: Double
  let volume: Float
  let flushGeneration: UInt64
}

func inspect(_ session: NativePlaybackSession) -> OutputState? {
  // Reflect only the immutable worker reference, never worker-owned fields.
  let worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
  var state: OutputState?
  worker.async {
    let value = OutputState(position: session.output.currentTime.seconds,
                            rate: session.output.actualRate, volume: session.output.volume,
                            flushGeneration: session.output.flushGeneration)
    DispatchQueue.main.async { state = value }
  }
  _ = waitUntil(2) { state != nil }
  return state
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

for file in ["pcm.mkv", "aac.mp4"] {
  for changedRate in [false, true] {
    let label = "\(file) \(changedRate ? "changed-rate" : "unchanged-rate")"
    var session: NativePlaybackSession? = NativePlaybackSession()
    weak var released = session
    let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
    layerHost.wantsLayer = true
    session!.output.displayLayer.frame = layerHost.bounds
    layerHost.layer!.addSublayer(session!.output.displayLayer)
    var latest: NativePlaybackSnapshot?
    var timeline: [(NativePlaybackPhase, Double, Float, Bool)] = []
    session!.onSnapshot = {
      latest = $0
      if timeline.count < 256 { timeline.append(($0.phase, $0.position, $0.rate, $0.wantsPlayback)) }
    }
    session!.open(directory.appendingPathComponent(file), autoplay: true)
    let ended = waitUntil(5) { latest?.phase == .ended || latest?.phase == .failed }
    check(ended && latest?.phase == .ended, "\(label): actual playback reaches EOF")
    check(latest?.generation == 1 && (latest?.audioSamples ?? 0) > 0 && (latest?.videoSamples ?? 0) > 0,
          "\(label): EOF follows actual decoded audio and video")
    check(waitUntil(2) { inspect(session!).map { $0.volume == 0 && $0.rate == 0 } == true },
          "\(label): EOF shared output is paused and silent")
    let duration = latest?.duration ?? 0
    let eofOutput = inspect(session!)
    let beforeCount = timeline.count
    if changedRate {
      check(session!.setRate(0.8), "\(label): supported rate change is accepted at EOF")
      check(waitUntil(3) {
        timeline.count > beforeCount && latest?.rate == 0.8 &&
          [.paused, .ended, .failed].contains(latest?.phase ?? .opening)
      }, "\(label): rate command reaches a settled real session state")
      check(latest?.phase == .ended, "\(label): rate change preserves EOF state")
      check(inspect(session!).map { $0.rate == 0 && $0.flushGeneration == eofOutput?.flushGeneration } == true,
            "\(label): rate change leaves ended output paused without refilling its tail")
      check(!session!.setRate(4), "\(label): unsupported rate is rejected at EOF")
      check(session!.setRate(0.5) && session!.setRate(1.2) && session!.setRate(0.8),
            "\(label): consecutive supported EOF rates are accepted")
      // Queue this read after all three rate commands, and deliver it after
      // their snapshot callbacks. A cached pre-command 0.8 cannot satisfy it.
      check(inspect(session!) != nil, "\(label): worker barrier observes every consecutive rate command")
      check(waitUntil(2) { latest?.phase == .ended && latest?.rate == 0.8 } &&
              timeline.dropFirst(beforeCount).allSatisfy { $0.0 == .ended },
            "\(label): consecutive rate commands keep EOF until an explicit transport action")
    }
    let beforeResume = inspect(session!)
    print("BEFORE_RESUME: case=\(label) phase=\(latest?.phase.rawValue ?? "missing") position=\(latest?.position ?? -1) duration=\(duration) requestedRate=\(latest?.rate ?? -1) actualClock=\(beforeResume?.position ?? -1) actualRate=\(beforeResume?.rate ?? -1)")
    let resumeIndex = timeline.count
    session!.setPaused(false)
    let restarted = waitUntil(3) {
      timeline.dropFirst(resumeIndex).contains { $0.0 == .playing && $0.1 < 0.25 }
    }
    check(restarted, "\(label): first resume rewinds EOF and plays from the beginning")
    check(latest?.generation == 1, "\(label): resume retains the same media generation")
    if restarted {
      check(waitUntil(2) { latest?.phase == .playing && (latest?.position ?? 0) > 0.3 && (latest?.position ?? duration) < duration },
            "\(label): resumed playback advances beyond the first frame")
      let actual = inspect(session!)
      check(actual.map { abs($0.rate - (changedRate ? 0.8 : 1)) < 0.0001 && $0.volume == 0 } == true,
            "\(label): resumed clock uses the selected rate without changing volume")
    }
    if changedRate {
      check(waitUntil(3) { latest?.phase == .ended }, "\(label): resumed media reaches a second actual EOF")
      check(session!.seek(to: 0.4), "\(label): an explicit seek leaves EOF")
      check(waitUntil(3) { latest?.phase == .paused && abs((latest?.position ?? -1) - 0.4) < 0.001 },
            "\(label): explicit seek reaches its actual paused target")
      check(session!.setRate(1.2), "\(label): post-seek rate change is accepted")
      check(waitUntil(3) { latest?.phase == .paused && latest?.rate == 1.2 && abs((latest?.position ?? -1) - 0.4) < 0.001 },
            "\(label): rate after an accepted seek preserves that target rather than rewinding")
      session!.setPaused(false)
      check(waitUntil(2) { latest?.phase == .playing && (latest?.position ?? 0) > 0.5 && (latest?.position ?? duration) < duration },
            "\(label): explicit-seek resume advances from the chosen position")
    }
    for (index, row) in timeline.enumerated() {
      print("SNAPSHOT: case=\(label) index=\(index) phase=\(row.0.rawValue) position=\(row.1) rate=\(row.2) wantsPlayback=\(row.3)")
    }
    var closed = false
    session!.shutdown { closed = true }
    check(waitUntil(3) { closed }, "\(label): shutdown completes")
    session!.output.displayLayer.removeFromSuperlayer()
    session = nil
    check(waitUntil(2) { released == nil }, "\(label): session releases")
  }
}
print("Rate EOF checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
