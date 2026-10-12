// Declaration-only boundary for local driver typechecking when full Xcode is unavailable.
// Never compile this file into the application or use it as runtime test evidence.
import AppKit
import AVFoundation

enum MPVProperty { static let idleActive = "idle-active" }
enum PlayerState { case idle, playing, paused, shutDown }
enum NativePlaybackPhase { case paused }
struct NativePlaybackSnapshot { var phase: NativePlaybackPhase; var volume: Float }
enum NativePlaybackQueryResult { case ready(NativePlaybackSnapshot), unavailable }
final class NativePlaybackSession {
  func captureCurrentState(completion: @escaping (NativePlaybackQueryResult) -> Void) {}
}
final class NativeSampleBufferOutput { let displayLayer = AVSampleBufferDisplayLayer() }
final class MPVController {
  var mpvRenderContext: OpaquePointer?
  func getFlag(_ property: String) -> Bool { false }
}
final class PlaybackInfo {
  var state = PlayerState.idle
  var volume = 0.0
  var currentURL: URL?
  var subTracks: [String] = []
}
final class VideoView: NSView { var hasInitializedOpenGL = false }
final class MainWindowController: NSWindowController {
  var loaded = false
  var videoView = VideoView()
  var volumeSlider: NSSlider!
  var playSlider: NSSlider!
  var menuActionHandler: MainMenuActionHandler!
}
final class MainMenuActionHandler: NSObject {
  @objc func menuTogglePause(_ sender: NSMenuItem) {}
}
final class PlayerCore {
  static let first = PlayerCore()
  static var newPlayerCore: PlayerCore { PlayerCore() }
  static var playerCores: [PlayerCore] = []
  let mpv = MPVController()
  let info = PlaybackInfo()
  let mainWindow = MainWindowController()
  var nativePlaybackSession: NativePlaybackSession?
  var nativePlaybackOutput: NativeSampleBufferOutput?
  var isUsingNativePlayback = false
  var playbackIsPaused = false
  var playbackVolume = 0.0
  var playbackPosition: Double?
  func openURL(_ url: URL, shouldAutoLoad: Bool) {}
  func seek(absoluteSecond: Double) {}
}
