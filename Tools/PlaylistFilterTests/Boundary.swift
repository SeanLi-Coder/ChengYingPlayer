import Cocoa

// No player, filesystem mutation, application window, or shared pasteboard is used.
// The boundary records real controller requests and preserves mpv move semantics.
final class ProbeTableView: NSTableView {
  var selectedIndexes = IndexSet()
  var clickedIndex = -1
  var senderRow = -1
  var reloadCount = 0
  var partialReloads: [IndexSet] = []
  override var selectedRowIndexes: IndexSet { selectedIndexes }
  override var selectedRow: Int { selectedIndexes.first ?? -1 }
  override var numberOfSelectedRows: Int { selectedIndexes.count }
  override var clickedRow: Int { clickedIndex }
  override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
    selectedIndexes = extend ? selectedIndexes.union(indexes) : indexes
  }
  override func deselectAll(_ sender: Any?) { selectedIndexes = [] }
  override func reloadData() { reloadCount += 1 }
  override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
    partialReloads.append(rowIndexes)
  }
  override func row(for view: NSView) -> Int { senderRow }
  override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {}
}
final class ProbePopover: NSPopover {
  var presentationCount = 0
  override func show(relativeTo positioningRect: NSRect, of positioningView: NSView,
                     preferredEdge: NSRectEdge) { presentationCount += 1 }
}
final class SubPopoverViewController: NSViewController {
  var player: PlayerCore!
  var filePath = ""
  let tableView = ProbeTableView()
  var playlistTableView = ProbeTableView()
  let heightConstraint = NSLayoutConstraint()
}
final class ProbePlaybackState { var active = true }
final class ProbePlaybackInfo {
  let state = ProbePlaybackState()
  @Atomic var playlist: [MPVPlaylistItem] = []
  @Atomic var matchedSubs: [String: [URL]] = [:]
}
final class ProbeMPV {
  var position = 0
  func getInt(_ property: String) -> Int { position }
}
enum MPVProperty { static let playlistPos = "playlist-pos" }
final class PlayerCore {
  let info = ProbePlaybackInfo()
  let mpv = ProbeMPV()
  let subsystem = "playlist-filter-tests"
  let playlistMutationLock = NSRecursiveLock()
  var livePlaylist: [MPVPlaylistItem] = []
  var snapshotAvailable = true
  var removedIDs: [Int64] = []
  var playedIDs: [Int64] = []
  var playedChapters: [Int] = []
  var moves: [(Int, Int)] = []
  var additions: [(paths: [String], index: Int)] = []
  var notifications = 0
  var onPlayableFiles: (() -> Void)?
  func playlistSnapshot() -> [MPVPlaylistItem]? { snapshotAvailable ? livePlaylist : nil }
  func playlistRemove(_ rows: IndexSet) {
    for row in rows.reversed() {
      precondition(livePlaylist.indices.contains(row), "Invalid removal index")
      removedIDs.append(livePlaylist.remove(at: row).entryID)
    }
  }
  func playFileInPlaylist(_ index: Int) {
    precondition(livePlaylist.indices.contains(index), "Invalid playback index")
    playedIDs.append(livePlaylist[index].entryID)
  }
  func playChapter(_ index: Int) { playedChapters.append(index) }
  func playlistMove(_ source: Int, to destination: Int) {
    precondition(livePlaylist.indices.contains(source) && (0...livePlaylist.count).contains(destination),
                 "Invalid reorder index")
    moves.append((source, destination))
    let item = livePlaylist.remove(at: source)
    livePlaylist.insert(item, at: destination > source ? destination - 1 : destination)
  }
  func addToPlaylist(paths: [String], at index: Int) {
    precondition((0...livePlaylist.count).contains(index), "Invalid insertion index")
    additions.append((paths, index))
  }
  func getPlayableFiles(in urls: [URL]) -> [URL] {
    onPlayableFiles?()
    return urls.filter(\.isFileURL)
  }
  func acceptFromPasteboard(_ info: NSDraggingInfo, isPlaylist: Bool) -> NSDragOperation { .copy }
  func postNotification(_ name: Notification.Name) { notifications += 1 }
}
enum Utility { static func resolveURLs(_ urls: [URL]) -> [URL] { urls } }
enum Logger {
  enum Level { case error }
  static func log(_ message: String, level: Level? = nil, subsystem: String) {}
}
extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("iinaPlaylistChanged")
}
extension NSPasteboard.PasteboardType {
  static let iinaPlaylistItem = NSPasteboard.PasteboardType("IINAPlaylistItem")
  static let nsFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  static let nsURL = NSPasteboard.PasteboardType("NSURLPboardType")
}
final class ProbeDraggingInfo: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  let draggingSource: Any?
  init(pasteboard: NSPasteboard, source: Any?) {
    draggingPasteboard = pasteboard
    draggingSource = source
  }
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  var draggedImage: NSImage? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                              classes classArray: [AnyClass],
                              searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                              using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
