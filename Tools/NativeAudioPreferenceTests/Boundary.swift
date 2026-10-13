import AppKit

enum Logger { enum Level { case error, warning } }
enum MPVProperty { static let audioDevice = "audio-device" }
enum Utility {
  static var alerts = [String]()
  static func showAlert(_ key: String, style: NSAlert.Style, sheetWindow: NSWindow?) { alerts.append(key) }
}
enum Preference {
  enum Key: String { case audioDevice, audioDeviceDesc, autoRepeat, defaultRepeatMode }
  static let domain = "org.chengying.audio-preference-tests." + UUID().uuidString
  static let store: UserDefaults = {
    let value = UserDefaults(suiteName: domain)!
    value.set("auto", forKey: "audioDevice")
    value.set("System default", forKey: "audioDeviceDesc")
    return value
  }()
  static var effectiveAudioDeviceName: String { store.string(forKey: Key.audioDevice.rawValue) ?? "auto" }
  static func set(_ value: String, for key: Key) { store.set(value, forKey: key.rawValue) }
  static func string(for key: Key) -> String? { store.string(forKey: key.rawValue) }
  static func integer(for key: Key) -> Int { preconditionFailure("Unrelated option") }
  static func float(for key: Key) -> Float { preconditionFailure("Unrelated option") }
  static func bool(for key: Key) -> Bool { preconditionFailure("Unrelated option") }
}

// This boundary only records deliveries. It does not report that a compatibility
// handoff, playback or physical audio output succeeded.
final class PlayerCore {
  static var playerCores = [PlayerCore]()
  static var active: PlayerCore { playerCores[0] }
  enum State { case idle, playing, shuttingDown, shutDown }
  final class Info { var state = State.idle }
  let info = Info()
  var nativeTerminationRequested = false
  var nativeRetiring = false
  var nativeTransport: Int?
  var playbackEventRoute = (revision: UInt64(0), acceptsMPV: true)
  var nativeCompatibilityCaptureID: UUID?
  var nativeCompatibilityRestore: Int?
  var hasPendingGenericPlaybackHandoff = false
  var hasPendingPermanentRotation = false
  var hasPendingURLPlaylistEnqueue = false
  var nativeQueueLoadPending = false
  var nativeQueueInstallation: Int?
  enum Phase { case ready, handoffFailed }
  struct Queue { var phase = Phase.ready }
  var nativeQueue: Queue?
  var isUsingNativePlayback: Bool { nativeTransport != nil }
  var hasNativePlaybackQueue: Bool { nativeQueue != nil }
  var deliveries = [String]()
  var deliveredOffMain = false
  var onDelivery: (() -> Void)?
  func setAudioDevice(_ name: String) {
    deliveredOffMain = deliveredOffMain || !Thread.isMainThread
    deliveries.append(name)
    onDelivery?()
  }
  func restoreSavedLoopMode() { preconditionFailure("Unrelated preference") }
  func getAudioDevices() -> [MPVAudioDevice] {
    [MPVAudioDevice(desc: "System default", name: "auto"), MPVAudioDevice(desc: "Device A", name: "coreaudio/a"), MPVAudioDevice(desc: "Device B", name: "coreaudio/b")]
  }
}
