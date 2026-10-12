import AppKit
import AVFoundation

// Application services and the legacy renderer are test boundaries. The native
// decoder, clock, output, layer, VideoView and extracted route methods are real.
final class MainWindowDouble: NSResponder {
  unowned let player: PlayerCore
  private var storedWindow: NSWindow?
  private var storedVideoView: VideoView?
  var window: NSWindow? {
    if let storedWindow { return storedWindow }
    let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    created.isReleasedWhenClosed = false
    storedWindow = created
    let video = VideoView(frame: created.contentView!.bounds, player: player)
    storedVideoView = video
    created.contentView = video
    player.initVideo()
    return created
  }
  var videoView: VideoView { _ = window; return storedVideoView! }
  var loaded: Bool { storedWindow != nil }
  var pendingShow = false
  var rotation = 0
  var setupCount = 0
  var showCount = 0
  var volumeEnabled = false
  let quickSettingView = QuickSettingDouble()
  struct FullscreenState { var isFullscreen = false }
  var fsState = FullscreenState()
  enum PIPStatus { case hidden, inPIP }
  var pipStatus = PIPStatus.hidden
  final class PIP { var playing = false }
  let pip = PIP()
  init(player: PlayerCore) { self.player = player; super.init() }
  required init?(coder: NSCoder) { fatalError("Unavailable") }
  func showWindow(_ sender: Any?) { showCount += 1; window?.orderFront(nil) }
  func setupUI() { setupCount += 1; updateVolume() }
  func updateVolume() { volumeEnabled = player.hasSelectedPlaybackAudio }
  func updateSpeedLabel(speed: Double) {}
  func handleVideoSizeChange() {
    guard let media = player.nativePlaybackMedia else { return }
    let rotated = media.rotationDegrees == 90 || media.rotationDegrees == 270
    let size = CGSize(width: rotated ? media.displayHeight : media.displayWidth,
      height: rotated ? media.displayWidth : media.displayHeight)
    window?.setContentSize(size)
    videoView.forcePlaybackRedraw()
  }
  func toggleWindowFullScreen() { fsState.isFullscreen.toggle() }
  func menuShowPlaylistPanel(_ sender: NSButton) {}
  func hideSideBar() {}
  func close() { storedWindow?.orderOut(nil); storedWindow?.close() }
}
final class QuickSettingDouble { func setHdrAvailability(to: Bool) {} }
final class InitialWindowDouble { var pendingShow = false; func close() {} }

class PlaybackInfoFields {
  var currentURL: URL?
  var isNetworkResource = false
  var shouldAutoLoadFiles = false
  var audioTracks: [Int] = [], videoTracks: [Int] = [], subTracks: [Int] = [], chapters: [Int] = []
  var aid: Int?, vid: Int?, sid: Int?, secondSid: Int?
  var videoWidth: Int?, videoHeight: Int?, displayWidth: Int?, displayHeight: Int?
  var videoDuration: VideoTime?, videoPosition: VideoTime?, videoRemaining: VideoTime?
  var playlist: [MPVPlaylistItem] = []
  var volume: Double = 0, playSpeed: Double = 1
  var audioDelay: Double = 0
  var audioEqFilter: String?
  var isMuted = false, deinterlace = false, justOpenedFile = false, justStartedFile = false
  var disableOSDForFileLoading = false, hdrAvailable = false, hdrEnabled = false, isSeeking = false
  var rotation = 0
  var thumbnails: [Int] = []
  var thumbnailsReady = false
  @Atomic var matchedSubs: [String: String] = [:]
}
func == (lhs: PlayerCore, rhs: PlayerCore?) -> Bool { lhs === rhs }
enum SleepPreventer { static func updateSleepPrevention() {} }
final class NowPlayingInfoManager {
  static let shared = NowPlayingInfoManager()
  func updateInfo() {}
}
final class VideoTime { var second: Double; init(_ value: Double) { second = value } }
struct MPVPlaylistItem { let filename: String; let isCurrent: Bool; let isPlaying: Bool; let title: String? }
enum LoopMode { case off, file, playlist }
final class UpdateWorkAdmission {
  static let shared = UpdateWorkAdmission()
  var isOpeningMediaBlocked = false
}
final class HistoryController {
  static let shared = HistoryController()
  var urls: [URL] = []
  func add(_ url: URL, duration: Double) { urls.append(url) }
}
final class EventDouble {
  enum Name { case fileLoaded, mpvInitialized }
  func emit(_ name: Name, data: String = "") {}
}
extension Notification.Name {
  static let chengyingMediaSourceChanged = Self("route-source")
  static let iinaFileLoaded = Self("route-loaded")
  static let iinaPlayerStopped = Self("route-stopped")
}

final class MPVController {
  weak var player: PlayerCore?
  var renderInitializations = 0, quitCalls = 0, firstLoads = 0
  var mpvRenderContext: Int?
  var flags = [MPVProperty.idleActive: true, MPVOption.PlaybackControl.pause: true]
  init(player: PlayerCore) { self.player = player }
  func lockAndSetOpenGLContext() {}
  func unlockOpenGLContext() {}
  func mpvUninitRendering() { mpvRenderContext = nil }
  func mpvReportSwap() {}
  func mpvInitRendering() { renderInitializations += 1; mpvRenderContext = 1 }
  func mpvQuit() { quitCalls += 1 }
  func prepareForFirstMPVMediaLoad() { firstLoads += 1 }
  func setDouble(_ key: String, _ value: Double) {}
  func setFlag(_ key: String, _ value: Bool, level: Logger.Level = .debug) { flags[key] = value }
  func setString(_ key: String, _ value: String) {}
  func setInt(_ key: String, _ value: Int) {}
  func getFlag(_ key: String) -> Bool { flags[key] ?? false }
  func getString(_ key: String) -> String? { nil }
  func getDouble(_ key: String) -> Double { 0 }
  func command(_ name: MPVCommand, args: [String] = [], level: Logger.Level = .debug) {
    if name == .loadfile { player?.noteMPVMediaCommand() }
  }
}
enum MPVCommand { case stop, loadfile }
final class CompatibilityTransportDouble: PlaybackTransport {
  var kind = PlaybackTransportKind.mpv
  var volumePercent: Double = 0, rate: Double = 1
  var isPaused = true
  var position: Double? = 0
  var isAtEOF = false
  func setPaused(_ paused: Bool, context: PlaybackCommandContext) -> PlaybackTransportResult { isPaused = paused; return .accepted }
  func seek(_ request: PlaybackSeekRequest, context: PlaybackCommandContext) -> PlaybackTransportResult { position = request.value; return .accepted }
  func setVolumePercent(_ volume: Double, context: PlaybackCommandContext) -> PlaybackTransportResult { volumePercent = volume; return .accepted }
  func setRate(_ value: Double, context: PlaybackCommandContext) -> PlaybackTransportResult { rate = value; return .accepted }
}
final class ViewLayer: CALayer {
  static var constructions = 0
  var colorspace: CGColorSpace?
  override var wantsExtendedDynamicRangeContent: Bool { get { false } set {} }
  var inLiveResize = false
  init(_ view: VideoView) { Self.constructions += 1; super.init() }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError("Unavailable") }
  func update(force: Bool = false) {}
  func setRenderICCProfile(_ profile: NSColorSpace) -> Bool { false }
}

enum Preference {
  enum Key { case videoViewAcceptsFirstMouse, enableDisplayIdle, loadIccProfile, enableToneMapping, toneMappingTargetPeak,
    toneMappingAlgorithm, enableAdvancedSettings, useUserDefinedConfDir, currentInputConfigName, savedVideoFilters,
    savedAudioFilters, subAutoLoadSearchPath, subAutoLoadIINA, resumeLastPosition, scaleRemainingTime, pauseWhenOpen,
    fullScreenWhenOpen, enableHdrSupport }
  static var pauseWhenOpen = false
  static var effectiveAudioDeviceName = "auto"
  static func bool(for key: Key) -> Bool { key == .pauseWhenOpen ? pauseWhenOpen : false }
  static func integer(for key: Key) -> Int { 0 }
  static func array(for key: Key) -> [Any]? { [] }
  static func string(for key: Key) -> String? {
    key == .currentInputConfigName ? "ChengYing Default" : key == .subAutoLoadSearchPath ? "./*" : nil
  }
  static func savedLoopMode(in defaults: UserDefaults, domain: String?) -> LoopMode? { .off }
  enum ToneMappingAlgorithmOption: Int { case basic; static let defaultValue = Self.basic; var mpvString: String { "auto" } }
}
enum Utility {
  enum ExtensionType { case video, sub }
  static let supportedFileExt: [ExtensionType: [String]] = [.video: ["mp4"], .sub: ["srt", "ass"]]
  static let playableFileExt = ["mp4"]
  static var watchLaterURL = URL(fileURLWithPath: "/nonexistent-route-fixture")
  static var alerts: [String] = []
  static func mpvWatchLaterMd5(_ path: String) -> String { "synthetic-file-only" }
  static func mediaLogSummary(_ url: URL) -> String { "synthetic-video" }
  static func showAlert(_ name: String) { alerts.append(name) }
}
enum Logger {
  struct Subsystem { let rawValue: String }
  enum Level { case debug, warning, verbose, error }
  static func makeSubsystem(_ name: String) -> Subsystem { Subsystem(rawValue: name) }
  static func log(_ message: String, level: Level = .debug, subsystem: Subsystem) {}
  static func log(_ message: () -> String, level: Level = .debug, subsystem: Subsystem) {}
  static func fatal(_ message: String) -> Never { fatalError(message) }
}
extension NSScreen { static func logEDR(_ text: String, _ screen: NSScreen, subsystem: Logger.Subsystem) {} }
extension NSPasteboard.PasteboardType {
  static let nsFilenames = Self("NSFilenamesPboardType")
  static let nsURL = Self("NSURLPboardType")
}
extension NSButton { static var dummy: NSButton { NSButton() } }
func mutableRawPointerOf(obj: AnyObject) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(obj).toOpaque() }
func CoreDisplay_DisplayCreateInfoDictionary(_ display: UInt32) -> Unmanaged<CFDictionary>? { nil }
