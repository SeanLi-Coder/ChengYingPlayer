import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let layer = try String(contentsOf: root.appendingPathComponent("iina/ViewLayer.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)

func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}

// Exercise the complete production drawing decisions and queue/lock flow without
// a window, a GPU context, or a libmpv instance. Their boundaries are explicit.
let state = section(layer, "  /// When `true` the frame needs to be rendered.",
                    "  /// Indicates whether the view is being rendered")
let liveResize = section(layer, "  @Atomic var inLiveResize:", "  /// Returns an initialized")
let drawing = section(layer, "  override func canDraw(", "  // Core Animation releases")
let display = section(layer, "  override func display()", "  // MARK: - Core OpenGL")
let priority = section(layer, "private class MainThreadPriorityLock", "\n}") + "\n}"
let updateFrame = section(controller, "  func shouldRenderUpdateFrame()", "  /// Remove observers")
let queue = section(layer, "  private let mpvGLQueue =", "\n")
var source = """
import Foundation

class ViewLayer: LayerBoundary {
  weak var videoView: VideoView!
  let displayLock: NSLocking = NSRecursiveLock()
  let mainThreadPriorityLock = MainThreadPriorityLock()
  var bufferDepth: GLint = 8
  var fbo: GLint = 1
\(queue)
\(state)
\(liveResize)
  init(_ view: VideoView) { videoView = view; super.init() }
\(drawing)
\(display)
  func ignoreGLError() {}
}
\(priority)
extension MPVBoundary {
\(updateFrame)
}
"""
if let legacyGate = ProcessInfo.processInfo.environment["RENDER_UPDATE_TEST_FRAME_GATE_ONLY"] {
  guard legacyGate == "1" else { fatalError("RENDER_UPDATE_TEST_FRAME_GATE_ONLY only accepts 1") }
  let currentGate = "return forceDraw || pendingRenderUpdate || hasFrame"
  guard source.components(separatedBy: currentGate).count == 2 else {
    fatalError("The production redraw gate changed; update the controlled negative test")
  }
  source = source.replacingOccurrences(of: currentGate, with: "return forceDraw || hasFrame")
  fputs("FAULT: Restoring only the former frame-bit drawing gate in the isolated test copy\n", stderr)
}
try source.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("RenderUpdates.swift"), atomically: true, encoding: .utf8)
