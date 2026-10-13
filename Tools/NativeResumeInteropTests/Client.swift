import Foundation

enum InteropError: Error { case setup(String) }

/// This client performs real commands and consumes real lifecycle events.
/// No production Core, native Session, rendered pixels or audible output is mocked.
final class ResumeClient {
  private var handle: OpaquePointer?
  private(set) var loaded = 0
  private(set) var restarts = 0
  private(set) var ended = 0
  private(set) var errors = 0
  private(set) var shutdown = false
  private(set) var initialIdle = false

  init(directory: URL, resume: Bool = true, save: Bool = false) throws {
    guard let created = mpv_create() else { throw InteropError.setup("mpv_create failed") }
    handle = created
    var completed = false
    defer {
      if !completed { mpv_terminate_destroy(created); handle = nil }
    }
    let options = [
      "config": "no", "config-dir": directory.path,
      "watch-later-directory": directory.appendingPathComponent("watch-later").path,
      "vo": "null", "ao": "null", "hwdec": "no", "idle": "yes",
      "pause": "yes", "keep-open": "yes", "cache": "no", "terminal": "no",
      "input-default-bindings": "no", "input-terminal": "no",
      "save-position-on-quit": save ? "yes" : "no",
      "resume-playback": resume ? "yes" : "no",
      "write-filename-in-watch-later-config": "no",
      "ignore-path-in-watch-later-config": "no", "resume-playback-check-mtime": "no"
    ]
    for (key, value) in options {
      guard mpv_set_option_string(created, key, value) >= 0 else {
        throw InteropError.setup("Rejected isolated option: \(key)")
      }
    }
    guard mpv_initialize(created) >= 0 else { throw InteropError.setup("mpv_initialize failed") }
    guard string("mpv-version")?.hasPrefix("mpv 0.38.0") == true else {
      throw InteropError.setup("Unexpected MPV version")
    }
    // MPV exposes this option only after initialization. This narrowly selects
    // the proposed interoperability format, not the app's complete saved state.
    try set("watch-later-options", "start,speed")
    guard wait({ self.initialIdle }) else { throw InteropError.setup("Initial idle event timed out") }
    completed = true
  }

  deinit {
    if let handle { mpv_terminate_destroy(handle) }
  }

  func set(_ key: String, _ value: String) throws {
    guard let handle, !shutdown, mpv_set_property_string(handle, key, value) >= 0 else {
      throw InteropError.setup("Property operation failed: \(key)")
    }
  }

  func command(_ arguments: [String]) throws {
    guard let handle, !shutdown else { throw InteropError.setup("Command after shutdown") }
    let storage = arguments.map { strdup($0) }
    defer { storage.forEach { free($0) } }
    var pointers: [UnsafePointer<CChar>?] = storage.map { $0.map { UnsafePointer($0) } } + [nil]
    guard mpv_command(handle, &pointers) >= 0 else {
      throw InteropError.setup("Command failed: \(arguments[0])")
    }
  }

  func number(_ name: String) -> Double? {
    guard let handle, !shutdown else { return nil }
    var value = 0.0
    guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
    return value
  }

  func flag(_ name: String) -> Bool? {
    guard let handle, !shutdown else { return nil }
    var value: Int32 = 0
    guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
    return value != 0
  }

  func string(_ name: String) -> String? {
    guard let handle, !shutdown, let value = mpv_get_property_string(handle, name) else { return nil }
    defer { mpv_free(value) }
    return String(cString: value)
  }

  @discardableResult
  func wait(_ predicate: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
      guard let handle, !shutdown, let event = mpv_wait_event(handle, 0.01) else { break }
      switch event.pointee.event_id {
      case MPV_EVENT_IDLE: initialIdle = true
      case MPV_EVENT_FILE_LOADED: loaded += 1
      case MPV_EVENT_PLAYBACK_RESTART: restarts += 1
      case MPV_EVENT_END_FILE:
        ended += 1
        let detail = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if detail.reason == MPV_END_FILE_REASON_ERROR { errors += 1 }
      case MPV_EVENT_SHUTDOWN: shutdown = true
      case MPV_EVENT_QUEUE_OVERFLOW: errors += 1
      default: break
      }
    }
    return predicate()
  }

  func load(_ url: URL) throws -> Bool {
    let oldLoaded = loaded, oldRestarts = restarts
    try command(["loadfile", url.path, "replace"])
    return wait { self.loaded == oldLoaded + 1 && self.restarts > oldRestarts && self.number("time-pos") != nil }
  }

  func seek(_ position: Double) throws -> Bool {
    let previous = restarts
    try command(["seek", String(position), "absolute+exact"])
    return wait { self.restarts > previous && self.number("time-pos").map { abs($0 - position) < 0.051 } == true }
  }

  func stop() throws -> Bool {
    let previous = ended
    try command(["stop"])
    return wait { self.ended > previous && self.flag("idle-active") == true && self.string("path") == nil }
  }

  func quit(expectedErrors: Int = 0) throws -> Bool {
    try command(["quit"])
    let result = wait { self.shutdown }
    if result, let handle {
      mpv_destroy(handle)
      self.handle = nil
    }
    return result && errors == expectedErrors
  }
}
