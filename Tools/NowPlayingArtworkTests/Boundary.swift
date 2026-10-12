import Foundation

// Only external image generation and system publication are replaced. The
// coordinator, tickets, retry budget, completion and priority enum are extracted.
enum Logger { enum Level { case debug, verbose } }
enum Preference {
  enum Key { case enableNowPlayingArtwork }
  static func bool(for key: Key) -> Bool { true }
}
let MPMediaItemPropertyArtwork = "Artwork"
final class MPNowPlayingInfoCenter {
  static let center = MPNowPlayingInfoCenter()
  static func `default`() -> MPNowPlayingInfoCenter { center }
  var nowPlayingInfo: [String: Int]? = [MPMediaItemPropertyArtwork: 1]
}
struct MPVTrack {}
final class PlayerCore {
  static let lastActive = PlayerCore()
  let info = Info()
  final class Info {
    struct State { var active = true }
    var state = State()
    var isNetworkResource = false
    var videoTracks: [MPVTrack] = []
  }
}
final class WorkerGate {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
}
class ArtworkBoundary {
  @Atomic var gate: WorkerGate? = nil
  @Atomic var coverAvailable = false
  @Atomic var quickLookSucceeds = false
  @Atomic var requests: [(ticket: Int, onMain: Bool)] = []
  var currentURL = URL(fileURLWithPath: "/synthetic-current.mp4")
  var oscRequests = 0
  var pendingUpdates = 0
  func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {}
  func log(_ message: String, _ url: URL, level: Logger.Level = .debug) {}
}
extension NowPlayingInfoManager {
  func searchTracksForArtwork(_ player: PlayerCore, _ url: URL,
                             _ ticket: Int, _ tracks: [MPVTrack]) -> Bool {
    if let heldGate = gate {
      heldGate.entered.signal()
      precondition(heldGate.release.wait(timeout: .now() + 5) == .success)
    }
    guard coverAvailable else { return false }
    DispatchQueue.main.async { [self] in
      defer { artworkUpdateComplete() }
      guard artworkTicket == ticket else { return }
      artworkKind = .frontCover
    }
    return true
  }
  func generateQLThumbnail(_ player: PlayerCore, _ url: URL, _ ticket: Int) {
    $requests.withLock { $0.append((ticket, Thread.isMainThread)) }
    DispatchQueue.main.async { [self] in
      defer { artworkUpdateComplete() }
      guard artworkTicket == ticket else { return }
      if quickLookSucceeds { artworkKind = .qlThumbnail }
      else { useOSCThumbnail(player, url) }
    }
  }
  func useOSCThumbnail(_ player: PlayerCore, _ url: URL) {
    dispatchPrecondition(condition: .onQueue(.main))
    oscRequests += 1
    if artworkKind.need(.oscThumbnail) { artworkKind = .oscThumbnail }
  }
  func updateInfo() {
    dispatchPrecondition(condition: .onQueue(.main))
    pendingUpdates += 1
    updateArtwork(PlayerCore.lastActive, currentURL, [])
  }
}
