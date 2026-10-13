import Foundation

enum TestFailure: Error { case timeout }
enum MediaType: Hashable { case video, audio }
enum PlayerState { case playing, shuttingDown, shutDown }
enum TicketExpiredError: Error { case ticketExpired }
enum LogLevel { case verbose, error }
enum MPVCommand { case playlistMove }
enum MPVProperty { static let playlistCount = "playlist-count"; static let playlistPos = "playlist-pos" }
enum MPVError: Int32 { case command = -12 }
let MPV_ERROR_COMMAND = MPVError.command
enum OSD { case addToPlaylist(Int) }
extension Notification.Name { static let iinaPlaylistChanged = Notification.Name("fixture.playlist") }
extension String { var lowercasedPathExtension: String { (self as NSString).pathExtension.lowercased() } }

final class UpdateWorkAdmission {
  static let shared = UpdateWorkAdmission()
  var isOpeningMediaBlocked = false
}

enum Utility {
  enum AlertStyle { case informational }
  static let playlistFileExt = ["m3u", "m3u8"]
  static func showAlert(_ message: String, style: AlertStyle) {}
  static func mediaType(forExtension ext: String) -> MediaType? {
    switch ext { case "mp4", "mkv": return .video; case "mp3": return .audio; default: return nil }
  }
}

/// Retain the real recursive lock while exposing the exact pre-wait boundary.
final class ObservedRecursiveLock: NSLocking {
  private let lockValue = NSRecursiveLock()
  var beforeMainLock: (() -> Void)?
  func lock() {
    if Thread.isMainThread { beforeMainLock?() }
    lockValue.lock()
  }
  func unlock() { lockValue.unlock() }
}

final class Info {
  var state = PlayerState.playing
  var currentURL: URL?
  var shouldAutoLoadFiles = true
}
struct PlaylistItem { let filename: String }
struct FileInfo {
  let url: URL
  var path: String { url.path }
}
struct NativeQueuePlan { let items: [URL] }

/// Only transport and unrelated native lifecycle effects are replaced. Source
/// admission, cancellation, recursive-lock placement and matcher loops are real.
final class PlayerCore {
  @Atomic var backgroundQueueTicket = 1
  var nativeTerminationRequested = false
  let info = Info()
  let playlistMutationLock = ObservedRecursiveLock()
  var nativeTransport: Bool?
  var nativeCompatibilityRestore: Bool?
  var nativeSingleInput = false
  var nativePlan: NativeQueuePlan?
  var acceptsNativePlan = false
  var retirement: (() -> Void)?
  var discURLs = Set<URL>()
  var onResolve: (() -> Void)?
  var onAppend: ((String) -> Void)?
  var opened: [URL] = []
  var notifications = 0
  var nativeResetCount = 0
  var appendEvents: [String] = []
  var moveEvents = 0
  var snapshot: [PlaylistItem] = []
  var matcherStopped = false
  lazy var mpv = MPVBoundary(player: self)

  func getPlayableFiles(in urls: [URL]) -> [URL] {
    onResolve?()
    return PlaylistPlaybackPolicy.playableFiles(in: urls, videoExtensions: ["mp4", "mkv"],
                                               blacklistedExtensions: ["srt", "txt"])
  }
  func isBDFolder(_ url: URL) -> Bool { discURLs.contains(url) }
  func nativeExplicitQueuePlan(_ urls: [URL], playableFiles: [URL]) -> NativeQueuePlan? { nativePlan }
  func requestNativeResumeSave(replacement: Bool) {}
  func invalidateGenericHandoff() {}
  func resetNativeQueue() { nativeResetCount += 1 }
  func resetURLPlaylistEnqueue() {}
  func resetPermanentRotationMedia(to url: URL?) {}
  func retireNativePlayback(completion: @escaping () -> Void) { retirement = completion }
  func attemptNativeQueue(_ plan: NativeQueuePlan) -> Bool { acceptsNativePlan }
  func open(_ url: URL) {
    opened.append(url)
    info.currentURL = url
    snapshot = [PlaylistItem(filename: url.path)]
  }
  func postNotification(_ name: Notification.Name) { notifications += 1 }
  func sendOSD(_ message: OSD) {}
  func playlistSnapshot() -> [PlaylistItem]? { snapshot }
  func appendToPlaylist(_ path: String, silent: Bool) {
    playlistMutationLock.lock()
    defer { playlistMutationLock.unlock() }
    mpv.playlistAppend(path)
  }
}

final class MPVBoundary {
  unowned let player: PlayerCore
  init(player: PlayerCore) { self.player = player }
  func getInt(_ key: String) -> Int { key == MPVProperty.playlistCount ? player.snapshot.count : 0 }
  func playlistAppend(_ path: String) {
    player.appendEvents.append(path)
    player.snapshot.append(PlaylistItem(filename: path))
    player.onAppend?(path)
  }
  func command(_ command: MPVCommand, args: [String], checkError: Bool, level: LogLevel,
               returnValueCallback: (Int32) -> Void) {
    player.moveEvents += 1
    returnValueCallback(0)
  }
}

final class AutoFileMatcher {
  unowned let player: PlayerCore
  let ticket: Int
  var filesGroupedByMediaType: [MediaType: [FileInfo]]
  init(player: PlayerCore, files: [URL]) {
    self.player = player
    ticket = player.backgroundQueueTicket
    filesGroupedByMediaType = [.video: files.map(FileInfo.init)]
  }
  func checkTicket() throws { try player.checkTicket(ticket) }
  func log(_ message: String, level: LogLevel = .verbose) {}
}
