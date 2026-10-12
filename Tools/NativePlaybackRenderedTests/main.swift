import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

setbuf(stdout, nil)

struct YUV {
  let name: String
  let y: Int
  let u: Int
  let v: Int
  static let red = YUV(name: "red", y: 63, u: 102, v: 240)
  static let green = YUV(name: "green", y: 173, u: 42, v: 26)
  static let blue = YUV(name: "blue", y: 32, u: 240, v: 118)
  static let purple = YUV(name: "purple", y: 78, u: 214, v: 230)
}

struct DisplayReadback {
  let rate: Double
  let time: Double
  let exactTime: CMTime
  let volume: Float
  let width: Int
  let height: Int
  let format: OSType
  let components: [Int]
  let hasImage: Bool

  func matches(_ color: YUV) -> Bool {
    guard hasImage, width == 160, height == 90,
          format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          components.count == 27 else { return false }
    for offset in stride(from: 0, to: components.count, by: 3) {
      if abs(components[offset] - color.y) > 1 ||
         abs(components[offset + 1] - color.u) > 1 ||
         abs(components[offset + 2] - color.v) > 1 { return false }
    }
    return true
  }
}

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() { passed += 1; print("PASS: \(message)") }
  else { failed += 1; print("FAIL: \(message)") }
}

@discardableResult
func waitUntil(_ seconds: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}

guard #available(macOS 14.4, *), CommandLine.arguments.count == 2 else {
  print("UNVERIFIED: Requires macOS 14.4 or newer and a synthetic fixture directory.")
  exit(77)
}
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
guard let screen = NSScreen.main else {
  print("UNVERIFIED: No WindowServer screen is available.")
  exit(77)
}
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
watchdog.schedule(deadline: .now() + 60)
watchdog.setEventHandler {
  fputs("FAIL: Native playback rendered verification exceeded its watchdog deadline.\n", stderr)
  exit(124)
}
watchdog.resume()

var observedSession: NativePlaybackSession?
var observationRevision: UInt64?
var observedStreams: Set<Bool> = []
let session = NativePlaybackSession(sampleObserver: { sample in
  if observationRevision != sample.revision {
    observationRevision = sample.revision
    observedStreams = []
  }
  if observedStreams.insert(sample.video).inserted, let output = observedSession?.output {
    let clock = output.currentTime
    print("FIRST: revision=\(sample.revision) video=\(sample.video) pts=\(String(format: "%.17g", sample.start)) end=\(String(format: "%.17g", sample.end)) clock=\(clock.value)/\(clock.timescale) seconds=\(String(format: "%.17g", clock.seconds)) rate=\(output.actualRate)")
  }
})
observedSession = session
// White-box diagnostics obtain the real owner queue only. They never enqueue
// samples, seek the output directly, inject snapshots, or mutate decoder state.
let worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 160,
  y: screen.visibleFrame.midY - 90, width: 320, height: 180),
  styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Native playback end-to-end pixel verification"
window.isReleasedWhenClosed = false
window.contentView!.wantsLayer = true
session.output.displayLayer.frame = window.contentView!.bounds
session.output.displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
window.contentView!.layer!.addSublayer(session.output.displayLayer)
window.orderFrontRegardless()
CATransaction.flush()

var latest: NativePlaybackSnapshot?
var failures: [NativePlaybackFailure] = []
var allSnapshotsMuted = true
var expectedGeneration: UInt64 = 0
session.onSnapshot = { snapshot in
  latest = snapshot
  allSnapshotsMuted = allSnapshotsMuted && snapshot.volume == 0
  if let failure = snapshot.failure { failures.append(failure) }
}

func readback() -> DisplayReadback? {
  var result: DisplayReadback?
  var finished = false
  worker.async {
    let output = session.output
    let rate = output.actualRate
    let exactTime = output.currentTime
    let time = exactTime.seconds
    let volume = output.volume
    let pixel = output.displayLayer.sampleBufferRenderer.displayedPixelBuffer()
    var components: [Int] = []
    if let pixel, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
       CVPixelBufferGetPlaneCount(pixel) == 2, CVPixelBufferGetWidth(pixel) == 160,
       CVPixelBufferGetHeight(pixel) == 90, CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess {
      if let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self),
         let chroma = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)?.assumingMemoryBound(to: UInt8.self) {
        for y in [8, 44, 80] {
          for x in [8, 80, 150] {
            let chromaOffset = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + (x / 2) * 2
            components += [Int(luma[y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + x]),
              Int(chroma[chromaOffset]), Int(chroma[chromaOffset + 1])]
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
    }
    let observed = DisplayReadback(rate: rate, time: time, exactTime: exactTime, volume: volume,
      width: pixel.map(CVPixelBufferGetWidth) ?? 0, height: pixel.map(CVPixelBufferGetHeight) ?? 0,
      format: pixel.map(CVPixelBufferGetPixelFormatType) ?? 0, components: components, hasImage: pixel != nil)
    DispatchQueue.main.async { result = observed; finished = true }
  }
  if !waitUntil(3, { finished }) {
    check(false, "Read-only renderer query completes without blocking main")
    return nil
  }
  return result
}

func expectPixels(_ color: YUV, _ message: String) {
  var observed: DisplayReadback?
  let matched = waitUntil(5) {
    observed = readback()
    return observed?.rate == 0 && observed?.matches(color) == true
  }
  check(matched, message)
  if let observed {
    print("DISPLAY: expected=\(color.name) pts=\(observed.time) clock=\(observed.exactTime.value)/\(observed.exactTime.timescale) rate=\(observed.rate) format=\(observed.format) yuv=\(Array(observed.components.prefix(3)))")
    check(observed.volume == 0, "Actual output remains silent while inspecting \(color.name)")
  }
}

func open(_ name: String, wait: Bool = true) {
  expectedGeneration &+= 1
  session.open(fixtures.appendingPathComponent(name), autoplay: false)
  if wait {
    check(waitUntil { latest?.generation == expectedGeneration && latest?.phase == .paused },
      "\(name) opens through the real decoder and session")
    check(latest?.media?.hasVideo == true && latest?.media?.hasAudio == true,
      "\(name) contains both selected streams")
    check((latest?.videoSamples ?? 0) > 0 && (latest?.audioSamples ?? 0) > 0,
      "\(name) primes both decoded streams")
  }
}

func seek(_ target: Double) {
  let previousRevision = latest?.revision ?? 0
  check(session.seek(to: target), "Session accepts seek to \(target)")
  check(waitUntil {
    guard let snapshot = latest else { return false }
    return snapshot.phase == .paused && snapshot.revision > previousRevision &&
      abs(snapshot.position - target) <= 0.001
  }, "Seek to \(target) reaches a newly anchored paused session")
}

check(window.isVisible, "Own end-to-end test window is visible")
for name in ["timeline.mkv", "timeline.mp4"] {
  open(name)
  expectPixels(.red, "\(name): decoded first-frame red pixels actually display")
  seek(1.7)
  expectPixels(.green, "\(name): seek displays the decoded green interval")
  check(readback()?.matches(.blue) == false, "\(name): displayed pixels are not a later decoded blue frame")
  seek(2.9)
  expectPixels(.blue, "\(name): seek displays the decoded blue interval")
  seek(0.2)
  expectPixels(.red, "\(name): backward seek replaces displayed blue with decoded red")
  session.setPaused(false)
  check(waitUntil { latest?.phase == .playing && (latest?.position ?? 0) >= 1.55 },
    "\(name): real demux/decode/playback advances into green")
  session.setPaused(true)
  check(waitUntil { latest?.phase == .paused && (latest?.position ?? 99) < 2.4 },
    "\(name): playback pauses before the blue boundary")
  expectPixels(.green, "\(name): played-and-paused pixels match the green interval")
  _ = waitUntil(0.7) { false }
  expectPixels(.green, "\(name): paused actual frame remains green")
  print("PATH: \(name) videoCodec=\(latest?.media?.videoCodec ?? "unknown") videoSamples=\(latest?.videoSamples ?? 0) videoToolbox=\(latest?.videoToolboxSamples ?? 0) hardwareProof=\(latest?.hardwareVideoSamples ?? 0)")
}

// Interleave openings without waiting for old work. The last file has a color
// absent from the timeline, so old decoder output cannot satisfy this assertion.
for index in 0..<8 { open(index % 2 == 0 ? "timeline.mp4" : "alternate.mkv", wait: false) }
check(waitUntil { latest?.generation == expectedGeneration && latest?.phase == .paused },
  "Rapid file changes settle on the final generation")
expectPixels(.purple, "Rapid file changes display only the final file's decoded purple pixels")
_ = waitUntil(0.4) { false }
expectPixels(.purple, "Late work from replaced files cannot resurrect red, green, or blue")

session.stop()
check(waitUntil { latest?.phase == .idle }, "Stop releases the decoder through the session")
check(waitUntil { readback()?.hasImage == false }, "Stop clears actual displayed pixels")
open("timeline.mkv")
expectPixels(.red, "A stopped session can reopen and display decoded content")
var closed = false
session.shutdown { closed = true }
check(waitUntil { closed }, "Session and renderer close asynchronously")
check(waitUntil { readback()?.hasImage == false }, "Closed session leaves no stale displayed frame")
check(latest?.phase == .closed, "Closed state is published")
check(allSnapshotsMuted, "All file generations and commands preserve zero volume")
check(failures.isEmpty, "No decoder or session failure occurred")
if !failures.isEmpty { print("FAILURES: \(failures)") }
session.output.displayLayer.removeFromSuperlayer()
window.orderOut(nil)
window.close()
watchdog.cancel()
print("Native rendered checks: \(passed) passed, \(failed) failed. Real local files were decoded by production CYNMediaDecoder and scheduled by NativePlaybackSession; this does not claim the shipping UI has migrated.")
exit(failed == 0 ? 0 : 1)
