import Cocoa

// Playback is the only behavioral boundary stub. Metadata reads, OperationQueue,
// controller bodies, AppKit controls, and cell classes are production code.
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
extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("iinaPlaylistChanged")
  static let iinaPlayerStopped = Notification.Name("iinaPlayerStopped")
  static let iinaPlayerShutdown = Notification.Name("iinaPlayerShutdown")
}
extension NSColor.Name {
  static let playlistProgressBar = NSColor.Name("playlistProgressBar")
}
