import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
func read(_ path: String) throws -> String {
  try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundary changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}
let playlist = try read("iina/PlaylistViewController.swift")
let menu = try read("iina/MenuController.swift")
let actions = try read("iina/MainMenuActions.swift")
let preferences = try read("iina/Base.lproj/PrefGeneralViewController.xib")
precondition(preferences.contains("title=\"Repeat playback (all videos):\""),
             "Preferences must describe the global repeat scope")
for binding in ["values.autoRepeat", "values.defaultRepeatMode"] {
  precondition(preferences.contains("keyPath=\"\(binding)\""), "Existing preference bindings must be preserved")
}
let setup = section(playlist, "    installSortControls()", "    playlistTableView.rowHeight")
precondition(setup.range(of: "installFolderBrowser()")!.lowerBound <
             setup.range(of: "installPlaybackModeControls()")!.lowerBound,
             "Mode controls must be installed after queue-only views are captured")
let fixture = """
import Cocoa

\(section(playlist, "enum PlaybackModeMenu", "class PlaylistViewController:"))

final class PlaylistModeControllerUnderTest: NSViewController {
  let player = PlayerCore()
  let loopBtn = NSButton()
  let playbackModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  let browserModeControl = NSSegmentedControl(labels: ["Files", "Playlist"], trackingMode: .selectOne,
                                               target: nil, action: nil)
  let sortControls = NSView()
  let folderBrowser = NSView()
  var browserPlaybackURL: URL?
  var prefersFolderBrowser = true
  var queuePresentationViews: [NSView] = []
  func updateTagFilterControls() {}
\(section(playlist, "  private func updateBrowserMode()", "  // MARK: - Visible playlist identity mapping"))
\(section(playlist, "  func updateLoopBtnStatus()", "  // MARK: - Tab switching"))
\(section(playlist, "  @IBAction func loopBtnAction", "  @IBAction func shuffleBtnAction"))
}

final class MenuControllerUnderTest: NSObject {
  let playbackMenu = NSMenu()
  let fileLoop = NSMenuItem(title: "File Loop", action: nil, keyEquivalent: "")
  let playlistLoop = NSMenuItem(title: "Playlist Loop", action: nil, keyEquivalent: "")
  var noLoop: NSMenuItem?
\(section(menu, "  private func installPlaybackModeMenu()", "  private func updatePlaybackMenu()"))
  func updatePlaybackMode(player: PlayerCore) {
\(section(menu, "    let loopMode = player.getLoopMode()", "    let speed = player.info.playSpeed"))
  }
}

final class MainMenuActionHandler: NSObject {
  let player = PlayerCore()
\(section(actions, "  @objc func menuFileLoop", "  @objc func menuPlaylistItem"))
}
"""
// Only access control changes; the UI and action bodies are production code.
try fixture.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("Production.swift"), atomically: true, encoding: .utf8)
