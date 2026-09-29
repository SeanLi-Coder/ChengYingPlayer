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

// Export jobs are outside this test: reuse only their existing isolated boundary.
let stubs = try String(contentsOf: root.appendingPathComponent("Tools/VideoToolsTests/Stubs.swift"), encoding: .utf8)
guard let start = stubs.range(of: "final class VideoToolsTaskManager:")?.lowerBound else {
  fatalError("The export task boundary changed")
}
try ("import Cocoa\n" + stubs[start...]).write(to: output.appendingPathComponent("ExportBoundary.swift"), atomically: true, encoding: .utf8)
