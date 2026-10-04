import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)

func method(_ signature: String) -> String {
  let needle = "  func \(signature)"
  guard source.components(separatedBy: needle).count == 2,
        let start = source.range(of: needle)?.lowerBound,
        let end = source.range(of: "\n  }", range: start..<source.endIndex)?.upperBound else {
    fatalError("Production method extraction boundary changed: \(signature)")
  }
  return String(source[start..<end])
}

// Playback commands and loop recovery remain the actual production implementations.
let methods = ["pause()", "resume()", "seek(absoluteSecond: Double)",
               "videoToolsEnforceLoopBounds(playbackRestarted: Bool = false)"]
let extracted = "import Cocoa\nextension PlayerCore {\n" + methods.map(method).joined(separator: "\n") + "\n}\n"
try extracted.write(to: output.appendingPathComponent("PlayerMethods.swift"), atomically: true, encoding: .utf8)

// Keep the production parent appearance callbacks: preloaded tab contents must
// not play until QuickSetting actually presents its tools tab.
let parentSource = try String(contentsOf: root.appendingPathComponent("iina/QuickSettingViewController.swift"), encoding: .utf8)
func parentMethod(_ signature: String) -> String {
  let needle = "  override func \(signature)"
  guard parentSource.components(separatedBy: needle).count == 2,
        let start = parentSource.range(of: needle)?.lowerBound,
        let end = parentSource.range(of: "\n  }", range: start..<parentSource.endIndex)?.upperBound else {
    fatalError("Production parent lifecycle extraction boundary changed: \(signature)")
  }
  return String(parentSource[start..<end])
}
let parent = """
import Cocoa
final class QuickSettingViewController: NSViewController {
  enum TabViewType { case tools, video }
  var currentTab = TabViewType.tools
  let videoToolsViewController: VideoToolsViewController?
  private(set) var appearanceUpdates = 0
  init(tools: VideoToolsViewController) {
    videoToolsViewController = tools
    super.init(nibName: nil, bundle: nil)
    addChild(tools)
  }
  required init?(coder: NSCoder) { fatalError("Unused fixture initializer") }
  override func loadView() {
    let container = NSView()
    let tools = videoToolsViewController!.view
    tools.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(tools)
    NSLayoutConstraint.activate([
      tools.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      tools.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      tools.topAnchor.constraint(equalTo: container.topAnchor),
      tools.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
  }
  func updateControlsState() { appearanceUpdates += 1 }
\(parentMethod("viewDidAppear()"))
\(parentMethod("viewDidDisappear()"))
}
"""
try parent.write(to: output.appendingPathComponent("QuickSettingLifecycle.swift"), atomically: true, encoding: .utf8)

// Export jobs are outside this test: reuse only their existing isolated boundary.
let stubs = try String(contentsOf: root.appendingPathComponent("Tools/VideoToolsTests/Stubs.swift"), encoding: .utf8)
guard let start = stubs.range(of: "final class VideoToolsTaskManager:")?.lowerBound else {
  fatalError("The export task boundary changed")
}
try ("import Cocoa\n" + stubs[start...]).write(to: output.appendingPathComponent("ExportBoundary.swift"), atomically: true, encoding: .utf8)
