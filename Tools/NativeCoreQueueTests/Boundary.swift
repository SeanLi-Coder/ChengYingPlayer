import AppKit
import AVFoundation

// Only application/UI services are boundaries. Playlist installation, media
// decoding, MPV properties/commands/events, and Core state machines are real.
var fixtureDirectory: URL!
var deliveredRotations: [(URL, Int)] = []
final class MPVPlaylistItem {
  let filename: String
  var isCurrent: Bool, isPlaying: Bool
  let title: String?
  init(filename: String, isCurrent: Bool, isPlaying: Bool, title: String?) {
    self.filename = filename; self.isCurrent = isCurrent; self.isPlaying = isPlaying; self.title = title
  }
}
enum TicketExpiredError: Error { case ticketExpired }
final class AppDelegate {
  static let shared = AppDelegate()
  func noteNewRecentDocumentURL(_ url: URL) { preconditionFailure("Recent documents must stay disabled") }
}
extension CharacterSet { static let urlAllowed = CharacterSet.urlQueryAllowed }
extension Data { init<T>(bytesOf value: [T]) { self = value.withUnsafeBytes { Data($0) } } }
extension Double { func clamped(to range: Range<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound.nextDown) } }
extension Double { func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) } }
final class TestTouchBar { func setupTouchBarUI() {} }
extension VideoTime { static var zero: VideoTime { VideoTime(0) } }
extension Preference {
  enum SeekOption { case relative, exact, auto }
  static var resumePositionWrites = [Double]()
  static var resumePathWrites = [URL]()
  static func set(_ value: Double, for key: Key) {
    if key == .iinaLastPlayedFilePosition { resumePositionWrites.append(value) }
    else { precondition(key == .softVolume) }
  }
  static func set(_ value: URL, for key: Key) {
    precondition(key == .iinaLastPlayedFilePath)
    resumePathWrites.append(value)
  }
}
enum AppData { static let mpvMinPlaybackSpeed = 0.01 }
extension Notification.Name { static let iinaPlaylistChanged = Self("queue-playlist") }
extension Notification.Name { static let iinaTracklistChanged = Self("queue-tracks") }
extension Utility {
  static func isLocalPlaybackPath(_ path: String) -> Bool { path.hasPrefix("/") }
  static let playlistFileExt: Set<String> = ["m3u", "m3u8"]
  static func showAlert(_ name: String, style: NSAlert.Style) { alerts.append(name) }
}
extension String { var lowercasedPathExtension: String { (self as NSString).pathExtension.lowercased() } }
extension PlaybackInfoFields {
  func getMatchedSubs(_ path: String) -> [URL]? { nil }
  func setCachedVideoDuration(_ path: String, _ duration: Double) {}
  func setCachedVideoDurationAndProgress(_ path: String, _ value: (duration: Double, progress: Double)) {
    cachedResumeWrites.append((path, value.duration, value.progress))
  }
}
var cachedResumeWrites = [(String, Double, Double)]()
extension MainWindowDouble {
  enum SettingsTab { case tools }
  func showSettingsSidebar(tab: SettingsTab, hideIfAlreadyShown: Bool) {}
  var isVideoLoaded: Bool { player.info.videoWidth != nil }
  func forceDraw(_ text: String, always: Bool = false) {}
}
extension UpdateWorkAdmission { var isHelperRestartBlocked: Bool { false } }
extension QuickSettingDouble {
  func cancelPendingAutomaticVideoToolsPreview() {}
  func applyPermanentRotation(clockwiseQuarterTurns: Int, inputURL: URL) -> Bool {
    deliveredRotations.append((inputURL, clockwiseQuarterTurns)); return true
  }
}
extension InitialWindowDouble { var defaultAlbumArt: NSView { NSView() } }

final class MPVController: MPVQueueInstallationBackend {
  weak var player: PlayerCore?
  let client: LiveQueueClient
  var mpv: OpaquePointer? { client.handle }
  var mpvRenderContext: Int?
  var renderInitializations = 0, quitCalls = 0, firstLoads = 0, titleReads = 0
  var owner: UUID?
  var receiver: ((MPVQueueInstaller.Event) -> Void)?
  var contextEntryID: Int64?
  var beforeRestart: (() -> Void)?
  var cancelledStopRequests = [UUID]()
  var preparedStopRequests = [(owner: UUID, mpvRouteEnabled: Bool)]()
  init(player: PlayerCore) {
    self.player = player
    client = LiveQueueClient(directory: fixtureDirectory)
    _ = mpv_set_property_string(client.handle, "volume", "0")
  }
  func queueCommand(_ arguments: [String]) -> Int32? {
    if arguments.first == "loadfile" { player?.noteMPVMediaCommand() }
    return client.queueCommand(arguments)
  }
  func queueSetPaused() -> Int32? { client.queueSetPaused() }
  func queueSnapshot() -> MPVQueueInstallationSnapshot? { client.queueSnapshot() }
  var queueHasReachedInitialIdle: Bool { client.queueHasReachedInitialIdle }
  func beginNativeQueueInstallation(owner: UUID, receive: @escaping (MPVQueueInstaller.Event) -> Void) -> Bool {
    guard self.owner == nil, player?.captureMPVEventRevision() == nil else { return false }
    self.owner = owner; receiver = receive; contextEntryID = nil
    return true
  }
  func endNativeQueueInstallation(owner: UUID) {
    guard self.owner == owner else { return }
    self.owner = nil; receiver = nil
  }
  // The real controller's quiescence and event-drain protocol is tested by
  // PlaybackBackendRoutingTests. This service boundary records Core ownership;
  // only the test explicitly delivers its completion, never a fake MPV event.
  func prepareCancelledNativeQueueStop(owner: UUID) {
    preparedStopRequests.append((owner, player?.captureMPVEventRevision() != nil))
  }
  func stopCancelledNativeQueue(owner: UUID) {
    cancelledStopRequests.append(owner)
    _ = queueCommand(["stop", "keep-playlist"])
  }
  func acknowledgeCancelledStopForCoreTest() -> Bool {
    guard !cancelledStopRequests.isEmpty,
          let snapshot = queueSnapshot(), snapshot.idle, snapshot.activePath == nil,
          snapshot.entries.allSatisfy({ !$0.current && !$0.playing }),
          queueCommand(["playlist-clear"]).map({ $0 >= 0 }) == true,
          queueSnapshot()?.entries.isEmpty == true else { return false }
    player?.idleActiveChanged()
    return true
  }
  func pump() {
    guard let event = mpv_wait_event(client.handle, 0) else { return }
    client.noteQueueEvent(event.pointee.event_id)
    let receiver = receiver
    switch event.pointee.event_id {
    case MPV_EVENT_START_FILE:
      let id = event.pointee.data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
      contextEntryID = id
      if let receiver { receiver(.startFile(entryID: id)) }
      else if player?.captureMPVEventRevision() != nil, let path = client.string("path") {
        player?.info.state = .starting; player?.fileStarted(path: path)
      }
    case MPV_EVENT_FILE_LOADED:
      let id = contextEntryID
      if let receiver, let id { receiver(.fileLoaded(entryID: id)) }
      else if player?.captureMPVEventRevision() != nil { player?.fileLoaded() }
    case MPV_EVENT_END_FILE:
      let id = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.playlist_entry_id
      receiver?(.endFile(entryID: id))
    case MPV_EVENT_PLAYBACK_RESTART:
      if let receiver, let id = contextEntryID { receiver(.playbackRestart(entryID: id)) }
      else if player?.captureMPVEventRevision() != nil {
        let callback = beforeRestart; beforeRestart = nil; callback?()
        player?.playbackRestarted()
      }
    case MPV_EVENT_VIDEO_RECONFIG:
      if receiver == nil, player?.captureMPVEventRevision() != nil { player?.onVideoReconfig() }
    case MPV_EVENT_SHUTDOWN: receiver?(.shutdown)
    case MPV_EVENT_QUEUE_OVERFLOW: receiver?(.queueOverflow)
    default: break
    }
  }
  func lockAndSetOpenGLContext() {}
  func unlockOpenGLContext() {}
  func mpvUninitRendering() { mpvRenderContext = nil }
  func mpvReportSwap() {}
  func mpvInitRendering() { renderInitializations += 1; mpvRenderContext = 1 }
  func mpvQuit() { quitCalls += 1 }
  func prepareForFirstMPVMediaLoad() { firstLoads += 1 }
  func setDouble(_ key: String, _ value: Double) { var value = value; _ = mpv_set_property(client.handle, key, MPV_FORMAT_DOUBLE, &value) }
  func setFlag(_ key: String, _ value: Bool, level: Logger.Level = .debug) { _ = mpv_set_property_string(client.handle, key, value ? "yes" : "no") }
  func setString(_ key: String, _ value: String) { _ = mpv_set_property_string(client.handle, key, value) }
  func setInt(_ key: String, _ value: Int) { setString(key, String(value)) }
  func getFlag(_ key: String) -> Bool { client.flag(key) ?? false }
  func getString(_ key: String) -> String? { client.string(key) }
  func getDouble(_ key: String) -> Double { var value = 0.0; _ = mpv_get_property(client.handle, key, MPV_FORMAT_DOUBLE, &value); return value }
  func getInt(_ key: String) -> Int { Int(getDouble(key)) }
  func playlistAppend(_ path: String) { _ = queueCommand(["loadfile", path, "append"]) }
  func playlistMove(_ from: Int, to: Int) { _ = queueCommand(["playlist-move", String(from), String(to)]) }
  func playlistRemove(_ index: Int) { _ = queueCommand(["playlist-remove", String(index)]) }
  func command(_ name: MPVCommand, args: [String] = [], checkError: Bool = true, level: Logger.Level = .debug) {
    _ = queueCommand([name.rawValue] + args)
  }
}

extension PlayerCore {
  var videoToolsCurrentTime: Double? { playbackPosition }
  var videoToolsLoopRange: VideoToolsLoopRange? { VideoToolsLoopRange(start: playbackLoopA, end: playbackLoopB) }
  var backgroundQueue: DispatchQueue { .global(qos: .utility) }
  var backgroundTaskInUse: Bool { !backgroundTaskTickets.isEmpty }
  var touchBarSupport: TestTouchBar { TestTouchBar() }
  func isBDFolder(_ url: URL) -> Bool { false }
  func getPlayableFiles(in urls: [URL]) -> [URL] {
    PlaylistPlaybackPolicy.playableFiles(in: urls, videoExtensions: ["mp4"], blacklistedExtensions: [])
  }
  func autoLoadFilesInCurrentFolder(ticket: Int) throws { preconditionFailure("Explicit queue must not invoke folder matcher") }
  func checkTicket(_ value: Int) throws {}
  func loadExternalSubFile(_ url: URL) { preconditionFailure("No external subtitles in this fixture") }
  enum TrackType { case sub }
  func setTrack(_ value: Int, forType: TrackType) { preconditionFailure("No external subtitles in this fixture") }
  func checkUnsyncedWindowOptions() {}
  func videoToolsResetViewport() {}
  func trackListChanged() {
    info.vid = mpv.getInt("vid"); info.aid = mpv.getInt("aid")
    postNotification(.iinaTracklistChanged)
  }
  func getPlaylist() {
    info.playlist = (mpv.queueSnapshot()?.entries ?? []).map {
      MPVPlaylistItem(filename: $0.path, isCurrent: $0.current, isPlaying: $0.playing, title: nil)
    }
  }
  func playlistSnapshot() -> [MPVPlaylistItem]? {
    guard let snapshot = mpv.queueSnapshot() else { return nil }
    return snapshot.entries.map { MPVPlaylistItem(filename: $0.path, isCurrent: $0.current, isPlaying: $0.playing, title: nil) }
  }
  func getChapters() {}
  func restoreNativeLoopToMPV(start: Double?, end: Double?) {
    mpv.setString("ab-loop-a", start.map(String.init(describing:)) ?? "no")
    mpv.setString("ab-loop-b", end.map(String.init(describing:)) ?? "no")
  }
  func videoToolsRestoreViewportToMPV(_ viewport: VideoToolsViewport) {
    mpv.setDouble("video-zoom", viewport.zoom)
    mpv.setDouble("video-pan-x", viewport.panX)
    mpv.setDouble("video-pan-y", viewport.panY)
  }
  func reloadSavedIINAfilters() {}
  func needReloadQuickSettingsView() {}
  func refreshEdrMode() {}
  func makeMPVTransport() -> PlaybackTransport {
    MPVPlaybackTransport(sink: .init(isAvailable: { true }, getFlag: { [unowned self] in self.mpv.getFlag($0) },
      getDouble: { [unowned self] in self.mpv.getDouble($0) },
      setFlag: { [unowned self] key, value, _ in self.mpv.setFlag(key, value) },
      setDouble: { [unowned self] key, value, _ in self.mpv.setDouble(key, value) },
      command: { [unowned self] name, args, _ in _ = self.mpv.queueCommand([name] + args) }))
  }
}
