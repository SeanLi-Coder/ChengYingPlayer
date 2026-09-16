import Cocoa

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL: \(message)")
  }
}
func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 1e-10 }
func require(_ value: VideoToolsViewport?, _ message: String) -> VideoToolsViewport {
  guard let value else { fatalError(message) }
  return value
}
func valid(_ viewport: VideoToolsViewport, _ message: String) {
  check(viewport.scale.isFinite && (0.2...8).contains(viewport.scale), "\(message): scale remains bounded")
  check(viewport.zoom.isFinite, "\(message): mpv logarithmic zoom remains finite")
  let coverageLimit = max(0, (1 - 1 / viewport.scale) / 2)
  check(viewport.panX.isFinite && abs(viewport.panX) <= coverageLimit + 1e-12,
        "\(message): horizontal pan keeps the original fitted rectangle covered")
  check(viewport.panY.isFinite && abs(viewport.panY) <= coverageLimit + 1e-12,
        "\(message): vertical pan keeps the original fitted rectangle covered")
}

let original = VideoToolsViewport(zoom: 0, panX: 0, panY: 0)
check(original.scale == 1 && original.zoom == 0, "The opened video's fitted view is exactly 100 percent")
let enlarged = require(original.applying(.zoomIn), "Zoom-in must resolve")
check(close(enlarged.scale, 1.1), "One equal-key press enlarges the picture to 110 percent")
check(close(require(enlarged.applying(.zoomIn), "Second zoom-in").scale, 1.2), "Two equal-key presses reach 120 percent")
check(close(require(original.applying(.zoomOut), "Zoom-out").scale, 0.9), "One minus-key press shrinks the picture to 90 percent")
check(close(require(enlarged.applying(.zoomOut), "Undo zoom").scale, 1), "Opposite zoom steps return to the original fitted view")
check(close(require(VideoToolsViewport(zoom: log2(0.65), panX: 0, panY: 0).applying(.zoomIn), "Arbitrary zoom").scale, 0.75),
      "An imported non-tenth zoom gains 10 percentage points without snapping")

var zoomed = original
for index in 0..<100 {
  zoomed = require(zoomed.applying(.zoomIn), "Repeated zoom-in")
  valid(zoomed, "Zoom-in step \(index)")
}
check(zoomed.scale == 8, "Repeated enlargement stops at 800 percent")
for index in 0..<100 {
  zoomed = require(zoomed.applying(.zoomOut), "Repeated zoom-out")
  valid(zoomed, "Zoom-out step \(index)")
}
check(zoomed.scale == 0.2, "Repeated reduction stops at 20 percent")

let doubled = VideoToolsViewport(zoom: 1, panX: 0, panY: 0)
let directions: [(VideoToolsShortcuts.Action, Double, Double)] = [
  (.panLeft, -0.025, 0), (.panRight, 0.025, 0), (.panUp, 0, -0.025), (.panDown, 0, 0.025)
]
for (action, x, y) in directions {
  let result = require(doubled.applying(action), "Pan action")
  check(result.scale == 2 && close(result.panX, x) && close(result.panY, y), "Pan direction moves the picture in the requested direction: \(action)")
  check(require(original.applying(action), "Original-view pan") == original, "An unzoomed picture cannot be pushed away: \(action)")
  var edge = doubled
  for _ in 0..<100 { edge = require(edge.applying(action), "Repeated pan") }
  valid(edge, "Pan edge \(action)")
  check(close(abs(edge.panX) + abs(edge.panY), 0.25), "Pan clamps exactly to the visible edge at 200 percent: \(action)")
  let shrunk = require(edge.applying(.zoomOut), "Shrink panned image")
  valid(shrunk, "Shrinking a panned image \(action)")
  check(abs(shrunk.panX) + abs(shrunk.panY) < 0.25, "Shrinking also contracts the pan range: \(action)")
  check(require(edge.applying(.resetViewport), "Reset viewport") == original, "Reset restores size and both axes: \(action)")
}
let fourTimes = require(VideoToolsViewport(zoom: 2, panX: 0, panY: 0).applying(.panRight), "Pan at 400 percent")
check(close(fourTimes.panX * fourTimes.scale, 0.05), "Pan distance stays at five percent of the original fitted width at 400 percent")
var panned = VideoToolsViewport(zoom: 1, panX: 0.25, panY: -0.25)
for _ in 0..<10 { panned = require(panned.applying(.zoomOut), "Return to normal view") }
check(panned == original, "Shrinking to 100 percent automatically recenters both axes")
check(VideoToolsViewport(zoom: -1, panX: 3, panY: -3).panX == 0,
      "A smaller-than-normal imported view also recenters")

for invalid in [Double.nan, Double.infinity, -Double.infinity] {
  let sanitized = VideoToolsViewport(zoom: invalid, panX: invalid, panY: invalid)
  check(sanitized == original, "Non-finite imported transforms return to a safe original view")
  valid(sanitized, "Non-finite transform")
}
check(VideoToolsViewport(zoom: Double.greatestFiniteMagnitude, panX: 10, panY: -10).scale == 8,
      "Extreme imported zoom cannot overflow the renderer")
check(VideoToolsViewport(zoom: -Double.greatestFiniteMagnitude, panX: 10, panY: -10).scale == 0.2,
      "Extreme negative imported zoom cannot underflow to a zero-size picture")
for unrelated: VideoToolsShortcuts.Action in [.speedUp, .speedDown, .rotateLeft, .rotateRight, .setA, .setB, .consume] {
  check(original.applying(unrelated) == nil, "Viewport model declines unrelated action \(unrelated)")
}

let viewportKeys: Set<String> = [MPVOption.Video.videoZoom, MPVOption.Video.videoPanX, MPVOption.Video.videoPanY]
let viewActions: [VideoToolsShortcuts.Action] = [.zoomIn, .zoomOut, .panLeft, .panRight, .panUp, .panDown, .resetViewport]
func unchangedPlayback(_ player: PlayerCore, _ message: String) {
  check(player.mpv.values[MPVOption.PlaybackControl.speed] as? Double == 1.4, "\(message): playback speed is preserved")
  check(player.mpv.values[MPVProperty.timePos] as? Double == 15, "\(message): playhead is preserved")
  check(player.mpv.values[MPVOption.PlaybackControl.pause] as? Bool == false, "\(message): play/pause is preserved")
  check(player.mpv.values[MPVOption.PlaybackControl.abLoopA] as? String == "10"
        && player.mpv.values[MPVOption.PlaybackControl.abLoopB] as? String == "20"
        && player.mpv.values[MPVOption.PlaybackControl.abLoopCount] as? String == "inf", "\(message): A-B loop is preserved")
  check(player.mpv.values[MPVOption.Video.videoRotate] as? Int == 0, "\(message): permanent rotation state is preserved")
  check(player.seeks.isEmpty && player.speedChanges.isEmpty && player.pauseChanges == 0 && player.abSyncs == 0,
        "\(message): no seek, speed, pause or loop side effects occur")
}
for action in viewActions {
  let player = PlayerCore()
  player.mpv.values[MPVOption.Video.videoZoom] = 1.0
  let result = player.videoToolsApplyViewportShortcut(action)
  check(result != nil, "Production player bridge accepts loaded-video action \(action)")
  check(Set(player.mpv.reads) == viewportKeys && player.mpv.reads.count == 3,
        "Bridge reads the live renderer transform, not cached UI state: \(action)")
  check(Set(player.mpv.writes.map(\.0)) == viewportKeys && player.mpv.writes.count == 3,
        "Bridge writes only the three video presentation properties: \(action)")
  unchangedPlayback(player, "Bridge \(action)")
}
for state in [PlayerState.loading, .starting, .stopping, .idle, .shuttingDown, .shutDown] {
  for action in viewActions {
    let player = PlayerCore()
    player.info.state = state
    check(player.videoToolsApplyViewportShortcut(action) == nil, "Unloaded/shutting-down player rejects \(action) in \(state)")
    player.videoToolsResetViewport()
    check(player.mpv.reads.isEmpty && player.mpv.writes.isEmpty, "No mpv access occurs in unsafe player state \(state)")
  }
}
for track: Int? in [nil, 0, -1] {
  let player = PlayerCore()
  player.info.vid = track
  check(player.videoToolsApplyViewportShortcut(.zoomIn) == nil, "No video track means no viewing transform")
  check(player.mpv.reads.isEmpty && player.mpv.writes.isEmpty, "Audio-only playback cannot read or change video rendering properties")
}
for state in [PlayerState.loaded, .playing, .paused] {
  let player = PlayerCore()
  player.info.state = state
  check(player.videoToolsApplyViewportShortcut(.zoomIn) != nil, "Loaded video accepts transforms in \(state)")
}
let repair = PlayerCore()
repair.mpv.values[MPVOption.Video.videoZoom] = Double.nan
repair.mpv.values[MPVOption.Video.videoPanX] = Double.infinity
repair.mpv.values[MPVOption.Video.videoPanY] = -Double.infinity
valid(require(repair.videoToolsApplyViewportShortcut(.zoomIn), "Invalid live state"), "Invalid live state repair")
let unrelated = PlayerCore()
check(unrelated.videoToolsApplyViewportShortcut(.speedUp) == nil && unrelated.mpv.writes.isEmpty,
      "The bridge never interprets playback actions as a viewing transform")
let reset = PlayerCore()
reset.mpv.values[MPVOption.Video.videoZoom] = 2.0
reset.mpv.values[MPVOption.Video.videoPanX] = 0.2
reset.mpv.values[MPVOption.Video.videoPanY] = -0.2
reset.videoToolsResetViewport()
check(viewportKeys.allSatisfy { reset.mpv.values[$0] as? Double == 0 }, "A new-file viewport reset clears the renderer's zoom and pan")
unchangedPlayback(reset, "New-file reset")

// These are actual AppKit windows, field editors, sheets and NSEvent instances.
// No global event taps, key injection, user preferences or playback files are used.
_ = NSApplication.shared
NSApp.setActivationPolicy(.regular)
NSApp.finishLaunching()
NSApp.activate(ignoringOtherApps: true)
let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 420),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Video Viewport Regression"
window.isReleasedWhenClosed = false
let surface = PlaybackSurface(frame: window.contentView!.bounds)
window.contentView = surface
let controller = PlayerWindowController(window: window)
window.windowController = controller
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(surface)
func settle(_ seconds: Double = 0.15) {
  let deadline = Date(timeIntervalSinceNow: seconds)
  repeat {
    while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
      NSApp.sendEvent(event)
    }
    RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.01)))
  } while Date() < deadline
}
settle()
check(NSApp.keyWindow === window, "The fixture owns a real key playback window")
let frame = window.frame
func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, characters: "", charactersIgnoringModifiers: "",
                  isARepeat: repeated, keyCode: code)!
}
PlayerCore.keyBindings = ["key-24": KeyBinding(action: "window-scale"), "key-27": KeyBinding(action: "window-scale")]
controller.keyDown(with: key(24))
check(close(pow(2, controller.player.mpv.getDouble(MPVOption.Video.videoZoom)), 1.1),
      "Actual equal-key event uses video zoom")
controller.keyDown(with: key(27))
check(close(pow(2, controller.player.mpv.getDouble(MPVOption.Video.videoZoom)), 1),
      "Actual minus-key event restores video size")
check(controller.legacyBindings.isEmpty && PluginInputManager.dispatches == 0,
      "Viewport shortcuts run before legacy window-scale bindings and plugins")
check(window.frame == frame, "Zooming never moves or resizes the containing NSWindow")
check(controller.player.osds.count == 2, "Zoom shortcuts show immediate on-screen feedback")
if case .custom(let message) = controller.player.osds.last {
  check(!message.contains("videotools.viewport.status") && message.contains("100"), "OSD resolves localized zoom feedback")
} else {
  check(false, "Zoom OSD is a localized custom message")
}
controller.player.mpv.values[MPVOption.Video.videoZoom] = 1.0
let commandShiftArrows: NSEvent.ModifierFlags = [.command, .shift, .numericPad, .function]
for (code, expectedX, expectedY): (UInt16, Double, Double) in [(123, -0.025, 0), (124, 0.025, 0), (126, 0, -0.025), (125, 0, 0.025)] {
  controller.player.mpv.values[MPVOption.Video.videoPanX] = 0.0
  controller.player.mpv.values[MPVOption.Video.videoPanY] = 0.0
  controller.keyDown(with: key(code, commandShiftArrows))
  check(close(controller.player.mpv.getDouble(MPVOption.Video.videoPanX), expectedX)
        && close(controller.player.mpv.getDouble(MPVOption.Video.videoPanY), expectedY),
        "Real Command-Shift-arrow event pans in the expected direction: \(code)")
  check(window.frame == frame, "Arrow pan cannot move the video window: \(code)")
}
controller.keyDown(with: key(29, [.command, .shift]))
check(viewportKeys.allSatisfy { controller.player.mpv.values[$0] as? Double == 0 },
      "Command-Shift-0 restores the original fitted size and centered position")
let writesBeforeRepeat = controller.player.mpv.writes.count
controller.keyDown(with: key(29, [.command, .shift], repeated: true))
check(controller.player.mpv.writes.count == writesBeforeRepeat, "A held reset key is consumed without redundant viewport updates")
unchangedPlayback(controller.player, "Native keyboard path")
check(controller.player.mainWindow.sidebarPresentations == 0
      && controller.player.mainWindow.quickSettingView.shortcuts.isEmpty, "Viewing transforms never trigger edit/export tools")

let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
surface.addSubview(textView)
window.makeFirstResponder(textView)
check(window.firstResponder === textView, "The fixture installs a real text responder")
let writesBeforeInput = controller.player.mpv.writes.count
for event in [key(24), key(27), key(124, commandShiftArrows)] {
  check(!controller.handleVideoToolsShortcutEvent(event), "Text input and text navigation remain available to the editor")
}
check(controller.player.mpv.writes.count == writesBeforeInput, "Typing in text editors never transforms the video")
window.makeFirstResponder(surface)
textView.removeFromSuperview()
let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
surface.addSubview(field)
window.makeFirstResponder(field)
check(window.firstResponder is NSTextInputClient, "An NSTextField uses the real shared field editor")
check(!controller.handleVideoToolsShortcutEvent(key(24)), "Native field editing does not intercept the equal key")
window.makeFirstResponder(surface)
field.removeFromSuperview()

let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                     styleMask: [.titled], backing: .buffered, defer: false)
sheet.isReleasedWhenClosed = false
window.beginSheet(sheet)
settle()
check(window.attachedSheet === sheet, "The fixture presents a real attached sheet")
check(!controller.handleVideoToolsShortcutEvent(key(24)), "Dialog sheets cannot trigger video zoom")
window.endSheet(sheet)
sheet.orderOut(nil)
settle()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(surface)
controller.player.mainWindow.isInInteractiveMode = true
check(!controller.handleVideoToolsShortcutEvent(key(24)), "Interactive crop mode retains its own keyboard interaction")
controller.player.mainWindow.isInInteractiveMode = false
let second = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
second.isReleasedWhenClosed = false
second.makeKeyAndOrderFront(nil)
settle()
check(NSApp.keyWindow === second, "A second native window can hold keyboard focus")
check(!controller.handleVideoToolsShortcutEvent(key(24)), "A background player cannot steal another window's shortcut")
second.orderOut(nil)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(surface)
settle()

controller.player.info.vid = nil
let audioReads = controller.player.mpv.reads.count
let audioWrites = controller.player.mpv.writes.count
controller.keyDown(with: key(24))
check(controller.player.mpv.reads.count == audioReads && controller.player.mpv.writes.count == audioWrites,
      "Audio-only equal-key presses do not access video properties")
check(controller.legacyBindings.isEmpty && window.frame == frame,
      "Audio-only viewport keys do not fall through to legacy window resizing")
controller.player.info.vid = 1
controller.player.info.state = .idle
check(!controller.handleVideoToolsShortcutEvent(key(24)), "An idle player does not claim viewing shortcuts")
controller.player.info.state = .playing
check(!controller.handleVideoToolsShortcutEvent(key(24, .command)), "Command-equal remains available to other app commands")
check(!controller.handleVideoToolsShortcutEvent(key(123)), "Plain arrow keys retain playback navigation")
controller.keyDown(with: key(49))
check(controller.fallbackEvents == 1 && PluginInputManager.dispatches == 1,
      "Unrelated keys still reach the existing plugin and responder path")
check(window.frame == frame, "All viewport keyboard operations preserve the initial native window frame")
window.orderOut(nil)
window.close()
second.close()
sheet.close()
print("Video viewport tests: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
