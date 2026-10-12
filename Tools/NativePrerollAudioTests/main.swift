import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

setbuf(stdout, nil)
var passed = 0
var failed = 0
func check(_ value: Bool, _ label: String) {
  if value { passed += 1; print("PASS: \(label)") }
  else { failed += 1; print("FAIL: \(label)") }
}
@discardableResult
func waitUntil(_ seconds: Double = 5, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}
struct PixelInspection {
  var image: [Int] = []
  // 0=ok, 1=raw nil, 2=dimensions, 3=format, 4=planes, 5=lock,
  // 6=base address, 7=nonzero clock rate (no readback attempted).
  var reason = 1
  var width = 0
  var height = 0
  var format: OSType = 0
  var planes = 0
  var lockCode: CVReturn = 0
  var numbers: [Double] {
    [Double(reason), Double(width), Double(height), Double(format), Double(planes), Double(lockCode)]
  }
}
func inspectPixels(_ buffer: CVPixelBuffer?) -> PixelInspection {
  var result = PixelInspection()
  guard let buffer else { return result }
  result.width = CVPixelBufferGetWidth(buffer)
  result.height = CVPixelBufferGetHeight(buffer)
  result.format = CVPixelBufferGetPixelFormatType(buffer)
  result.planes = CVPixelBufferGetPlaneCount(buffer)
  guard result.width == 160, result.height == 90 else { result.reason = 2; return result }
  guard result.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { result.reason = 3; return result }
  guard result.planes == 2 else { result.reason = 4; return result }
  result.lockCode = CVPixelBufferLockBaseAddress(buffer, .readOnly)
  guard result.lockCode == kCVReturnSuccess else { result.reason = 5; return result }
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
        let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
    result.reason = 6; return result
  }
  for y in [8, 44, 80] {
    for x in [8, 80, 150] {
      let offset = y / 2 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x / 2 * 2
      result.image += [Int(yPlane[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]),
                      Int(uvPlane[offset]), Int(uvPlane[offset + 1])]
    }
  }
  result.reason = 0
  return result
}
func pixels(_ buffer: CVPixelBuffer?) -> [Int] { inspectPixels(buffer).image }

/// Fixed-size numerical evidence only. No pixel values, media buffers or file
/// paths are retained, and no per-sample printing changes normal scheduling.
final class ReadbackTimeline {
  struct Entry {
    let time: Double
    let event: Int
    let values: [Double]
  }
  private let lock = NSLock()
  private var entries = [Entry?](repeating: nil, count: 1024)
  private var total = 0
  func record(_ event: Int, _ values: [Double]) {
    precondition(values.count <= 32)
    let entry = Entry(time: ProcessInfo.processInfo.systemUptime, event: event, values: values)
    lock.lock()
    entries[total % entries.count] = entry
    total += 1
    lock.unlock()
  }
  func dump() {
    lock.lock()
    let count = min(total, entries.count)
    let first = total - count
    let rows = (first..<total).compactMap { entries[$0 % entries.count] }.sorted { $0.time < $1.time }
    let dropped = total - count
    lock.unlock()
    print("READBACK_FAILURE_TIMELINE: entries=\(rows.count) capacity=1024 dropped=\(dropped)")
    print("READBACK_EVENTS: 1=sample [generation,revision,video,start,end]; 2=snapshot [generation,revision,phase,position,rate,wantsPlayback,videoSamples,audioSamples,queuedBytes]; 3=output; 4=wait_begin [clock]; 5=deadline [visible]")
    print("READBACK_PHASES: 0=idle 1=opening 2=seeking 3=paused 4=playing 5=ended 6=failed 7=closed")
    print("READBACK_OUTPUT: reason,width,height,format,planes,lockCode,syncClock,syncRate,videoClock,videoRate,requestedRate,flushGeneration,flushingVideo,videoReady,audioReady,hasOutputError,acceptedVideo,acceptedAudio,rendererStatus,rendererError,requiresFlush,sufficient,readyForDisplay,attached,layerHidden,windowVisible,occlusionVisible,layerWidth,layerHeight")
    print("READBACK_REASONS: 0=ok 1=raw_nil 2=dimensions 3=format 4=planes 5=lock_failed 6=base_address 7=rate_nonzero")
    for row in rows { print("READBACK_EVENT \(row.time) \(row.event) \(row.values)") }
  }
}

struct Reference {
  var audio: [(start: Double, end: Double)] = []
  var image: [Int] = []
  var firstVideo = -1.0
  var audioBeforeVideo = 0
}
func reference(_ url: URL, seeking targets: [Double] = []) -> Reference? {
  var result: Reference?
  DispatchQueue(label: "NativePrerollReference.decoder").async {
    let decoder = CYNMediaDecoder()
    defer { decoder.close() }
    do {
      guard let info = try decoder.open(url) else { return }
      for target in targets { try decoder.seek(to: target) }
      var value = Reference()
      while let sample = try decoder.readSample() {
        let buffer = sample.sampleBuffer
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if sample.isVideo {
          if value.firstVideo < 0 {
            value.firstVideo = start
            value.image = pixels(CMSampleBufferGetImageBuffer(buffer))
          }
        } else {
          let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer)).seconds
          if end > 0 && start < info.duration {
            value.audio.append((max(0, start), min(info.duration, end)))
          }
          if value.firstVideo < 0 { value.audioBeforeVideo += 1 }
        }
      }
      DispatchQueue.main.async { result = value }
    } catch { print("REFERENCE ERROR: \(error)") }
  }
  check(waitUntil { result != nil }, "Independent decoder reference completes: \(url.lastPathComponent)")
  return result
}

guard #available(macOS 14.4, *), CommandLine.arguments.count == 2 else { exit(77) }
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
guard let screen = NSScreen.main else { print("UNVERIFIED: WindowServer unavailable"); exit(77) }
let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 160,
  y: screen.visibleFrame.midY - 90, width: 320, height: 180),
  styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Native paused preroll verification"
window.isReleasedWhenClosed = false
window.contentView!.wantsLayer = true
window.orderFrontRegardless()
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
watchdog.schedule(deadline: .now() + 105)
watchdog.setEventHandler { print("FAIL: Test watchdog expired"); exit(124) }
watchdog.resume()

struct State {
  let rate: Double
  let clock: Double
  let volume: Float
  let image: [Int]
  let heldCount: Int
  let heldBytes: Int
  let queuedBytes: Int
  let flushingVideo: Bool
}
@available(macOS 14.4, *)
final class Harness {
  let session: NativePlaybackSession
  let worker: DispatchQueue
  var latest: NativePlaybackSnapshot?
  var observations: [NativePlaybackSampleObservation] = []
  var allMuted = true
  var peakQueue = 0
  let readbackTimeline: ReadbackTimeline
  init() {
    let timeline = ReadbackTimeline()
    readbackTimeline = timeline
    var receive: ((NativePlaybackSampleObservation) -> Void)?
    session = NativePlaybackSession(sampleObserver: { item in
      timeline.record(1, [Double(item.generation), Double(item.revision), item.video ? 1 : 0, item.start, item.end])
      DispatchQueue.main.async { receive?(item) }
    })
    worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
    receive = { [weak self] in self?.observations.append($0) }
    session.onSnapshot = { [weak self] value in
      guard let self else { return }
      self.latest = value
      self.allMuted = self.allMuted && value.volume == 0
      self.peakQueue = max(self.peakQueue, value.queuedBytes)
      let phases: [NativePlaybackPhase] = [.idle, .opening, .seeking, .paused, .playing, .ended, .failed, .closed]
      timeline.record(2, [Double(value.generation), Double(value.revision),
        Double(phases.firstIndex(of: value.phase)!), value.position, Double(value.rate),
        value.wantsPlayback ? 1 : 0, Double(value.videoSamples), Double(value.audioSamples), Double(value.queuedBytes)])
    }
    session.output.displayLayer.frame = window.contentView!.bounds
    window.contentView!.layer!.addSublayer(session.output.displayLayer)
    CATransaction.flush()
    if ProcessInfo.processInfo.environment["NATIVE_PREROLL_FLUSH_DELAY"] == "1" {
      worker.async { [session] in
        // These are actual renderer flushes. The mechanically generated test
        // output delays acknowledgement, not the call or its pending count.
        for _ in 0..<12 { session.output.flush(removeImage: true) }
      }
      check(state()?.flushingVideo == true, "Twelve real asynchronous flushes are still awaiting controlled acknowledgement")
    }
  }
  func state() -> State? {
    // Presentation ownership is observed on main, not from the worker query.
    let layer = session.output.displayLayer
    let presentation: [Double] = [layer.isReadyForDisplay ? 1 : 0, layer.superlayer != nil ? 1 : 0,
      layer.isHidden ? 1 : 0, window.isVisible ? 1 : 0, window.occlusionState.contains(.visible) ? 1 : 0,
      layer.bounds.width, layer.bounds.height]
    var result: State?
    worker.async { [session, readbackTimeline] in
      let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: session).children.compactMap {
        child -> (String, Any)? in child.label.map { ($0, child.value) }
      })
      let output = session.output
      let rate = output.actualRate
      let renderer = output.displayLayer.sampleBufferRenderer
      var inspection = PixelInspection()
      if rate == 0 { inspection = inspectPixels(renderer.displayedPixelBuffer()) }
      else { inspection.reason = 7 }
      let image = inspection.image
      let outputState: [Double] = [output.currentTime.seconds, rate,
        CMTimebaseGetTime(renderer.timebase).seconds, CMTimebaseGetRate(renderer.timebase),
        Double(output.requestedRate), Double(output.flushGeneration), output.isFlushingVideo ? 1 : 0,
        output.isReady(video: true) ? 1 : 0, output.isReady(video: false) ? 1 : 0,
        output.error != nil ? 1 : 0, Double(output.acceptedVideoSamples), Double(output.acceptedAudioSamples),
        Double(renderer.status.rawValue), Double((renderer.error as NSError?)?.code ?? 0),
        renderer.requiresFlushToResumeDecoding ? 1 : 0,
        renderer.hasSufficientMediaDataForReliablePlaybackStart ? 1 : 0]
      readbackTimeline.record(3, inspection.numbers + outputState + presentation)
      let held = fields["heldPrerollAudio"].map { Mirror(reflecting: $0).children.count } ?? 0
      let state = State(rate: rate, clock: output.currentTime.seconds, volume: output.volume, image: image,
        heldCount: held - (fields["heldPrerollAudioHead"] as? Int ?? 0),
        heldBytes: fields["heldPrerollAudioBytes"] as? Int ?? 0,
        queuedBytes: fields["queuedBytes"] as? Int ?? 0, flushingVideo: output.isFlushingVideo)
      DispatchQueue.main.async { result = state }
    }
    if !waitUntil(2, { result != nil }) { check(false, "Worker read-only query responds") }
    return result
  }
  @discardableResult
  func open(_ name: String, delayed: Bool) -> Bool {
    let generation = (latest?.generation ?? 0) + 1
    session.open(fixtures.appendingPathComponent(name), autoplay: false)
    let ready = waitUntil { latest?.generation == generation && latest?.phase == .paused }
    check(ready, "\(name) reaches paused-ready within five seconds")
    if ready, let value = state() {
      check(value.rate == 0 && value.clock == 0 && value.volume == 0, "\(name) paused clock is exactly zero and muted")
      check(delayed ? value.heldCount > 0 : value.heldCount == 0, "\(name) uses held FIFO only for delayed-video backpressure")
      check(value.heldCount <= 256 && value.heldBytes <= 8 * 1024 * 1024 && value.queuedBytes <= 128 * 1024 * 1024,
        "\(name) staging and output queue stay within their explicit budgets")
    }
    return ready
  }
  func expectImage(_ expected: [Int], clock: Double, _ label: String) {
    var observed: State?
    readbackTimeline.record(4, [clock])
    let visible = waitUntil(3) {
      observed = state()
      return observed?.image == expected && !expected.isEmpty && observed?.rate == 0
    }
    check(visible, label)
    check(observed.map { abs($0.clock - clock) < 0.000001 && $0.volume == 0 } == true,
      "Pixel readback does not advance the shared clock or enable audio")
    readbackTimeline.record(5, [visible ? 1 : 0])
    if !visible { readbackTimeline.dump() }
    print("DISPLAY: clock=\(observed?.clock ?? -1) rate=\(observed?.rate ?? -1) held=\(observed?.heldCount ?? -1) imageAvailable=\(observed?.image.isEmpty == false)")
  }
  func close() {
    var done = false
    session.shutdown { done = true }
    check(waitUntil(3) { done }, "Shutdown completion stays responsive")
    if let value = state() {
      check(value.heldCount == 0 && value.heldBytes == 0 && value.queuedBytes == 0, "Shutdown releases all staged and queued accounting")
    }
    check(allMuted, "Every snapshot remained muted")
    session.output.displayLayer.removeFromSuperlayer()
    session.onSnapshot = nil
  }
}

for name in ["control.mkv", "control.mp4", "delayed.mkv", "delayed.mp4"] {
  guard let expected = reference(fixtures.appendingPathComponent(name)) else { continue }
  let delayed = name.hasPrefix("delayed")
  if delayed {
    check(expected.firstVideo == 1 && expected.audioBeforeVideo >= 48, "\(name) truly has audio before its delayed first video")
    if let sought = reference(fixtures.appendingPathComponent(name), seeking: [2, 0]) {
      print("DECODER SEEK: file=\(name) initial_audio=\(expected.audio.count) sought_audio=\(sought.audio.count) initial_first=\(expected.audio.first?.start ?? -1) sought_first=\(sought.audio.first?.start ?? -1) sought_video=\(sought.firstVideo) sought_preceding=\(sought.audioBeforeVideo)")
      check(sought.audio.count == expected.audio.count && zip(sought.audio, expected.audio).allSatisfy {
        $0.start == $1.start && $0.end == $1.end
      }, "\(name) independent backwards seek preserves the beginning audio samples")
    }
  }
  let harness = Harness()
  if harness.open(name, delayed: delayed) {
    harness.expectImage(expected.image, clock: 0, "\(name) actual paused renderer displays the first decoded image")
    let oldCount = harness.observations.count
    _ = waitUntil(0.2) { false }
    let stable = harness.state()
    check(stable?.rate == 0 && stable?.clock == 0 && harness.observations.count == oldCount,
      "Paused preview does not secretly consume more samples or play")
    harness.session.setPaused(false)
    check(waitUntil(6) { harness.latest?.phase == .ended }, "\(name) resumes through actual EOF")
    let actual = harness.observations.filter { !$0.video }
    check(actual.count == expected.audio.count, "\(name) retains every original audio sample through resume")
    let same = actual.count == expected.audio.count && zip(actual, expected.audio).allSatisfy {
      abs($0.start - $1.start) < 0.0000001 && abs($0.end - $1.end) < 0.0000001
    }
    check(same, "\(name) audio PTS and end times match independent decode in FIFO order")
    let drained = harness.state()
    check(drained?.heldCount == 0 && drained?.heldBytes == 0, "\(name) EOF is not reported while staged audio remains")
    print("AUDIO: file=\(name) expected=\(expected.audio.count) accepted=\(actual.count) max_queue=\(harness.peakQueue)")
  }
  harness.close()
}

for name in ["delayed.mkv", "delayed.mp4"] {
  guard let expected = reference(fixtures.appendingPathComponent(name)) else { continue }
  let autoplay = Harness()
  autoplay.session.open(fixtures.appendingPathComponent(name), autoplay: true)
  check(waitUntil(6) { autoplay.latest?.phase == .ended }, "\(name) autoplay reaches actual EOF after preroll changes phase")
  let actual = autoplay.observations.filter { !$0.video }
  check(actual.count == expected.audio.count && zip(actual, expected.audio).allSatisfy {
    abs($0.start - $1.start) < 0.0000001 && abs($0.end - $1.end) < 0.0000001
  }, "\(name) in-pump autoplay transition cannot let new audio overtake held audio")
  autoplay.close()
}

let lifecycle = Harness()
if let expected = reference(fixtures.appendingPathComponent("delayed.mkv")), lifecycle.open("delayed.mkv", delayed: true) {
  let oldRevision = lifecycle.latest?.revision
  lifecycle.session.seek(to: 2)
  check(waitUntil { lifecycle.latest?.revision != oldRevision && lifecycle.latest?.phase == .paused }, "Seek away from staged audio reaches paused-ready")
  lifecycle.expectImage(expected.image, clock: 2, "Seek shows a current video image")
  check(lifecycle.state()?.heldCount == 0, "Seek clears obsolete held audio")
  let backwardRevision = lifecycle.latest?.revision
  lifecycle.session.seek(to: 0)
  check(waitUntil { lifecycle.latest?.revision != backwardRevision && lifecycle.latest?.phase == .paused && lifecycle.latest?.position == 0 }, "Backward seek can stage delayed audio again")
  let backwardState = lifecycle.state()
  print("BACKWARD: phase=\(String(describing: lifecycle.latest?.phase)) clock=\(backwardState?.clock ?? -1) rate=\(backwardState?.rate ?? -1) held=\(backwardState?.heldCount ?? -1) imageAvailable=\(backwardState?.image.isEmpty == false)")
  check(lifecycle.state().map { $0.heldCount > 0 } == true, "Backward seek recreates only the new FIFO")
  let beforeShortLoop = lifecycle.observations.count
  lifecycle.session.setLoop(try! NativePlaybackInterval(start: 0, end: 0.5), repeatFile: false)
  check(waitUntil {
    let observed = lifecycle.state()
    return lifecycle.latest?.phase == .paused && lifecycle.latest?.position == 0 && observed?.heldCount == 0
  },
    "Audio-only A/B interval discards old held audio and becomes paused-ready")
  let shortLoopSamples = lifecycle.observations.dropFirst(beforeShortLoop)
  check(!shortLoopSamples.isEmpty && shortLoopSamples.allSatisfy { !$0.video && $0.start >= 0 && $0.end <= 0.5 },
    "Audio-only A/B preroll retains actual audio and excludes every video or sample beyond B")
  lifecycle.session.setLoop(try! NativePlaybackInterval(start: 0, end: 2), repeatFile: false)
  check(waitUntil {
    let observed = lifecycle.state()
    return lifecycle.latest?.phase == .paused && (observed?.heldCount ?? 0) > 0
  }, "A/B containing delayed video stages bounded audio")
  let loopState = lifecycle.state()
  print("AB: phase=\(String(describing: lifecycle.latest?.phase)) clock=\(loopState?.clock ?? -1) rate=\(loopState?.rate ?? -1) held=\(loopState?.heldCount ?? -1) imageAvailable=\(loopState?.image.isEmpty == false)")
  lifecycle.session.setPaused(false)
  let before = lifecycle.observations.count
  check(waitUntil(8) {
    let later = lifecycle.observations.dropFirst(before)
    // The first frame of the current iteration was already submitted while
    // paused, before this baseline. Allow two full two-second intervals plus
    // bounded decoder/output reinitialization; this is not a speed benchmark.
    return later.filter { $0.video && abs($0.start - 1) < 0.000001 }.count >= 2
  }, "A/B completes two automatic wraps with delayed-video staging")
  let loopSamples = lifecycle.observations.dropFirst(before)
  check(loopSamples.contains { !$0.video && $0.start == 0 }, "Automatic A/B wrap restores the leading audio from the source beginning")
  check(loopSamples.allSatisfy { $0.start >= 0 && $0.end <= 2 }, "Every accepted A/B sample stays inside the requested interval")
  lifecycle.session.setPaused(true)
  check(waitUntil { lifecycle.latest?.phase == .paused }, "A/B can pause without clearing user intent")
  lifecycle.session.stop()
  check(waitUntil { lifecycle.latest?.phase == .idle }, "Stop completes after staged A/B playback")
  check(lifecycle.state()?.heldCount == 0, "Stop clears held audio")
  for _ in 0..<10 {
    lifecycle.session.open(fixtures.appendingPathComponent("delayed.mkv"), autoplay: false)
    lifecycle.session.open(fixtures.appendingPathComponent("control.mkv"), autoplay: false)
  }
  check(waitUntil { lifecycle.latest?.phase == .paused && lifecycle.latest?.generation == 21 }, "Rapid replacement reaches only the final generation")
  check(lifecycle.state()?.heldCount == 0, "Rapid replacement cannot retain the preceding media's held audio")
}
lifecycle.close()

let excessive = Harness()
excessive.session.open(fixtures.appendingPathComponent("excessive.mkv"), autoplay: false)
check(waitUntil(3) { excessive.latest?.phase == .failed }, "Video delay beyond three-second staging limit fails promptly")
check(excessive.latest?.failure == .bufferLimit, "Excessive audio lead has an explicit buffer-limit failure")
check(excessive.state()?.heldCount == 0, "Failure releases the held queue")
excessive.close()

let audioOnly = Harness()
if audioOnly.open("audio-only.wav", delayed: false) {
  audioOnly.session.setPaused(false)
  check(waitUntil(2) { audioOnly.latest?.phase == .ended }, "Audio-only media remains playable without a video prerequisite")
}
audioOnly.close()
window.orderOut(nil)
window.close()
watchdog.cancel()
print("Preroll audio checks: \(passed) passed, \(failed) failed. Pixel reads inspect the paused renderer, not physical screen presentation; audio checks verify submitted decoded samples, not audible output.")
exit(failed == 0 ? 0 : 1)
