import Foundation

// The production admission and complete append methods are real. Only the player
// shell is replaced; its commands and snapshots use the integration's live mpv core.
enum Utility {
  static func isLocalPlaybackPath(_ path: String) -> Bool { path.hasPrefix("/") }
}

extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("fixture.playlist.changed")
}

final class PlaylistAdmissionMPV {
  func playlistAppend(_ path: String) {
    check(command(["loadfile", path, "append"]), "Admitted production append reaches real libmpv")
  }
}

class PlaylistAdmissionBoundary {
  let playlistMutationLock = NSRecursiveLock()
  let mpv = PlaylistAdmissionMPV()
  private(set) var notifications = 0
  func getPlaylist() {}
  func playlistSnapshot() -> [MPVPlaylistItem]? { snapshot() }
  func playlistMove(_ from: Int, to: Int) {
    check(command(["playlist-move", String(from), String(to)]), "Admitted production insertion uses real libmpv")
  }
  func postNotification(_ name: Notification.Name) { notifications += 1 }
}
