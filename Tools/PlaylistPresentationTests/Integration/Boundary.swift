import Cocoa

// Playback and opening media are boundary stubs. Metadata reads, OperationQueue,
// controller bodies, AppKit controls, folder browsing, and cells are production code.
final class ProbePlaybackState { var active = true }
final class ProbePlaybackInfo {
  let state = ProbePlaybackState()
  var currentURL: URL?
  var playlist: [MPVPlaylistItem] = []
}
final class PlayerCore: NSObject {
  let info = ProbePlaybackInfo()
  var backendPlaylist: [MPVPlaylistItem] = []
  var reorderCount = 0
  var snapshotReads = 0
  var inactiveReads = 0
  var openedURLs: [URL] = []
  func openURL(_ url: URL, shouldAutoLoad: Bool = true) {
    openedURLs.append(url)
  }
  func getPlaylist() {
    snapshotReads += 1
    if !info.state.active { inactiveReads += 1 }
    info.playlist = backendPlaylist
  }
  func playlistReorder(newPlaylist: [MPVPlaylistItem]) -> Bool {
    reorderCount += 1
    backendPlaylist = newPlaylist
    return true
  }
}
enum Utility {
  static let playableFileExt = ["mp4", "mkv", "mov", "webm", "mp3", "m4a"]
}
final class ImageViewerCoordinator {
  static let shared = ImageViewerCoordinator()
  var openedURLGroups: [[URL]] = []
  func openImages(in urls: [URL]) {
    openedURLGroups.append(urls)
  }
}
extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("iinaPlaylistChanged")
  static let iinaPlayerStopped = Notification.Name("iinaPlayerStopped")
  static let iinaPlayerShutdown = Notification.Name("iinaPlayerShutdown")
  static let iinaFileLoaded = Notification.Name("iinaFileLoaded")
}
extension NSColor.Name {
  static let playlistProgressBar = NSColor.Name("playlistProgressBar")
}
