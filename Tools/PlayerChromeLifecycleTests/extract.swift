import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/MainWindowController.swift"), encoding: .utf8)

func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}

let sections = [
  section("  private var chromeAnimationGeneration:", "  // Left and right arrow buttons"),
  section("  enum UIAnimationState {", "  private var osdLastMessage:"),
  section("  enum SideBarViewType {", "  enum InteractiveMode {"),
  section("  override func mouseMoved(with event:", "  @objc func handleMagnifyGesture("),
  section("  func windowWillClose(_ notification:", "  // MARK: - Window delegate: Full screen"),
  section("  private func refreshChromeAfterWindowTransition()", "  // MARK: - UI: Title"),
  section("  private func showSideBar(viewController:", "  private func setConstraintsForVideoView("),
  section("  func showSettingsSidebar(tab:", "  func showPluginSidebar(")
]

for callback in ["windowDidEnterFullScreen", "windowDidExitFullScreen",
                 "windowDidFailToEnterFullScreen", "windowDidFailToExitFullScreen"] {
  let body = section("  func \(callback)(", "\n  func ")
  guard body.components(separatedBy: "refreshChromeAfterWindowTransition()").count == 2 else {
    fatalError("Fullscreen completion must refresh dynamic chrome membership exactly once: \(callback)")
  }
  print("PASS: \(callback) integrates the production window-transition refresh")
}
print("Fullscreen source integration checks passed: 4")
var code = """
import Cocoa
import QuartzCore

final class MainWindowUnderTest: ChromeFixture {
\(sections.joined(separator: "\n"))
}

protocol SidebarViewController {
  var downShift: CGFloat { get set }
}
"""
// Only access control and operating-system effect boundaries are substituted.
// The production state guards, generation comparisons, and completion bodies stay unchanged.
code = code.replacingOccurrences(of: "private ", with: "")
  .replacingOccurrences(of: "NSAnimationContext.runAnimationGroup", with: "ChromeAnimations.runAnimationGroup")
  .replacingOccurrences(of: ".animator()", with: ".chromeImmediateAnimator()")
  .replacingOccurrences(of: "NSEvent.pressedMouseButtons", with: "ChromeInput.pressedMouseButtons")
  .replacingOccurrences(of: "NSCursor.setHiddenUntilMouseMoves", with: "ChromeInput.setHiddenUntilMouseMoves")
  .replacingOccurrences(of: "UserDefaults.standard", with: "ChromeDefaults.value")
try code.write(to: output.appendingPathComponent("Controller.swift"), atomically: true, encoding: .utf8)
