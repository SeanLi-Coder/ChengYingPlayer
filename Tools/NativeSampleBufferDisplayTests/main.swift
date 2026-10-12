import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

struct Color: Equatable {
  let name: String
  let r: UInt8
  let g: UInt8
  let b: UInt8
  static let red = Color(name: "red", r: 210, g: 30, b: 20)
  static let green = Color(name: "green", r: 20, g: 200, b: 40)
  static let blue = Color(name: "blue", r: 25, g: 45, b: 210)
  static let yellow = Color(name: "yellow", r: 205, g: 195, b: 20)
  static let purple = Color(name: "purple", r: 190, g: 25, b: 200)
}

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() { passed += 1; print("PASS: \(message)") }
  else { failed += 1; print("FAIL: \(message)") }
}

@discardableResult
func waitUntil(_ seconds: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while Date() < deadline
  return predicate()
}

func makeSample(_ color: Color, at time: Double, duration: Double) -> CMSampleBuffer {
  var pixel: CVPixelBuffer?
  let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                    kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
    attributes, &pixel) == kCVReturnSuccess)
  let image = pixel!
  precondition(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
  let address = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
  let stride = CVPixelBufferGetBytesPerRow(image)
  for y in 0..<48 {
    for x in 0..<64 {
      let offset = y * stride + x * 4
      address[offset] = color.b
      address[offset + 1] = color.g
      address[offset + 2] = color.r
      address[offset + 3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(image, [])
  var format: CMVideoFormatDescription?
  precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: image, formatDescriptionOut: &format) == noErr)
  var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 600),
    presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600), decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
  return sample!
}

// Inspect the renderer's actual displayed pixel buffer, never the submitted sample.
// Do not alter the returned buffer's bytes or attachments.
func matches(_ pixel: CVPixelBuffer?, _ color: Color) -> Bool {
  guard let pixel, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
        CVPixelBufferGetWidth(pixel) == 64, CVPixelBufferGetHeight(pixel) == 48,
        CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return false }
  defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
  guard let address = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return false }
  let stride = CVPixelBufferGetBytesPerRow(pixel)
  for y in [4, 24, 43] {
    for x in [4, 32, 59] {
      let offset = y * stride + x * 4
      if abs(Int(address[offset]) - Int(color.b)) > 2 ||
         abs(Int(address[offset + 1]) - Int(color.g)) > 2 ||
         abs(Int(address[offset + 2]) - Int(color.r)) > 2 || address[offset + 3] < 250 { return false }
    }
  }
  return true
}

guard #available(macOS 14.4, *) else {
  print("UNVERIFIED: Displayed pixel readback requires macOS 14.4 or newer.")
  exit(77)
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
watchdog.schedule(deadline: .now() + 45)
watchdog.setEventHandler {
  fputs("FAIL: Native display verification exceeded its watchdog deadline.\n", stderr)
  exit(124)
}
watchdog.resume()
guard let screen = NSScreen.main else {
  print("UNVERIFIED: No WindowServer screen is available for the native display test.")
  exit(77)
}
let worker = DispatchQueue(label: "NativeSampleBufferDisplayTests.worker")
let output = NativeSampleBufferOutput(workerQueue: worker)
let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 160,
  y: screen.visibleFrame.midY - 120, width: 320, height: 240),
  styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Native sample-buffer display verification"
window.isReleasedWhenClosed = false
window.contentView!.wantsLayer = true
output.displayLayer.frame = window.contentView!.bounds
output.displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
window.contentView!.layer!.addSublayer(output.displayLayer)
window.orderFrontRegardless()
CATransaction.flush()

func displayed() -> CVPixelBuffer? {
  worker.sync { output.displayLayer.sampleBufferRenderer.displayedPixelBuffer() }
}
func expectColor(_ color: Color, _ description: String) {
  check(waitUntil(3) { matches(displayed(), color) }, description)
  if let pixel = displayed() {
    print("DISPLAY: expected=\(color.name) format=\(CVPixelBufferGetPixelFormatType(pixel)) size=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel)) clock=\(worker.sync { output.currentTime.seconds })")
  } else {
    print("DISPLAY: expected=\(color.name) actual=unavailable clock=\(worker.sync { output.currentTime.seconds })")
  }
}
func enqueue(_ color: Color, at time: Double, duration: Double) {
  let sample = makeSample(color, at: time, duration: duration)
  check(waitUntil { worker.sync { output.isReady(video: true) } }, "Renderer ready for \(color.name) at \(time)")
  do { try worker.sync { try output.enqueue(sample, video: true) } }
  catch { check(false, "Enqueue \(color.name): \(error.localizedDescription)") }
}
func pausePlayback() {
  worker.sync { _ = output.setRate(0) }
  check(waitUntil { worker.sync { output.actualRate == 0 } }, "Shared clock actually pauses before pixel readback")
}
func anchor(_ time: Double) {
  worker.sync { _ = output.setRate(0, at: CMTime(seconds: time, preferredTimescale: 600)) }
  check(waitUntil { worker.sync { output.actualRate == 0 && abs(output.currentTime.seconds - time) <= 0.001 } },
    "Paused shared clock reaches anchor \(time)")
}

check(window.isVisible, "Own AppKit window is visible")
anchor(0)
enqueue(.red, at: 0, duration: 0.8)
enqueue(.green, at: 0.8, duration: 0.8)
enqueue(.blue, at: 1.6, duration: 3.2)
expectColor(.red, "Paused startup actually displays the first red pixels")
check(!matches(displayed(), .blue), "Readback is the displayed frame, not the most recently enqueued blue sample")
worker.sync { _ = output.setRate(1) }
check(waitUntil(3) { worker.sync { output.currentTime.seconds >= 0.95 } }, "Playback reaches the green frame interval")
pausePlayback()
check(worker.sync { output.currentTime.seconds < 1.6 }, "Pause occurs before the queued blue frame")
expectColor(.green, "Timed playback actually replaces red with green pixels")
let pausedAt = worker.sync { output.currentTime.seconds }
_ = waitUntil(1) { false }
check(worker.sync { abs(output.currentTime.seconds - pausedAt) < 0.001 }, "Pause preserves the clock while wall time crosses the next frame")
expectColor(.green, "Paused display does not leak the future blue frame")
check(!matches(displayed(), .blue), "Future queued pixels remain distinguishable from the paused display")

worker.sync { output.flush(removeImage: false) }
expectColor(.green, "Flush without image removal preserves the actual displayed frame")
worker.sync { output.flush(removeImage: true) }
check(waitUntil { displayed() == nil }, "Flush with image removal clears actual displayed pixels")
anchor(1.6)
enqueue(.yellow, at: 1.6, duration: 0.8)
enqueue(.purple, at: 2.4, duration: 3.2)
expectColor(.yellow, "Seek displays the new yellow frame instead of the old queued blue frame")
worker.sync { _ = output.setRate(1) }
check(waitUntil(3) { worker.sync { output.currentTime.seconds >= 2.55 } }, "Post-seek playback reaches the new purple interval")
pausePlayback()
expectColor(.purple, "Post-seek output displays purple with no stale blue queue contents")

worker.sync { output.flush(removeImage: true) }
anchor(0)
enqueue(.red, at: 0, duration: 1)
expectColor(.red, "Backward seek can actually display an earlier frame after flush")
check(worker.sync { output.volume == 0 && output.error == nil }, "Display test stays muted and renderer has no error")

// Overlap asynchronous flush requests. The next frame is only supplied after
// all prior flushes finish, including callbacks for superseded seek generations.
let initialGeneration = worker.sync { output.flushGeneration }
worker.sync {
  for index in 0..<12 { output.flush(removeImage: index % 2 == 0) }
  output.flush(removeImage: true)
}
check(waitUntil { worker.sync { !output.isFlushingVideo } }, "Overlapping video flushes all complete")
check(worker.sync { output.flushGeneration == initialGeneration + 13 }, "Each overlapping flush retains its generation")
check(waitUntil { displayed() == nil }, "Final overlapping clear leaves no old displayed pixels")
anchor(0)
enqueue(.yellow, at: 0, duration: 1)
expectColor(.yellow, "New pixels survive every prior asynchronous flush completion")
_ = waitUntil(0.2) { false }
expectColor(.yellow, "A late flush callback cannot erase the replacement frame")

var stopped = false
worker.async { output.shutdown { stopped = true } }
check(waitUntil(5) { stopped }, "Display output shuts down asynchronously")
check(waitUntil { displayed() == nil }, "Shutdown removes the final displayed image")
output.displayLayer.removeFromSuperlayer()
window.orderOut(nil)
window.close()
watchdog.cancel()
print("Native display checks: \(passed) passed, \(failed) failed. Readback verifies the renderer's displayed pixel buffer, not physical display HDR or audible output.")
exit(failed == 0 ? 0 : 1)
