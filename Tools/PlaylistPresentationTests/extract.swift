import Foundation

// Extract production bodies mechanically so compiler and lifecycle checks cannot
// silently drift into testing a hand-maintained replacement implementation.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlaylistViewController.swift"), encoding: .utf8)
func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}
let declarations = section("  var playlistChangeObserver:", "  /** Enum for tab switching */")
let notifications = section("    // notifications", "    // register for double click action")
let deinitialization = section("  deinit {", "  func reloadData(playlist:")
let operations = section("  func reloadData(playlist:", "  private func showTotalLength()")
let menu = section("  @IBAction func sortingBtnAction", "  // MARK: - Table delegates")
let controller = """
import Cocoa

final class PlaylistControllerUnderTest: NSViewController {
  weak var player: PlayerCore!
  let playlistTableView = NSTableView()
  let chapterTableView = NSTableView()
  var playlistTotalLengthIsReady = false
\(declarations)
  func installNotifications() {
\(notifications)
  }
\(deinitialization)
\(operations)
\(menu)
}
"""
// The generated test copy only relaxes Swift access control; production visibility
// and all extracted method bodies remain unchanged in the application target.
try controller.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("Controller.swift"), atomically: true, encoding: .utf8)
let cells = "import Cocoa\n" + section("class PlaylistTrackCellView:", "class SubPopoverViewController:")
try cells.write(to: output.appendingPathComponent("Cells.swift"), atomically: true, encoding: .utf8)
