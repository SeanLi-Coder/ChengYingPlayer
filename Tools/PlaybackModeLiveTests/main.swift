import Foundation

setbuf(stdout, nil)

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func require(_ status: Int32, _ operation: String) {
  guard status >= 0 else {
    fatalError("FAIL: \(operation): \(String(cString: mpv_error_string(status)))")
  }
}

struct MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
}

final class LiveMPV {
  var mpv: OpaquePointer?
  var loadedPaths: [String] = []
  var seekEvents = 0
  var writes: [String] = []
  var hooks: [UInt64: MPVHookValue] = [:]

  init(keepOpen: String = "yes") {
    guard let handle = mpv_create() else { fatalError("FAIL: Create actual libmpv") }
    mpv = handle
    for (name, value) in [
      "config": "no", "config-dir": directory.path, "terminal": "no",
      "vo": "null", "ao": "null", "hwdec": "no", "idle": "yes",
      "keep-open": keepOpen, "pause": "yes", "save-position-on-quit": "no",
      "resume-playback": "no", "cache": "no"
    ] {
      require(mpv_set_option_string(handle, name, value), "Configure \(name)")
    }
    require(mpv_initialize(handle), "Initialize actual libmpv")
  }

  deinit {
    if let mpv { mpv_terminate_destroy(mpv) }
  }

  func getString(_ name: String) -> String? {
    guard let text = mpv_get_property_string(mpv, name) else { return nil }
    defer { mpv_free(text) }
    return String(cString: text)
  }

  func number(_ name: String) -> Double? {
    var value = 0.0
    return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
  }

  func flag(_ name: String) -> Bool? {
    var value: Int32 = 0
    return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
  }

  func setString(_ name: String, _ value: String) {
    writes.append(name)
    require(mpv_set_property_string(mpv, name, value), "Set \(name)=\(value)")
  }

  func command(_ arguments: [String]) {
    let pointers = arguments.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var input: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer($0) } }
    input.append(nil)
    require(mpv_command(mpv, &input), "Run \(arguments.first!)")
  }

  func addHook(_ name: MPVHook, priority: Int32, hook: MPVHookValue) {
    let key = UInt64(hooks.count + 1)
    hooks[key] = hook
    require(mpv_hook_add(mpv, key, name.rawValue, priority), "Register actual \(name.rawValue) hook")
  }

  func event() {
    guard let event = mpv_wait_event(mpv, 0.01) else { return }
    switch event.pointee.event_id {
    case MPV_EVENT_HOOK:
      let hookID = event.pointee.data.assumingMemoryBound(to: mpv_event_hook.self).pointee.id
      guard let hook = hooks[event.pointee.reply_userdata] else { fatalError("FAIL: Unknown loading hook") }
      hook.block { require(mpv_hook_continue(self.mpv, hookID), "Continue actual loading hook") }
    case MPV_EVENT_FILE_LOADED:
      guard let path = getString("path") else { fatalError("FAIL: Loaded event has no media path") }
      loadedPaths.append(path)
    case MPV_EVENT_SEEK:
      seekEvents += 1
    case MPV_EVENT_END_FILE:
      let end = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
      if end.reason == MPV_END_FILE_REASON_ERROR {
        fatalError("FAIL: Decoder ended with \(String(cString: mpv_error_string(end.error)))")
      }
    default: break
    }
    // The production preloaded hook restores state on the main queue before continuing mpv.
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
  }

  func pump(_ duration: TimeInterval) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { event() }
  }

  func until(_ message: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { event() }
    guard condition() else {
      fatalError("FAIL: \(message); path=\(getString("path") ?? "nil") time=\(number("time-pos") ?? -1) pause=\(String(describing: flag("pause"))) eof=\(String(describing: flag("eof-reached"))) loaded=\(loadedPaths.count)")
    }
  }

  func load(_ first: String, then second: String? = nil) {
    let target = loadedPaths.count + 1
    setString("pause", "yes")
    command(["loadfile", first, "replace"])
    until("Load synthetic media") { self.loadedPaths.count >= target && self.number("time-pos") != nil }
    if let second { command(["loadfile", second, "append"]) }
    pump(0.08)
  }

  func play() {
    setString("speed", "4")
    setString("pause", "no")
  }
}

class PlaybackModeFixture {
  enum State { case active, shuttingDown, shutDown }
  struct Info { var state = State.active }
  var info = Info()
  var savedMode: LoopMode?
  let mpv: LiveMPV
  init(keepOpen: String = "yes") { mpv = LiveMPV(keepOpen: keepOpen) }
}

class PlaybackModeHookFixture {
  let player: PlaybackModePlayer
  init(player: PlaybackModePlayer) { self.player = player }
  func addHook(_ name: MPVHook, priority: Int32, hook: MPVHookValue) {
    player.mpv.addHook(name, priority: priority, hook: hook)
  }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let first = directory.appendingPathComponent("red.mp4").path
let second = directory.appendingPathComponent("blue.mp4").path

func expectMode(_ player: PlaybackModePlayer, _ mode: LoopMode) {
  expect(player.getLoopMode() == mode, "Production mode reader agrees with actual engine mode \(mode)")
  expect(player.mpv.getString("loop-file") == (mode == .file ? "inf" : "no") &&
         player.mpv.getString("loop-playlist") == (mode == .playlist ? "inf" : "no"),
         "Actual loop-file and loop-playlist are mutually exclusive for \(mode)")
}

do {
  let player = PlaybackModePlayer()
  let engine = player.mpv
  engine.load(first, then: second)
  engine.setString("ab-loop-a", "0.125")
  engine.setString("ab-loop-b", "1")
  engine.setString("ab-loop-count", "inf")
  engine.command(["seek", "0.5", "absolute+exact"])
  engine.until("Settle paused A-B media") { engine.flag("seeking") == false && (engine.number("time-pos") ?? 0) >= 0.45 }
  engine.pump(0.08)
  let initialTime = engine.number("time-pos")!
  let initialSeeks = engine.seekEvents
  let initialLoads = engine.loadedPaths
  engine.writes.removeAll()
  for mode: LoopMode in [.playlist, .file, .off, .file, .playlist, .off] {
    player.applyLoopMode(mode)
    expectMode(player, mode)
    engine.pump(0.06)
    expect(engine.flag("pause") == true && abs((engine.number("time-pos") ?? -1) - initialTime) < 0.001,
           "Switching to \(mode) preserves paused position")
    expect(engine.number("ab-loop-a") == 0.125 && engine.number("ab-loop-b") == 1 &&
           engine.getString("ab-loop-count") == "inf", "Switching to \(mode) preserves A-B markers")
  }
  expect(engine.seekEvents == initialSeeks && engine.loadedPaths == initialLoads,
         "Changing whole-file modes never seeks or reloads media")
  expect(Set(engine.writes) == ["loop-file", "loop-playlist"],
         "Production apply touches only whole-file loop properties")
  expect(engine.number("playlist-count") == 2 && engine.number("playlist-pos") == 0,
         "Mode selection preserves playlist contents and current entry")
}

for keepOpen in ["yes", "always"] {
  let player = PlaybackModePlayer(keepOpen: keepOpen)
  let engine = player.mpv
  engine.load(first, then: second)
  player.applyLoopMode(.file)
  engine.play()
  var highPositionSeen = false
  var wraps = 0
  engine.until("Observe two actual single-file wraps with keep-open=\(keepOpen)") {
    guard let position = engine.number("time-pos") else { return false }
    if position > 0.8 { highPositionSeen = true }
    if highPositionSeen && position < 0.4 {
      highPositionSeen = false
      wraps += 1
    }
    return wraps >= 2
  }
  expect(engine.getString("path") == first && engine.number("playlist-pos") == 0 && engine.flag("pause") == false,
         "File repeat wraps without advancing or pausing with keep-open=\(keepOpen)")
  expectMode(player, .file)
}

do {
  let player = PlaybackModePlayer()
  let engine = player.mpv
  engine.load(first, then: second)
  player.applyLoopMode(.playlist)
  engine.play()
  engine.until("Observe actual multi-item playlist wrap") { engine.loadedPaths.count >= 4 }
  expect(Array(engine.loadedPaths.prefix(4)) == [first, second, first, second],
         "Playlist repeat visits both entries and wraps to the first")
  expectMode(player, .playlist)
  engine.setString("pause", "yes")
  engine.command(["playlist-clear"])
  expect(engine.number("playlist-count") == 1 && player.getLoopMode() == .playlist,
         "Clearing the queue preserves the selected repeat mode")
  engine.command(["stop"])
  engine.until("Stop the actual decoder") { engine.flag("idle-active") == true }
  expectMode(player, .playlist)
  engine.load(first)
  expectMode(player, .playlist)
  engine.play()
  let loads = engine.loadedPaths.count
  engine.until("Wrap a one-item playlist after stopping and reusing the core") { engine.loadedPaths.count > loads }
  expect(engine.getString("path") == first, "A one-item playlist repeats after stop and reopen")
}

do {
  let player = PlaybackModePlayer()
  let engine = player.mpv
  let controller = PlaybackModeController(player: player)
  player.savedMode = .file
  // Production restores the global property once after mpv initialization, before any load.
  player.applyLoopMode(.file)
  var restoredModes: [LoopMode] = []
  engine.addHook(.onPreLoaded, priority: -100, hook: MPVHookValue { [unowned engine] next in
    // Simulate the stale file-local options restored by a profile or watch-later entry.
    engine.setString("file-local-options/loop-file", "inf")
    engine.setString("file-local-options/loop-playlist", "no")
    next()
  })
  controller.addSavedLoopModeHook()
  engine.addHook(.onPreLoaded, priority: 200, hook: MPVHookValue { [unowned player] next in
    restoredModes.append(player.getLoopMode())
    next()
  })
  engine.load(first, then: second)
  // A new selection must survive the old file-local backup when the file unloads.
  player.savedMode = .playlist
  player.applyLoopMode(.playlist)
  engine.play()
  engine.until("Restore the global mode before automatic next-item and playlist wraps") { engine.loadedPaths.count >= 4 }
  expect(Array(engine.loadedPaths.prefix(4)) == [first, second, first, second],
         "Changing file repeat to playlist repeat survives stale file-local backups at EOF")
  expect(restoredModes.count >= 4 && restoredModes.first == .file &&
         restoredModes.dropFirst().allSatisfy { $0 == .playlist },
         "The latest saved choice is restored before every real preloaded barrier")
  expectMode(player, .playlist)
  engine.setString("pause", "yes")
  player.savedMode = .off
  player.applyLoopMode(.off)
  engine.play()
  engine.until("Reach EOF after disabling playlist repetition") { engine.flag("eof-reached") == true }
  engine.pump(0.25)
  expect(engine.loadedPaths == [first, second, first, second] && engine.getString("path") == second,
         "Changing playlist repeat to off prevents another wrap despite stale file-local backups")
  expect(engine.flag("pause") == true && engine.flag("eof-reached") == true,
         "Disabling repeat keeps the final file paused at EOF")
  expectMode(player, .off)
}

for keepOpen in ["yes", "always"] {
  let player = PlaybackModePlayer(keepOpen: keepOpen)
  let engine = player.mpv
  engine.load(first, then: second)
  player.applyLoopMode(.off)
  engine.play()
  engine.until("Reach non-repeating EOF with keep-open=\(keepOpen)") { engine.flag("eof-reached") == true }
  engine.pump(0.25)
  let expectedPaths = keepOpen == "yes" ? [first, second] : [first]
  expect(engine.loadedPaths == expectedPaths && engine.getString("path") == expectedPaths.last,
         "Sequential mode respects automatic next-item setting with keep-open=\(keepOpen)")
  expect(engine.flag("pause") == true && engine.flag("eof-reached") == true,
         "Sequential mode stops at EOF without wrapping with keep-open=\(keepOpen)")
  expectMode(player, .off)
}

print("Live playback mode checks passed: \(checks)")
