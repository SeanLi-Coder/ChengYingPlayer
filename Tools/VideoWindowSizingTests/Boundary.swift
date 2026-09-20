import Cocoa

// Only screens, window side effects and unrelated app services are recording
// boundaries. Production sizing, display rotation, preferences, geometry and
// aspect-preserving arithmetic are compiled unchanged by extract.swift.
struct Aspect { let value: CGFloat }

final class NSScreen {
  static var main: NSScreen?
  let visibleFrame: NSRect
  let backingScaleFactor: CGFloat
  init(_ frame: NSRect, scale: CGFloat) {
    visibleFrame = frame
    backingScaleFactor = scale
  }
}

final class RecordingWindow {
  var frame: NSRect
  var aspectRatio = NSSize.zero
  var screen: NSScreen?
  var isVisible = true
  var frames: [NSRect] = []
  var animations: [Bool] = []
  init(frame: NSRect, screen: NSScreen) {
    self.frame = frame
    self.screen = screen
  }
  func selectDefaultScreen() -> NSScreen { screen ?? NSScreen.main! }
  func setFrame(_ value: NSRect, display: Bool, animate: Bool = false) {
    frame = value
    frames.append(value)
    animations.append(animate)
  }
}

struct GeometryDef {
  var w: String?
  var h: String?
  var x: String?
  var xSign: String?
  var y: String?
  var ySign: String?
}

struct FullScreenState: Equatable {
  var isFullscreen = false
  var priorWindowedFrame: NSRect?
  static let windowed = FullScreenState()
}

struct PlayerInfo {
  var displayWidth: Int? = 1280
  var displayHeight: Int? = 720
  var videoWidth: Int? = 1280
  var justStartedFile = true
  var justOpenedFile = true
  var cachedWindowScale = 1.0
}

enum LogLevel { case verbose, warning }
enum Logger {
  static func log(_ text: String, level: LogLevel, subsystem: String) {}
}

final class MPVBoundary {
  var integers: [String: Int] = [:]
  var writes: [(String, Double)] = []
  func getInt(_ name: String) -> Int { integers[name] ?? 0 }
  func setDouble(_ name: String, _ value: Double, level: LogLevel) { writes.append((name, value)) }
}

enum PlayerEvent { case windowSizeAdjusted }
final class EventBoundary {
  var frames: [NSRect] = []
  func emit(_ event: PlayerEvent, data: NSRect) { frames.append(data) }
}

class PlayerBoundary {
  var info = PlayerInfo()
  var mpv = MPVBoundary()
  var events = EventBoundary()
  var disableWindowAnimation = true
  var generatedThumbnails = 0
  let subsystem = "test"
  func getGeometry() -> GeometryDef? { nil }
  func generateThumbnails() { generatedThumbnails += 1 }
}

final class PiPBoundary { var aspectRatio = NSSize.zero }

class ControllerBoundary {
  let player = PlayerCore()
  let pip = PiPBoundary()
  var window: RecordingWindow?
  var destinationScreen: NSScreen!
  var fsState = FullScreenState.windowed
  var minSize = NSSize(width: 320, height: 320)
  var shouldApplyInitialWindowSize = true
  var isVideoLoaded = false
  var cachedGeometry: GeometryDef?
  var playTimeUpdates = 0
  func determineScreenToUse(_ window: RecordingWindow) -> NSScreen { destinationScreen }
  func handleVideoSizeChange() {}
  func log(_ text: String) {}
  func updatePlayTime(withDuration: Bool, andProgressBar: Bool) { playTimeUpdates += 1 }
}
