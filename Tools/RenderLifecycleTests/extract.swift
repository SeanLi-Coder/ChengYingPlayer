import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let layer = try String(contentsOf: root.appendingPathComponent("iina/ViewLayer.swift"), encoding: .utf8)
let view = try String(contentsOf: root.appendingPathComponent("iina/VideoView.swift"), encoding: .utf8)

func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}

// Keep the real layer declarations, complete initializers, destructor, CGL
// factories and copy methods. Only rendering and unrelated app APIs are stubs.
let declarations = section(layer, "import Cocoa", "  // MARK: - Draw")
let copies = section(layer, "  override func copyCGLPixelFormat(", "  /// Reload the content of this layer.")
let factories = section(layer, "  private static func createPixelFormat(", "  // MARK: - ICC Profile")
let priorityLock = section(layer, "private class MainThreadPriorityLock", "\n}") + "\n}"
let layerSource = """
\(declarations)
\(copies)
\(factories)
  func update(force: Bool = false) {}
}
\(priorityLock)
"""
try layerSource.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("Layer.swift"), atomically: true, encoding: .utf8)

let uninit = section(view, "  func uninit() {", "  deinit {")
let start = section(view, "  func startDisplayLink() {", "  @objc func stopDisplayLink()")
let viewSource = """
import Cocoa

final class VideoView: VideoViewBoundary {
\(uninit)
\(start)
}
"""
try viewSource.write(to: output.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
