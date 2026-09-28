import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let player = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let preferences = try String(contentsOf: root.appendingPathComponent("iina/Preference.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)
let window = try String(contentsOf: root.appendingPathComponent("iina/PlayerWindowController.swift"), encoding: .utf8)

func section(_ text: String, _ start: String, _ end: String) -> String {
  guard let begin = text.range(of: start)?.lowerBound,
        let finish = text.range(of: end, range: begin..<text.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(text[begin..<finish])
}

let open = section(player, "  private func openMainWindow(", "  static func loadKeyBindings()")
precondition(open.range(of: "restoreSavedLoopMode()")!.lowerBound < open.range(of: "mpv.command(.loadfile")!.lowerBound,
             "Restore the saved selection before manual loads")
let start = section(player, "  func startMPV()", "  func initVideo()")
precondition(start.range(of: "mpv.mpvInit()")!.lowerBound < start.range(of: "restoreSavedLoopMode()")!.lowerBound,
             "Restore the saved selection after initializing new cores")
let initBody = section(controller, "  func mpvInit()", "  /// Initialize the `mpv` renderer.")
precondition(initBody.components(separatedBy: "addSavedLoopModeHook()").count == 2,
             "Install the restoration hook exactly once")
precondition(initBody.contains("for key in [PK.autoRepeat, PK.defaultRepeatMode]"),
             "Observe both existing settings bindings")
let propertyChange = section(controller, "    case MPVOption.PlaybackControl.loopPlaylist,", "    case MPVOption.Video.deinterlace:")
precondition(!propertyChange.contains("saveLoopMode") && !propertyChange.contains("setLoopMode"),
             "Incidental mpv property events must never save the global choice")
let keyboard = section(window, "  func handleKeyBinding(", "  func abLoop()")
precondition(keyboard.range(of: "player.handleLoopModeKeyBinding(keyBinding.action)")!.lowerBound <
             keyboard.range(of: "player.mpv.command(rawString:")!.lowerBound,
             "Route recognized loop shortcuts before raw mpv commands")

let source = """
import Foundation

enum Preference {
  struct Key {
    let rawValue: String
    static let autoRepeat = Key(rawValue: "autoRepeat")
    static let defaultRepeatMode = Key(rawValue: "defaultRepeatMode")
  }
\(section(preferences, "  enum DefaultRepeatMode:", "  // MARK: - Defaults"))
\(section(preferences, "  static func savedLoopMode(", "  /// Preserve the selected device"))
}

final class PlayerCore {
  static var playerCores: [PlayerCore] = []
  let mpv = MPVFixture()
  let info = InfoFixture()
\(section(player, "  func togglePlaylistLoop()", "  func toggleShuffle()"))
}

final class HookController: HookFixture {
\(section(controller, "  private func addSavedLoopModeHook()", "  /// Start each newly loaded video silently"))
}
"""
try source.replacingOccurrences(of: "private func", with: "func")
  .write(to: output.appendingPathComponent("Production.swift"), atomically: true, encoding: .utf8)

let bundle = output.appendingPathComponent("PlaybackModeTests.app/Contents", isDirectory: true)
try FileManager.default.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
let plist: [String: Any] = [
  "CFBundleIdentifier": "org.chengying.tests.playback-mode.\(UUID().uuidString)",
  "CFBundleExecutable": "PlaybackModeTests",
  "CFBundlePackageType": "APPL"
]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  .write(to: bundle.appendingPathComponent("Info.plist"))
