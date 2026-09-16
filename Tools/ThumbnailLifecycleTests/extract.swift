import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}
let requests = section("  private func invalidateThumbnails() {", "  func makeTouchBar()")
let delegates = String(source[source.range(of: "extension PlayerCore: FFmpegControllerDelegate {")!.lowerBound...])
let generation = section("  @Atomic private var thumbnailGeneration:", "  var initialWindow:")
let extracted = """
import Foundation
final class ThumbnailPlayerUnderTest: ThumbnailPlayerFixture {
\(generation)
\(requests)
}
\(delegates.replacingOccurrences(of: "extension PlayerCore:", with: "extension ThumbnailPlayerUnderTest:"))
"""
// Only access control is relaxed in the temporary copy; method bodies are unchanged.
try extracted.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("Player.swift"), atomically: true, encoding: .utf8)

// Ensure manual open and all terminal paths invalidate requests, in addition to
// the executed file-start/stop/shutdown bodies in PlaybackLifecycleTests.
for (start, end) in [
  ("  private func openMainWindow(path:", "  ///"),
  ("  func mpvHasShutdown() {", "  /// Keep legacy callers")
] {
  precondition(section(start, end).contains("invalidateThumbnails()"), "Missing lifecycle cancellation: \(start)")
}
