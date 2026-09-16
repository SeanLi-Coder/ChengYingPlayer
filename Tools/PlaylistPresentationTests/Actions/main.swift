import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
func entry(_ id: Int64, _ name: String) -> MPVPlaylistItem {
  MPVPlaylistItem(filename: "/tmp/playlist-action-fixtures/\(name)", isCurrent: id == 1,
                  isPlaying: id == 1, title: nil, entryID: id)
}
let first = entry(1, "First.mp4")
let second = entry(2, "Second.mp4")
let third = entry(3, "Third.mp4")
let controller = PlaylistActionsUnderTest()
let player = controller.player!
let sender = NSMenuItem()
func prepare(_ entries: [MPVPlaylistItem], selected: IndexSet = IndexSet(integer: 0)) {
  player.info.state.active = true
  player.snapshotAvailable = true
  player.snapshotCount = 0
  player.inactiveSnapshotCount = 0
  player.info.playlist = entries
  player.livePlaylist = entries
  player.removedIDs = []
  controller.playlistTableView.selectedIndexes = selected
  controller.playlistTableView.clickedIndex = selected.first ?? -1
  FileManager.default.trashedURLs = []
  FileManager.default.onTrash = nil
  Utility.selectedFiles = nil
  Utility.onAlert = nil
  controller.menuNeedsUpdate(NSMenu())
}

prepare([first, second])
// The menu label referred to First.mp4. Reordering while the menu is tracking
// must not authorize deleting Second.mp4, the new occupant of numeric row zero.
player.info.playlist = [second, first]
player.livePlaylist = [second, first]
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.map(\.path) == [first.filename],
      "A menu opened before reordering trashes only the originally selected file")
check(player.removedIDs == [first.entryID] && player.livePlaylist.map(\.entryID) == [second.entryID],
      "Removal after trash resolves the original identity at its current row")

prepare([first, second])
player.livePlaylist = [second, first]
controller.contextMenuRemove(sender)
check(player.removedIDs == [first.entryID],
      "A stale displayed playlist cannot redirect removal to the live row's new occupant")

prepare([first, second])
player.livePlaylist = [second]
controller.contextMenuDeleteFile(sender)
controller.contextMenuRemove(sender)
check(FileManager.default.trashedURLs.isEmpty && player.removedIDs.isEmpty,
      "A removed menu target cancels destructive actions without touching its replacement")

prepare([first, second])
player.livePlaylist = [entry(100, "First.mp4"), second]
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.isEmpty, "Reopening the same path does not revive an obsolete menu identity")

prepare([first, second])
player.livePlaylist = [entry(first.entryID, "Changed.mp4"), second]
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.isEmpty, "A changed filename invalidates the menu's original authorization")

prepare([first, second], selected: IndexSet(integersIn: 0...1))
FileManager.default.onTrash = { _ in
  // Simulate an mpv change while the filesystem operation or an error alert is running.
  player.livePlaylist = [third, second, first]
  player.info.playlist = player.livePlaylist
}
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.map(\.path) == [first.filename, second.filename],
      "A mutation during a multi-file trash operation cannot change the captured file targets")
check(Set(player.removedIDs) == [first.entryID, second.entryID] && player.livePlaylist.map(\.entryID) == [third.entryID],
      "A mutation during trash cannot make playlist cleanup remove an unrelated entry")

let duplicate = entry(4, "First.mp4")
prepare([first, duplicate, second], selected: IndexSet(integersIn: 0...1))
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.count == 1 && Set(player.removedIDs) == [first.entryID, duplicate.entryID],
      "Duplicate selected paths are trashed once and both selected identities are removed")

prepare([first, second], selected: IndexSet(integersIn: 0...1))
FileManager.default.onTrash = { url in
  if url.path == first.filename { throw NSError(domain: "TestTrash", code: 1) }
}
Utility.onAlert = {
  player.livePlaylist = [third, second, first]
  player.info.playlist = player.livePlaylist
}
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.map(\.path) == [second.filename] && player.removedIDs == [second.entryID],
      "A failed trash and modal-list mutation preserve the failed and unrelated entries")

prepare([first, second], selected: IndexSet(integersIn: 0...1))
FileManager.default.onTrash = { url in
  if url.path == second.filename { throw NSError(domain: "TestTrash", code: 1) }
}
var snapshotsAtShutdown = -1
Utility.onAlert = {
  player.info.state.active = false
  snapshotsAtShutdown = player.snapshotCount
}
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.map(\.path) == [first.filename],
      "A trash error can stop playback after an earlier file was successfully trashed")
check(snapshotsAtShutdown >= 0 && player.snapshotCount == snapshotsAtShutdown &&
      player.inactiveSnapshotCount == 0 && player.removedIDs.isEmpty,
      "Returning from a trash error after shutdown cannot query mpv or remove playlist rows")

prepare([first, second])
player.info.state.active = false
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.isEmpty, "A stopped player cannot execute an old destructive menu action")
prepare([first, second])
player.snapshotAvailable = false
controller.contextMenuDeleteFile(sender)
check(FileManager.default.trashedURLs.isEmpty, "An unavailable live snapshot fails closed before filesystem mutation")

prepare([first, second])
player.livePlaylist = [second, first]
controller.contextMenuPlayInNewWindow(sender)
check(PlayerCore.newPlayerCore.openedURLs.map(\.path) == [first.filename],
      "Open in a new window follows the selected identity after a reorder")
controller.contextMenuShowInFinder(sender)
check(NSWorkspace.shared.revealedURLs.map(\.path) == [first.filename],
      "Reveal in Finder follows the selected identity after a reorder")

let subtitle = URL(fileURLWithPath: "/tmp/playlist-action-fixtures/First.srt")
prepare([first, second])
player.info.matchedSubs = [:]
controller.contextMenuAddSubtitle(sender)
Utility.selectedFiles?([URL(fileURLWithPath: "/tmp/playlist-action-fixtures/notes.txt"), subtitle, subtitle])
check(player.info.getMatchedSubs(first.filename) == [subtitle],
      "Unsupported selections do not discard later valid subtitles and repeated files are not duplicated")
prepare([first, second])
player.info.matchedSubs = [:]
controller.contextMenuAddSubtitle(sender)
player.livePlaylist = [second]
Utility.selectedFiles?([subtitle])
check(player.info.matchedSubs.isEmpty, "Finishing a subtitle panel cannot mutate a removed playlist target")

prepare([first])
let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlaylistActions-\(UUID().uuidString)"))
defer { pasteboard.releaseGlobally() }
controller.copyToPasteboard(controller.playlistTableView, writeRowsWith: IndexSet([0, 8]), to: pasteboard)
check(pasteboard.propertyList(forType: .nsFilenames) as? [String] == [first.filename],
      "Copying a selection after list shrink ignores out-of-range rows without crashing")
let archivedRows = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSIndexSet.self,
                                                        from: pasteboard.data(forType: .iinaPlaylistItem)!)
check(archivedRows as IndexSet? == IndexSet(integer: 0), "The drag archive and copied file paths use the same validated rows")
pasteboard.clearContents()
pasteboard.setPropertyList(["http://[invalid", first.filename], forType: .nsFilenames)
check(controller.pasteFromPasteboard(row: 0, from: pasteboard) && player.addedPaths == [first.filename],
      "Malformed pasted URLs are skipped without discarding later valid local files")

let popover = SubPopoverViewController()
popover.player = player
popover.filePath = first.filename
player.info.matchedSubs = [first.filename: [subtitle]]
check(popover.tableView(NSTableView(), objectValueFor: nil, row: 0) as? String == subtitle.lastPathComponent,
      "The actual subtitle popover still displays valid rows")
player.info.matchedSubs = [first.filename: []]
check(popover.tableView(NSTableView(), objectValueFor: nil, row: 0) == nil &&
      popover.tableView(NSTableView(), objectValueFor: nil, row: -1) == nil,
      "The subtitle popover safely rejects rows invalidated by a background update")

print("PASS: \(checks) playlist action checks")
