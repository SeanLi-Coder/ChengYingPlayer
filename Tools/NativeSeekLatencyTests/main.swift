import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit

// This CLI uses the real decoder and session, with a deliberately controlled
// output boundary. It measures sample delivery, not physical screen latency.
final class SeekTrace {
  static let shared = SeekTrace()
  private let lock = NSLock()
  private var reads = 0
  private var discarded = 0
  private var pumps = 0
  private var pumpReads = 0
  private var maximumReads = 0
  private var immediate = 0
  private var delayed = 0
  private var callback: (() -> Void)?
  private var readDelay = 0.0
  func reset(readDelay: Double = 0, callback: (() -> Void)? = nil) {
    lock.lock(); defer { lock.unlock() }
    reads = 0; discarded = 0; pumps = 0; pumpReads = 0; maximumReads = 0
    immediate = 0; delayed = 0; self.callback = callback; self.readDelay = readDelay
  }
  func beginPump() { lock.lock(); pumps += 1; pumpReads = 0; lock.unlock() }
  func endPump() { lock.lock(); maximumReads = max(maximumReads, pumpReads); lock.unlock() }
  func read() {
    lock.lock(); reads += 1; pumpReads += 1
    let action = reads == 8 ? callback : nil
    let delay = readDelay
    lock.unlock(); action?()
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
  }
  func discard() { lock.lock(); discarded += 1; lock.unlock() }
  func schedule(_ delay: DispatchTimeInterval) {
    lock.lock(); defer { lock.unlock() }
    if case .milliseconds(0) = delay { immediate += 1 } else { delayed += 1 }
  }
  func snapshot() -> [String: Int] {
    lock.lock(); defer { lock.unlock() }
    return ["reads": reads, "discarded": discarded, "pumps": pumps,
            "maximum_reads_per_pump": maximumReads, "immediate": immediate, "delayed": delayed]
  }
}

struct Delivered {
  let video: Bool
  let start: Double
  let end: Double
  let digest: String
  let bytes: Int
  let time: Double
}

func payload(_ sample: CMSampleBuffer, video: Bool) -> Data {
  if video, let pixel = CMSampleBufferGetImageBuffer(sample) {
    precondition(CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    precondition(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var data = Data()
    for plane in 0..<2 {
      let width = CVPixelBufferGetWidthOfPlane(pixel, plane) * (plane == 0 ? 1 : 2)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
      let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!
      for row in 0..<CVPixelBufferGetHeightOfPlane(pixel, plane) {
        data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width)
      }
    }
    return data
  }
  guard let block = CMSampleBufferGetDataBuffer(sample) else { preconditionFailure("Missing PCM block") }
  var data = Data(count: CMBlockBufferGetDataLength(block))
  let status = data.withUnsafeMutableBytes { memory in
    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: memory.count, destination: memory.baseAddress!)
  }
  precondition(status == noErr)
  return data
}

func delivered(_ sample: CMSampleBuffer, video: Bool) throws -> Delivered {
  let enteredOutput = ProcessInfo.processInfo.systemUptime
  let bytes = payload(sample, video: video)
  return Delivered(video: video, start: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
    end: try NativePlaybackSampleGate.end(of: sample, clippedAt: nil),
    digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    bytes: bytes.count, time: enteredOutput)
}

// Explicit boundary: no AV renderer, NSApplication, window or system audio.
// All mutable members are accessed on the production session's own worker.
final class NativeSampleBufferOutput {
  enum OutputError: Error { case backpressure }
  let workerQueue: DispatchQueue
  var onAudioFlush: ((CMTime) -> Void)?
  var error: Error? { nil }
  var isFlushingVideo = false
  var blocked = false
  var audioBlocked = false
  var videoEnqueueDelay = 0.0
  var flushDelay = false
  var anchorDelay = false
  var readinessRejections = 0
  var videoReadinessRejections = 0
  var flushGeneration: UInt64 = 0
  var volume: Float = 0
  var actualRate: Double = 0
  private var anchored = 0.0
  private var hostTime = ProcessInfo.processInfo.systemUptime
  private(set) var received: [Delivered] = []
  var currentTime: CMTime {
    CMTime(seconds: anchored + (ProcessInfo.processInfo.systemUptime - hostTime) * actualRate,
           preferredTimescale: 1_000_000_000)
  }
  init(workerQueue: DispatchQueue) { self.workerQueue = workerQueue }
  func setVolume(_ value: Float) { volume = value }
  func setRate(_ value: Float, at time: CMTime? = nil) {
    anchored = currentTime.seconds; hostTime = ProcessInfo.processInfo.systemUptime; actualRate = Double(value)
    if let time {
      if anchorDelay { return }
      anchored = time.seconds
    }
  }
  func flush(removeImage: Bool) {
    flushGeneration &+= 1; received.removeAll(); isFlushingVideo = flushDelay; readinessRejections = 0
    videoReadinessRejections = 0
  }
  func isReady(video: Bool) -> Bool {
    let ready = !blocked && !isFlushingVideo && (video || !audioBlocked)
    if !ready { readinessRejections += 1 }
    if !ready && video { videoReadinessRejections += 1 }
    return ready
  }
  func enqueue(_ sample: CMSampleBuffer, video: Bool) throws {
    guard isReady(video: video) else { throw OutputError.backpressure }
    received.append(try delivered(sample, video: video))
    if video && videoEnqueueDelay > 0 { Thread.sleep(forTimeInterval: videoEnqueueDelay) }
  }
  func shutdown(completion: @escaping () -> Void) {
    actualRate = 0; received.removeAll()
    DispatchQueue.main.async(execute: completion)
  }
}

setbuf(stdout, nil)
var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  if condition() { passed += 1; print("PASS: \(name)") }
  else { failed += 1; print("FAIL: \(name)") }
}
@discardableResult
func wait(_ seconds: Double = 15, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}
func onWorker<T>(_ session: NativePlaybackSession, _ action: @escaping (NativeSampleBufferOutput) -> T) -> T? {
  var result: T?
  session.output.workerQueue.async {
    let value = action(session.output)
    DispatchQueue.main.async { result = value }
  }
  _ = wait { result != nil }
  return result
}
precondition(CommandLine.arguments.count == 4)
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
precondition(["baseline", "candidate"].contains(mode))
let instrumented = ProcessInfo.processInfo.environment["NATIVE_SEEK_INSTRUMENT"] != "0"
let reportPath = URL(fileURLWithPath: CommandLine.arguments[3])
let points = [1.2, 6.4, 8.7]
var references: [Double: [Delivered]] = [:]
let referenceQueue = DispatchQueue(label: "seek-reference")
referenceQueue.sync {
  for target in points + [2.5] {
    let decoder = CYNMediaDecoder()
    do {
      _ = try decoder.open(fixture)
      var values: [Delivered] = []
      while let sample = try decoder.readSample() {
        if values.contains(where: { $0.video == sample.isVideo }) { continue }
        if case .sample(let retained) = try NativePlaybackSampleGate.clip(sample.sampleBuffer,
            video: sample.isVideo, start: target, end: nil) {
          values.append(try delivered(retained, video: sample.isVideo))
        }
        if values.count == 2 { break }
      }
      references[target] = values
    } catch { print("REFERENCE ERROR: \(error)") }
    decoder.close()
  }
}
check(references.values.allSatisfy { $0.count == 2 } && references.count == 4,
      "Origin-decoded references contain target video and PCM")
var snapshot: NativePlaybackSnapshot?
var observations: [NativePlaybackSampleObservation] = []
let observationLock = NSLock()
let session = NativePlaybackSession(sampleObserver: {
  observationLock.lock(); observations.append($0); observationLock.unlock()
})
func resetTrace(readDelay: Double = 0, callback: (() -> Void)? = nil) {
  _ = onWorker(session) { _ in
    SeekTrace.shared.reset(readDelay: readDelay, callback: callback)
    return true
  }
}
session.onSnapshot = { snapshot = $0 }
session.open(fixture, autoplay: false)
check(wait { snapshot?.phase == .paused }, "Real decoder opens paused through production session")
check(snapshot?.volume == 0, "Open remains silent")
func decoderPaths() -> [String: Any] {
  observationLock.lock(); defer { observationLock.unlock() }
  let video = observations.filter { $0.revision == snapshot?.revision && $0.video }
  return ["scope": "delivered-target-samples-only", "video_samples": video.count,
          "hardware_samples": video.filter { $0.hardwareDecoded }.count,
          "videotoolbox_samples": video.filter { $0.videoToolboxDecoded }.count]
}
func firstStreamSamples(_ values: [Delivered]) -> [[String: Any]] {
  return [true, false].compactMap { video in
    guard let value = values.first(where: { $0.video == video }) else { return nil }
    return ["video": value.video, "start": value.start, "end": value.end,
            "bytes": value.bytes, "sha256": value.digest]
  }
}
func validate(_ target: Double, _ label: String, checkPausedClock: Bool = true) {
  let values = onWorker(session) { $0.received } ?? []
  for video in [true, false] {
    let actual = values.first { $0.video == video }
    let expected = references[target]?.first { $0.video == video }
    check(actual != nil && expected != nil, "\(label): both stream samples are delivered")
    if let actual, let expected {
      check(abs(actual.start - expected.start) < 0.000001 && abs(actual.end - expected.end) < 0.000001,
            "\(label): exact \(video ? "video" : "audio") target timing matches origin decode")
      check(actual.bytes == expected.bytes && actual.digest == expected.digest,
            "\(label): \(video ? "pixels" : "PCM bytes") match origin decode without precision loss")
    }
  }
  check(values.allSatisfy { $0.start >= target - 0.000001 }, "\(label): no pre-target samples reach output")
  if checkPausedClock {
    check(snapshot?.phase == .paused && abs((snapshot?.position ?? -1) - target) < 0.000001,
          "\(label): paused clock remains at exact target")
  }
  observationLock.lock()
  let currentObservations = observations.filter { $0.revision == snapshot?.revision }
  observationLock.unlock()
  check(!currentObservations.isEmpty && currentObservations.allSatisfy {
    $0.generation == snapshot?.generation && $0.start >= target - 0.000001
  }, "\(label): delivered observations retain current generation and exact seek boundary")
  for video in [true, false] {
    let stream = values.filter { $0.video == video }
    check(zip(stream, stream.dropFirst()).allSatisfy { $0.start <= $1.start },
          "\(label): \(video ? "video" : "audio") delivery remains ordered")
  }
  if instrumented {
    check(SeekTrace.shared.snapshot()["maximum_reads_per_pump", default: 99] <= 8,
          "\(label): cooperative work stays at most eight decoder reads per pump")
  }
}
var measurements: [[String: Any]] = []
let rounds = Int(ProcessInfo.processInfo.environment["NATIVE_SEEK_ROUNDS"] ?? "5")!
precondition((1...5).contains(rounds))
for round in 0..<rounds {
  for target in points {
    let revision = snapshot?.revision ?? 0
    resetTrace()
    let started = ProcessInfo.processInfo.systemUptime
    check(session.seek(to: target), "Measured seek is accepted")
    check(wait { (snapshot?.revision ?? 0) > revision && snapshot?.phase == .paused }, "Measured seek reaches paused-ready")
    let rows = onWorker(session) { $0.received } ?? []
    let latency = rows.first(where: { $0.video }).map { ($0.time - started) * 1000 } ?? -1
    let trace = SeekTrace.shared.snapshot()
    measurements.append(["round": round, "target": target, "delivery_ms": latency, "trace": trace,
      "decoder_paths": decoderPaths(),
      "samples": firstStreamSamples(rows)])
    print("MEASURE: mode=\(mode) target=\(target) delivery_ms=\(latency) trace=\(trace)")
    validate(target, "Measured seek \(round)/\(target)")
    if instrumented && target == 8.7 {
      check(trace["discarded", default: 0] > 200, "Long GOP requires real pre-target decoded samples")
      if mode == "candidate" {
        check(trace["immediate", default: 0] > 15 && trace["delayed", default: 99] <= 1,
              "Active preroll yields immediately instead of adding fixed ten-millisecond sleeps")
      } else {
        check(trace["delayed", default: 0] > 15, "Old implementation reproduces repeated fixed-delay catch-up")
      }
    }
  }
}

// Keep playback intent enabled throughout both forward and backward seeks.
// Readiness is the first real output sample, never a phase-only shortcut.
var playbackMeasurements: [[String: Any]] = []
for target in [8.7, 1.2] {
  session.setPaused(false)
  check(wait { snapshot?.phase == .playing && snapshot?.wantsPlayback == true },
        "Playing seek starts from active playback")
  let previousFlush = onWorker(session) { $0.flushGeneration } ?? 0
  resetTrace()
  let started = ProcessInfo.processInfo.systemUptime
  check(session.seek(to: target), "Playing seek is accepted")
  check(wait {
    onWorker(session) { output in
      output.flushGeneration > previousFlush && output.received.contains { $0.video } &&
        output.received.contains { !$0.video }
    } == true
  }, "Playing seek reaches real video and audio output")
  let rows = onWorker(session) { $0.received } ?? []
  let latency = rows.first(where: { $0.video }).map { ($0.time - started) * 1000 } ?? -1
  check(wait { snapshot?.phase == .playing && snapshot?.wantsPlayback == true },
        "Playing seek preserves playback intent")
  check(snapshot?.volume == 0 && onWorker(session, { $0.volume }) == 0,
        "Playing seek preserves zero volume")
  session.setPaused(true)
  check(wait { snapshot?.phase == .paused }, "Playing seek can pause after actual frame delivery")
  validate(target, "Playing seek \(target)", checkPausedClock: false)
  playbackMeasurements.append(["target": target, "delivery_ms": latency,
    "trace": SeekTrace.shared.snapshot(),
    "decoder_paths": decoderPaths(),
    "samples": firstStreamSamples(rows)])
  print("PLAYING_MEASURE: mode=\(mode) target=\(target) delivery_ms=\(latency)")
}

if instrumented {
// A blocked renderer must remain on a delayed retry, not an immediate loop.
for (condition, target) in [("backpressure", 2.5), ("flush", 6.4), ("anchor", 1.2)] {
  let previousFlush: UInt64 = onWorker(session) { output in
    output.blocked = condition == "backpressure"
    output.flushDelay = condition == "flush"
    output.anchorDelay = condition == "anchor"
    output.videoEnqueueDelay = condition == "backpressure" ? 0.006 : 0
    return output.flushGeneration
  } ?? 0
  resetTrace()
  let revision = snapshot?.revision ?? 0
  check(session.seek(to: target), "\(condition): seek accepted")
  // Backpressure first has to decode to its target; count only a stable
  // blocked interval, after the one retained sample reaches the output gate.
  let reached = wait(3) {
    (onWorker(session) { output in
      guard output.flushGeneration > previousFlush else { return false }
      if condition == "backpressure" { return output.videoReadinessRejections > 0 }
      return SeekTrace.shared.snapshot()["delayed", default: 0] >= 3 &&
        (condition == "flush" ? output.isFlushingVideo : abs(output.currentTime.seconds - target) > 0.001)
    }) == true
  }
  check(reached, "\(condition): actual controlled waiting boundary reached")
  let trace = SeekTrace.shared.snapshot()
  resetTrace()
  _ = wait(0.08) { false }
  let blockedTrace = SeekTrace.shared.snapshot()
  check(blockedTrace["immediate", default: -1] == 0 && blockedTrace["pumps", default: 99] < 20,
        "\(condition): stalled retry remains bounded and delayed")
  _ = onWorker(session) { output in
    output.blocked = false; output.flushDelay = false; output.anchorDelay = false; output.isFlushingVideo = false
    output.setRate(0, at: CMTime(seconds: target, preferredTimescale: 1_000_000_000))
    return true
  }
  check(wait { (snapshot?.revision ?? 0) > revision && snapshot?.phase == .paused }, "\(condition): recovery completes same seek")
  validate(target, "\(condition) recovery")
  _ = onWorker(session) { $0.videoEnqueueDelay = 0; return true }
  print("BLOCKED: \(condition) initial=\(trace) stalled=\(blockedTrace)")
}

// The first audio frame may remain genuinely blocked. A paused preview must
// still become ready without spinning or waiting for an impossible drain.
_ = onWorker(session) { $0.audioBlocked = true; return true }
let audioBlockedRevision = snapshot?.revision ?? 0
resetTrace()
check(session.seek(to: 2.5), "Permanent audio backpressure accepts seek")
check(wait { (snapshot?.revision ?? 0) > audioBlockedRevision && snapshot?.phase == .paused },
      "Permanent audio backpressure does not deadlock a paused video preview")
let audioBlockedRows = onWorker(session) { $0.received } ?? []
check(audioBlockedRows.contains { $0.video } && !audioBlockedRows.contains { !$0.video },
      "Permanent audio backpressure preserves video without pretending audio was delivered")
check(audioBlockedRows.first(where: { $0.video })?.digest == references[2.5]?.first(where: { $0.video })?.digest,
      "Permanent audio backpressure preserves exact target pixels")
let blockedPausedPumps = SeekTrace.shared.snapshot()["pumps"]
_ = wait(0.08) { false }
check(SeekTrace.shared.snapshot()["pumps"] == blockedPausedPumps,
      "Permanent audio backpressure stops pumping once paused")
_ = onWorker(session) { $0.audioBlocked = false; return true }

// Controlled decoder-call cost proves the time quantum, not a performance
// claim. Every call still invokes the real decoder and preserves its samples.
let slowRevision = snapshot?.revision ?? 0
resetTrace(readDelay: 0.006)
check(session.seek(to: 1.2), "Slow-decode cooperative check accepts seek")
check(wait { (snapshot?.revision ?? 0) > slowRevision && snapshot?.phase == .paused },
      "Slow-decode cooperative check reaches exact target")
let slowTrace = SeekTrace.shared.snapshot()
check(slowTrace["maximum_reads_per_pump"] == (mode == "candidate" ? 1 : 8),
      "Slow decoder yields between samples at the cooperative time budget")
validate(1.2, "Slow-decode cooperative check")
print("SLOW_QUANTUM: \(slowTrace)")

// A new seek accepted between bounded quanta invalidates all older work.
var replacementAccepted = false
var replacementRevision: UInt64 = 0
resetTrace(callback: {
  DispatchQueue.main.async {
    replacementRevision = snapshot?.revision ?? 0
    replacementAccepted = session.seek(to: 2.5)
  }
})
check(session.seek(to: 8.7), "Cancelled catch-up is initially accepted")
check(wait { replacementAccepted && (snapshot?.revision ?? 0) > replacementRevision && snapshot?.phase == .paused &&
  abs((snapshot?.position ?? -1) - 2.5) < 0.000001 }, "Latest seek supersedes in-flight long-GOP catch-up")
validate(2.5, "Superseded seek")
var closed = false
resetTrace(callback: { DispatchQueue.main.async { session.shutdown { closed = true } } })
check(session.seek(to: 8.7), "Seek before cancellation is accepted")
check(wait { closed }, "Close preempts catch-up without an unbounded tight loop")
check(snapshot?.phase == .closed, "Closed revision owns final state")
check((onWorker(session) { $0.received.isEmpty }) == true, "No retired samples remain after close")
} else {
  var closed = false
  session.shutdown { closed = true }
  check(wait { closed }, "Uninstrumented session closes")
}
let report: [String: Any] = ["schema_version": 2, "rounds": rounds,
  "scope": "real-decoder-session-controlled-output", "mode": mode,
  "instrumented": instrumented,
  "measurements": measurements, "playback_measurements": playbackMeasurements,
  "passed": passed, "failed": failed,
  "physical_display": "not-tested", "framework_output": "not-tested"]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportPath)
print("RESULT: \(passed) passed / \(failed) failed")
exit(failed == 0 ? 0 : 1)
