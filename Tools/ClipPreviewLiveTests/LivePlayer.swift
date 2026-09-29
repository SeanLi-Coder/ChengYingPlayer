import Cocoa

// Only application services unrelated to playback/export preview are boundaries.
enum Preference {
  enum Key: Hashable { case frameExtractionFormat }
  static var values: [Key: String] = [:]
  static func string(for key: Key) -> String? { values[key] }
  static func set(_ value: String, for key: Key) { values[key] = value }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class VideoTime { var second: Double; init(_ second: Double) { self.second = second } }
enum PlayerState {
  case idle, paused, playing, shuttingDown, shutDown
  var loaded: Bool { self == .paused || self == .playing }
  var active: Bool { loaded }
}
final class PlaybackInfo {
  var state = PlayerState.idle
  var currentURL: URL?
  var videoDuration: VideoTime?
  var videoPosition: VideoTime?
  var isNetworkResource = false
  var vid: Int? = 1
}
final class LiveVideoView { func displayActive() { _ = clip_renderer_pump() } }
final class MainWindowController: NSObject { let videoView = LiveVideoView() }
enum Logger { enum Level { case verbose, warning, debug } }
enum OSDMessage { case custom(String) }
final class MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
}

final class MPVController {
  private let handle: OpaquePointer
  private var serial: UInt64 = 100
  private struct Reply { let status: Int32; let string: String?; let number: Double? }
  private var replies: [UInt64: Reply] = [:]
  private var hooks: [UInt64: MPVHookValue] = [:]
  private var nextHook: UInt64 = 1
  private(set) var loaded = false
  private(set) var seekCommands = 0
  private(set) var restartEvents = 0
  private(set) var error: String?
  var needsEnforcement = false
  var restarted = false

  init() {
    guard let created = mpv_create() else { fatalError("Unable to create libmpv") }
    handle = created
    for (name, value) in [
      ("config", "no"), ("terminal", "no"), ("input-default-bindings", "no"),
      ("input-terminal", "no"), ("idle", "yes"), ("keep-open", "yes"),
      ("vo", "libmpv"), ("ao", "null"), ("hwdec", "no"), ("pause", "yes"),
      ("cache", "no"), ("save-position-on-quit", "no"), ("resume-playback", "no"),
      ("osd-level", "0"), ("loop-file", "no"), ("loop-playlist", "no")
    ] { require(mpv_set_option_string(handle, name, value), "Set isolated playback option") }
    require(mpv_initialize(handle), "Initialize shipped libmpv")
    if !clip_renderer_open(handle) { error = "The real software render context is unavailable" }
    for name in ["time-pos", "eof-reached", "seeking"] {
      require(mpv_observe_property(handle, 0, name, MPV_FORMAT_NONE), "Observe playback boundary")
    }
  }

  deinit {
    clip_renderer_close()
    mpv_terminate_destroy(handle)
  }

  private func require(_ status: Int32, _ operation: String) {
    if status < 0, error == nil { error = "\(operation): \(String(cString: mpv_error_string(status)))" }
  }

  func drain(render: Bool = true) {
    if render && !clip_renderer_pump() { error = "Real frame rendering failed" }
    while let pointer = mpv_wait_event(handle, 0), pointer.pointee.event_id != MPV_EVENT_NONE {
      let event = pointer.pointee
      switch event.event_id {
      case MPV_EVENT_FILE_LOADED:
        loaded = true
      case MPV_EVENT_SEEK, MPV_EVENT_PROPERTY_CHANGE:
        needsEnforcement = true
      case MPV_EVENT_PLAYBACK_RESTART:
        restartEvents += 1
        needsEnforcement = true
        restarted = true
      case MPV_EVENT_END_FILE:
        if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
           end.reason == MPV_END_FILE_REASON_ERROR { require(end.error, "Decode media") }
      case MPV_EVENT_HOOK:
        if let hook = event.data?.assumingMemoryBound(to: mpv_event_hook.self).pointee {
          let hookID = hook.id
          if let value = hooks[event.reply_userdata] {
            value.block { [weak self] in
              guard let self else { return }
              self.require(mpv_hook_continue(self.handle, hookID), "Continue media hook")
            }
          } else { require(mpv_hook_continue(handle, hookID), "Continue unowned hook") }
        }
      case MPV_EVENT_GET_PROPERTY_REPLY, MPV_EVENT_SET_PROPERTY_REPLY, MPV_EVENT_COMMAND_REPLY:
        var value: String?
        var number: Double?
        if event.event_id == MPV_EVENT_GET_PROPERTY_REPLY, event.error >= 0,
           let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
          if property.format == MPV_FORMAT_STRING,
             let string = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
            value = String(cString: string)
          } else if property.format == MPV_FORMAT_DOUBLE {
            number = property.data?.assumingMemoryBound(to: Double.self).pointee
          } else if property.format == MPV_FORMAT_FLAG,
                    let flag = property.data?.assumingMemoryBound(to: Int32.self).pointee {
            number = Double(flag)
          }
        }
        replies[event.reply_userdata] = Reply(status: event.error, string: value, number: number)
      default: break
      }
    }
  }

  private func nextRequest() -> UInt64 { serial += 1; return serial }
  private func awaitReply(_ id: UInt64, allowUnavailable: Bool = false) -> Reply? {
    let deadline = Date().addingTimeInterval(8)
    var renderDeadline = Date().addingTimeInterval(0.05)
    repeat {
      drain(render: false)
      if let result = replies.removeValue(forKey: id) {
        if !allowUnavailable { require(result.status, "Complete real player request") }
        return result
      }
      // Production synchronous property access does not recursively fire AppKit
      // timers. Service a blocked video output request without reentering UI code.
      if Date() >= renderDeadline {
        if !clip_renderer_pump() { error = "Real frame rendering failed" }
        renderDeadline = Date().addingTimeInterval(0.05)
      }
      usleep(250)
    } while error == nil && Date() < deadline
    error = error ?? "The real player request timed out"
    return nil
  }

  func getString(_ name: String) -> String? {
    let id = nextRequest()
    require(mpv_get_property_async(handle, id, name, MPV_FORMAT_STRING), "Request playback property")
    return awaitReply(id, allowUnavailable: true)?.string
  }
  func getDouble(_ name: String) -> Double {
    let id = nextRequest()
    require(mpv_get_property_async(handle, id, name, MPV_FORMAT_DOUBLE), "Request full-precision playback property")
    return awaitReply(id, allowUnavailable: true)?.number ?? 0
  }
  func getInt(_ name: String) -> Int { Int(getDouble(name)) }
  func getFlag(_ name: String) -> Bool {
    let id = nextRequest()
    require(mpv_get_property_async(handle, id, name, MPV_FORMAT_FLAG), "Request playback flag")
    return awaitReply(id, allowUnavailable: true)?.number == 1
  }
  func setString(_ name: String, _ value: String) {
    let id = nextRequest()
    value.withCString { value in
      var pointer: UnsafePointer<CChar>? = value
      require(mpv_set_property_async(handle, id, name, MPV_FORMAT_STRING, &pointer), "Set playback property")
    }
    _ = awaitReply(id)
  }
  func setDouble(_ name: String, _ value: Double) {
    let id = nextRequest()
    var number = value
    require(mpv_set_property_async(handle, id, name, MPV_FORMAT_DOUBLE, &number), "Set full-precision playback property")
    _ = awaitReply(id)
  }
  func setInt(_ name: String, _ value: Int) { setString(name, String(value)) }
  func setFlag(_ name: String, _ value: Bool, level: Logger.Level = .verbose) { setString(name, value ? "yes" : "no") }
  func command(_ command: MPVCommand, args: [String] = [], checkError: Bool = true) {
    if command == .seek { seekCommands += 1 }
    rawCommand([command.rawValue] + args)
  }
  func rawCommand(_ arguments: [String]) {
    let id = nextRequest()
    let strings = arguments.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
    require(mpv_command_async(handle, id, &pointers), "Send playback command")
    _ = awaitReply(id)
  }
  func addHook(_ name: MPVHook, hook: MPVHookValue) {
    let id = nextHook
    nextHook += 1
    hooks[id] = hook
    require(mpv_hook_add(handle, id, name.rawValue, 0), "Register media hook")
  }
}

final class PlayerCore: NSObject {
  let info = PlaybackInfo()
  let mpv = MPVController()
  let mainWindow = MainWindowController()
  var videoToolsMediaGeneration: UInt64 = 1
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  func syncPositionIfNeeded() { info.videoPosition = VideoTime(mpv.getDouble(MPVProperty.timePos)) }
  func syncAbLoop() {}
  func log(_ message: String, level: Logger.Level = .debug) {}
  func sendOSD(_ message: OSDMessage) {}
  func togglePause() { mpv.getFlag(MPVOption.PlaybackControl.pause) ? resume() : pause() }
  func frameStep(backwards: Bool) { mpv.command(backwards ? .frameBackStep : .frameStep) }
  func setSpeed(_ value: Double) { mpv.setDouble(MPVOption.PlaybackControl.speed, value) }

  func processEvents() {
    mpv.drain()
    if mpv.loaded {
      info.state = mpv.getFlag(MPVOption.PlaybackControl.pause) ? .paused : .playing
      if info.videoDuration == nil { info.videoDuration = VideoTime(mpv.getDouble(MPVProperty.duration)) }
    }
    if mpv.needsEnforcement {
      let restarted = mpv.restarted
      mpv.needsEnforcement = false
      mpv.restarted = false
      videoToolsEnforceLoopBounds(playbackRestarted: restarted)
    }
  }
}
