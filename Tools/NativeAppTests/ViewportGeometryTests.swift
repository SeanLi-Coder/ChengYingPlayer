import AppKit
import AVFoundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
  checks += 1
  guard condition else { fatalError("FAIL: \(message)") }
}
// No window, app bundle, global events or installed application are needed.
// This validates the driver comparator against real production layer layout;
// it is not complete App event-routing or physical-screen presentation proof.
let surface = NativePlaybackSurface(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
let layer = AVSampleBufferDisplayLayer()
check(surface.attach(layer), "Production surface accepts the owned layer")
for angle in [0, 90, 180, 270] {
  check(surface.setVideoGeometry(codedSize: CGSize(width: 160, height: 96),
                                pixelAspectRatio: 1.25, rotationDegrees: angle), "Valid SAR/rotation")
  check(surface.setNormalizedViewport(zoom: 1.5, pan: CGPoint(x: -0.05 / 1.5, y: 0.05 / 1.5)), "Normalized pan accepted")
  func matches() -> Bool {
    ViewportComparator.matchesViewportLayout(surface, layer: layer, scale: 1.5,
                                             panX: -0.05 / 1.5, panY: 0.05 / 1.5)
  }
  check(matches(), "Correct production geometry is accepted")
  let originalBounds = layer.bounds
  layer.bounds.size.width += 2
  check(!matches(), "Wrong zoomed width is rejected")
  layer.bounds = originalBounds
  let originalPosition = layer.position
  layer.position.y = surface.bounds.midY - surface.pan.y
  check(!matches(), "Inverted pan direction is rejected")
  layer.position = originalPosition
  let originalTransform = layer.transform
  layer.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
  check(!matches(), "Wrong rotation is rejected")
  layer.transform = originalTransform
  let previousPan = surface.pan
  surface.setFrameSize(CGSize(width: 520, height: 330))
  check(matches(), "Resize recomputes normalized pan and fitted geometry")
  layer.position = CGPoint(x: surface.bounds.midX + previousPan.x, y: surface.bounds.midY + previousPan.y)
  check(!matches(), "Stale pre-resize point offsets are rejected")
  check(surface.setNormalizedViewport(zoom: 1.5, pan: CGPoint(x: -0.05 / 1.5, y: 0.05 / 1.5)), "Restore valid viewport")
  layer.videoGravity = .resizeAspect
  check(!matches(), "Second implicit aspect-fit is rejected")
  layer.videoGravity = .resize
  surface.resetViewport()
  check(ViewportComparator.matchesViewportLayout(surface, layer: layer, scale: 1, panX: 0, panY: 0),
        "Reset restores a centered fitted layer")
  surface.setFrameSize(CGSize(width: 640, height: 480))
}
check(surface.detach() === layer && layer.superlayer == nil, "Owned layer is detached")
print("Viewport geometry comparator: \(checks) checks passed; model-layer verification only.")
