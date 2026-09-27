import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/VideoView.swift"), encoding: .utf8)
let playerSource = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)

func section(_ source: String, _ start: String, _ end: String) -> String {
  guard source.components(separatedBy: start).count == 2,
        source.components(separatedBy: end).count == 2,
        let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start)")
  }
  return String(source[begin..<finish])
}

let constants = source.components(separatedBy: .newlines).filter {
  $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let SRGB =")
}
guard constants.count == 1 else { fatalError("Production sRGB declaration changed") }
let fileStart = section(playerSource, "  func fileStarted(path: String) {", "    // Auto load")
guard fileStart.contains("info.justStartedFile = true") else {
  fatalError("The production file-start handler must mark each new file")
}

// Compile the complete production SDR method unchanged. Only unrelated app
// services and the mpv/Core Animation side effects are recording boundaries.
let code = """
import Cocoa

final class VideoView: VideoViewBoundary {
\(constants[0])
\(section(source, "  private func setICCProfile() {", "  // MARK: - Error Logging"))
  func applySDRColorState() { setICCProfile() }
}

final class PlayerCore: PlaybackBoundary {
\(section(playerSource, "  func playbackRestarted() {", "  func secondarySubDelayChanged("))
}
"""
try code.write(to: output.appendingPathComponent("Production.swift"), atomically: true, encoding: .utf8)
