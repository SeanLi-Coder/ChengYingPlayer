import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)

func section(_ start: String, _ end: String, in text: String = source) -> String {
  guard text.components(separatedBy: start).count == 2,
        let begin = text.range(of: start)?.lowerBound,
        let finish = text.range(of: end, range: begin..<text.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(text[begin..<finish])
}

// Compile the production reader and option application against a real libmpv adapter.
// UserDefaults persistence belongs to the separate isolated preference tests.
let player = """
import Foundation

final class PlaybackModePlayer: PlaybackModeFixture {
\(section("  func getLoopMode() -> LoopMode {", "  func setLoopMode("))
\(section("  private func applyLoopMode(_ newMode: LoopMode) {", "  /// Handle standard repeat shortcuts"))
  // An in-memory saved choice replaces UserDefaults only at the persistence boundary.
  func restoreSavedLoopMode() {
    if let savedMode { applyLoopMode(savedMode) }
  }
}

final class PlaybackModeController: PlaybackModeHookFixture {
\(section("  private func addSavedLoopModeHook()", "  /// Start each newly loaded video silently", in: controller))
}
"""
try player.replacingOccurrences(of: "private func", with: "func")
  .write(to: output.appendingPathComponent("Player.swift"), atomically: true, encoding: .utf8)
