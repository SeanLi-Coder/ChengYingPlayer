import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  if condition() { passed += 1; print("PASS: \(description)") }
  else { failed += 1; print("FAIL: \(description)") }
}

@discardableResult
func waitUntil(_ seconds: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}

func settle(_ seconds: TimeInterval) { _ = waitUntil(seconds) { false } }

struct OutputState {
  let position: Double
  let volume: Float
  let rate: Double
  let flushGeneration: UInt64
  let videoSamples: UInt64
  let audioSamples: UInt64
  let requestedRate: Float
  let flushingVideo: Bool
  let videoReady: Bool
  let audioReady: Bool
  let hasError: Bool
}

// White-box diagnostics honor the production output's worker-only contract.
// Do not infer renderer state merely from cached UI snapshots.
func inspectOutput(_ session: NativePlaybackSession, timeout: TimeInterval = 5) -> OutputState? {
  // Only the immutable queue reference is reflected. Mutable session state is
  // never inspected, and every output property below is read on its worker.
  let worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
  let output = session.output
  var state: OutputState?
  worker.async {
    let observed = OutputState(position: output.currentTime.seconds, volume: output.volume, rate: output.actualRate,
      flushGeneration: output.flushGeneration, videoSamples: output.acceptedVideoSamples,
      audioSamples: output.acceptedAudioSamples, requestedRate: output.requestedRate,
      flushingVideo: output.isFlushingVideo, videoReady: output.isReady(video: true),
      audioReady: output.isReady(video: false), hasError: output.error != nil)
    DispatchQueue.main.async { state = observed }
  }
  _ = waitUntil(timeout) { state != nil }
  return state
}

func outputState(_ session: NativePlaybackSession) -> OutputState? {
  let state = inspectOutput(session)
  check(state != nil, "Renderer diagnostics return without blocking main")
  return state
}

/// Numeric-only observations from existing callbacks; no media or session is
/// retained. Dumping happens only after the original deadline already failed.
final class FailureTimeline {
  struct Entry {
    let time: TimeInterval
    let event: Int
    let values: [Double]
  }
  private let lock = NSLock()
  private var entries = [Entry?](repeating: nil, count: 512)
  private var total = 0

  func record(_ event: Int, _ values: [Double]) {
    let entry = Entry(time: ProcessInfo.processInfo.systemUptime, event: event, values: values)
    lock.lock()
    entries[total % entries.count] = entry
    total += 1
    lock.unlock()
  }

  func record(_ sample: NativePlaybackSampleObservation) {
    record(sample.video ? 1 : 2, [Double(sample.generation), Double(sample.revision), sample.start, sample.end])
  }

  func record(_ snapshot: NativePlaybackSnapshot) {
    let phases: [NativePlaybackPhase] = [.idle, .opening, .seeking, .paused, .playing, .ended, .failed, .closed]
    record(3, [Double(snapshot.generation), Double(snapshot.revision),
      Double(phases.firstIndex(of: snapshot.phase)!), snapshot.position, Double(snapshot.rate),
      snapshot.wantsPlayback ? 1 : 0, Double(snapshot.videoSamples), Double(snapshot.audioSamples),
      Double(snapshot.queuedBytes)])
  }

  func dump() {
    lock.lock()
    let count = min(total, entries.count)
    let first = total - count
    let rows = (first..<total).compactMap { entries[$0 % entries.count] }.sorted { $0.time < $1.time }
    let dropped = total - count
    lock.unlock()
    print("FAILURE_TIMELINE: entries=\(rows.count) capacity=512 dropped=\(dropped)")
    print("FAILURE_EVENTS: 1=video 2=audio [generation,revision,start,end]; 3=snapshot [generation,revision,phase,position,rate,wantsPlayback,videoSamples,audioSamples,queuedBytes]; 4=loop_start [revision]; 5=deadline [samples,wraps]")
    print("FAILURE_PHASES: 0=idle 1=opening 2=seeking 3=paused 4=playing 5=ended 6=failed 7=closed")
    for row in rows { print("FAILURE_EVENT \(row.time) \(row.event) \(row.values)") }
  }
}

final class Observations {
  private let lock = NSLock()
  private var values: [NativePlaybackSampleObservation] = []
  func append(_ value: NativePlaybackSampleObservation) {
    lock.lock()
    if values.count >= 4096 { values.removeFirst(2048) }
    values.append(value)
    lock.unlock()
  }
  func read() -> [NativePlaybackSampleObservation] {
    lock.lock(); defer { lock.unlock() }
    return values
  }
}

final class WeakSessionReference {
  weak var value: NativePlaybackSession?
  init(_ value: NativePlaybackSession) { self.value = value }
}

func pcm(at pts: CMTime, rate: Int32 = 48_000, count: Int = 64) -> CMSampleBuffer {
  var stream = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
    mBitsPerChannel: 32, mReserved: 0)
  var format: CMAudioFormatDescription?
  precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream,
    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
    formatDescriptionOut: &format) == noErr)
  var data: CMBlockBuffer?
  precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &data) == noErr)
  let values = (0..<count).map(Float.init)
  values.withUnsafeBytes {
    precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data!,
      offsetIntoDestination: 0, dataLength: $0.count) == noErr)
  }
  var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
    presentationTimeStamp: pts, decodeTimeStamp: .invalid)
  var size = 4
  var sample: CMSampleBuffer?
  precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
    formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
    sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
    sampleBufferOut: &sample) == noErr)
  return sample!
}

func video(at pts: CMTime, duration: CMTime) -> CMSampleBuffer {
  var pixel: CVPixelBuffer?
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
    nil, &pixel) == kCVReturnSuccess)
  var format: CMVideoFormatDescription?
  precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
  var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
  return sample!
}

func gateChecks() throws {
  let input = pcm(at: .zero)
  guard case .sample(let trimmed) = try NativePlaybackSampleGate.clip(input, video: false,
    start: 8.0 / 48_000, end: 20.0 / 48_000) else {
    check(false, "PCM interval returns a trimmed sample"); return
  }
  check(CMSampleBufferGetNumSamples(trimmed) == 12, "PCM trim keeps exactly the selected 12 frames")
  check(abs(CMSampleBufferGetPresentationTimeStamp(trimmed).seconds - 8.0 / 48_000) < 1e-12,
    "PCM trim preserves the exact first sample timestamp")
  var first: Float = -1
  withUnsafeMutableBytes(of: &first) {
    check(CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(trimmed)!, atOffset: 0,
      dataLength: 4, destination: $0.baseAddress!) == noErr, "PCM bytes remain readable")
  }
  check(first == 8, "PCM trim removes bytes before the A boundary")
  check(CMSampleBufferGetNumSamples(input) == 64, "PCM gate does not mutate its input")
  if case .beforeRange = try NativePlaybackSampleGate.clip(input, video: false, start: 1, end: 2) {
    check(true, "PCM before A is rejected")
  } else { check(false, "PCM before A is rejected") }
  if case .afterRange = try NativePlaybackSampleGate.clip(pcm(at: CMTime(value: 2, timescale: 1)),
    video: false, start: 0, end: 1) { check(true, "PCM at or after B is rejected") }
  else { check(false, "PCM at or after B is rejected") }

  let image = video(at: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 30))
  guard case .sample(let clippedImage) = try NativePlaybackSampleGate.clip(image, video: true,
    start: 1.01, end: 1.02) else { check(false, "Video interval returns a clipped frame"); return }
  check(CMSampleBufferGetImageBuffer(image) === CMSampleBufferGetImageBuffer(clippedImage),
    "Video gate preserves the original pixels")
  check(abs(CMSampleBufferGetPresentationTimeStamp(clippedImage).seconds - 1.01) < 1e-9 &&
    abs(CMSampleBufferGetDuration(clippedImage).seconds - 0.01) < 1e-9,
    "Video frame timing is clipped to A and B")
  do { _ = try NativePlaybackInterval(start: 1, end: 1); check(false, "Empty intervals are rejected") }
  catch { check(true, "Empty intervals are rejected") }

  let highRate: Int32 = 192_000
  let alignedStart = Double(9000 * Int64(highRate) + 1) / Double(highRate)
  guard case .sample(let longPCM) = try NativePlaybackSampleGate.clip(
    pcm(at: CMTime(value: 9000, timescale: 1), rate: highRate), video: false,
    start: alignedStart, end: nil) else { check(false, "Long-timeline PCM gate retains media"); return }
  check(CMSampleBufferGetNumSamples(longPCM) == 63,
    "Sample-aligned A on a 9000-second timeline removes one frame, not two")

  let microsecondFrame = video(at: CMTime(value: 2, timescale: 1_000_000),
    duration: CMTime(value: 33_333, timescale: 1_000_000))
  let expectedEnd = CMTime(value: 33_335, timescale: 1_000_000).seconds
  let doubleSum = CMSampleBufferGetPresentationTimeStamp(microsecondFrame).seconds +
    CMSampleBufferGetDuration(microsecondFrame).seconds
  check(doubleSum > expectedEnd && doubleSum == expectedEnd.nextUp,
    "Real sample timing reproduces the one-ULP Double addition overrun")
  let rationalEnd = try NativePlaybackSampleGate.end(of: microsecondFrame, clippedAt: nil)
  check(rationalEnd == expectedEnd,
    "Rational sample end is exactly 33335 microseconds without a one-ULP EOF residue")
  let boundedEnd = try NativePlaybackSampleGate.end(of: microsecondFrame, clippedAt: expectedEnd)
  check(boundedEnd == expectedEnd,
    "Final sample end is reachable by a clock clamped to exact media duration")
  let earlierEnd = try NativePlaybackSampleGate.end(of: microsecondFrame, clippedAt: expectedEnd.nextDown)
  check(earlierEnd == expectedEnd.nextDown,
    "Sample end obeys a tighter upper bound exactly instead of using a tolerance")
  let trimmedPCMEnd = try NativePlaybackSampleGate.end(of: trimmed, clippedAt: 20.0 / 48_000)
  check(trimmedPCMEnd == 20.0 / 48_000,
    "Trimmed PCM end uses the rational duration of all retained audio samples")
}

do { try gateChecks() }
catch { check(false, "Sample gate completed without error: \(error)") }

_ = NSApplication.shared
precondition(CommandLine.arguments.count == 2)
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pcmURL = directory.appendingPathComponent("pcm.mkv")
let aacURL = directory.appendingPathComponent("aac.mp4")
let observations = Observations()
let failureTimeline = FailureTimeline()
var session: NativePlaybackSession? = NativePlaybackSession(sampleObserver: {
  observations.append($0)
  failureTimeline.record($0)
})
weak var weakSession = session
var snapshot: NativePlaybackSnapshot?
var snapshots: [NativePlaybackSnapshot] = []
session!.onSnapshot = {
  precondition(Thread.isMainThread)
  snapshot = $0
  snapshots.append($0)
  failureTimeline.record($0)
  if $0.phase == .failed { print("DIAGNOSTIC: native failure \(String(describing: $0.failure))") }
}
let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
host.wantsLayer = true
session!.output.displayLayer.frame = host.bounds
host.layer!.addSublayer(session!.output.displayLayer)

session!.open(pcmURL, autoplay: false)
check(!session!.seek(to: 1), "Seek during opening is rejected without cancelling open")
let opened = waitUntil { snapshot?.phase == .paused || snapshot?.phase == .failed }
check(opened && snapshot?.phase == .paused, "Real FFmpeg and sample-buffer session opens paused")
if snapshot?.phase == .paused {
  check(snapshot?.volume == 0, "New video snapshot starts with volume zero")
  check((snapshot?.videoSamples ?? 0) > 0 && (snapshot?.audioSamples ?? 0) > 0,
    "Both real decoded streams are enqueued before ready")
  session!.setVolume(0.7)
  check(waitUntil { abs((snapshot?.volume ?? 0) - 0.7) < 0.0001 }, "Explicit volume 70 is retained in the snapshot")
  check(abs((outputState(session!)?.volume ?? 0) - 0.7) < 0.0001,
    "Explicit volume 70 reaches the actual audio renderer")
  session!.open(pcmURL, autoplay: true)
  check(waitUntil { snapshot?.generation == 2 && snapshot?.phase == .playing }, "Second video opens and plays")
  check(snapshot?.volume == 0, "Second video resets volume to zero instead of inheriting 70")
  check(outputState(session!)?.volume == 0, "Second video resets the actual audio renderer to zero")
  check(waitUntil { (snapshot?.position ?? 0) > 0.25 }, "The real shared playback clock advances")
  session!.setPaused(true)
  check(waitUntil { snapshot?.phase == .paused }, "Pause is reflected in the session")
  settle(0.1)
  let paused = snapshot?.position ?? -1
  let pausedOutput = outputState(session!)
  settle(0.2)
  check(abs((snapshot?.position ?? 0) - paused) < 0.03, "Paused position remains stable")
  let afterPause = outputState(session!)
  check(pausedOutput?.rate == 0 && afterPause?.rate == 0 &&
    abs((pausedOutput?.position ?? -100) - (afterPause?.position ?? 0)) < 0.03,
    "Pause stops the actual renderer clock, not just snapshot updates")
  check(session!.setRate(0.8), "0.8 playback rate is accepted")
  check(waitUntil { snapshot?.phase == .paused && snapshot?.rate == 0.8 }, "Rate 0.8 re-prerolls without resuming")
  check(session!.setRate(1.2), "1.2 playback rate is accepted")
  check(waitUntil { snapshot?.phase == .paused && snapshot?.rate == 1.2 }, "Rate 1.2 re-prerolls without resuming")
  check(!session!.setRate(0.1), "Unsupported rate is rejected explicitly")
  session!.setPaused(false)
  check(waitUntil { snapshot?.phase == .playing }, "Resume returns to real playback")
  settle(0.1)
  check(abs((outputState(session!)?.rate ?? 0) - 1.2) < 0.0001,
    "Resume applies rate 1.2 to the actual shared renderer clock")
  session!.setPaused(true)
  _ = waitUntil { snapshot?.phase == .paused }
  check(session!.seek(to: 2), "Forward seek accepted")
  check(waitUntil { snapshot?.phase == .paused && abs((snapshot?.position ?? 0) - 2) < 0.03 },
    "Forward seek anchors at the requested position")
  check(session!.seek(to: 0.4), "Backward seek accepted")
  check(waitUntil { snapshot?.phase == .paused && abs((snapshot?.position ?? 0) - 0.4) < 0.03 },
    "Backward seek does not reuse the old high clock value")
  for target in [1.8, 0.8, 2.1, 0.6] { check(session!.seek(to: target), "Rapid seek \(target) accepted") }
  check(waitUntil { snapshot?.phase == .paused && abs((snapshot?.position ?? 0) - 0.6) < 0.03 },
    "Rapid seeks converge on the final request")

  let loop = try! NativePlaybackInterval(start: 0.5, end: 0.9)
  let oldRevision = snapshot?.revision ?? 0
  session!.setLoop(loop)
  check(session!.seek(to: loop.start), "A/B configuration followed immediately by seek is accepted")
  check(waitUntil { (snapshot?.revision ?? 0) > oldRevision && snapshot?.phase == .paused },
    "A/B seek reaches a ready paused state")
  let loopRevision = snapshot?.revision ?? 0
  failureTimeline.record(4, [Double(loopRevision)])
  session!.setPaused(false)
  settle(1.5)
  let loopSamples = observations.read().filter { $0.generation == 2 && $0.revision == loopRevision }
  check(!loopSamples.isEmpty && loopSamples.allSatisfy { $0.start >= loop.start - 1e-9 && $0.end <= loop.end + 1e-9 },
    "Every enqueued A/B sample stays within the half-open interval")
  let loopVideos = loopSamples.filter(\.video)
  let wraps = zip(loopVideos, loopVideos.dropFirst()).filter { $0.1.start < $0.0.start - 0.1 }.count
  failureTimeline.record(5, [Double(loopSamples.count), Double(wraps)])
  print("DIAGNOSTIC: loop samples=\(loopSamples.count) wraps=\(wraps) minStart=\(loopSamples.map(\.start).min() ?? -1) maxEnd=\(loopSamples.map(\.end).max() ?? -1) phase=\(snapshot?.phase.rawValue ?? "none")")
  let wrapsMeetDeadline = wraps >= 2
  check(wrapsMeetDeadline, "A/B restarts at least twice without leaving the interval")
  check(snapshot?.phase != .failed && (snapshot?.queuedBytes ?? Int.max) <= 128 * 1024 * 1024,
    "Repeated A/B playback retains bounded queue accounting")
  if !wrapsMeetDeadline {
    failureTimeline.dump()
    // This is a later read-only observation, not extra time to pass the test.
    // No further sample count may replace the already recorded failure.
    if let observed = inspectOutput(session!, timeout: 1) {
      print("FAILURE_OUTPUT_AFTER_DEADLINE: clock=\(observed.position) rate=\(observed.rate) requestedRate=\(observed.requestedRate) flushGeneration=\(observed.flushGeneration) flushingVideo=\(observed.flushingVideo) videoReady=\(observed.videoReady) audioReady=\(observed.audioReady) acceptedVideo=\(observed.videoSamples) acceptedAudio=\(observed.audioSamples) hasError=\(observed.hasError)")
    } else {
      print("FAILURE_OUTPUT_AFTER_DEADLINE: unavailable within 1 second; original failure is unchanged")
    }
  }
  session!.setLoop(nil)
  session!.open(aacURL, autoplay: true)
  check(waitUntil(7) { snapshot?.generation == 3 && (snapshot?.phase == .ended || snapshot?.phase == .failed) }
      && snapshot?.phase == .ended, "Real AAC tail reaches EOF rather than waiting beyond duration")
  if snapshot?.phase == .ended {
    session!.setPaused(true)
    settle(0.2)
    check(snapshot?.phase == .ended && outputState(session!)?.rate == 0,
      "Pausing an ended file preserves EOF and its stopped renderer clock")
    session!.setPaused(false)
    check(waitUntil { snapshot?.phase == .playing && (snapshot?.position ?? 100) < 0.3 },
      "Resume after EOF and repeated pause restarts at the beginning")
    check(waitUntil(7) { snapshot?.phase == .ended || snapshot?.phase == .failed } && snapshot?.phase == .ended,
      "Replayed media reaches a second real EOF")
  }
  session!.stop()
  check(waitUntil { snapshot?.phase == .idle }, "Stop returns to idle")
}

session!.open(pcmURL)
session!.stop()
session!.open(aacURL, autoplay: false)
check(waitUntil { snapshot?.phase == .paused || snapshot?.phase == .failed } && snapshot?.phase == .paused,
  "Immediate open-stop-open cancellation preserves the final open")
var closed = 0
session!.shutdown { closed += 1 }
session!.shutdown { closed += 1 }
check(waitUntil { closed == 2 }, "Repeated shutdown calls complete asynchronously without deadlock")
check(!session!.seek(to: 0), "Closed session refuses further seeks")
session = nil
check(waitUntil { weakSession == nil }, "Shutdown session releases without a retain cycle")
check(snapshots.allSatisfy { $0.position.isFinite && $0.queuedBytes >= 0 },
  "All published positions and queue counts remain valid")

func exerciseTrackAvailability(_ name: String, file: String, video: Bool, audio: Bool,
                               seekTarget: Double?) {
  let seen = Observations()
  var reader: NativePlaybackSession? = NativePlaybackSession(sampleObserver: seen.append)
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    if $0.phase == .failed { print("DIAGNOSTIC: \(name) failure \(String(describing: $0.failure))") }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  reader!.open(directory.appendingPathComponent(file), autoplay: false)
  check(waitUntil(13) { latest?.phase == .paused || latest?.phase == .failed } && latest?.phase == .paused,
    "\(name): valid media reaches ready without requiring both tracks at time zero")
  if latest?.phase == .paused {
    check(latest?.media?.hasVideo == video && latest?.media?.hasAudio == audio,
      "\(name): actual stream presence is preserved")
    var readyToPlay = true
    if let target = seekTarget {
      let revision = latest?.revision ?? 0
      check(reader!.seek(to: target), "\(name): seek into the selected range is accepted")
      readyToPlay = waitUntil(13) {
        (latest?.revision ?? 0) > revision && (latest?.phase == .paused || latest?.phase == .failed)
      } && latest?.phase == .paused
      check(readyToPlay, "\(name): seek works even when the selected range has no audio samples")
      if readyToPlay {
        check(abs((latest?.position ?? -1) - target) < 0.03,
          "\(name): seek reaches the requested media time")
      }
    }
    if readyToPlay {
      reader!.setPaused(false)
      check(waitUntil(7) { latest?.phase == .ended || latest?.phase == .failed } && latest?.phase == .ended,
        "\(name): real playback reaches EOF without deadlock or fabricated missing-track errors")
      let samples = seen.read()
      check(samples.contains(where: \.video) == video,
        "\(name): output video samples match actual stream presence")
      check(samples.contains(where: { !$0.video }) == audio,
        "\(name): output audio samples match actual stream presence")
      if file == "delayed-audio.mkv" {
        let audioSamples = samples.filter { !$0.video }
        check(!audioSamples.isEmpty && audioSamples.allSatisfy { $0.start >= 1.249 },
          "\(name): delayed audio keeps its original timing rather than moving to zero")
      }
    }
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "\(name): shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "\(name): session releases")
}

exerciseTrackAvailability("Audio ends before video", file: "short-audio.mkv", video: true, audio: true, seekTarget: 2)
exerciseTrackAvailability("Delayed audio", file: "delayed-audio.mkv", video: true, audio: true, seekTarget: nil)
exerciseTrackAvailability("Video-only", file: "video-only.mkv", video: true, audio: false, seekTarget: 0.7)
exerciseTrackAvailability("Audio-only", file: "audio-only.wav", video: false, audio: true, seekTarget: 0.4)

func exerciseLoopAfterAudioEnds() {
  let seen = Observations()
  var reader: NativePlaybackSession? = NativePlaybackSession(sampleObserver: seen.append)
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  var clockPositions: [Double] = []
  var loopRevision: UInt64?
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    if $0.revision == loopRevision { clockPositions.append($0.position) }
    if $0.phase == .failed { print("DIAGNOSTIC: long-tail loop failure \(String(describing: $0.failure))") }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  reader!.open(directory.appendingPathComponent("long-short-audio.mkv"), autoplay: false)
  check(waitUntil { latest?.phase == .paused || latest?.phase == .failed } && latest?.phase == .paused,
    "Long-tail fixture opens before testing a loop beyond the audio track")
  if latest?.phase == .paused {
    check((latest?.duration ?? 0) >= 29.9, "Long-tail fixture has thirty seconds of media")
    let range = try! NativePlaybackInterval(start: 2, end: 3)
    let previousRevision = latest?.revision ?? 0
    reader!.setLoop(range)
    check(reader!.seek(to: 2), "Long-tail A/B immediately followed by seek is accepted")
    check(waitUntil { (latest?.revision ?? 0) > previousRevision &&
      (latest?.phase == .paused || latest?.phase == .failed) } && latest?.phase == .paused,
      "Long-tail A/B prerolls successfully without audio inside its interval")
    if latest?.phase == .paused {
      loopRevision = latest?.revision
      let started = ProcessInfo.processInfo.systemUptime
      reader!.setPaused(false)
      func wraps() -> Int {
        zip(clockPositions, clockPositions.dropFirst()).filter { $0.0 >= 2.7 && $0.1 <= 2.2 }.count
      }
      let wrappedInTime = waitUntil(3.5) { wraps() >= 2 || latest?.phase == .failed }
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      print("DIAGNOSTIC: long-tail clock wraps=\(wraps()) elapsed=\(elapsed) phase=\(latest?.phase.rawValue ?? "none")")
      check(wrappedInTime && wraps() >= 2 && latest?.phase != .failed,
        "A/B clock wraps twice promptly after audio ends instead of waiting for the file tail")
      let loopSamples = seen.read().filter { $0.revision == loopRevision }
      check(!loopSamples.isEmpty && loopSamples.allSatisfy { $0.start >= 2 - 1e-9 && $0.end <= 3 + 1e-9 },
        "Long-tail A/B enqueues only samples in its requested interval")
      check(!loopSamples.contains { !$0.video },
        "Long-tail A/B does not invent audio beyond the real audio endpoint")
    }
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "Long-tail A/B shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "Long-tail A/B session releases")
}

exerciseLoopAfterAudioEnds()

func exerciseTinyLoopCancellation() {
  let seen = Observations()
  var reader: NativePlaybackSession? = NativePlaybackSession(sampleObserver: seen.append)
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  var loopRevision: UInt64?
  var automaticSeeks = 0
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    if $0.revision == loopRevision && $0.phase == .seeking { automaticSeeks += 1 }
    if $0.phase == .failed { print("DIAGNOSTIC: tiny loop failure \(String(describing: $0.failure))") }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  reader!.open(pcmURL, autoplay: false)
  check(waitUntil { latest?.phase == .paused || latest?.phase == .failed } && latest?.phase == .paused,
    "Tiny-loop fixture opens with real video and PCM audio")
  if latest?.phase == .paused {
    let range = try! NativePlaybackInterval(start: 0, end: 0.0001)
    let previousRevision = latest?.revision ?? 0
    reader!.setLoop(range)
    check(reader!.seek(to: 0), "A 100-microsecond A/B loop accepts its explicit seek")
    check(waitUntil { (latest?.revision ?? 0) > previousRevision &&
      (latest?.phase == .paused || latest?.phase == .failed) } && latest?.phase == .paused,
      "A 100-microsecond A/B loop prerolls without losing its clipped samples")
    if latest?.phase == .paused {
      loopRevision = latest?.revision
      reader!.setPaused(false)
      // Flush/preroll overhead is not a playback-throughput promise. Collect
      // enough real wraps first, then impose a separate strict stop deadline.
      let looped = waitUntil(10) { automaticSeeks >= 20 || latest?.phase == .failed }
      let loopSamples = seen.read().filter { $0.revision == loopRevision }
      print("DIAGNOSTIC: tiny-loop samples=\(loopSamples.count) videoSamples=\(loopSamples.filter(\.video).count) wraps=\(automaticSeeks) minStart=\(loopSamples.map(\.start).min() ?? -1) maxEnd=\(loopSamples.map(\.end).max() ?? -1)")
      check(looped && automaticSeeks >= 20 && latest?.phase != .failed,
        "Tiny A/B playback completes twenty real automatic wraps without recursive starvation")
      check(loopSamples.filter(\.video).count >= 20 &&
        loopSamples.allSatisfy { $0.start >= 0 && $0.end <= 0.0001 },
        "Tiny-loop wraps repeatedly enqueue real decoded samples within the exact interval")
      let stopStarted = ProcessInfo.processInfo.systemUptime
      reader!.stop()
      let stopped = waitUntil(0.5) { latest?.phase == .idle }
      let stopElapsed = ProcessInfo.processInfo.systemUptime - stopStarted
      print("DIAGNOSTIC: tiny-loop wraps=\(automaticSeeks) stopElapsed=\(stopElapsed) phase=\(latest?.phase.rawValue ?? "none")")
      check(stopped, "Stop interrupts active tiny-loop playback within half a second")
      check(outputState(reader!)?.rate == 0,
        "Stopping tiny-loop playback also stops the actual renderer clock")
      let stoppedSeeks = automaticSeeks
      settle(0.15)
      check(latest?.phase == .idle && automaticSeeks == stoppedSeeks,
        "No queued tiny-loop wrap resumes playback after stop")
    }
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "Tiny-loop shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "Tiny-loop session releases")
}

exerciseTinyLoopCancellation()

func exerciseInjectedOutputFlush() {
  var reader: NativePlaybackSession? = NativePlaybackSession()
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  var seekingEvents = 0
  var failedEvents = 0
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    if $0.phase == .seeking { seekingEvents += 1 }
    if $0.phase == .failed { failedEvents += 1 }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  reader!.open(pcmURL, autoplay: false)
  check(waitUntil { latest?.phase == .paused || latest?.phase == .failed } && latest?.phase == .paused,
    "Injected-flush fixture opens paused")
  if latest?.phase == .paused {
    let worker = Mirror(reflecting: reader!).children.first { $0.label == "worker" }!.value as! DispatchQueue
    let beforeFlush = outputState(reader!)
    let releaseWorker = DispatchSemaphore(value: 0)
    var phaseAtInjection: NativePlaybackPhase?
    let retainedReader = reader!
    // Queue seek and recovery before allowing the seek to schedule its pump.
    // This makes the production handler run while seeking, not accidentally
    // after a fast preroll has already reached paused. No media is fabricated.
    worker.async { _ = releaseWorker.wait(timeout: .now() + 2) }
    check(reader!.seek(to: 1.2), "Injected-flush seek is accepted")
    worker.async {
      let phase = Mirror(reflecting: retainedReader).children.first { $0.label == "phase" }!.value as! NativePlaybackPhase
      DispatchQueue.main.async { phaseAtInjection = phase }
    }
    reader!.output.onAudioFlush?(CMTime(seconds: 2.8, preferredTimescale: 1_000_000))
    releaseWorker.signal()
    check(waitUntil { phaseAtInjection != nil } && phaseAtInjection == .seeking,
      "Synthetic output-flush callback is delivered during an actual seek transaction")
    check(waitUntil { seekingEvents >= 2 && latest?.phase == .paused },
      "Production flush handler restarts preroll even while already seeking")
    let afterFlush = outputState(reader!)
    check((afterFlush?.flushGeneration ?? 0) == (beforeFlush?.flushGeneration ?? 0) + 2,
      "Explicit seek and injected recovery each flush both real output queues")
    check((afterFlush?.videoSamples ?? 0) > 0 && (afterFlush?.audioSamples ?? 0) > 0,
      "Recovery re-primes actual video and audio samples rather than stale readiness flags")
    check(latest?.phase == .paused && abs((latest?.position ?? -1) - 1.2) < 0.001,
      "Recovery retains the active seek target instead of the stale callback timestamp")
    reader!.setPaused(false)
    check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) > 1.4 },
      "Recovered output resumes real clock progression")

    reader!.open(pcmURL, autoplay: false)
    check(waitUntil { latest?.generation == 2 && latest?.phase == .paused },
      "A new file clears the previous output-recovery budget")
    seekingEvents = 0
    failedEvents = 0
    for _ in 0..<4 { reader!.output.onAudioFlush?(.zero) }
    check(waitUntil { latest?.phase == .failed } && latest?.failure == .outputRecoveryLimit,
      "Four injected automatic flushes stop with explicit outputRecoveryLimit")
    check(seekingEvents == 3 && failedEvents == 1,
      "Only three recovery attempts are made before the fourth flush fails")
    check(outputState(reader!)?.rate == 0,
      "Recovery-limit failure stops the actual renderer clock")
    let finalSeekingEvents = seekingEvents
    let finalFailedEvents = failedEvents
    settle(0.2)
    check(latest?.phase == .failed && seekingEvents == finalSeekingEvents && failedEvents == finalFailedEvents,
      "Recovery-limit failure does not schedule an endless retry loop")
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "Injected-flush shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "Injected-flush session releases")
}

exerciseInjectedOutputFlush()

func exerciseCrossFilePreferences() {
  let seen = Observations()
  var reader: NativePlaybackSession? = NativePlaybackSession(sampleObserver: seen.append)
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  var positions: [(generation: UInt64, position: Double)] = []
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    positions.append(($0.generation, $0.position))
    if $0.phase == .failed { print("DIAGNOSTIC: preference fixture failure \(String(describing: $0.failure))") }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  let worker = Mirror(reflecting: reader!).children.first { $0.label == "worker" }!.value as! DispatchQueue
  let releaseInitialCommands = DispatchSemaphore(value: 0)
  worker.async { _ = releaseInitialCommands.wait(timeout: .now() + 2) }
  check(reader!.setRate(1.2), "Playback rate can be configured before the first open")
  reader!.setLoop(nil, repeatFile: true)
  reader!.setVolume(0.7)
  reader!.open(pcmURL)
  releaseInitialCommands.signal()
  check(waitUntil { latest?.generation == 1 && (latest?.phase == .playing || latest?.phase == .failed) }
    && latest?.phase == .playing, "Pre-open preferences survive their queued commands being superseded by open")
  if latest?.phase == .playing {
    check(latest?.rate == 1.2 && latest?.volume == 0,
      "First open retains the preferred rate but discards pre-open volume")
    check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) > 0.1 },
      "First open advances its clock after the asynchronous output-rate change")
    let firstOutput = outputState(reader!)
    print("DIAGNOSTIC: pre-open actualRate=\(firstOutput?.rate ?? -1) actualVolume=\(firstOutput?.volume ?? -1)")
    check(abs((firstOutput?.rate ?? 0) - 1.2) < 0.0001 && firstOutput?.volume == 0,
      "Pre-open rate and per-file mute reach the real renderer")
    check(reader!.seek(to: 2.7), "Pre-open repeat preference permits a seek near EOF")
    check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) >= 2.7 },
      "First file reaches the real near-EOF clock position")
    check(waitUntil(3) { latest?.phase == .playing && (latest?.position ?? 100) < 0.5 },
      "Repeat mode configured before opening restarts the actual file at EOF")
    reader!.setPaused(true)
    check(waitUntil { latest?.phase == .paused }, "Preference fixture pauses before configuring per-file A/B")
    let range = try! NativePlaybackInterval(start: 0.5, end: 0.9)
    var revision = latest?.revision ?? 0
    reader!.setLoop(range)
    check(reader!.seek(to: 0.5), "Per-file A/B can be configured without overriding repeat mode")
    check(waitUntil { (latest?.revision ?? 0) > revision && latest?.phase == .paused &&
      abs((latest?.position ?? -1) - 0.5) < 0.001 }, "Per-file A/B becomes active before testing a new file")
    revision = latest?.revision ?? 0
    reader!.setLoop(nil)
    check(reader!.seek(to: 1.6), "Clearing A/B permits seeking beyond its old endpoint")
    check(waitUntil { (latest?.revision ?? 0) > revision && latest?.phase == .paused &&
      abs((latest?.position ?? -1) - 1.6) < 0.001 }, "Cleared A/B no longer clamps the current file")
    revision = latest?.revision ?? 0
    reader!.setLoop(range)
    _ = reader!.seek(to: 0.5)
    check(waitUntil { (latest?.revision ?? 0) > revision && latest?.phase == .paused &&
      abs((latest?.position ?? -1) - 0.5) < 0.001 }, "A/B is active again immediately before rapid file changes")
    reader!.setVolume(0.7)
    check(waitUntil { latest?.volume == 0.7 }, "Previous file volume is explicitly raised before replacement")
    check(outputState(reader!)?.volume == 0.7, "Previous file renderer really has volume 70")

    let releaseRapidCommands = DispatchSemaphore(value: 0)
    worker.async { _ = releaseRapidCommands.wait(timeout: .now() + 2) }
    check(reader!.setRate(0.8), "A new preferred rate is accepted immediately before rapid opens")
    reader!.open(pcmURL, autoplay: false)
    reader!.open(directory.appendingPathComponent("video-only.mkv"), autoplay: false)
    reader!.open(aacURL, autoplay: false)
    releaseRapidCommands.signal()
    check(waitUntil { latest?.generation == 4 && (latest?.phase == .paused || latest?.phase == .failed) }
      && latest?.phase == .paused, "Rapid opens converge on the final media generation")
    check(latest?.rate == 0.8 && latest?.volume == 0 && abs((latest?.position ?? -1)) < 0.001,
      "Final generation retains rate 0.8, resets volume, and opens at zero instead of old A")
    check(outputState(reader!)?.volume == 0, "Final generation resets the actual renderer volume to zero")
    revision = latest?.revision ?? 0
    check(reader!.seek(to: 1.6), "New media accepts a seek outside the previous file's A/B range")
    check(waitUntil { (latest?.revision ?? 0) > revision && latest?.phase == .paused &&
      abs((latest?.position ?? -1) - 1.6) < 0.001 }, "Old A/B does not constrain a new generation's real seek")
    check(seen.read().contains { $0.generation == 4 && $0.start >= 1.5 },
      "New generation enqueues actual samples beyond the old B boundary")
    reader!.setPaused(false)
    check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) > 1.7 },
      "Final generation resumes real playback after its seek")
    check(abs((outputState(reader!)?.rate ?? 0) - 0.8) < 0.0001,
      "Final generation applies preferred rate 0.8 to the actual renderer clock")
    _ = reader!.seek(to: 2.7)
    check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) >= 2.7 },
      "Final generation reaches its own near-EOF position")
    check(waitUntil(3) { latest?.generation == 4 && latest?.phase == .playing &&
      (latest?.position ?? 100) < 0.5 }, "Repeat preference survives A/B set, A/B clear, and rapid cross-file opens")
    check(positions.filter { $0.generation == 4 }.allSatisfy { $0.position.isFinite && $0.position >= 0 },
      "Rapid-open preference snapshots retain valid positions")
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "Cross-file preference shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "Cross-file preference session releases")
}

exerciseCrossFilePreferences()

func exercisePausedH264Seeks() {
  let seen = Observations()
  var reader: NativePlaybackSession? = NativePlaybackSession(sampleObserver: seen.append)
  let releasedReader = WeakSessionReference(reader!)
  var latest: NativePlaybackSnapshot?
  reader!.onSnapshot = {
    precondition(Thread.isMainThread)
    latest = $0
    if $0.phase == .failed { print("DIAGNOSTIC: paused H264 failure \(String(describing: $0.failure))") }
  }
  let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  layerHost.wantsLayer = true
  reader!.output.displayLayer.frame = layerHost.bounds
  layerHost.layer!.addSublayer(reader!.output.displayLayer)
  reader!.open(aacURL, autoplay: false)
  check(waitUntil { latest?.phase == .paused || latest?.phase == .failed } && latest?.phase == .paused,
    "Reordered H264 fixture opens without autoplay")
  if latest?.phase == .paused {
    let initialOutput = outputState(reader!)
    check((initialOutput?.videoSamples ?? 0) > 0 && initialOutput?.rate == 0,
      "Paused H264 open primes an actual video sample while its renderer clock stays stopped")
    var previousFlush = initialOutput?.flushGeneration ?? 0
    for target in [1.6, 0.105, 2.6, 0.0] {
      let revision = latest?.revision ?? 0
      check(reader!.seek(to: target), "Paused H264 seek to \(target) is accepted")
      let ready = waitUntil {
        (latest?.revision ?? 0) > revision && (latest?.phase == .paused || latest?.phase == .failed)
      } && latest?.phase == .paused
      check(ready, "Paused H264 seek to \(target) finishes reordered-video preroll")
      if !ready { break }
      let state = outputState(reader!)
      let frames = seen.read().filter { $0.video && $0.revision == latest?.revision }
      check((state?.flushGeneration ?? 0) > previousFlush && (state?.videoSamples ?? 0) > 0,
        "Paused H264 seek to \(target) primes video after a fresh real output flush")
      previousFlush = state?.flushGeneration ?? previousFlush
      check(!frames.isEmpty && frames.allSatisfy { $0.start >= target - 1e-9 } &&
        (frames.first?.start ?? 100) <= target + 1.0 / 30 + 1e-9,
        "Paused H264 seek to \(target) enqueues target-frame timing, not old-generation frames")
      check(state?.rate == 0 && abs((state?.position ?? -100) - target) <= 0.001,
        "Paused H264 seek to \(target) anchors the actual stopped clock before enqueueing")
      settle(0.1)
      check(latest?.phase == .paused && abs((latest?.position ?? -100) - target) <= 0.001,
        "Paused H264 seek to \(target) remains paused instead of silently resuming")
    }
  }
  var closed = false
  reader!.shutdown { closed = true }
  check(waitUntil { closed }, "Paused H264 shutdown completes")
  reader = nil
  check(waitUntil { releasedReader.value == nil }, "Paused H264 session releases")
}

exercisePausedH264Seeks()

print("RESULT: \(passed) passed; \(failed) failed")
print("LIMIT: Enqueue and clock checks do not certify displayed pixels or audible output.")
print("LIMIT: Injected flush callbacks verify recovery state handling, not a physical output-device switch.")
exit(failed == 0 ? 0 : 1)
