import Foundation

// Test the production event and resize method bodies, not a rewritten policy.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
func source(_ name: String) throws -> String {
  try String(contentsOf: root.appendingPathComponent("iina/\(name).swift"), encoding: .utf8)
}
func section(_ text: String, _ start: String, _ end: String) -> String {
  guard let begin = text.range(of: start)?.lowerBound,
        let finish = text.range(of: end, range: begin..<text.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(text[begin..<finish])
}
let base = try source("PlayerWindowController")
let main = try source("MainWindowController")
let mini = try source("MiniPlayerWindowController")
let data = try source("AppData")
let extensions = try source("Extensions")
let declarations = section(base, "  // Scroll direction", "  /** This variable is true when the window ready")
let scrolling = section(base, "  override func scrollWheel(with event:", "  /**\n   Being called to perform single click action")
let mainScrolling = section(main, "  override func scrollWheel(with event:", "  override func mouseEntered(with event:")
let miniScrolling = section(mini, "  override func scrollWheel(with event:", "  override func mouseEntered(with event:")
let mainResize = section(main, "  func windowDidEndLiveResize(", "  func windowDidChangeBackingProperties(")
let miniResize = section(mini, "  func windowDidEndLiveResize(", "  // MARK: - Window delegate: Activeness status")
let arrays = section(data, "  static let seekAmountMap =", "  static let encodings =")
let clamp = section(extensions, "extension Comparable {", "// Formats a number to max 2 digits")
let unified = section(extensions, "extension CGFloat {\n  var unifiedDouble:", "\nextension Double {\n  func prettyFormat()")
let code = """
import Cocoa

\(clamp)
\(unified)
enum AppData {
\(arrays)
}
class ScrollControllerUnderTest: NSResponder {
  let player = PlayerCore()
  let volumeSlider = NSSlider()
  var relativeSeekAmount = 3
  var volumeScrollAmount = 3
  var playbackSpeedScrollAmount = 3
  var useExactSeek = Preference.SeekOption.exact
  var horizontalScrollAction = Preference.ScrollAction.seek
  var verticalScrollAction = Preference.ScrollAction.volume
\(declarations)
\(scrolling)
}
final class MainWindowUnderTest: ScrollControllerUnderTest {
  var isInInteractiveMode = false
  var isMomentumScrollingAllowed = true
  var isMouseInWindow = true
  let playSlider = NSSlider()
  let fragSliderView = NSView()
  let fragVolumeView = NSView()
  let currentControlBar = NSView()
  let cornerControls = NSView()
  let sideBarView = NSView()
  let titleBarView = NSView()
  let subPopoverView = NSView()
  var hitView: NSView?
  let videoView = VideoView()
  var parameterUpdates = 0
  func updateWindowParametersForMPV() { parameterUpdates += 1 }
  func isMouseEvent(_ event: NSEvent, inAnyOf views: [NSView?]) -> Bool {
    views.contains { $0 != nil && $0 === hitView }
  }
\(mainScrolling)
\(mainResize)
}
final class MiniPlayerWindowController: ScrollControllerUnderTest {
  let playSlider = NSSlider()
  let volumeSliderView = NSView()
  let backgroundView = NSView()
  var hitView: NSView?
  var popoverEvents: [(Bool, Bool, Bool)] = []
  let videoView = VideoView()
  var window: NSWindow?
  var isPlaylistVisible = false
  let AutoHidePlaylistThreshold: CGFloat = 10
  func normalWindowHeight() -> CGFloat { 100 }
  func setToInitialWindowSize() {}
  func handleVolumePopover(_ began: Bool, _ ended: Bool, _ mouse: Bool) {
    popoverEvents.append((began, ended, mouse))
  }
  func isMouseEvent(_ event: NSEvent, inAnyOf views: [NSView?]) -> Bool {
    views.contains { $0 != nil && $0 === hitView }
  }
\(miniScrolling)
\(miniResize)
}
"""
try code.write(to: output.appendingPathComponent("Controllers.swift"), atomically: true, encoding: .utf8)
