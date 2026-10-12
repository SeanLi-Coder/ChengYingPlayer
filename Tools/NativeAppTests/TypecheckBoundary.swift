// Declaration-only boundary for local driver typechecking when full Xcode is unavailable.
// Never compile this file into the application or use it as runtime test evidence.
import AppKit
import AVFoundation

extension Notification.Name {
  static let iinaPlaySliderLoopKnobChanged = Notification.Name("fixture.loop-knob-changed")
  static let iinaPlayerShutdown = Notification.Name("fixture.player-shutdown")
}

enum MPVProperty { static let idleActive = "idle-active" }
enum PlayerState { case idle, playing, paused, shutDown }
enum LoopMode { case off, file }
enum Preference {
  enum SeekOption { case exact }
  static func savedLoopMode(in defaults: UserDefaults, domain: String?) -> LoopMode? { nil }
}
struct VideoTime { var second: Double }
enum NativePlaybackPhase { case paused, playing }
struct NativePlaybackSnapshot {
  var phase: NativePlaybackPhase
  var volume: Float
  var generation: UInt64
  var revision: UInt64
  var position: Double
  var wantsPlayback: Bool
}
enum NativePlaybackQueryResult { case ready(NativePlaybackSnapshot), unavailable }
final class NativePlaybackSession {
  func captureCurrentState(completion: @escaping (NativePlaybackQueryResult) -> Void) {}
}
final class NativeSampleBufferOutput { let displayLayer = AVSampleBufferDisplayLayer() }
final class MPVController {
  var mpv: OpaquePointer?
  var mpvRenderContext: OpaquePointer?
  func getFlag(_ property: String) -> Bool { false }
}
final class PlaybackInfo {
  enum LoopStatus { case cleared, aSet, bSet }
  var state = PlayerState.idle
  var volume = 0.0
  var currentURL: URL?
  var subTracks: [String] = []
  var videoDuration: VideoTime?
  var abLoopStatus = LoopStatus.cleared
}
struct VideoToolsViewport { var scale = 1.0; var panX = 0.0; var panY = 0.0 }
struct VideoToolsLoopRange { var start: Double; var end: Double }
final class VideoToolsViewController: NSViewController, NSTextFieldDelegate {}
final class QuickSettingViewController: NSViewController {
  enum TabViewType { case tools }
  var currentTab = TabViewType.tools
}
final class VideoView: NSView {
  var hasInitializedOpenGL = false
  var isUninited = false
  var nativeSurface: NativePlaybackSurface?
}
final class PlaySliderLoopKnob: NSView { var doubleValue = 0.0 }
final class PlaySlider: NSSlider {
  var abLoopA = PlaySliderLoopKnob()
  var abLoopB = PlaySliderLoopKnob()
}
final class MainWindowController: NSWindowController {
  enum SideBarViewType { case hidden, settings }
  var loaded = false
  var videoView = VideoView()
  var volumeSlider: NSSlider!
  var playSlider: PlaySlider!
  var menuActionHandler: MainMenuActionHandler!
  var quickSettingView = QuickSettingViewController()
  var sideBarStatus = SideBarViewType.hidden
  var isSidebarVisible = false
  var sidebarAutoHidden = false
  func beginControlInteraction() {}
  func endControlInteraction() {}
  func hideUIAndCursor() {}
  func hideSideBar(animate: Bool = true, after: @escaping () -> Void = {}) {}
}
final class MainMenuActionHandler: NSObject {
  @objc func menuTogglePause(_ sender: NSMenuItem) {}
  @objc func menuFileLoop(_ sender: NSMenuItem) {}
  @objc func menuABLoop(_ sender: NSMenuItem) {}
  @objc func menuShowVideoTools(_ sender: NSMenuItem) {}
}
final class PlayerCore {
  enum NativeLoopAction { case moveB(Double) }
  enum NativeLoopActionResult { case applied, invalid, unavailable, superseded }
  static let first = PlayerCore()
  static var newPlayerCore: PlayerCore { PlayerCore() }
  static var playerCores: [PlayerCore] = []
  let mpv = MPVController()
  let info = PlaybackInfo()
  let mainWindow = MainWindowController()
  var nativePlaybackSession: NativePlaybackSession?
  var nativePlaybackOutput: NativeSampleBufferOutput?
  var nativeViewport = VideoToolsViewport()
  var isUsingNativePlayback = false
  var playbackIsPaused = false
  var playbackVolume = 0.0
  var playbackPosition: Double?
  var playbackLoopA: Double?
  var playbackLoopB: Double?
  var nativePreviewInProgress = false
  var videoToolsLoopRange: VideoToolsLoopRange?
  func openURL(_ url: URL, shouldAutoLoad: Bool) {}
  func seek(absoluteSecond: Double) {}
  func seek(relativeSecond: Double, option: Preference.SeekOption) {}
  func getLoopMode() -> LoopMode { .off }
  func setLoopMode(_ mode: LoopMode) {}
  func requestNativeLoopAction(_ action: NativeLoopAction, completion: @escaping (NativeLoopActionResult) -> Void) {}
}
