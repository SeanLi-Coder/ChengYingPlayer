import Cocoa

enum Utility {
  static let playableFileExt = ["mp4", "mkv", "mp3", "flac"]
}

enum Preference {
  enum Key { case recordRecentFiles }
  static var recordRecentFiles = true
  static func bool(for key: Key) -> Bool { recordRecentFiles }
}
final class AppDelegate {
  static let shared = AppDelegate()
  var recentURLs: [URL] = []
  func noteNewRecentDocumentURL(_ url: URL) { recentURLs.append(url) }
}
final class PlayerCore {
  static var urls: [URL] = []
  static func openURLs(_ urls: [URL]) -> Int? { self.urls = urls; return urls.count }
}
