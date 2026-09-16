import Cocoa

// These recording boundaries replace only the full application's dependencies.
// Viewport state, arithmetic, property updates and keyboard routing are production code.
final class VideoTime {
  var second: Double
  init(_ second: Double) { self.second = second }
}

final class PlaybackInfo {
  var state = PlayerState.playing
  var currentURL: URL? = URL(fileURLWithPath: "/tmp/viewport-fixture.mp4")
  var videoDuration: VideoTime? = VideoTime(120)
  var vid: Int? = 1
  var abLoopStatus = 2
}

final class MPVController {
  var values: [String: Any] = [
    MPVOption.Video.videoZoom: 0.0,
    MPVOption.Video.videoPanX: 0.0,
    MPVOption.Video.videoPanY: 0.0,
    MPVOption.Video.videoRotate: 0,
    MPVOption.PlaybackControl.speed: 1.4,
    MPVOption.PlaybackControl.pause: false,
    MPVOption.PlaybackControl.abLoopA: "10",
    MPVOption.PlaybackControl.abLoopB: "20",
    MPVOption.PlaybackControl.abLoopCount: "inf",
    MPVProperty.timePos: 15.0
  ]
  var reads: [String] = []
  var writes: [(String, Any)] = []
  func getDouble(_ key: String) -> Double {
    reads.append(key)
    return values[key] as? Double ?? Double(values[key] as? String ?? "") ?? 0
  }
  func getFlag(_ key: String) -> Bool {
    reads.append(key)
    return values[key] as? Bool ?? false
  }
  func getString(_ key: String) -> String? {
    reads.append(key)
    return values[key].map { String(describing: $0) }
  }
  func getInt(_ key: String) -> Int {
    reads.append(key)
    return values[key] as? Int ?? 0
  }
  func setDouble(_ key: String, _ value: Double) { write(key, value) }
  func setString(_ key: String, _ value: String) { write(key, value) }
  func setInt(_ key: String, _ value: Int) { write(key, value) }
  private func write(_ key: String, _ value: Any) {
    writes.append((key, value))
    values[key] = value
  }
}

enum TestOSD {
  case custom(String)
  case abLoop(Int)
}

final class SettingsBoundary {
  var shortcuts: [VideoToolsShortcuts.Action] = []
  @discardableResult
  func performVideoToolsShortcut(_ action: VideoToolsShortcuts.Action) -> Bool {
    shortcuts.append(action)
    return true
  }
}

final class MainWindowBoundary {
  enum Tab { case tools }
  var isInInteractiveMode = false
  let quickSettingView = SettingsBoundary()
  var sidebarPresentations = 0
  func showSettingsSidebar(tab: Tab, hideIfAlreadyShown: Bool) { sidebarPresentations += 1 }
}

final class PlayerCore {
  static var keyBindings: [String: KeyBinding] = [:]
  let info = PlaybackInfo()
  let mpv = MPVController()
  let mainWindow = MainWindowBoundary()
  var videoToolsMediaGeneration: UInt64 = 1
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  var isInMiniPlayer = false
  var seeks: [Double] = []
  var speedChanges: [Double] = []
  var pauseChanges = 0
  var abSyncs = 0
  var osds: [TestOSD] = []
  func pause() { pauseChanges += 1; mpv.setDouble(MPVOption.PlaybackControl.pause, 1) }
  func resume() { pauseChanges += 1; mpv.setDouble(MPVOption.PlaybackControl.pause, 0) }
  func seek(absoluteSecond: Double) { seeks.append(absoluteSecond) }
  func syncAbLoop() { abSyncs += 1 }
  func setSpeed(_ speed: Double) { speedChanges.append(speed); mpv.setDouble(MPVOption.PlaybackControl.speed, speed) }
  func sendOSD(_ osd: TestOSD) { osds.append(osd) }
}

class KeyboardBoundary: NSWindowController {
  var fallbackEvents = 0
  override func keyDown(with event: NSEvent) { fallbackEvents += 1 }
}

struct KeyBinding {
  let action: String
}

enum KeyCodeHelper {
  static func mpvKeyCode(from event: NSEvent) -> String { "key-\(event.keyCode)" }
  static func normalizeMpv(_ value: String) -> String { value }
}

enum PluginInputManager {
  enum InputEvent { case keyDown }
  static var dispatches = 0
  static func handle(input: String, event: InputEvent, player: PlayerCore,
                     arguments: [Any], handler: () -> Bool, defaultHandler: () -> Void) {
    dispatches += 1
    if !handler() { defaultHandler() }
  }
}

final class PlaybackSurface: NSView {
  override var acceptsFirstResponder: Bool { true }
}
