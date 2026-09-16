import Cocoa

// Preserve the production controller and real AppKit pasteboard while replacing
// only playback, file deletion, external applications, and modal file selection.
final class ActionTableView: NSTableView {
  var clickedIndex = 0
  var selectedIndexes = IndexSet(integer: 0)
  override var clickedRow: Int { clickedIndex }
  override var selectedRowIndexes: IndexSet { selectedIndexes }
}
final class PlaybackState { var active = true }
final class PlaybackInfo {
  let state = PlaybackState()
  @Atomic var playlist: [MPVPlaylistItem] = []
  @Atomic var matchedSubs: [String: [URL]] = [:]
  func getMatchedSubs(_ path: String) -> [URL]? { matchedSubs[path] }
}
final class ProbeMPV {
  var position = 0
  func getInt(_ property: String) -> Int { position }
}
enum MPVProperty { static let playlistPos = "playlist-pos" }
final class PlayerCore {
  static var newPlayerCore = PlayerCore()
  let info = PlaybackInfo()
  let mpv = ProbeMPV()
  let subsystem = "test"
  let playlistMutationLock = NSRecursiveLock()
  var livePlaylist: [MPVPlaylistItem] = []
  var snapshotAvailable = true
  var snapshotCount = 0
  var inactiveSnapshotCount = 0
  var removedIDs: [Int64] = []
  var openedURLs: [URL] = []
  var addedPaths: [String] = []
  func playlistSnapshot() -> [MPVPlaylistItem]? {
    snapshotCount += 1
    if !info.state.active { inactiveSnapshotCount += 1 }
    return snapshotAvailable ? livePlaylist : nil
  }
  func playlistRemove(_ rows: IndexSet) {
    for row in rows.reversed() {
      guard livePlaylist.indices.contains(row) else { fatalError("Invalid removal row") }
      removedIDs.append(livePlaylist.remove(at: row).entryID)
    }
  }
  func playlistMove(_ from: Int, to: Int) {
    let item = livePlaylist.remove(at: from)
    livePlaylist.insert(item, at: to > from ? to - 1 : to)
  }
  func postNotification(_ name: Notification.Name) {}
  func openURLs(_ urls: [URL], shouldAutoLoad: Bool) { openedURLs = urls }
  func getPlayableFiles(in urls: [URL]) -> [URL] { urls.filter(\.isFileURL) }
  func addToPlaylist(paths: [String], at: Int) { addedPaths.append(contentsOf: paths) }
}
enum Logger {
  enum Level { case error }
  static func log(_ message: String, level: Level? = nil, subsystem: String) {}
}
enum TrackType { case sub }
enum Utility {
  static let supportedFileExt: [TrackType: [String]] = [.sub: ["srt", "ass"]]
  static var selectedFiles: (([URL]) -> Void)?
  static var onAlert: (() -> Void)?
  static func quickMultipleOpenPanel(title: String, dir: URL, canChooseDir: Bool,
                                    _ completion: @escaping ([URL]) -> Void) { selectedFiles = completion }
  static func showAlert(_ name: String, arguments: [String]) { onAlert?() }
  static func resolveURLs(_ urls: [URL]) -> [URL] { urls }
}
final class FileManager {
  static let `default` = FileManager()
  var trashedURLs: [URL] = []
  var onTrash: ((URL) throws -> Void)?
  func trashItem(at url: URL, resultingItemURL: UnsafeMutablePointer<NSURL?>?) throws {
    try onTrash?(url)
    trashedURLs.append(url)
  }
}
final class NSWorkspace {
  static let shared = NSWorkspace()
  var revealedURLs: [URL] = []
  func activateFileViewerSelecting(_ urls: [URL]) { revealedURLs = urls }
  func open(_ url: URL) {}
}
extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("iinaPlaylistChanged")
}
extension NSPasteboard.PasteboardType {
  static let iinaPlaylistItem = NSPasteboard.PasteboardType("IINAPlaylistItem")
  static let nsFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  static let nsURL = NSPasteboard.PasteboardType("NSURLPboardType")
}
