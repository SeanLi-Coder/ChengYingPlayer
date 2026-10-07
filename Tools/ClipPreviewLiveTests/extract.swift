import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
// Optional baselines: argument 3 is an older settings parent, argument 4 an older PlayerCore;
// "-" keeps the working-tree source for that position.
func optionalSource(_ index: Int, fallback: String) -> URL {
  guard CommandLine.arguments.count > index, CommandLine.arguments[index] != "-" else {
    return root.appendingPathComponent(fallback)
  }
  return URL(fileURLWithPath: CommandLine.arguments[index])
}
let source = try String(contentsOf: optionalSource(4, fallback: "iina/PlayerCore.swift"), encoding: .utf8)

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
let parentSource = try String(contentsOf: optionalSource(3, fallback: "iina/QuickSettingViewController.swift"), encoding: .utf8)
func parentMember(_ needle: String, required: Bool = true) -> String {
  guard parentSource.components(separatedBy: needle).count == 2,
        let start = parentSource.range(of: needle)?.lowerBound,
        let end = parentSource.range(of: "\n  }", range: start..<parentSource.endIndex)?.upperBound else {
    if required { fatalError("Production parent lifecycle extraction boundary changed: \(needle)") }
    return ""
  }
  return String(parentSource[start..<end])
}
func parentMethod(_ signature: String) -> String { parentMember("  override func \(signature)") }
// Older parents predate the chrome-visibility helper and the explicit close hook; their
// legacy teardown compiles unchanged and the hook becomes a no-op for the comparison.
let chromeVisibilityHelper = parentMember("  private var isHiddenWithPlayerChrome: Bool {", required: false)
var explicitClose = parentMember("  func sidebarDidClose() {", required: false)
if explicitClose.isEmpty { explicitClose = "  func sidebarDidClose() {}" }
let parent = """
import Cocoa
final class QuickSettingViewController: NSViewController {
  enum TabViewType { case tools, video }
  var currentTab = TabViewType.tools
  let videoToolsViewController: VideoToolsViewController?
  weak var mainWindow: MainWindowController!
  private(set) var appearanceUpdates = 0
  private(set) var disappearances = 0
  init(tools: VideoToolsViewController, mainWindow: MainWindowController) {
    videoToolsViewController = tools
    self.mainWindow = mainWindow
    super.init(nibName: nil, bundle: nil)
    addChild(tools)
  }
  override func viewWillDisappear() {
    super.viewWillDisappear()
    disappearances += 1
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
\(chromeVisibilityHelper)
\(explicitClose)
}
"""
try parent.write(to: output.appendingPathComponent("QuickSettingLifecycle.swift"), atomically: true, encoding: .utf8)

// Export jobs are outside this test: reuse only their existing isolated boundary.
let stubs = try String(contentsOf: root.appendingPathComponent("Tools/VideoToolsTests/Stubs.swift"), encoding: .utf8)
guard let start = stubs.range(of: "final class VideoToolsTaskManager:")?.lowerBound else {
  fatalError("The export task boundary changed")
}
try ("import Cocoa\n" + stubs[start...]).write(to: output.appendingPathComponent("ExportBoundary.swift"), atomically: true, encoding: .utf8)
