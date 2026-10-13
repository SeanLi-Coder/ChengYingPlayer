import Foundation

enum IINAError: Error { case unsupportedMPVNodeFormat(UInt32) }

/// No playlist/readiness success is mocked. Faults redirect an actual MPV
/// command to a deliberately invalid command, or withhold an actual event.
final class LiveQueueClient: MPVQueueInstallationBackend {
  let handle: OpaquePointer
  var commandNames: [String] = []
  var appendCalls = 0
  var rejectedAppend: Int?
  var rejectStop = false
  var rejectClear = false
  var rejectPause = false
  var rejectActivation = false
  var replaceSelectedIndex: Int?
  var afterCommand: (([String]) -> Void)?
  var beforeSnapshot: (() -> Void)?
  var afterSnapshot: (() -> Void)?
  var beforeForwardLoaded: (() -> Void)?
  var beforeForwardStart: (() -> Void)?
  var missingSnapshot = false
  var missingCommandResult = false
  var missingActivationResult = false
  var pauseCalls = 0
  var afterPause: (() -> Void)?
  var actualLoaded = 0
  var actualStarts: [Int64] = []
  var actualEnds: [Int64] = []
  var eventEntryID: Int64?
  var loadedReadback: MPVQueueInstallationSnapshot?
  var dropLoadedEvents = false
  private(set) var diagnostics: [String] = []

  private func record(_ value: String) {
    diagnostics.append(value)
    if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
  }

  init(directory: URL) {
    guard let mpv = mpv_create() else { fatalError("Cannot create real libmpv") }
    handle = mpv
    for (key, value) in ["config": "no", "config-dir": directory.path, "terminal": "no", "vo": "null",
                         "ao": "null", "hwdec": "no", "idle": "yes", "pause": "yes", "keep-open": "yes",
                         "save-position-on-quit": "no", "resume-playback": "no", "cache": "no"] {
      let status = mpv_set_option_string(handle, key, value)
      guard status >= 0 else { fatalError("Cannot configure real MPV option \(key): \(status)") }
    }
    guard mpv_initialize(handle) >= 0 else { fatalError("Cannot initialize real MPV") }
  }
  deinit { mpv_terminate_destroy(handle) }

  func rawCommand(_ arguments: [String]) -> Int32 {
    let pointers = arguments.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var values: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer($0) } }
    values.append(nil)
    return mpv_command(handle, &values)
  }
  func queueCommand(_ arguments: [String]) -> Int32? {
    commandNames.append(arguments[0])
    var actual = arguments
    if arguments[0] == "loadfile" {
      if appendCalls == rejectedAppend { actual = ["loadfile", arguments[1], "invalid-append-mode"] }
      appendCalls += 1
    }
    if arguments[0] == "stop" && rejectStop || arguments[0] == "playlist-clear" && rejectClear ||
       arguments[0] == "playlist-play-index" && rejectActivation { actual = ["invalid-installer-test-command"] }
    if arguments[0] == "playlist-play-index", let index = replaceSelectedIndex { actual[1] = String(index) }
    let status = rawCommand(actual)
    record("command=\(arguments[0]) status=\(status)")
    afterCommand?(arguments)
    return missingCommandResult || missingActivationResult && arguments[0] == "playlist-play-index" ? nil : status
  }
  func queueSetPaused() -> Int32? {
    pauseCalls += 1
    let status = mpv_set_property_string(handle, rejectPause ? "invalid-installer-test-property" : "pause", "yes")
    record("pause status=\(status)")
    afterPause?()
    return status
  }
  func flag(_ name: String) -> Bool? {
    var value: Int32 = 0
    return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
  }
  func string(_ name: String) -> String? {
    guard let text = mpv_get_property_string(handle, name) else { return nil }
    defer { mpv_free(text) }
    return String(cString: text)
  }
  func queueSnapshot() -> MPVQueueInstallationSnapshot? {
    beforeSnapshot?()
    guard !missingSnapshot else { return nil }
    var node = mpv_node()
    guard mpv_get_property(handle, "playlist", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
    defer { mpv_free_node_contents(&node) }
    // Do not allocate an unbounded test-side playlist from an unexpected source.
    guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list,
          (0...Int32(NativeQueuePlan.maximumItems)).contains(list.pointee.num),
          let rows = try? MPVNode.parse(node) as? [[String: Any?]],
          let idle = flag("idle-active"), let paused = flag("pause") else { return nil }
    var entries: [MPVQueueInstallationSnapshot.Entry] = []
    for row in rows {
      guard let id = row["id"] as? Int64, let path = row["filename"] as? String else { return nil }
      entries.append(.init(id: id, path: path, current: row["current"] as? Bool ?? false,
                           playing: row["playing"] as? Bool ?? false))
    }
    let snapshot = MPVQueueInstallationSnapshot(entries: entries, idle: idle, paused: paused, activePath: string("path"))
    record("snapshot ids=\(entries.map(\.id)) current=\(entries.filter(\.current).map(\.id)) playing=\(entries.filter(\.playing).map(\.id)) idle=\(idle) paused=\(paused) hasPath=\(snapshot.activePath != nil)")
    afterSnapshot?()
    return snapshot
  }
  func pump(_ installer: MPVQueueInstaller) {
    guard let event = mpv_wait_event(handle, 0.002) else { return }
    switch event.pointee.event_id {
    case MPV_EVENT_START_FILE:
      let id = event.pointee.data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
      actualStarts.append(id)
      eventEntryID = id
      beforeForwardStart?()
      installer.receive(.startFile(entryID: id))
    case MPV_EVENT_FILE_LOADED:
      guard let id = eventEntryID else { fatalError("Actual FILE_LOADED without a preceding START_FILE") }
      actualLoaded += 1
      loadedReadback = queueSnapshot()
      beforeForwardLoaded?()
      if !dropLoadedEvents { installer.receive(.fileLoaded(entryID: id)) }
    case MPV_EVENT_END_FILE:
      let id = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.playlist_entry_id
      actualEnds.append(id)
      installer.receive(.endFile(entryID: id))
    case MPV_EVENT_SHUTDOWN: installer.receive(.shutdown)
    case MPV_EVENT_QUEUE_OVERFLOW: installer.receive(.queueOverflow)
    default: break
    }
  }
}
