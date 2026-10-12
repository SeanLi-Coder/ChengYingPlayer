import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

setbuf(stdout, nil)
var passed = 0, failed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() { passed += 1; print("PASS: \(message)") }
  else { failed += 1; print("FAIL: \(message)") }
}
@discardableResult
func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return condition()
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000001 }
func rect(_ actual: CGRect?, _ expected: CGRect) -> Bool {
  guard let actual else { return false }
  return close(actual.minX, expected.minX) && close(actual.minY, expected.minY) &&
    close(actual.width, expected.width) && close(actual.height, expected.height)
}
if CommandLine.arguments.contains("--reject-worker-mutation") {
  _ = NSApplication.shared
  let invalidOwner = NativePlaybackSurface(frame: .zero)
  DispatchQueue.global().async { _ = invalidOwner.setViewport(zoom: 2) }
  RunLoop.main.run(until: Date().addingTimeInterval(3))
  exit(65)
}
guard #available(macOS 14.4, *), CommandLine.arguments.count == 2 else { exit(77) }
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
guard NSScreen.main != nil else { print("UNVERIFIED: WindowServer unavailable"); exit(77) }
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 55)
watchdog.setEventHandler { fputs("FAIL: Surface verification deadline exceeded\n", stderr); exit(124) }
watchdog.resume()
let surface = NativePlaybackSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
let window = NSWindow(contentRect: surface.frame, styleMask: [.titled, .closable, .resizable],
  backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = surface
window.orderFrontRegardless()
let sampleLayer = AVSampleBufferDisplayLayer()
sampleLayer.bounds = CGRect(x: 1, y: 2, width: 37, height: 24)
sampleLayer.position = CGPoint(x: 18, y: -8)
sampleLayer.contentsScale = 1.5
let originalBounds = sampleLayer.bounds, originalPosition = sampleLayer.position
check(surface.attach(sampleLayer), "Unowned display layer attaches on main")
check(surface.attach(sampleLayer), "Repeated attach is idempotent")
check(!surface.attach(AVSampleBufferDisplayLayer()), "Replacement requires explicit detach")
check(sampleLayer.isHidden, "Unspecified video geometry stays hidden")
check(surface.layer?.masksToBounds == true, "Viewport clips zoomed or panned video")
check(!surface.isFlipped, "View uses upward-positive point coordinates")
check(surface.hitTest(CGPoint(x: 10, y: 10)) == nil, "Display surface leaves pointer handling to its player host")
check(surface.setVideoGeometry(codedSize: CGSize(width: 1920, height: 1080)), "Square-pixel source is accepted")
check(rect(surface.displayedVideoRect, CGRect(x: 0, y: 75, width: 800, height: 450)), "Wide source fits without distortion")
check(sampleLayer.videoGravity == .resize, "Geometry is applied once without nested aspect-fit")
check(close(sampleLayer.contentsScale, window.backingScaleFactor), "Current window backing scale reaches video layer")
check(surface.setVideoGeometry(codedSize: CGSize(width: 720, height: 576), pixelAspectRatio: 16.0 / 15), "Anamorphic source is accepted")
check(rect(surface.displayedVideoRect, CGRect(x: 0, y: 0, width: 800, height: 600)), "SAR corrects coded 5:4 to display 4:3 exactly once")
check(surface.setVideoGeometry(codedSize: CGSize(width: 720, height: 576), pixelAspectRatio: 16.0 / 15, rotationDegrees: 90), "Quarter source rotation is accepted")
check(rect(surface.displayedVideoRect, CGRect(x: 175, y: 0, width: 450, height: 600)), "Quarter rotation swaps SAR-corrected dimensions")
check(surface.setViewport(zoom: 2, pan: CGPoint(x: 100, y: 30)), "Linear zoom and point pan are accepted")
check(rect(surface.displayedVideoRect, CGRect(x: 50, y: -270, width: 900, height: 1200)), "Zoom and positive-Y-up pan preserve unclipped geometry")
check(sampleLayer.position == CGPoint(x: 500, y: 330), "Pan applies in viewport points, not scaled image units")
surface.resetViewport()
check(surface.zoom == 1 && surface.pan == .zero, "Viewport reset returns to aspect-fit")
surface.setFrameSize(CGSize(width: 400, height: 300))
check(rect(surface.displayedVideoRect, CGRect(x: 87.5, y: 0, width: 225, height: 300)), "Frame resize immediately recomputes video geometry")
surface.setBoundsOrigin(CGPoint(x: 5, y: 7))
check(rect(surface.displayedVideoRect, CGRect(x: 92.5, y: 7, width: 225, height: 300)), "Nonzero viewport origin remains part of the transform")
surface.setBoundsOrigin(.zero)
surface.isHidden = true
check(sampleLayer.isHidden, "Hiding presentation hides its layer without a playback command")
surface.isHidden = false
check(!sampleLayer.isHidden, "Showing presentation restores its valid video geometry")
surface.setFrameSize(.zero)
check(sampleLayer.isHidden && surface.displayedVideoRect == nil, "Zero viewport does not produce NaN layer transforms")
surface.setFrameSize(CGSize(width: 400, height: 300))
check(!sampleLayer.isHidden, "Restoring viewport size restores the same valid source")
let validFrame = surface.frame, validBounds = surface.bounds
surface.setFrameSize(CGSize(width: CGFloat.nan, height: 300))
surface.setBoundsSize(CGSize(width: CGFloat.infinity, height: 300))
surface.setBoundsOrigin(CGPoint(x: CGFloat.nan, y: 0))
check(surface.frame == validFrame && surface.bounds == validBounds, "Invalid viewport geometry is stopped before reaching AppKit")
let validGeometry = surface.geometry
for size in [CGSize(width: 0, height: 1), CGSize(width: -1, height: 1),
  CGSize(width: CGFloat.infinity, height: 1), CGSize(width: CGFloat.nan, height: 1),
  CGSize(width: 1.5, height: 10), CGSize(width: 32769, height: 1), CGSize(width: 32768, height: 32768)] {
  check(!surface.setVideoGeometry(codedSize: size), "Invalid coded dimensions are rejected")
}
for ratio in [0.0, -1, Double.nan, Double.infinity, 1.0 / 257, 257] {
  check(!surface.setVideoGeometry(codedSize: CGSize(width: 640, height: 480), pixelAspectRatio: ratio), "Invalid SAR is rejected")
}
check(!surface.setVideoGeometry(codedSize: CGSize(width: 640, height: 480), rotationDegrees: 45), "Non-quarter rotation is rejected")
check(surface.geometry == validGeometry, "Rejected geometry does not poison previous valid state")
for zoom in [0.0, -1, Double.nan, Double.infinity, 33] {
  check(!surface.setViewport(zoom: zoom), "Invalid zoom is rejected without silent clamping")
}
check(!surface.setViewport(pan: CGPoint(x: CGFloat.infinity, y: 0)), "Nonfinite pan is rejected")
check(!surface.setViewport(pan: CGPoint(x: 0, y: 1_048_577)), "Excessive pan is rejected without changing units")
check(surface.zoom == 1 && surface.pan == .zero, "Invalid viewport leaves valid state unchanged")
check(surface.setVideoGeometry(codedSize: CGSize(width: 64, height: 48), rotationDegrees: -90), "Negative quarter rotation normalizes safely")
check(surface.geometry?.rotationDegrees == 270, "Negative rotation preserves clockwise convention")
check(surface.setVideoGeometry(codedSize: CGSize(width: 64, height: 48), rotationDegrees: 720), "Multiple full rotations normalize safely")
check(surface.geometry?.rotationDegrees == 0, "Full rotation returns to identity")
surface.clearVideoGeometry()
check(sampleLayer.isHidden && surface.displayedVideoRect == nil, "Clearing source geometry hides stale presentation")
check(sampleLayer.animationKeys()?.isEmpty != false, "Geometry changes do not create implicit layer animations")
check(surface.detach() === sampleLayer, "Detach returns the exact attached layer")
check(sampleLayer.superlayer == nil, "Detach removes the surface's only ownership")
check(sampleLayer.bounds == originalBounds && sampleLayer.position == originalPosition,
  "Detach restores the original layer geometry")
check(sampleLayer.videoGravity == .resizeAspect && sampleLayer.contentsScale == 1.5,
  "Detach restores gravity and scale without issuing a renderer flush")
check(surface.detach() == nil, "Repeated detach is harmless")
let foreignHost = CALayer(), foreign = AVSampleBufferDisplayLayer()
foreignHost.addSublayer(foreign)
check(!surface.attach(foreign) && foreign.superlayer === foreignHost, "A foreign display layer is never stolen")
foreign.removeFromSuperlayer()

// Real-file direction proof: FFmpeg autorotation produces independent quadrant
// bytes. Production decoder metadata and actual CALayer point conversion must
// map each displayed source quadrant to that same reference quadrant.
let session = NativePlaybackSession()
let worker = Mirror(reflecting: session).children.first { $0.label == "worker" }!.value as! DispatchQueue
var latest: NativePlaybackSnapshot?
session.onSnapshot = { latest = $0 }
surface.setFrameSize(CGSize(width: 400, height: 300))
surface.clearVideoGeometry()
check(surface.attach(session.output.displayLayer), "Production output attaches without OpenGL or another clock")
var generation: UInt64 = 0
let sourcePoints = [(16, 12), (48, 12), (16, 36), (48, 36)]
let sourceYUV = [[63, 102, 240], [173, 42, 26], [32, 240, 118], [219, 16, 138]]
func displayedComponents() -> [[Int]]? {
  var finished = false
  var result: [[Int]]?
  worker.async {
    var values: [[Int]]?
    if session.output.actualRate == 0,
       let pixel = session.output.displayLayer.sampleBufferRenderer.displayedPixelBuffer(),
       CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
       CVPixelBufferGetWidth(pixel) == 64, CVPixelBufferGetHeight(pixel) == 48,
       CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess {
      if let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)?.assumingMemoryBound(to: UInt8.self),
         let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)?.assumingMemoryBound(to: UInt8.self) {
        values = sourcePoints.map { x, row in
          let offset = row / 2 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + x / 2 * 2
          return [Int(y[row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + x]), Int(uv[offset]), Int(uv[offset + 1])]
        }
      }
      CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
    }
    DispatchQueue.main.async { result = values; finished = true }
  }
  _ = waitUntil { finished }
  return result
}
for angle in [0, 90, 180, 270] {
  generation += 1
  session.open(fixtures.appendingPathComponent("rotation-\(angle).mp4"), autoplay: false)
  check(waitUntil { latest?.generation == generation && latest?.phase == .paused }, "Real rotated file \(angle) opens paused")
  guard let media = latest?.media else { check(false, "Decoded metadata exists"); continue }
  check(media.rotationDegrees == (360 - angle) % 360, "Decoder clockwise angle agrees with FFmpeg metadata convention for \(angle)")
  check(surface.setVideoGeometry(codedSize: CGSize(width: media.width, height: media.height),
    rotationDegrees: media.rotationDegrees), "Decoded source geometry drives the real layer for \(angle)")
  check(waitUntil { displayedComponents() == sourceYUV }, "Actual displayed buffer contains decoded quadrants for \(angle)")
  let reference = try Data(contentsOf: fixtures.appendingPathComponent("reference-\(angle).yuv"))
  let width = angle % 180 == 0 ? 64 : 48, height = angle % 180 == 0 ? 48 : 64
  check(reference.count == width * height * 3 / 2, "Independent autorotation reference has correct dimensions for \(angle)")
  guard let rectangle = surface.displayedVideoRect, let host = surface.layer else { continue }
  let video = session.output.displayLayer
  for (index, point) in sourcePoints.enumerated() {
    let local = CGPoint(x: CGFloat(point.0) / 64 * video.bounds.width,
      y: (1 - CGFloat(point.1) / 48) * video.bounds.height)
    let mapped = video.convert(local, to: host)
    let x = Int(((mapped.x - rectangle.minX) / rectangle.width * CGFloat(width)).rounded(.down))
    let y = Int(((rectangle.maxY - mapped.y) / rectangle.height * CGFloat(height)).rounded(.down))
    guard x >= 0, y >= 0, x < width, y < height else { check(false, "Mapped quadrant remains inside rotated bounds"); continue }
    let chroma = (y / 2) * (width / 2) + x / 2
    let values = [Int(reference[y * width + x]), Int(reference[width * height + chroma]),
      Int(reference[width * height * 5 / 4 + chroma])]
    check(values == sourceYUV[index], "Real CALayer clockwise mapping matches FFmpeg quadrant \(index) at \(angle)")
  }
  check(video.animationKeys()?.isEmpty != false, "Source rotation has no implicit animation for \(angle)")
}
// NSView's local cache is not a WindowServer capture. Inspect only our own
// synthetic surface to determine whether this API includes AVFoundation planes.
// Its result is diagnostic, not a substitute for displayed-buffer assertions.
if let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
  surface.cacheDisplay(in: surface.bounds, to: bitmap)
  let positions = [(bitmap.pixelsWide / 4, bitmap.pixelsHigh / 4),
    (bitmap.pixelsWide * 3 / 4, bitmap.pixelsHigh * 3 / 4)]
  let localRGB = positions.compactMap { x, y -> [Int]? in
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    return [Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded())]
  }
  print("LOCAL_CACHE_DIAGNOSTIC: rgb=\(localRGB); not composited-display acceptance")
}
surface.isHidden = true
surface.isHidden = false
check(surface.detach() === session.output.displayLayer, "Production display detaches independently of decoder shutdown")
var closed = false
session.shutdown { closed = true }
check(waitUntil { closed }, "Detached production session shuts down asynchronously")
window.orderOut(nil)
window.close()
let ownershipProbe = Process()
ownershipProbe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
ownershipProbe.arguments = ["--reject-worker-mutation"]
ownershipProbe.standardOutput = FileHandle.nullDevice
ownershipProbe.standardError = FileHandle.nullDevice
try ownershipProbe.run()
check(waitUntil(5) { !ownershipProbe.isRunning }, "Ownership negative probe ends without a UI wait")
if ownershipProbe.isRunning { ownershipProbe.terminate() }
else {
  check(ownershipProbe.terminationReason == .uncaughtSignal && [SIGILL, SIGTRAP].contains(ownershipProbe.terminationStatus),
    "A worker-thread surface mutation is rejected by the main-thread assertion")
}
watchdog.cancel()
print("Native surface checks: \(passed) passed, \(failed) failed. Layer geometry and displayed source pixels are verified, not physical-screen HDR or composited screenshots.")
exit(failed == 0 ? 0 : 1)
