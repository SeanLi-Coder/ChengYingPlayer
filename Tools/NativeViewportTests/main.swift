import AppKit
import AVFoundation

setbuf(stdout, nil)
var passed = 0, failed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() { passed += 1; print("PASS: \(message)") }
  else { failed += 1; print("FAIL: \(message)") }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.000001 }
func point(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
func rect(_ a: CGRect?, _ b: CGRect) -> Bool {
  guard let a else { return false }
  return point(a.origin, b.origin) && near(a.width, b.width) && near(a.height, b.height)
}
func runTests() {
guard NSScreen.main != nil else { print("UNVERIFIED: WindowServer unavailable"); exit(77) }
let player = PlayerCore()
let surface = player.mainWindow.videoView.surface
let sampleLayer = AVSampleBufferDisplayLayer()
check(surface.attach(sampleLayer), "Actual sample-buffer layer attaches to the production surface")
for rotation in [0, 90, 180, 270] {
  for geometry in [(CGSize(width: 1920, height: 1080), 1.0),
                   (CGSize(width: 720, height: 576), 16.0 / 15),
                   (CGSize(width: 1080, height: 1920), 1.0)] {
    check(surface.setVideoGeometry(codedSize: geometry.0, pixelAspectRatio: geometry.1,
      rotationDegrees: rotation), "Source geometry accepts rotation \(rotation)")
    let viewport = VideoToolsViewport(zoom: 1, panX: 0.1, panY: -0.15)
    check(player.applyNativeViewport(viewport), "Native transform commits without a playback command")
    for size in [CGSize(width: 800, height: 600), CGSize(width: 1200, height: 400), CGSize(width: 300, height: 800)] {
      surface.setFrameSize(size)
      let source = CGSize(width: geometry.0.width * geometry.1, height: geometry.0.height)
      let rotated = rotation == 90 || rotation == 270 ? CGSize(width: source.height, height: source.width) : source
      let fit = min(size.width / rotated.width, size.height / rotated.height)
      let displayed = CGSize(width: rotated.width * fit * 2, height: rotated.height * fit * 2)
      let offset = CGPoint(x: displayed.width * 0.1, y: displayed.height * 0.15)
      let center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
      check(point(surface.pan, offset), "Normalized pan tracks rotated fit dimensions after resize")
      check(point(sampleLayer.position, center), "MPV downward-positive Y maps to upward-positive surface points")
      check(rect(surface.displayedVideoRect, CGRect(x: center.x - displayed.width / 2,
        y: center.y - displayed.height / 2, width: displayed.width, height: displayed.height)),
        "Actual unclipped layer geometry matches independent fit and zoom math")
    }
  }
}
let valid = player.nativeViewport
let originBefore = surface.displayedVideoRect!
surface.setBoundsOrigin(CGPoint(x: 19, y: -13))
check(rect(surface.displayedVideoRect, originBefore.offsetBy(dx: 19, dy: -13)),
      "Nonzero bounds origin translates the normalized viewport exactly once")
surface.setBoundsOrigin(.zero)
surface.setFrameSize(.zero)
check(sampleLayer.isHidden && surface.displayedVideoRect == nil,
      "Zero-sized viewport hides presentation without losing normalized intent")
surface.setFrameSize(CGSize(width: 300, height: 800))
check(rect(surface.displayedVideoRect, originBefore),
      "Restoring viewport size reapplies its accepted normalized transform")
let acceptedRect = surface.displayedVideoRect
for invalidPan in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 0.51, y: 0)] {
  check(!surface.setNormalizedViewport(zoom: 2, pan: invalidPan), "Invalid normalized pan is rejected")
}
check(surface.displayedVideoRect == acceptedRect, "Rejected surface input preserves prior geometry")
player.mainWindow.videoView.accepts = false
check(player.videoToolsApplyViewportShortcut(.zoomIn) == nil && player.nativeViewport == valid,
      "Rejected surface update cannot commit a different logical viewport")
player.mainWindow.videoView.accepts = true
for state in [PlayerState.idle, .loading, .stopping, .shuttingDown, .shutDown] {
  player.info.state = state
  check(player.videoToolsApplyViewportShortcut(.zoomIn) == nil && player.nativeViewport == valid,
        "Inactive player rejects viewport commands in \(state)")
}
player.info.state = .paused
player.nativeRetiring = true
check(player.videoToolsApplyViewportShortcut(.zoomIn) == nil && player.nativeViewport == valid,
      "Retiring media rejects a late viewport command")
player.nativeRetiring = false
player.nativeReady = false
check(!player.applyNativeViewport(valid), "Unready media cannot mutate presentation")
player.nativeReady = true
player.nativeTerminationRequested = true
check(!player.applyNativeViewport(valid), "Terminal media cannot mutate presentation")
player.nativeTerminationRequested = false
player.videoToolsResetViewport()
check(player.nativeViewport.scale == 1 && surface.zoom == 1 && surface.pan == .zero,
      "Native reset returns the model and actual surface to fitted center")
surface.setFrameSize(CGSize(width: 640, height: 480))
check(surface.pan == .zero, "Reset does not revive old normalized pan on resize")
check(surface.setViewport(zoom: 2, pan: CGPoint(x: 20, y: -30)), "Existing point-based surface API remains available")
surface.setFrameSize(CGSize(width: 800, height: 600))
check(surface.pan == CGPoint(x: 20, y: -30), "Point-based pan keeps fixed points rather than fractions")
check(player.mpv.reads.isEmpty && player.mpv.writes.isEmpty, "Native geometry and controls do not read or write idle MPV")

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let input = InputSurface(frame: window.contentLayoutRect)
window.contentView = input
let controller = Controller(player: player, window: window)
window.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
window.makeFirstResponder(input)
let deadline = ProcessInfo.processInfo.systemUptime + 3
while NSApp.keyWindow !== window && ProcessInfo.processInfo.systemUptime < deadline {
  while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
    NSApp.sendEvent(event)
  }
  if NSApp.isActive { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(input) }
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
check(NSApp.keyWindow === window, "Synthetic shortcut test owns its own key window")
func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool {
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
    isARepeat: false, keyCode: code)!
  return controller.handleVideoToolsShortcutEvent(event)
}
player.videoToolsResetViewport()
let frame = window.frame
for _ in 0..<10 { _ = key(24) }
check(near(player.nativeViewport.scale, 2), "Ten real shortcut dispatches accumulate native scale to 2x")
check(key(126, [.command, .shift]) && player.nativeViewport.panY < 0 && surface.pan.y > 0,
      "Up shortcut moves the native picture upward")
check(key(124, [.command, .shift]) && player.nativeViewport.panX > 0 && surface.pan.x > 0,
      "Right shortcut moves the native picture rightward")
check(key(123, [.command, .shift]) && near(player.nativeViewport.panX, 0), "Left shortcut reverses right pan")
check(key(125, [.command, .shift]) && near(player.nativeViewport.panY, 0), "Down shortcut reverses up pan")
check(player.compatibilityCalls == 0 && player.isUsingNativePlayback,
      "Native viewport shortcuts never request MPV compatibility")
check(window.frame == frame, "Viewport shortcuts move the picture without resizing its window")
for _ in 0..<100 { _ = key(24) }
check(player.nativeViewport.scale == 8, "Repeated zoom-in retains the existing 8x ceiling")
for _ in 0..<100 { _ = key(27) }
check(player.nativeViewport.scale == 0.2 && player.nativeViewport.panX == 0 && player.nativeViewport.panY == 0,
      "Repeated zoom-out retains the existing 0.2x floor and recenters")
check(key(29, [.command, .shift]) && player.nativeViewport.scale == 1 && surface.pan == .zero,
      "Reset keyboard command restores aspect fit directly in native")
let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
input.addSubview(field)
window.makeFirstResponder(field)
check(!key(24) && player.nativeViewport.scale == 1, "Text entry keeps ownership of zoom-like keystrokes")
window.makeFirstResponder(input)
player.mainWindow.isInInteractiveMode = true
check(!key(24), "Interactive editing retains existing shortcut exclusion")
player.mainWindow.isInInteractiveMode = false
check(player.mpv.reads.isEmpty && player.mpv.writes.isEmpty && !player.osds.isEmpty,
      "Native shortcut feedback does not touch MPV properties")
window.close()

player.nativeTransport = nil
let handoff = VideoToolsViewport(zoom: log2(1.7), panX: 0.12, panY: -0.08)
player.videoToolsRestoreViewportToMPV(handoff)
check(player.mpv.values[MPVOption.Video.videoZoom] == handoff.zoom &&
      player.mpv.values[MPVOption.Video.videoPanX] == handoff.panX &&
      player.mpv.values[MPVOption.Video.videoPanY] == handoff.panY,
      "Compatibility restore writes log2 zoom and unchanged MPV pan fractions")
player.mpv.writes = []; player.mpv.reads = []
let next = player.videoToolsApplyViewportShortcut(.zoomIn)
check(near(next?.scale ?? 0, 1.8) && player.mpv.reads.count == 3 && player.mpv.writes.count == 3,
      "Legacy MPV shortcut behavior retains three reads and three presentation writes")
player.videoToolsResetViewport()
check(player.mpv.values[MPVOption.Video.videoZoom] == 0 && player.mpv.values[MPVOption.Video.videoPanX] == 0 &&
      player.mpv.values[MPVOption.Video.videoPanY] == 0, "Legacy reset retains zero MPV properties")
player.info.state = .stopping
let writes = player.mpv.writes.count
player.videoToolsRestoreViewportToMPV(handoff)
check(player.mpv.writes.count == writes, "Compatibility viewport cannot write after media stops")
print("Native viewport: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
}

final class TestApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async { runTests() }
  }
}
let applicationDelegate = TestApplicationDelegate()
_ = NSApplication.shared
NSApp.delegate = applicationDelegate
NSApp.setActivationPolicy(.regular)
NSApp.run()
