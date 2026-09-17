import Foundation

// Extract complete production methods; only access control is relaxed for tests.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlaylistViewController.swift"), encoding: .utf8)
func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}
let generated = """
import Cocoa

final class PlaylistFilterControllerUnderTest: NSObject {
  let player: PlayerCore! = PlayerCore()
  let playlistTableView = ProbeTableView()
  let chapterTableView = ProbeTableView()
  let subPopover = ProbePopover()
  var displayedPlaylist: [MPVPlaylistItem] = []
  var draggedPlaylistSnapshot: [MPVPlaylistItem] = []
  var tagFilter: PlaylistTagFilter = .all
  var fileMetadata: [String: PlaylistFileMetadata] = [:]
  var filterControlUpdates = 0
  func updateTagFilterControls() { filterControlUpdates += 1 }
  func buildMenu() -> NSMenu { NSMenu() }
\(section("  // MARK: - Visible playlist identity mapping", "  private func updateTagFilterControls()"))
\(section("  // MARK: - Drag and Drop", "  // MARK: - Edit Menu Support"))
\(section("  @objc func delete(", "  // MARK: - private methods"))
\(section("  @IBAction func removeBtnAction", "  @IBAction func addFileAction"))
\(section("  @objc func performDoubleAction", "  @IBAction func prefixBtnAction"))
\(section("  @IBAction func subBtnAction", "  @IBAction func sortingBtnAction"))
\(section("  // MARK: - Context menu", "  @IBAction func contextMenuPlayInNewWindow"))
\(section("  @IBAction func contextMenuRemove", "  @IBAction func contextMenuDeleteFile"))
}

extension SubPopoverViewController {
\(section("  @IBAction func wrongSubBtnAction", "\n}\n\nclass ChapterTableCellView"))
}
"""
try generated.replacingOccurrences(of: "private ", with: "")
  .write(to: output, atomically: true, encoding: .utf8)
