import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

func read(_ path: String) throws -> String {
  try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func section(_ source: String, from start: String, to end: String) -> String {
  guard source.components(separatedBy: start).count == 2,
        source.components(separatedBy: end).count == 2,
        let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start)")
  }
  return String(source[begin..<finish])
}

let controller = try read("iina/MainWindowController.swift")
let player = try read("iina/PlayerCore.swift")
let preference = try read("iina/Preference.swift")
let extensions = try read("iina/Extensions.swift")
let appData = try read("iina/AppData.swift")
let appDelegate = try read("iina/AppDelegate.swift")
guard let enumStart = preference.range(of: "  static func `enum`<T:")?.lowerBound else {
  fatalError("Production enum accessor changed")
}
let enumAccessor = String(preference[enumStart...])

// This wiring assertion complements runtime execution of the actual defaults and
// sizing methods. It is not presented as a full application launch test.
guard appDelegate.contains("UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map") else {
  fatalError("Application preference registration wiring changed")
}

let keys = ["usePhysicalResolution", "resizeWindowTiming", "resizeWindowOption", "disableAnimations"]
let defaultBlock = section(preference, from: "  static let defaultPreference:", to: "  static var effectiveAudioDeviceName:")
let defaultLines = keys.map { key -> String in
  let matches = defaultBlock.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".\(key):") }
  guard matches.count == 1 else { fatalError("Missing or repeated production default: \(key)") }
  return matches[0]
}.joined(separator: "\n")
let keyLines = keys.map { key -> String in
  let matches = preference.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let \(key) = Key(") }
  guard matches.count == 1 else { fatalError("Missing or repeated production key: \(key)") }
  return matches[0]
}.joined(separator: "\n")
let audioLines = ["widthWhenNoVideo", "heightWhenNoVideo"].map { name -> String in
  let matches = appData.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("static let \(name) =") }
  guard matches.count == 1 else { fatalError("Audio fallback dimensions changed") }
  return matches[0]
}.joined(separator: "\n")

let code = """
import Cocoa

\(section(preference, from: "protocol InitializingFromKey {", to: "struct Preference {"))

struct Preference {
  struct Key: Hashable {
    let rawValue: String
    init(_ value: String) { rawValue = value }
\(keyLines)
  }
  static var ud = UserDefaults(suiteName: "io.github.SeanLi-Coder.WindowSizingTests.unused")!
\(section(preference, from: "  enum ResizeWindowTiming:", to: "  enum WindowBehaviorWhenPip:"))
  static let defaultPreference: [Key: Any] = [
\(defaultLines)
  ]
\(section(preference, from: "  static func bool(for key:", to: "  static func float(for key:"))
\(section(enumAccessor, from: "  static func `enum`<T:", to: "\n}\n"))
}

struct AppData {
\(audioLines)
}

\(section(extensions, from: "extension NSSize {", to: "extension NSPoint {"))

final class PlayerCore: PlayerBoundary {
\(section(player, from: "  var videoSizeForDisplay:", to: "  var originalVideoSize:"))
}

final class MainWindowController: ControllerBoundary {
\(section(controller, from: "  func windowFrameFromGeometry(", to: "  /// Determine the screen to use for the window."))
\(section(controller, from: "  override func handleVideoSizeChange() {", to: "  // MARK: - UI: Others"))
}
"""
try code.write(to: output.appendingPathComponent("Production.swift"), atomically: true, encoding: .utf8)
