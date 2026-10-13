// This boundary records admission only. It does not emulate media decoding,
// MPV playback, AppKit windows, or a native playlist.
enum LoopMode { case off, file, playlist }
enum State { case idle, shuttingDown, shutDown }
struct Info {
  var state = State.idle
  var shouldAutoLoadFiles = true
  var audioDelay = 0.0
  var audioEqFilter: String?
  var deinterlace = false
}
struct EventRoute { var revision: UInt64 = 0; var acceptsMPV = true }
enum MPVProperty { static let idleActive = "idle-active"; static let path = "path" }
final class MPVBoundary {
  var idle = true
  var path: String?
  var prepareCalls = 0
  func getFlag(_ name: String) -> Bool { precondition(name == MPVProperty.idleActive); return idle }
  func getString(_ name: String) -> String? { precondition(name == MPVProperty.path); return path }
  func prepareForFirstMPVMediaLoad() { precondition(Thread.isMainThread); prepareCalls += 1 }
}
class AdmissionBoundary {
  let nativeQueue: NativeQueueState? = nil
  func handoffUnopenedNativeQueue() {
    preconditionFailure("Explicit queue admission is outside this single-source fixture")
  }
  var nativeTerminationRequested = false
  var hasIssuedMPVMediaCommand = false
  var nativeSingleInput = true
  var plugins: [String] = []
  var info = Info()
  let mpv = MPVBoundary()
  var playbackEventRoute = EventRoute()
  var result: String?
  var nativeStarts = 0
  var compatibilityStarts = 0
  var logs: [String] = []
  func log(_ message: String) { precondition(Thread.isMainThread); logs.append(message) }
  @discardableResult
  func advancePlaybackRoute(acceptsMPV: Bool) -> UInt64 {
    precondition(Thread.isMainThread)
    playbackEventRoute.revision += 1
    playbackEventRoute.acceptsMPV = acceptsMPV
    return playbackEventRoute.revision
  }
  func beginNativeOpen(_ url: URL, request: UInt64) {
    precondition(Thread.isMainThread && request == playbackEventRoute.revision)
    precondition(!playbackEventRoute.acceptsMPV && result == nil)
    nativeStarts += 1
    result = "native"
  }
  func openMainWindow(path: String, url: URL, isNetwork: Bool, allowNative: Bool) {
    precondition(Thread.isMainThread && !isNetwork && !allowNative && path == url.path)
    precondition(playbackEventRoute.acceptsMPV && result == nil)
    compatibilityStarts += 1
    result = "compatibility"
  }
}
enum Preference {
  enum Key: Hashable {
    case enableAdvancedSettings, useUserDefinedConfDir, currentInputConfigName,
         savedVideoFilters, savedAudioFilters, subAutoLoadSearchPath, subAutoLoadIINA,
         keepOpenOnFileEnd, playlistAutoPlayNext, playlistAutoAdd, resumeLastPosition
  }
  static var booleans: [Key: Bool] = [:]
  static var subtitles = 0
  static var loop = LoopMode.off
  static var effectiveAudioDeviceName = "auto"
  static var inputConfiguration = "ChengYing Default"
  static var subtitleSearch = "./*"
  static func reset() {
    booleans = [.playlistAutoAdd: true, .playlistAutoPlayNext: true, .keepOpenOnFileEnd: true]
    subtitles = 0; loop = .off; effectiveAudioDeviceName = "auto"
    inputConfiguration = "ChengYing Default"; subtitleSearch = "./*"
  }
  static func bool(for key: Key) -> Bool { booleans[key] ?? false }
  static func integer(for key: Key) -> Int { precondition(key == .subAutoLoadIINA); return subtitles }
  static func array(for key: Key) -> [Any]? {
    precondition(key == .savedVideoFilters || key == .savedAudioFilters); return []
  }
  static func string(for key: Key) -> String? {
    switch key {
    case .currentInputConfigName: return inputConfiguration
    case .subAutoLoadSearchPath: return subtitleSearch
    default: preconditionFailure("Unexpected preference read")
    }
  }
  static func savedLoopMode(in defaults: UserDefaults, domain: String?) -> LoopMode? { loop }
}
enum Utility {
  enum ExtensionType { case video, sub }
  static let supportedFileExt: [ExtensionType: [String]] = [.video: ["mp4"], .sub: ["srt", "ass"]]
  static let playableFileExt = ["mp4", "mp3"]
  static var watchLaterURL = URL(fileURLWithPath: "/unconfigured-admission-fixture")
  static func mpvWatchLaterMd5(_ path: String) -> String { "fixture-record" }
}
