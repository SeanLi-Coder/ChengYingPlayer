import AppKit
import AVFoundation

// Only dependencies outside the production presentation boundary are doubles.
// VideoView, NativePlaybackSurface and NativeSampleBufferOutput are unmodified.
final class PlayerCore {
  var isUsingNativePlayback = true
  var nativePlaybackOutput: NativeSampleBufferOutput? = NativeSampleBufferOutput()
  var mpv: MPVController! = MPVController()
  let mainWindow = MainWindowDouble()
  let info = PlaybackInfoDouble()
  let playerNumber = 1
  let subsystem = Logger.Subsystem(rawValue: "test")
  var isInMiniPlayer = false
  func acceptFromPasteboard(_ sender: NSDraggingInfo, isPlaylist: Bool = false) -> NSDragOperation { [] }
  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool { false }
}

final class MainWindowDouble: NSResponder {
  var window: NSWindow?
  var loaded = true
  let quickSettingView = QuickSettingDouble()
  func menuShowPlaylistPanel(_ sender: NSButton) {}
  func hideSideBar() {}
}
final class QuickSettingDouble { func setHdrAvailability(to: Bool) {} }
final class PlaybackInfoDouble {
  struct State { var loaded = true }
  var state = State()
  var hdrAvailable = false
  var hdrEnabled = true
}

final class MPVController {
  var touches = 0
  func lockAndSetOpenGLContext() { touches += 1 }
  func unlockOpenGLContext() { touches += 1 }
  func mpvUninitRendering() { touches += 1 }
  func mpvReportSwap() { touches += 1 }
  func setDouble(_ key: String, _ value: Double) { touches += 1 }
  func setFlag(_ key: String, _ value: Bool) { touches += 1 }
  func setString(_ key: String, _ value: String) { touches += 1 }
  func setInt(_ key: String, _ value: Int) { touches += 1 }
  func getString(_ key: String) -> String? { touches += 1; return nil }
  func getDouble(_ key: String) -> Double { touches += 1; return 0 }
}

final class ViewLayer: CALayer {
  static var constructions = 0
  var colorspace: CGColorSpace?
  override var wantsExtendedDynamicRangeContent: Bool { get { false } set {} }
  var inLiveResize = false
  var updates = 0
  init(_ view: VideoView) { Self.constructions += 1; super.init() }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError("Unavailable") }
  func update(force: Bool = false) { updates += 1 }
  func setRenderICCProfile(_ profile: NSColorSpace) -> Bool { false }
}

enum Preference {
  enum Key { case videoViewAcceptsFirstMouse, enableDisplayIdle, loadIccProfile, enableToneMapping, toneMappingTargetPeak, toneMappingAlgorithm }
  static func bool(for key: Key) -> Bool { true }
  static func integer(for key: Key) -> Int { 0 }
  enum ToneMappingAlgorithmOption: Int {
    case basic
    static let defaultValue = Self.basic
    var mpvString: String { "auto" }
  }
}
enum Logger {
  struct Subsystem { let rawValue: String }
  enum Level { case debug, warning, verbose }
  static func makeSubsystem(_ name: String) -> Subsystem { Subsystem(rawValue: name) }
  static func log(_ message: String, level: Level = .debug, subsystem: Subsystem) {}
  static func log(_ message: () -> String, level: Level = .debug, subsystem: Subsystem) {}
  static func fatal(_ message: String) -> Never { fatalError(message) }
}
extension NSScreen {
  static func logEDR(_ text: String, _ screen: NSScreen, subsystem: Logger.Subsystem) {}
}
extension NSPasteboard.PasteboardType {
  static let nsFilenames = Self("NSFilenamesPboardType")
  static let nsURL = Self("NSURLPboardType")
}
extension NSButton { static var dummy: NSButton { NSButton() } }
func mutableRawPointerOf(obj: AnyObject) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(obj).toOpaque() }
func CoreDisplay_DisplayCreateInfoDictionary(_ display: UInt32) -> Unmanaged<CFDictionary>? { nil }
