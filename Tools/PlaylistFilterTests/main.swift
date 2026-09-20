import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setbuf(stdout, nil)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
func entry(_ id: Int64, _ name: String? = nil) -> MPVPlaylistItem {
  MPVPlaylistItem(filename: "/tmp/playlist-filter-fixtures/\(name ?? "Video \(id).mp4")",
                  isCurrent: id == 1, isPlaying: id == 1, title: nil, entryID: id)
}
let all = (1...5).map { entry(Int64($0)) }
let controller = PlaylistFilterControllerUnderTest()
let player = controller.player!
let table = controller.playlistTableView
let menu = NSMenuItem()
let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlaylistFilterTests-\(UUID().uuidString)"))
defer { pasteboard.releaseGlobally() }
let internalDrag = ProbeDraggingInfo(pasteboard: pasteboard, source: table)
let externalDrag = ProbeDraggingInfo(pasteboard: pasteboard, source: nil)
let subtitle = SubPopoverViewController()
subtitle.player = player
subtitle.playlistTableView = table
controller.subPopover.contentViewController = subtitle

func prepare(filtered: Bool = true, selected: IndexSet = [0]) {
  player.info.state.active = true
  player.snapshotAvailable = true
  player.livePlaylist = all
  player.info.playlist = all
  player.removedIDs = []
  player.playedIDs = []
  player.playedChapters = []
  player.moves = []
  player.additions = []
  player.notifications = 0
  player.mpv.position = 0
  player.onPlayableFiles = nil
  controller.displayedPlaylist = all
  controller.draggedPlaylistSnapshot = []
  controller.tagFilter = .all
  controller.fileMetadata = Dictionary(uniqueKeysWithValues: all.map { item in
    let tags = item.entryID == 2 || item.entryID == 4 ? [PlaylistFileTag(name: "Review", colorIndex: 6)] : []
    return (item.filename, PlaylistFileMetadata(url: URL(fileURLWithPath: item.filename), tags: tags))
  })
  table.selectedIndexes = []
  table.isHidden = false
  controller.requestTagFilter(filtered ? .color(6) : .all)
  table.selectedIndexes = selected
  table.clickedIndex = selected.first ?? -1
  table.senderRow = selected.first ?? -1
  controller.chapterTableView.selectedIndexes = []
  pasteboard.clearContents()
}
func writeExternalFiles() {
  pasteboard.clearContents()
  pasteboard.setPropertyList(["/tmp/playlist-filter-fixtures/New.mp4"], forType: .nsFilenames)
}
func startDrag(_ rows: IndexSet) {
  check(controller.tableView(table, writeRowsWith: rows, to: pasteboard),
        "The real drag producer creates an isolated playlist pasteboard")
}
func acceptInternal(at row: Int) -> Bool {
  controller.tableView(table, acceptDrop: internalDrag, row: row, dropOperation: .above)
}

prepare(filtered: false, selected: [3])
controller.requestTagFilter(.color(6))
check(controller.displayedPlaylist.map(\.entryID) == [2, 4], "Color filtering displays only matching entries")
check(table.selectedRowIndexes == [1], "Filtering preserves the selected entry by identity rather than numeric row")
check(player.livePlaylist.map(\.entryID) == [1, 2, 3, 4, 5] && player.moves.isEmpty &&
      player.removedIDs.isEmpty && player.playedIDs.isEmpty && player.notifications == 0,
      "Filtering does not mutate, restart, or advance the real playback queue")
controller.requestTagFilter(.color(4))
check(controller.displayedPlaylist.isEmpty && table.selectedRowIndexes.isEmpty,
      "An unmatched color produces an empty view and clears only hidden selection")
controller.requestTagFilter(.all)
check(controller.displayedPlaylist.map(\.entryID) == [1, 2, 3, 4, 5],
      "Clearing the filter restores every entry in its original playback order")
player.info.state.active = false
controller.requestTagFilter(.color(6))
check(controller.tagFilter == .all, "Inactive playback ignores new filter requests")

prepare()
check(controller.playlistIndex(forVisibleRow: 0, in: all) == 1 &&
      controller.playlistIndex(forVisibleRow: 1, in: all) == 3,
      "Visible rows resolve to their noncontiguous real queue indexes")
check(controller.playlistRows(forVisibleRows: [0, 1], in: all) == [1, 3],
      "Multiselection maps every visible identity into the full queue")
check(controller.playlistRows(forVisibleRows: [0, 2], in: all) == nil &&
      controller.playlistIndex(forVisibleRow: -1, in: all) == nil,
      "An invalid or stale selection fails closed instead of partially targeting rows")
check(controller.playlistIndex(forVisibleRow: 0, in: [entry(2, "Replaced.mp4")]) == nil &&
      controller.playlistIndex(forVisibleRow: 0, in: [entry(22, "Video 2.mp4")]) == nil,
      "Both entry ID and filename must match the displayed authorization")
let duplicate = entry(20, "Video 2.mp4")
check(controller.playlistIndex(forVisibleRow: 0, in: [duplicate, all[1]]) == 1,
      "Duplicate filenames cannot redirect an action to a different queue entry")
controller.displayedPlaylist = [entry(-1)]
check(controller.playlistIndex(forVisibleRow: 0, in: [entry(-1)]) == nil,
      "Entries without a stable backend identity cannot authorize an action")

prepare()
player.livePlaylist = all.reversed()
controller.performDoubleAction(sender: table)
check(player.playedIDs == [2], "Double-click plays the visible entry after a live queue reorder")
prepare()
player.livePlaylist = all.filter { $0.entryID != 2 }
controller.performDoubleAction(sender: table)
check(player.playedIDs.isEmpty, "Double-click on a removed entry cannot play its replacement row")
prepare()
controller.chapterTableView.selectedIndexes = [3]
controller.performDoubleAction(sender: controller.chapterTableView)
check(player.playedChapters == [3] && player.playedIDs.isEmpty,
      "Chapter double-click retains chapter indexing while a playlist filter is active")
prepare(selected: [0, 1])
player.livePlaylist = all.reversed()
controller.delete(menu)
check(Set(player.removedIDs) == [2, 4] && player.livePlaylist.map(\.entryID) == [5, 3, 1],
      "Delete removes only selected visible identities after a live reorder")
prepare(selected: [1])
controller.removeBtnAction(NSButton())
check(player.removedIDs == [4], "The remove button targets its visible entry rather than a hidden neighbor")
prepare(selected: [0, 1])
player.livePlaylist = all.filter { $0.entryID != 4 }
controller.delete(menu)
check(player.removedIDs.isEmpty, "A partially stale multiselection cancels the entire removal")
prepare()
player.snapshotAvailable = false
controller.delete(menu)
controller.performDoubleAction(sender: table)
check(player.removedIDs.isEmpty && player.playedIDs.isEmpty,
      "An unavailable live snapshot rejects destructive and playback actions")
prepare()
player.info.state.active = false
controller.delete(menu)
controller.performDoubleAction(sender: table)
check(player.removedIDs.isEmpty && player.playedIDs.isEmpty,
      "Stopping playback invalidates queued removal and double-click actions")

prepare(selected: [0, 1])
table.isHidden = true
controller.delete(menu)
controller.removeBtnAction(NSButton())
check(player.removedIDs.isEmpty && player.livePlaylist.map(\.entryID) == all.map(\.entryID),
      "Hidden playback rows cannot be removed by stale menu or button actions")
table.isHidden = false
let hiddenQueueContainer = NSView()
hiddenQueueContainer.addSubview(table)
hiddenQueueContainer.isHidden = true
controller.delete(menu)
controller.removeBtnAction(NSButton())
check(player.removedIDs.isEmpty && player.livePlaylist.map(\.entryID) == all.map(\.entryID),
      "Folder mode hiding the queue ancestor also blocks deletion of its retained selection")
hiddenQueueContainer.isHidden = false
controller.removeBtnAction(NSButton())
check(Set(player.removedIDs) == [2, 4],
      "Restoring queue visibility restores deletion with the original visible-row identity mapping")
table.removeFromSuperview()

prepare(selected: [0, 1])
controller.copyToPasteboard(table, writeRowsWith: [0, 1], to: pasteboard)
check(pasteboard.propertyList(forType: .nsFilenames) as? [String] == [all[1].filename, all[3].filename],
      "Copy contains only displayed selected filenames, never hidden row occupants")
let archived = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSIndexSet.self,
                                                      from: pasteboard.data(forType: .iinaPlaylistItem)!)
check(archived as IndexSet? == [1, 3], "The drag archive stores matching real queue indexes")
pasteboard.clearContents()
controller.copyToPasteboard(table, writeRowsWith: [0, 20], to: pasteboard)
check(pasteboard.types?.isEmpty ?? true, "A stale copy selection cannot emit mismatched files and drag indexes")
prepare()
player.info.playlist = all.reversed()
controller.copyToPasteboard(table, writeRowsWith: [0], to: pasteboard)
check(pasteboard.propertyList(forType: .nsFilenames) as? [String] == [all[1].filename],
      "Copy resolves the displayed identity even when the cached queue has reordered")

for (visibleRow, realIndex) in [(0, 1), (1, 3), (2, 4)] {
  prepare()
  writeExternalFiles()
  check(controller.pasteFromPasteboard(row: visibleRow, from: pasteboard) && player.additions.last?.index == realIndex,
        "External insertion at visible boundary \(visibleRow) maps to real boundary \(realIndex)")
}
prepare()
controller.requestTagFilter(.color(4))
writeExternalFiles()
check(controller.pasteFromPasteboard(row: 0, from: pasteboard) && player.additions.last?.index == 5,
      "Dropping into an empty filtered view safely appends after the real queue")
for invalidRow in [-1, 3, Int.max] {
  prepare()
  writeExternalFiles()
  check(!controller.pasteFromPasteboard(row: invalidRow, from: pasteboard) && player.additions.isEmpty,
        "Invalid insertion boundary \(invalidRow) cannot mutate the queue")
}
prepare()
writeExternalFiles()
player.onPlayableFiles = { player.livePlaylist = all.reversed() }
check(controller.pasteFromPasteboard(row: 1, from: pasteboard) && player.additions.last?.index == 1,
      "Insertion resolves its anchor after potentially slow external file discovery")
prepare()
writeExternalFiles()
player.onPlayableFiles = { player.livePlaylist = all.filter { $0.entryID != 4 } }
check(!controller.pasteFromPasteboard(row: 1, from: pasteboard) && player.additions.isEmpty,
      "A removed insertion anchor fails closed after external file discovery")
prepare()
pasteboard.setPropertyList(["https://example.invalid/video.mp4"], forType: .nsURL)
check(controller.pasteFromPasteboard(row: 1, from: pasteboard) && player.additions.last?.index == 3,
      "URL-list paste follows the same visible-to-real insertion mapping")
prepare()
pasteboard.setString("https://example.invalid/video.mp4", forType: .string)
check(controller.pasteFromPasteboard(row: 1, from: pasteboard) && player.additions.last?.index == 3,
      "Plain URL paste follows the same visible-to-real insertion mapping")
prepare()
writeExternalFiles()
player.info.state.active = false
check(!controller.pasteFromPasteboard(row: 0, from: pasteboard) && player.additions.isEmpty,
      "External insertion is rejected after playback stops")

prepare(selected: [1])
controller.menuNeedsUpdate(NSMenu())
check(controller.contextMenuTargets.map(\.entryID) == [4], "Right-click captures the visible item's identity")
player.livePlaylist = all.reversed()
controller.contextMenuRemove(menu)
check(player.removedIDs == [4], "A context menu opened before a reorder still removes its original visible target")
prepare(selected: [0, 1])
table.clickedIndex = 1
controller.menuNeedsUpdate(NSMenu())
check(controller.contextMenuSelection()?.rows == [1, 3],
      "Context menu and plugin row indexes remain real queue indexes for a filtered multiselection")
prepare(selected: [0])
table.clickedIndex = 1
controller.menuNeedsUpdate(NSMenu())
controller.contextMenuPlayNext(menu)
check(player.livePlaylist.map(\.entryID) == [1, 4, 2, 3, 5],
      "Play Next places the clicked visible entry after the hidden currently playing entry")
prepare()
controller.menuNeedsUpdate(NSMenu())
player.livePlaylist = [entry(2, "Changed.mp4")]
check(controller.contextMenuSelection() == nil, "A changed context target filename invalidates every downstream menu action")
prepare(selected: [1])
player.info.playlist = all.reversed()
controller.subBtnAction(NSButton())
check(subtitle.filePath == all[3].filename && controller.subPopover.presentationCount == 1,
      "Subtitle popover binds to the visible identity after the cached queue reorders")
player.info.playlist = []
controller.subBtnAction(NSButton())
check(controller.subPopover.presentationCount == 1,
      "A removed subtitle target cannot present stale or unrelated subtitle data")
prepare(selected: [1])
subtitle.filePath = all[3].filename
player.info.matchedSubs = [all[3].filename: [URL(fileURLWithPath: "/tmp/playlist-filter-fixtures/Subtitle.srt")]]
let reloadsBeforeClearing = table.reloadCount
subtitle.wrongSubBtnAction(NSButton())
check(player.info.matchedSubs[all[3].filename]?.isEmpty == true &&
      table.reloadCount == reloadsBeforeClearing + 1 && table.partialReloads.isEmpty,
      "Clearing matched subtitles refreshes visible rows without using the filtered-out backend row index")

prepare()
startDrag([0])
check(controller.tableView(table, validateDrop: internalDrag, proposedRow: 1, proposedDropOperation: .above).isEmpty,
      "Internal drag validation rejects reordering while entries are hidden")
check(!acceptInternal(at: 1) && player.moves.isEmpty && player.additions.isEmpty,
      "The final drop independently rejects filtered internal reordering")
prepare(filtered: false)
startDrag([1])
controller.requestTagFilter(.color(6))
check(!acceptInternal(at: 1) && player.moves.isEmpty,
      "Enabling a filter after a drag starts cannot bypass the final reorder guard")
prepare(filtered: false)
startDrag([1])
player.livePlaylist = all.reversed()
check(!acceptInternal(at: 3) && player.moves.isEmpty,
      "A backend reorder after drag start invalidates the archived numeric positions")
prepare(filtered: false)
startDrag([1])
player.livePlaylist = [entry(1, "Changed.mp4")] + Array(all.dropFirst())
check(!acceptInternal(at: 3) && player.moves.isEmpty,
      "A renamed queue entry invalidates an in-flight drag snapshot")
prepare(filtered: false)
startDrag([1])
controller.displayedPlaylist = all.reversed()
check(!acceptInternal(at: 3) && player.moves.isEmpty,
      "A stale display order cannot authorize an internal numeric-index reorder")
prepare(filtered: false)
startDrag([1, 3])
check(acceptInternal(at: 5) && player.livePlaylist.map(\.entryID) == [1, 3, 5, 2, 4],
      "Unfiltered multi-item internal dragging retains the original stable reorder behavior")
prepare()
writeExternalFiles()
check(controller.tableView(table, validateDrop: externalDrag, proposedRow: 1, proposedDropOperation: .above) == .copy &&
      controller.tableView(table, acceptDrop: externalDrag, row: 1, dropOperation: .above) &&
      player.additions.last?.index == 3,
      "External dragging remains enabled and inserts beside the correct filtered anchor")
prepare()
writeExternalFiles()
let otherTableDrag = ProbeDraggingInfo(pasteboard: pasteboard, source: NSTableView())
check(controller.tableView(table, acceptDrop: otherTableDrag, row: 1, dropOperation: .above) &&
      player.additions.last?.index == 3,
      "Dragging from a different playlist treats the destination's filter as an insertion mapping")
prepare()
writeExternalFiles()
check(!acceptInternal(at: 1) && player.moves.isEmpty && player.additions.isEmpty,
      "A missing internal drag archive cannot fall through to copying entries into a filtered queue")
prepare()
writeExternalFiles()
let wrongArchive = try NSKeyedArchiver.archivedData(withRootObject: "Wrong root" as NSString, requiringSecureCoding: true)
pasteboard.setData(wrongArchive, forType: .iinaPlaylistItem)
check(!acceptInternal(at: 1) && player.moves.isEmpty && player.additions.isEmpty,
      "A malformed internal drag archive is rejected instead of being reinterpreted as an external paste")
prepare(filtered: false)
startDrag([1])
let invalidArchive = try NSKeyedArchiver.archivedData(withRootObject: IndexSet(integer: 90), requiringSecureCoding: true)
pasteboard.setData(invalidArchive, forType: .iinaPlaylistItem)
check(!acceptInternal(at: 2) && player.moves.isEmpty,
      "Out-of-range archived drag indexes cannot reach the playback mutation boundary")

print("PASS: \(checks) production playlist filter interaction checks")
