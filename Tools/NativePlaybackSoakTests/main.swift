import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

setbuf(stdout, nil)
var checks = 0
var failures = 0
@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
  checks += 1
  if condition() { print("PASS: \(message)"); return true }
  failures += 1
  print("FAIL: \(message)")
  return false
}

@discardableResult
func waitUntil(_ timeout: Double = 8, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}

struct Reference {
  let bits: Int
  let y: Int
  let u: Int
  let v: Int
}

struct Picture {
  let time: Double
  let rate: Double
  let volume: Float
  let width: Int
  let height: Int
  let bits: Int
  let values: [Int]
  let hasImage: Bool
  var isValid4K: Bool { hasImage && width == 3840 && height == 2160 && values.count == 27 }
  var signature: String { values.prefix(3).map(String.init).joined(separator: ",") }

  func matches(_ reference: Reference) -> Bool {
    guard isValid4K, bits == reference.bits else { return false }
    for offset in stride(from: 0, to: values.count, by: 3) {
      if abs(values[offset] - reference.y) > 1 ||
         abs(values[offset + 1] - reference.u) > 1 ||
         abs(values[offset + 2] - reference.v) > 1 { return false }
    }
    return true
  }
}

struct Memory {
  let resident: UInt64
  let footprint: UInt64
  static func read() -> Memory? {
    var rss: UInt64 = 0, footprint: UInt64 = 0
    guard native_soak_memory(&rss, &footprint) else { return nil }
    return Memory(resident: rss, footprint: footprint)
  }
}

final class WeakSessionReference {
  weak var value: NativePlaybackSession?
  init(_ value: NativePlaybackSession) { self.value = value }
}

final class Harness {
  let session = NativePlaybackSession()
  let worker: DispatchQueue
  let surface: NativePlaybackSurface
  var latest: NativePlaybackSnapshot?
  var generation: UInt64 = 0
  var muted = true
  var highestQueuedBytes = 0
  var sessionErrors = 0
  var successfulReads = 0
  var peakResident: UInt64 = 0
  var peakFootprint: UInt64 = 0
  var peakHardwareSamples = 0
  var peakVideoToolboxSamples = 0
  let startedAt = ProcessInfo.processInfo.systemUptime
  var nextMemoryLog = 0.0
  let fixtures: URL

  init(fixtures: URL, host: NSView) {
    self.fixtures = fixtures
    // Read-only reflection obtains only the production owner's serial queue.
    // No state is injected and all commands go through the actual session.
    worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
    surface = NativePlaybackSurface(frame: host.bounds)
    surface.autoresizingMask = [.width, .height]
    host.addSubview(surface)
    check(surface.attach(session.output.displayLayer), "Attach actual output to production AppKit surface")
    session.onSnapshot = { [weak self] snapshot in
      guard let self else { return }
      self.latest = snapshot
      self.muted = self.muted && snapshot.volume == 0
      self.highestQueuedBytes = max(self.highestQueuedBytes, snapshot.queuedBytes)
      self.peakHardwareSamples = max(self.peakHardwareSamples, snapshot.hardwareVideoSamples)
      self.peakVideoToolboxSamples = max(self.peakVideoToolboxSamples, snapshot.videoToolboxSamples)
      if let error = snapshot.failure {
        self.sessionErrors += 1
        print("SESSION_ERROR: \(error)")
      }
      if let media = snapshot.media {
        _ = self.surface.setVideoGeometry(codedSize: CGSize(width: media.width, height: media.height),
          pixelAspectRatio: Double(media.sampleAspectNumerator) / Double(media.sampleAspectDenominator),
          rotationDegrees: media.rotationDegrees)
      }
    }
  }

  func open(_ filename: String, wait: Bool = true) -> Bool {
    generation &+= 1
    session.open(fixtures.appendingPathComponent(filename), autoplay: false)
    guard wait else { return true }
    let ready = waitUntil { self.latest?.generation == self.generation && self.latest?.phase == .paused }
    check(ready, "Open \(filename) generation \(generation) paused through actual decoder")
    if let snapshot = latest, let media = snapshot.media {
      print("PATH: codec=\(media.videoCodec) hardware_samples=\(snapshot.hardwareVideoSamples) videotoolbox_samples=\(snapshot.videoToolboxSamples) audio_channels=\(media.audioChannels) audio_rate=\(media.audioSampleRate)")
      check(media.width == 3840 && media.height == 2160 && media.hasAudio && !media.isHDR,
        "Opened fixture is 4K SDR with an actual audio stream")
    }
    return ready
  }

  func seek(_ time: Double) -> Bool {
    let revision = latest?.revision ?? 0
    let oldAudio = latest?.audioSamples ?? 0
    let oldVideo = latest?.videoSamples ?? 0
    guard check(session.seek(to: time), "Accept seek to \(time)") else { return false }
    let ready = check(waitUntil {
      self.latest?.phase == .paused && (self.latest?.revision ?? 0) > revision &&
      abs((self.latest?.position ?? -100) - time) < 0.001
    }, "Seek completes at exact paused target \(time)")
    check((latest?.audioSamples ?? 0) > oldAudio && (latest?.videoSamples ?? 0) > oldVideo,
      "Seek re-primes both real decoded streams before paused-ready")
    print("REFILL: revision=\(latest?.revision ?? 0) audio_delta=\((latest?.audioSamples ?? 0) - oldAudio) video_delta=\((latest?.videoSamples ?? 0) - oldVideo)")
    return ready
  }

  func readback() -> Picture? {
    var result: Picture?
    worker.async { [session] in
      autoreleasepool {
        let output = session.output
        let pixel = output.displayLayer.sampleBufferRenderer.displayedPixelBuffer()
        let format = pixel.map(CVPixelBufferGetPixelFormatType) ?? 0
        let bits = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 8 :
          format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 10 : 0
        var values: [Int] = []
        if let pixel, bits > 0, CVPixelBufferGetWidth(pixel) == 3840,
           CVPixelBufferGetHeight(pixel) == 2160, CVPixelBufferGetPlaneCount(pixel) == 2,
           CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess {
          defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
          if let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0),
             let chroma = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) {
            for y in [8, 1080, 2150] {
              for x in [8, 1920, 3830] {
                let row = luma.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0))
                let uv = chroma.advanced(by: y / 2 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1))
                if bits == 8 {
                  values += [Int(row.assumingMemoryBound(to: UInt8.self)[x]),
                    Int(uv.assumingMemoryBound(to: UInt8.self)[x / 2 * 2]),
                    Int(uv.assumingMemoryBound(to: UInt8.self)[x / 2 * 2 + 1])]
                } else {
                  values += [Int(row.assumingMemoryBound(to: UInt16.self)[x] >> 6),
                    Int(uv.assumingMemoryBound(to: UInt16.self)[x / 2 * 2] >> 6),
                    Int(uv.assumingMemoryBound(to: UInt16.self)[x / 2 * 2 + 1] >> 6)]
                }
              }
            }
          }
        }
        let picture = Picture(time: output.currentTime.seconds, rate: output.actualRate,
          volume: output.volume, width: pixel.map(CVPixelBufferGetWidth) ?? 0,
          height: pixel.map(CVPixelBufferGetHeight) ?? 0, bits: bits,
          values: values, hasImage: pixel != nil)
        DispatchQueue.main.async { result = picture }
      }
    }
    guard waitUntil(4, { result != nil }) else {
      check(false, "Worker display readback remains responsive")
      return nil
    }
    successfulReads += 1
    if let memory = Memory.read() {
      peakResident = max(peakResident, memory.resident)
      peakFootprint = max(peakFootprint, memory.footprint)
      let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
      if elapsed >= nextMemoryLog {
        print("MEMORY_SAMPLE: seconds=\(elapsed) generation=\(latest?.generation ?? 0) revision=\(latest?.revision ?? 0) phase=\(latest?.phase.rawValue ?? "unknown") rss=\(memory.resident) footprint=\(memory.footprint) queued=\(latest?.queuedBytes ?? 0)")
        nextMemoryLog = elapsed + 1
      }
    }
    return result
  }

  func expect(_ reference: Reference, label: String, time: Double = 0) -> Bool {
    var picture: Picture?
    let matched = waitUntil {
      picture = self.readback()
      return picture?.rate == 0 && abs((picture?.time ?? -100) - time) < 0.001 &&
        picture?.matches(reference) == true
    }
    if let picture {
      print("DISPLAY: \(label) time=\(picture.time) rate=\(picture.rate) size=\(picture.width)x\(picture.height) bits=\(picture.bits) yuv=\(picture.signature)")
      check(picture.volume == 0, "Actual renderer is silent at \(label)")
    }
    return check(matched, "Actual 4K displayed pixels match independent reference at \(label)")
  }

  func shutdown() {
    var completed = false
    session.shutdown { completed = true }
    check(waitUntil { completed }, "Real session/renderer shutdown completes asynchronously")
    check(latest?.phase == .closed, "Session publishes closed state")
    check(waitUntil { self.readback()?.hasImage == false }, "Closed renderer leaves no stale displayed pixels")
    check(muted && readback()?.volume == 0, "Every snapshot and final output remain at zero volume")
    check(sessionErrors == 0, "No decoder, scheduling or output failures occurred")
    check(highestQueuedBytes <= 128 * 1024 * 1024, "Published outstanding sample budget remains at most 128 MiB")
    _ = surface.detach()
    surface.removeFromSuperview()
    session.onSnapshot = nil
    print("RESOURCE: reads=\(successfulReads) queued_peak=\(highestQueuedBytes) rss_peak=\(peakResident) footprint_peak=\(peakFootprint) hardware_samples=\(peakHardwareSamples) videotoolbox_samples=\(peakVideoToolboxSamples)")
  }
}

guard #available(macOS 14.4, *), CommandLine.arguments.count == 3,
      let duration = Double(CommandLine.arguments[2]), duration >= 60 else { exit(77) }
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var references: [String: [Int: Reference]] = [:]
for line in try String(contentsOf: fixtures.appendingPathComponent("references.tsv"), encoding: .utf8).split(separator: "\n") {
  let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  guard fields.count == 9, let phase = Int(fields[1]), let bits = Int(fields[2]),
        let y = Int(fields[3]), let u = Int(fields[7]), let v = Int(fields[8]),
        fields[3...6].allSatisfy({ Int($0) == y }) else {
    print("FAIL: Independent uniform source reference is malformed."); exit(1)
  }
  references[fields[0], default: [:]][phase] = Reference(bits: bits, y: y, u: u, v: v)
}
guard references.count == 2, references.values.allSatisfy({ $0.count == 4 }) else { exit(1) }
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
guard let screen = NSScreen.main else { print("UNVERIFIED: No WindowServer screen."); exit(77) }
let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 320,
  y: screen.visibleFrame.midY - 180, width: 640, height: 360),
  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Native 4K playback stress verification"
window.isReleasedWhenClosed = false
window.orderFrontRegardless()
check(window.isVisible, "Own native test window is visible")
let wrongReference = ProcessInfo.processInfo.environment["NATIVE_SOAK_WRONG_REFERENCE"] == "1"
var postCloseMemory: [Memory] = []
var closedWeakReferences: [() -> Bool] = []
let began = ProcessInfo.processInfo.systemUptime

for round in 0..<3 {
  let roundStart = ProcessInfo.processInfo.systemUptime
  autoreleasepool {
    let harness = Harness(fixtures: fixtures, host: window.contentView!)
    let weakSession = WeakSessionReference(harness.session)
    closedWeakReferences.append { weakSession.value == nil }
    defer { harness.shutdown() }
    for filename in ["h264.mp4", "hevc-main10.mp4"] {
      guard harness.open(filename) else { return }
      for phase in [0, 3, 1, 2, 0] {
        let target = Double(phase * 2) + 0.25
        guard harness.seek(target) else { return }
        let expectedPhase = wrongReference ? (phase + 1) % 4 : phase
        guard harness.expect(references[filename]![expectedPhase]!, label: "\(filename) at \(target)", time: target) else { return }
      }
    }
    guard failures == 0 else { return }
    for index in 0..<12 { _ = harness.open(index.isMultiple(of: 2) ? "h264.mp4" : "hevc-main10.mp4", wait: false) }
    check(waitUntil { harness.latest?.generation == harness.generation && harness.latest?.phase == .paused },
      "Twelve rapid opens settle on the final generation")
    guard harness.expect(references["hevc-main10.mp4"]![0]!, label: "final rapid-open 10-bit fixture") else { return }
    for rate: Float in [0.5, 1.0, 1.75] {
      guard harness.seek(0.25) else { return }
      check(harness.session.setRate(rate), "Accept rate \(rate)")
      check(waitUntil { harness.latest?.phase == .paused && harness.latest?.rate == rate }, "Rate change completes its refill")
      harness.session.setPaused(false)
      let advancing = waitUntil {
        guard let picture = harness.readback() else { return false }
        return abs(picture.rate - Double(rate)) < 0.001 && picture.time > 0.6 && picture.isValid4K
      }
      check(advancing, "Actual \(rate)x timebase advances with a displayed 4K frame")
      if let picture = harness.readback() {
        print("CLOCK: requested_rate=\(rate) actual_rate=\(picture.rate) time=\(picture.time) size=\(picture.width)x\(picture.height) volume=\(picture.volume)")
      }
      harness.session.setPaused(true)
      check(waitUntil { harness.latest?.phase == .paused && harness.readback()?.rate == 0 }, "Pause stops the actual timebase after \(rate)x")
      let time = harness.readback()?.time
      _ = waitUntil(0.15) { false }
      check(time != nil && abs((harness.readback()?.time ?? -100) - time!) < 0.001,
        "Paused timebase stays fixed after \(rate)x")
    }
    harness.session.stop()
    check(waitUntil { harness.latest?.phase == .idle && harness.readback()?.hasImage == false }, "Stop clears real displayed pixels before reopening")
    let sustainedFile = round.isMultiple(of: 2) ? "h264.mp4" : "hevc-main10.mp4"
    guard harness.open(sustainedFile) else { return }
    check(harness.session.setRate(1), "Restore normal speed for sustained playback")
    check(waitUntil { harness.latest?.phase == .paused && harness.latest?.rate == 1 }, "Normal-speed refill completes")
    harness.session.setLoop(nil, repeatFile: true)
    harness.session.setPaused(false)
    var displayedPhases: Set<Int> = []
    var missingImages = 0
    var invalidImages = 0
    var unknownColors = 0
    let runningUntil = max(roundStart + duration / 3, ProcessInfo.processInfo.systemUptime + 12)
    while ProcessInfo.processInfo.systemUptime < runningUntil {
      autoreleasepool {
        if let picture = harness.readback() {
          if picture.isValid4K {
            if let phase = references[sustainedFile]!.first(where: { picture.matches($0.value) })?.key {
              displayedPhases.insert(phase)
            } else { unknownColors += 1 }
          }
          else if picture.hasImage { invalidImages += 1 }
          else { missingImages += 1 }
          if picture.volume != 0 { harness.muted = false }
        }
      }
      _ = waitUntil(0.2) { false }
      if harness.sessionErrors > 0 { break }
    }
    check(displayedPhases == Set(0..<4), "Sustained real playback displays all four independently verified source intervals")
    check(unknownColors == 0, "Every nonempty 4K frame matches a real source interval in its original bit depth")
    check(invalidImages == 0, "No displayed frame loses 4K dimensions or its supported pixel format")
    print("ROUND: index=\(round + 1) seconds=\(ProcessInfo.processInfo.systemUptime - roundStart) source_phases=\(displayedPhases.sorted()) no_image_samples=\(missingImages) invalid_images=\(invalidImages) unknown_colors=\(unknownColors)")
  }
  _ = waitUntil(0.6) { false }
  check(closedWeakReferences.last!(), "Retired session is deallocated after asynchronous shutdown")
  if let memory = Memory.read() { postCloseMemory.append(memory) }
  else { check(false, "Mach process memory diagnostics are available") }
  if failures > 0 { break }
}

if postCloseMemory.count >= 3 {
  let warm = postCloseMemory[1], final = postCloseMemory[2]
  let residentGrowth = Int64(final.resident) - Int64(warm.resident)
  let footprintGrowth = Int64(final.footprint) - Int64(warm.footprint)
  print("MEMORY: post_warm_resident_growth=\(residentGrowth) post_warm_footprint_growth=\(footprintGrowth)")
}
window.orderOut(nil)
window.close()
print("Native 4K stress: \(checks) checks, \(failures) failures; elapsed=\(ProcessInfo.processInfo.systemUptime - began). Displayed-buffer and source-codec verification only; no shipping UI, physical HDR, audible output, or M4 Max AV1 claim.")
exit(failures == 0 ? 0 : 1)
