import Foundation

// The actual matcher, FileInfo, FileGroup, file scanning, and atomic storage are
// compiled unchanged. Preferences and playback are the application boundaries.
enum MPVTrack {
  enum TrackType { case video, audio, sub }
}
enum Preference {
  enum Key { case playlistAutoAdd, subAutoLoadSearchPath, subAutoLoadIINA, subAutoLoadPriorityString }
  enum IINAAutoLoadAction {
    case disabled, mpvFuzzy, iina
    func shouldLoadSubsContainingVideoName() -> Bool { self != .disabled }
    func shouldLoadSubsMatchedByIINA() -> Bool { self == .iina }
  }
  static var action = IINAAutoLoadAction.iina
  static var autoAdd = true
  static func bool(for key: Key) -> Bool { autoAdd }
  static func string(for key: Key) -> String? {
    key == .subAutoLoadSearchPath ? "./*" : ""
  }
  static func `enum`(for key: Key) -> IINAAutoLoadAction { action }
}
enum Utility {
  static let supportedFileExt: [MPVTrack.TrackType: [String]] = [
    .video: ["mp4", "mkv"], .audio: ["mp3"], .sub: ["srt", "ass"]
  ]
  static func mediaType(forExtension ext: String) -> MPVTrack.TrackType? {
    supportedFileExt.first { $0.value.contains(ext.lowercased()) }?.key
  }
}
enum Logger {
  typealias Subsystem = String
  enum Level { case debug, verbose, warning, error }
  static var messages: [String] = []
  static func makeSubsystem(_ name: String) -> Subsystem { name }
  static func log(_ message: String, level: Level = .debug, subsystem: Subsystem) { messages.append(message) }
  static func log(_ message: () -> String, level: Level = .debug, subsystem: Subsystem) { messages.append(message()) }
}
final class PlaybackInfo {
  var currentURL: URL?
  var isMatchingSubtitles = false
  @Atomic var matchedSubs: [String: [URL]] = [:]
  var currentSubsInfo: [FileInfo] = []
  var currentVideosInfo: [FileInfo] = []
}
enum MPVProperty {
  static let playlistCount = "playlist-count"
  static let playlistPos = "playlist-pos"
}
enum MPVCommand { case playlistMove }
enum MPVError: Int32 { case command = -12 }
let MPV_ERROR_COMMAND = MPVError.command
final class ProbeMPV {
  func getInt(_ property: String) -> Int { fatalError("Unexpected playlist command") }
  func command(_ command: MPVCommand, args: [String], checkError: Bool, level: Logger.Level,
               _ completion: (Int32) -> Void) { fatalError("Unexpected playlist command") }
}
final class PlayerCore {
  enum TicketExpiredError: Error { case ticketExpired }
  let playerNumber = 1
  let info = PlaybackInfo()
  let mpv = ProbeMPV()
  let playlistMutationLock = NSRecursiveLock()
  var validTicket = 1
  func checkTicket(_ ticket: Int) throws {
    if ticket != validTicket { throw TicketExpiredError.ticketExpired }
  }
  // A missing playback snapshot prevents list mutation, without suppressing
  // either production subtitle-matching stage or the default auto-add setting.
  func playlistSnapshot() -> [MPVPlaylistItem]? { nil }
  func appendToPlaylist(_ path: String, silent: Bool) { fatalError("Unexpected playlist command") }
  func postNotification(_ notification: Notification.Name) {}
}
extension Notification.Name {
  static let iinaPlaylistChanged = Notification.Name("AutoFileMatchingTests.playlistChanged")
}
extension URL {
  var isExistingDirectory: Bool {
    (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
extension String {
  mutating func deleteLast(_ number: Int) { removeLast(Swift.min(number, count)) }
  func countOccurrences(of text: String, in range: Range<Index>?) -> Int {
    guard let first = self.range(of: text, range: range) else { return 0 }
    return 1 + countOccurrences(of: text, in: first.upperBound..<endIndex)
  }
}
