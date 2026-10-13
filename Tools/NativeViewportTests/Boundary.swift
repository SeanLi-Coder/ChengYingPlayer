import AppKit
import AVFoundation

// Playback lifecycle and MPV are explicit recording boundaries. The viewport
// model, PlayerCore admission/commit method, bridge, keyboard and surface are real.
final class InfoBoundary {
  var state = PlayerState.playing
  var vid: Int? = 1
  var abLoopStatus = 0
}
final class MPVBoundary {
  var values: [String: Double] = [:]
  var reads: [String] = []
  var writes: [(String, Double)] = []
  func getDouble(_ key: String) -> Double { reads.append(key); return values[key] ?? 0 }
  func setDouble(_ key: String, _ value: Double) { writes.append((key, value)); values[key] = value }
}
enum OSDBoundary { case custom(String), abLoop(Int) }
final class SettingsBoundary {
  func prepareVideoToolsForLoopEdit() {
    preconditionFailure("Loop editing is outside the focused viewport boundary")
  }
  @discardableResult
  func performVideoToolsShortcut(_ action: VideoToolsShortcuts.Action) -> Bool { false }
}
final class VideoViewBoundary {
  let surface = NativePlaybackSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  var accepts = true
  func updateNativeViewport(scale: Double, normalizedPan: CGPoint) -> Bool {
    accepts && surface.setNormalizedViewport(zoom: scale, pan: normalizedPan)
  }
}
final class MainWindowBoundary {
  enum Tab { case tools }
  let videoView = VideoViewBoundary()
  let quickSettingView = SettingsBoundary()
  var isInInteractiveMode = false
  func showSettingsSidebar(tab: Tab, hideIfAlreadyShown: Bool) {}
}
class CoreBoundary {
  let hasPendingPermanentRotation = false
  let hasPendingGenericPlaybackHandoff = false
  func requestPermanentRotation(clockwiseQuarterTurns: Int) -> Bool {
    preconditionFailure("Rotation is outside the focused viewport boundary")
  }
  var nativeTransport: NSObject? = NSObject()
  var nativeReady = true
  var nativeRetiring = false
  var nativeTerminationRequested = false
  var isUsingNativePlayback: Bool { nativeTransport != nil }
  let info = InfoBoundary()
  let mainWindow = MainWindowBoundary()
  let mpv = MPVBoundary()
  var compatibilityCalls = 0
  var osds: [OSDBoundary] = []
  var speedCalls: [Double] = []
  var isInMiniPlayer = false
  var currentPlaybackSpeed = 1.0
  var legacyLoopCalls = 0
  enum NativeLoopAction { case captureA, captureB }
  enum NativeLoopActionResult { case applied, invalid, unavailable, superseded }
  func requireMPVCompatibility(reason: String, completion: @escaping () -> Void) {
    compatibilityCalls += 1
    // Do not replay an unsupported route into the same native test core.
  }
  func requestNativeLoopAction(_ action: NativeLoopAction, completion: (NativeLoopActionResult) -> Void) {
    completion(.applied)
  }
  func sendOSD(_ value: OSDBoundary) { osds.append(value) }
  func setSpeed(_ value: Double) { currentPlaybackSpeed = value; speedCalls.append(value) }
  func videoToolsSetLoopStart() -> Bool { legacyLoopCalls += 1; return true }
  func videoToolsSetLoopEnd() -> Bool { legacyLoopCalls += 1; return true }
}
final class InputSurface: NSView { override var acceptsFirstResponder: Bool { true } }
