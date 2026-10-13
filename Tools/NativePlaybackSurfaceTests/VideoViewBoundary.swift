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
  var nativeTransport: RetirementTransportBoundary?
  var nativeInitialPauseIntent: Bool?
  var nativeLoopA: Double?, nativeLoopB: Double?
  var nativeRetirementCompletion: (() -> Void)?
  var nativeRetiring = false
  var nativeReady = true
  var nativeResumeReceipt: NativePlaybackResumeReceipt?
  let videoToolsMediaGeneration: UInt64 = 1
  struct CompatibilityRestoreBoundary {
    private init() {}
    var url: URL { preconditionFailure("No compatibility restore in presentation retirement tests") }
    var id: UUID { preconditionFailure("No compatibility restore in presentation retirement tests") }
  }
  let nativeCompatibilityRestore: CompatibilityRestoreBoundary? = nil
  var retirementRouteRevision: UInt64 = 0
  // This presentation fixture retires native output without a generic handoff
  // owner. Keep the real retirement body and reject any owned-handoff branch.
  struct GenericHandoffPhaseBoundary {
    private init() {}
    static func retiring(_ revision: UInt64) -> Self {
      preconditionFailure("Generic retirement ownership requires the handoff tests")
    }
  }
  struct GenericHandoffOwnerBoundary {
    private init() {}
    var phase: GenericHandoffPhaseBoundary {
      get { preconditionFailure("No generic owner in presentation retirement tests") }
      set { preconditionFailure("No generic owner in presentation retirement tests") }
    }
  }
  var genericHandoffOwner: GenericHandoffOwnerBoundary? = nil
  func ownsGenericHandoff(_ id: UUID?) -> Bool {
    precondition(id == nil, "No owned generic handoff in presentation retirement tests")
    return true
  }
  var previewCancellations = 0
  var loopCancellations = 0
  func cancelNativePreview(restoreLoop: Bool) {
    precondition(!restoreLoop)
    previewCancellations += 1
  }
  func cancelNativeLoopRequests() { loopCancellations += 1 }
  @discardableResult
  func advancePlaybackRoute(acceptsMPV: Bool) -> UInt64 {
    precondition(!acceptsMPV)
    retirementRouteRevision &+= 1
    return retirementRouteRevision
  }
  func acceptFromPasteboard(_ sender: NSDraggingInfo, isPlaylist: Bool = false) -> NSDragOperation { [] }
  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool { false }
}

final class MainWindowDouble: NSResponder {
  var window: NSWindow?
  var videoView: VideoView!
  var loaded = true
  let quickSettingView = QuickSettingDouble()
  func menuShowPlaylistPanel(_ sender: NSButton) {}
  func hideSideBar() {}
}
final class QuickSettingDouble { func setHdrAvailability(to: Bool) {} }
final class PlaybackInfoDouble {
  var state = PlayerState.paused
  var hdrAvailable = false
  var hdrEnabled = true
}

// The decoder/shutdown scheduling is controlled only in the retirement slice.
// The output, CALayer, surface, VideoView and extracted Core method are real.
final class RetirementTransportBoundary {
  let session: RetirementSessionBoundary
  var onSnapshot: (() -> Void)? = {}
  init(output: NativeSampleBufferOutput) { session = RetirementSessionBoundary(output: output) }
}
final class RetirementSessionBoundary {
  struct Snapshot {
    private init() {}
    var position: Double { preconditionFailure("No decoded sample in controlled retirement") }
    var duration: Double { preconditionFailure("No decoded sample in controlled retirement") }
    var rate: Float { preconditionFailure("No decoded sample in controlled retirement") }
  }
  enum CaptureResult { case ready(Snapshot), unavailable }
  let output: NativeSampleBufferOutput
  var shutdownCalls = 0
  private var completions: [() -> Void] = []
  init(output: NativeSampleBufferOutput) { self.output = output }
  func shutdown(capturingState: ((CaptureResult) -> Void)? = nil, completion: @escaping () -> Void) {
    shutdownCalls += 1
    completions.append { capturingState?(.unavailable); completion() }
  }
  func finish() {
    let pending = completions
    completions.removeAll()
    pending.forEach { $0() }
  }
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
  enum Key { case videoViewAcceptsFirstMouse, enableDisplayIdle, loadIccProfile, enableToneMapping, toneMappingTargetPeak, toneMappingAlgorithm, resumeLastPosition }
  static func bool(for key: Key) -> Bool { key == .resumeLastPosition ? false : true }
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
