import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let live = try String(contentsOf: root.appendingPathComponent("Tools/PlaybackModeLiveTests/main.swift"), encoding: .utf8)
guard let end = live.range(of: "class PlaybackModeFixture {")?.lowerBound else { fatalError("Live MPV extraction boundary changed") }
let core = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let begin = core.range(of: "  func navigateInPlaylist(nextMedia: Bool) {")!.lowerBound
let finish = core.range(of: "\n  }", range: begin..<core.endIndex)!.upperBound
let method = String(core[begin..<finish])
let extensionText = """
enum ProbeLogLevel { case verbose }
var navigationReturnCodes: [Int32] = []
extension LiveMPV {
  func getFlag(_ property: String) -> Bool { flag(property) ?? false }
  func setFlag(_ property: String, _ value: Bool, level: ProbeLogLevel) { setString(property, value ? "yes" : "no") }
  func command(_ command: MPVCommand, args: [String] = [], checkError: Bool = true) {
    let pointers = ([command.rawValue] + args).map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var values: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer($0) } }
    values.append(nil)
    let status = mpv_command(mpv, &values)
    navigationReturnCodes.append(status)
    if checkError { require(status, "Run typed navigation") }
  }
}
final class UpdateWorkAdmission {
  static let shared = UpdateWorkAdmission()
  let isOpeningMediaBlocked = false
}
final class ProbeVideoView { func displayActive() {} }
final class ProbeWindow { let videoView = ProbeVideoView() }
struct ProbeEntry { let isPlaying: Bool }
struct ProbeInfo { let playlist: [ProbeEntry] }
final class NavigationPlayer {
  let mpv: LiveMPV
  let mainWindow = ProbeWindow()
  let isUsingNativePlayback = false
  var info: ProbeInfo { ProbeInfo(playlist: [ProbeEntry(isPlaying: mpv.number("playlist-pos") == 0)]) }
  init(_ mpv: LiveMPV) { self.mpv = mpv }
  // This MPV-only fixture has no URL enqueue or rotation transaction.
  func resetURLPlaylistEnqueue() {}
  func resetPermanentRotationMedia(to: URL?) {}
  func requireMPVCompatibility(reason: String, completion: @escaping () -> Void) { preconditionFailure("Unexpected native handoff") }
  func log(_ message: String) {}
  func seek(absoluteSecond: Double) { mpv.command(["seek", String(absoluteSecond), "absolute+exact"]) }
\(method)
}
"""
let suite = try String(contentsOf: root.appendingPathComponent("Tools/NativePlaybackQueueTests/MPVNavigationProbe.swift"), encoding: .utf8)
try (String(live[..<end]) + extensionText + suite).write(to: output, atomically: true, encoding: .utf8)
