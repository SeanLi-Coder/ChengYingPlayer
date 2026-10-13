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
func runNativeTests() -> Never {
let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 420),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Video Viewport Regression"
window.isReleasedWhenClosed = false
let surface = PlaybackSurface(frame: window.contentView!.bounds)
window.contentView = surface
let controller = PlayerWindowController(window: window)
window.windowController = controller
func settle(_ seconds: Double = 0.15) {
  let deadline = Date(timeIntervalSinceNow: seconds)
  repeat {
    while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
      NSApp.sendEvent(event)
    }
    RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.01)))
  } while Date() < deadline
}
func waitFor(_ message: String, timeout: Double = 10, condition: () -> Bool) {
  let deadline = ProcessInfo.processInfo.systemUptime + timeout
  while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
    settle(0.02)
  }
  guard condition() else {
    let keyNumber = NSApp.keyWindow?.windowNumber ?? -1
    print("FAIL: \(message); active=\(NSApp.isActive), keyWindow=\(keyNumber)")
    print("Video viewport tests: \(checks) checks, \(failures + 1) failures")
    exit(1)
  }
}
func focus(_ target: NSWindow, responder: NSResponder? = nil) {
  target.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
  // Activation is asynchronous on a newly launched GUI process. Wait for the
  // real application state before requesting the window's keyboard ownership.
  waitFor("The native fixture application becomes active") { NSApp.isActive }
  target.makeKeyAndOrderFront(nil)
  if let responder { target.makeFirstResponder(responder) }
  waitFor("The requested native window owns keyboard focus") {
    NSApp.keyWindow === target && target.isKeyWindow
      && (responder == nil || target.firstResponder === responder)
  }
  settle()
}
focus(window, responder: surface)
check(NSApp.keyWindow === window, "The fixture owns a real key playback window")
let frame = window.frame
func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
  let arrowCharacters: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                      125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
  let characters = arrowCharacters[code].flatMap(UnicodeScalar.init).map(String.init) ?? ""
  return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
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
let shiftArrows: NSEvent.ModifierFlags = [.shift, .numericPad, .function]
let arrowDirections: [(UInt16, Double, Double)] = [(123, 0.025, 0), (124, -0.025, 0), (125, 0, -0.025), (126, 0, 0.025)]
for (code, expectedX, expectedY) in arrowDirections {
  for intrinsicFlags: NSEvent.ModifierFlags in [[], .numericPad, .function, [.numericPad, .function]] {
    for capsLock: NSEvent.ModifierFlags in [[], .capsLock] {
      let modifiers = intrinsicFlags.union(.shift).union(capsLock)
      controller.player.mpv.values[MPVOption.Video.videoPanX] = 0.0
      controller.player.mpv.values[MPVOption.Video.videoPanY] = 0.0
      controller.keyDown(with: key(code, modifiers))
      check(close(controller.player.mpv.getDouble(MPVOption.Video.videoPanX), expectedX)
            && close(controller.player.mpv.getDouble(MPVOption.Video.videoPanY), expectedY),
            "Real Shift-arrow event reverses the previous pan direction: \(code), flags \(modifiers.rawValue)")
      controller.keyDown(with: key(code, modifiers, repeated: true))
      check(close(controller.player.mpv.getDouble(MPVOption.Video.videoPanX), expectedX * 2)
            && close(controller.player.mpv.getDouble(MPVOption.Video.videoPanY), expectedY * 2),
            "Held Shift-arrow continues in the reversed direction: \(code), flags \(modifiers.rawValue)")
      check(window.frame == frame, "Arrow pan cannot move the video window: \(code)")
    }
    let readsBeforeRejectedArrow = controller.player.mpv.reads.count
    let writesBeforeRejectedArrow = controller.player.mpv.writes.count
    for modifiers: NSEvent.ModifierFlags in [intrinsicFlags, intrinsicFlags.union([.command, .shift]),
                                            intrinsicFlags.union([.option, .shift]), intrinsicFlags.union([.control, .shift])] {
      check(!controller.handleVideoToolsShortcutEvent(key(code, modifiers)),
            "Ordinary or additionally modified arrows retain their existing bindings: \(code), flags \(modifiers.rawValue)")
    }
    check(controller.player.mpv.reads.count == readsBeforeRejectedArrow
          && controller.player.mpv.writes.count == writesBeforeRejectedArrow,
          "Rejected arrow combinations never access viewport properties: \(code)")
  }
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
for event in [key(24), key(27)] + arrowDirections.map({ key($0.0, shiftArrows) }) {
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
for (code, _, _) in arrowDirections {
  check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows)),
        "The native field editor retains Shift-arrow text selection: \(code)")
}
window.makeFirstResponder(surface)
field.removeFromSuperview()

final class FixtureTableDataSource: NSObject, NSTableViewDataSource {
  let rows = ["Fixture A", "Fixture B", "Fixture C", "Fixture D"]
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { rows[row] }
}
func preservesControlArrows(_ control: NSView, _ context: String) {
  check(window.makeFirstResponder(control) && window.firstResponder === control,
        "The native \(context) owns keyboard focus")
  let reads = controller.player.mpv.reads.count
  let writes = controller.player.mpv.writes.count
  for (code, _, _) in arrowDirections {
    for repeated in [false, true] {
      check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows, repeated: repeated)),
            "The native \(context) retains Shift-arrow input: \(code), repeat \(repeated)")
    }
  }
  check(controller.player.mpv.reads.count == reads && controller.player.mpv.writes.count == writes,
        "Shift-arrow input in \(context) never reads or writes viewport properties")
}
let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 260, height: 140))
table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture-name")))
table.allowsMultipleSelection = true
let tableDataSource = FixtureTableDataSource()
table.dataSource = tableDataSource
surface.addSubview(table)
table.reloadData()
table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
preservesControlArrows(table, "file table")
let extendSelection = key(125, shiftArrows)
if !controller.handleVideoToolsShortcutEvent(extendSelection) { table.keyDown(with: extendSelection) }
check(table.selectedRowIndexes == IndexSet(integersIn: 1...2),
      "A real table Shift-Down event extends the selected range without losing the original row")
check(table.numberOfRows == 4 && tableDataSource.rows == ["Fixture A", "Fixture B", "Fixture C", "Fixture D"],
      "Shift-arrow range selection preserves all table data")
let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 140))
let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture-outline"))
outline.addTableColumn(outlineColumn)
outline.outlineTableColumn = outlineColumn
let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 260, height: 140))
collection.isSelectable = true
let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
slider.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
for (control, context): (NSView, String) in [(table, "file table"), (outline, "folder outline"),
                                          (collection, "collection view"), (slider, "slider control")] {
  if control.superview == nil { surface.addSubview(control) }
  preservesControlArrows(control, context)
  let child = PlaybackSurface(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
  control.addSubview(child)
  preservesControlArrows(child, "\(context) descendant")
  window.makeFirstResponder(surface)
  child.removeFromSuperview()
  control.removeFromSuperview()
}
check(window.makeFirstResponder(surface), "Playback regains focus after native controls")
let resumedPanWrites = controller.player.mpv.writes.count
check(controller.handleVideoToolsShortcutEvent(key(124, shiftArrows)),
      "Shift-arrow panning resumes when focus returns to the video surface")
check(controller.player.mpv.writes.count == resumedPanWrites + 3,
      "Returning to the video surface restores the production viewport bridge")

let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                     styleMask: [.titled], backing: .buffered, defer: false)
sheet.isReleasedWhenClosed = false
window.beginSheet(sheet)
settle()
check(window.attachedSheet === sheet, "The fixture presents a real attached sheet")
check(!controller.handleVideoToolsShortcutEvent(key(24)), "Dialog sheets cannot trigger video zoom")
for (code, _, _) in arrowDirections {
  check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows)), "Dialog sheets retain Shift-arrow navigation: \(code)")
}
window.endSheet(sheet)
sheet.orderOut(nil)
waitFor("The real dialog sheet finishes detaching") { window.attachedSheet == nil }
focus(window, responder: surface)
controller.player.mainWindow.isInInteractiveMode = true
check(!controller.handleVideoToolsShortcutEvent(key(24)), "Interactive crop mode retains its own keyboard interaction")
for (code, _, _) in arrowDirections {
  check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows)), "Interactive crop mode retains Shift-arrow input: \(code)")
}
controller.player.mainWindow.isInInteractiveMode = false
let second = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: false)
second.isReleasedWhenClosed = false
focus(second)
check(NSApp.keyWindow === second, "A second native window can hold keyboard focus")
check(!controller.handleVideoToolsShortcutEvent(key(24)), "A background player cannot steal another window's shortcut")
for (code, _, _) in arrowDirections {
  check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows)), "A background player cannot steal Shift-arrow input: \(code)")
}
second.orderOut(nil)
focus(window, responder: surface)

controller.player.info.vid = nil
let audioReads = controller.player.mpv.reads.count
let audioWrites = controller.player.mpv.writes.count
controller.keyDown(with: key(24))
for (code, _, _) in arrowDirections { controller.keyDown(with: key(code, shiftArrows)) }
check(controller.player.mpv.reads.count == audioReads && controller.player.mpv.writes.count == audioWrites,
      "Audio-only zoom and Shift-arrow presses do not access video properties")
check(controller.legacyBindings.isEmpty && window.frame == frame,
      "Audio-only viewport keys do not fall through to legacy window resizing")
controller.player.info.vid = 1
controller.player.info.state = .idle
check(!controller.handleVideoToolsShortcutEvent(key(24)), "An idle player does not claim viewing shortcuts")
for (code, _, _) in arrowDirections {
  check(!controller.handleVideoToolsShortcutEvent(key(code, shiftArrows)), "An idle player does not claim Shift-arrow input: \(code)")
}
controller.player.info.state = .playing
check(!controller.handleVideoToolsShortcutEvent(key(24, .command)), "Command-equal remains available to other app commands")
check(!controller.handleVideoToolsShortcutEvent(key(123)), "Plain arrow keys retain playback navigation")
controller.keyDown(with: key(49))
check(controller.fallbackEvents == 1 && PluginInputManager.dispatches == 1,
      "Unrelated keys still reach the existing plugin and responder path")
let ordinaryArrowBindings: [(UInt16, String)] = [(123, "seek -5"), (124, "seek 5"), (125, "add volume -5"), (126, "add volume 5")]
let plainArrowReads = controller.player.mpv.reads.count
let plainArrowWrites = controller.player.mpv.writes.count
for (code, action) in ordinaryArrowBindings {
  PlayerCore.keyBindings["key-\(code)"] = KeyBinding(action: action)
  let previousBindingCount = controller.legacyBindings.count
  controller.keyDown(with: key(code, [.numericPad, .function]))
  check(controller.legacyBindings.count == previousBindingCount + 1 && controller.legacyBindings.last?.action == action,
        "Plain arrow reaches its existing seek or volume binding through production dispatch: \(code)")
}
check(controller.player.mpv.reads.count == plainArrowReads && controller.player.mpv.writes.count == plainArrowWrites,
      "Plain seek and volume arrows never access viewport properties")
check(window.frame == frame, "All viewport keyboard operations preserve the initial native window frame")
window.orderOut(nil)
window.close()
second.close()
sheet.close()
print("Video viewport tests: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
}

final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Enter the normal event loop before creating windows or activating the app.
    DispatchQueue.main.async { runNativeTests() }
  }
}
let fixtureDelegate = FixtureApplicationDelegate()
_ = NSApplication.shared
NSApp.delegate = fixtureDelegate
NSApp.setActivationPolicy(.regular)
NSApp.run()
fatalError("The native fixture event loop stopped before its assertions completed")
