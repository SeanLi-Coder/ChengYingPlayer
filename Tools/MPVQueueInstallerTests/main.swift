import Foundation

setbuf(stdout, nil)
var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  if value() { passed += 1; print("PASS: \(label)") }
  else { failed += 1; print("FAIL: \(label)") }
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = directory.appendingPathComponent("red.mp4")
let blue = directory.appendingPathComponent("blue.mp4")
let missing = directory.appendingPathComponent("missing.mp4")

final class InstallationRig {
  let client: LiveQueueClient
  var current: NativeQueueState.InstallationToken?
  var nowOffset: TimeInterval = 0
  lazy var installer = MPVQueueInstaller(backend: client, isCurrent: { [weak self] in self?.current == $0 },
    clock: { [weak self] in ProcessInfo.processInfo.systemUptime + (self?.nowOffset ?? 0) })
  var outcomes: [MPVQueueInstaller.Outcome] = []
  init() { client = LiveQueueClient(directory: directory) }
  @discardableResult
  func begin(_ urls: [URL], selected: Int = 0) -> NativeQueueState.InstallationToken {
    let plan = try! NativeQueuePlan(urls: urls)
    var state = try! NativeQueueState(plan: plan, selectedIndex: selected)
    let checkpoint = state.handoffCheckpoint()!
    let token = state.beginHandoff(checkpoint)!
    current = token
    check(installer.begin(checkpoint, installation: token, completion: { [weak self] in self?.outcomes.append($0) }) == .accepted,
          "Accept a fresh real MPV installation")
    return token
  }
  func run(timeout: TimeInterval = 4) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while installer.isBusy && ProcessInfo.processInfo.systemUptime < deadline {
      installer.advance(); client.pump(installer)
    }
    check(!installer.isBusy, "Installation reaches a bounded terminal outcome")
  }
  var isEmpty: Bool {
    guard let snapshot = client.queueSnapshot() else { return false }
    return snapshot.entries.isEmpty && snapshot.idle && snapshot.activePath == nil
  }
}

func checkHeldHookCleanup() {
  for hookName in ["on_before_start_file", "on_after_end_file"] {
    let rig = InstallationRig()
    rig.client.heldHookName = hookName
    rig.client.dropLoadedEvents = true
    check(mpv_hook_add(rig.client.handle, 101, hookName, 100) == 0,
          "\(hookName): register an actual MPV lifecycle hook")
    let token = rig.begin([red])
    rig.installer.advance()
    let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
    while (hookName == "on_before_start_file" ? rig.client.heldHookID == nil : rig.client.actualLoaded == 0) &&
          ProcessInfo.processInfo.systemUptime < readyDeadline {
      rig.client.pump(rig.installer)
    }
    check(hookName == "on_before_start_file" ?
            rig.client.heldHookID != nil && rig.client.actualStarts.isEmpty :
            rig.client.actualLoaded == 1 && rig.outcomes.isEmpty,
          "\(hookName): cancellation reaches the actual lifecycle boundary")
    rig.installer.cancel(token)
    let hookDeadline = ProcessInfo.processInfo.systemUptime + 2
    while rig.client.heldHookID == nil && ProcessInfo.processInfo.systemUptime < hookDeadline {
      rig.client.pump(rig.installer)
    }
    let heldSnapshot = rig.client.queueSnapshot()
    check(rig.client.heldHookID != nil && heldSnapshot?.idle == true && heldSnapshot?.activePath == nil &&
          heldSnapshot?.entries.contains(where: { $0.current }) == true &&
          (hookName != "on_after_end_file" || rig.client.actualEnds.count == 1),
          "\(hookName): real idle and missing path precede current-entry retirement")
    rig.installer.advance()
    check(rig.installer.isBusy && rig.outcomes.isEmpty && !rig.client.commandNames.contains("playlist-clear"),
          "\(hookName): cleanup cannot clear or acknowledge while the real hook is held")
    check(rig.client.releaseHeldHook() == 0, "\(hookName): release the actual held MPV hook")
    rig.run()
    check(rig.outcomes == [.cancelled(.verifiedEmpty)] && rig.isEmpty,
          "\(hookName): cleanup verifies empty only after the actual hook retires")
  }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[2] == "cleanup-hooks" {
  checkHeldHookCleanup()
  print("Queue installer: \(passed + failed) checks, \(failed) failures")
  exit(failed == 0 ? 0 : 1)
}

if CommandLine.arguments.count == 3 {
  guard let repetitions = Int(CommandLine.arguments[2]), (1...500).contains(repetitions) else {
    fatalError("Invalid partial-cancellation repetition count")
  }
  for iteration in 0..<repetitions {
    let rig = InstallationRig()
    let token = rig.begin(Array(repeating: red, count: 20))
    rig.installer.advance()
    rig.installer.cancel(token)
    rig.run()
    let empty = rig.isEmpty
    if rig.outcomes != [.cancelled(.verifiedEmpty)] || !empty {
      print("CANCELLATION_DIAGNOSTIC: iteration=\(iteration) outcomes=\(rig.outcomes) empty=\(empty) trace=\(rig.client.diagnostics)")
    }
    check(rig.outcomes == [.cancelled(.verifiedEmpty)] && empty,
          "Repeated partial cancellation verifies empty idle cleanup")
  }
  print("Queue installer stress: \(passed + failed) checks, \(failed) failures")
  exit(failed == 0 ? 0 : 1)
}

for (name, urls, selected) in [
  ("single", [red], 0), ("first", [red, blue], 0), ("last", [red, blue], 1),
  ("duplicate-middle", [red, red, blue], 1), ("duplicate-last", [red, blue, red], 2),
  ("maximum", Array(repeating: red, count: 256), 255)
] {
  let rig = InstallationRig()
  let token = rig.begin(urls, selected: selected)
  check(rig.outcomes.isEmpty && rig.client.actualLoaded == 0, "\(name): acceptance is not loaded success")
  rig.run()
  if case .installed(let receipt) = rig.outcomes.first {
    check(receipt.installation == token && receipt.selectedIndex == selected && receipt.entryIDs.count == urls.count,
          "\(name): receipt identifies the exact selected queue")
    check(Set(receipt.entryIDs).count == urls.count && Set(receipt.itemIDs).count == urls.count,
          "\(name): repeated URLs keep independent actual MPV entry IDs")
    check(rig.client.actualLoaded == 1 && rig.client.actualStarts == [receipt.selectedEntryID],
          "\(name): success requires the actual selected START_FILE and FILE_LOADED")
  } else { check(false, "\(name): installation succeeds") }
  let snapshot = rig.client.queueSnapshot()
  check(snapshot?.entries.map(\.path) == urls.map(\.path), "\(name): real full playlist retains exact order")
  check(snapshot?.paused == true && snapshot?.entries[selected].current == true && snapshot?.entries[selected].playing == true,
        "\(name): the actual selected file remains paused")
  rig.installer.receive(.fileLoaded(entryID: -1)); rig.installer.receive(.endFile(entryID: -1)); rig.installer.cancel(token)
  check(rig.outcomes.count == 1, "\(name): late callbacks cannot deliver success twice")
}

for index in 0..<3 {
  let rig = InstallationRig(); rig.client.rejectedAppend = index
  rig.begin([red, blue, red]); rig.run()
  check(rig.outcomes == [.failed(.appendFailed(index), .verifiedEmpty)], "Failed append \(index) reports its exact command and verified cleanup")
  check(rig.isEmpty && rig.client.actualLoaded == 0, "Failed append \(index) leaves no partial list or playback")
  rig.client.rejectedAppend = nil
  rig.begin([blue]); rig.run()
  if case .installed = rig.outcomes.last { check(true, "Failed append \(index) permits a clean explicit retry") }
  else { check(false, "Failed append \(index) permits a clean explicit retry") }
}

do {
  let rig = InstallationRig(); rig.client.replaceSelectedIndex = 0
  rig.begin([red, red], selected: 1); rig.run()
  check(rig.outcomes == [.failed(.unexpectedStart, .verifiedEmpty)], "Duplicate-path wrong selected entry cannot produce a success receipt")
  check(rig.isEmpty, "Wrong selected entry is stopped and cleared")
}
do {
  let rig = InstallationRig(); rig.client.rejectActivation = true
  rig.begin([red, blue]); rig.run()
  if rig.outcomes != [.failed(.activationFailed, .verifiedEmpty)] || !rig.isEmpty {
    print("ACTIVATION_CLEANUP_DIAGNOSTIC: outcomes=\(rig.outcomes) trace=\(rig.client.diagnostics)")
  }
  check(rig.outcomes == [.failed(.activationFailed, .verifiedEmpty)] && rig.isEmpty,
        "Actual activation command error is not reported as loaded")
}
do {
  let rig = InstallationRig(); rig.begin([missing]); rig.run()
  check(rig.outcomes == [.failed(.loadFailed, .verifiedEmpty)] && rig.client.actualLoaded == 0,
        "Actual unreadable selected media fails after append and start")
}
for point in ["before", "partial", "started"] {
  let rig = InstallationRig()
  let token = rig.begin(Array(repeating: red, count: point == "partial" ? 20 : 2))
  if point == "partial" { rig.installer.advance() }
  if point == "started" {
    rig.installer.advance()
    let end = ProcessInfo.processInfo.systemUptime + 2
    while rig.client.actualStarts.isEmpty && ProcessInfo.processInfo.systemUptime < end { rig.client.pump(rig.installer) }
    check(rig.client.actualStarts.count == 1 && rig.outcomes.isEmpty, "Cancellation is tested after a real selected start")
  }
  rig.installer.cancel(token); rig.run()
  let empty = rig.isEmpty
  if rig.outcomes != [.cancelled(.verifiedEmpty)] || !empty {
    print("CANCELLATION_DIAGNOSTIC: point=\(point) outcomes=\(rig.outcomes) empty=\(empty) trace=\(rig.client.diagnostics)")
  }
  check(rig.outcomes == [.cancelled(.verifiedEmpty)] && empty, "\(point): current-owner cancellation verifies empty idle cleanup")
}
checkHeldHookCleanup()
for operation in ["stop", "clear"] {
  let rig = InstallationRig()
  rig.client.rejectedAppend = 1
  rig.client.rejectStop = operation == "stop"; rig.client.rejectClear = operation == "clear"
  rig.begin([red, blue]); rig.run()
  check(rig.outcomes == [.failed(.appendFailed(1), .unverified)], "\(operation): cleanup command failure stays explicit")
  check(rig.client.queueSnapshot()?.entries.count == 1, "\(operation): failed cleanup never fabricates an empty playlist")
}
do {
  let rig = InstallationRig(); rig.client.missingCommandResult = true
  rig.begin([red]); rig.run()
  check(rig.outcomes == [.failed(.appendFailed(0), .unverified)], "Missing command return value is not success")
}
do {
  let rig = InstallationRig(); rig.client.rejectPause = true
  rig.begin([red]); rig.run()
  check(rig.outcomes == [.failed(.pauseFailed, .unverified)] && rig.client.appendCalls == 0,
        "Failed pause command prevents any append or activation")
}
do {
  let rig = InstallationRig(); rig.client.dropLoadedEvents = true
  rig.begin([red]); rig.installer.advance()
  let end = ProcessInfo.processInfo.systemUptime + 2
  while rig.client.actualLoaded == 0 && ProcessInfo.processInfo.systemUptime < end { rig.client.pump(rig.installer) }
  check(rig.client.actualLoaded == 1 && rig.outcomes.isEmpty, "Real loaded media without delivered FILE_LOADED is not accepted")
  rig.nowOffset = 11; rig.run()
  check(rig.outcomes == [.failed(.timedOut, .verifiedEmpty)] && rig.isEmpty, "Withheld loaded event times out and cleans its own queue")
}
for event in ["start", "loaded"] {
  let rig = InstallationRig()
  let expire: () -> Void = { [weak rig] in rig?.nowOffset = 11 }
  if event == "start" { rig.client.beforeForwardStart = expire }
  else { rig.client.beforeForwardLoaded = expire }
  rig.begin([red]); rig.run()
  check(rig.outcomes == [.failed(.timedOut, .verifiedEmpty)] && rig.isEmpty,
        "Late \(event) event cannot win against the installation deadline")
}
do {
  let rig = InstallationRig(); let token = rig.begin([red])
  rig.client.beforeForwardLoaded = { [weak rig] in
    rig?.client.afterSnapshot = { [weak rig] in
      rig?.client.afterSnapshot = nil
      rig?.installer.cancel(token)
    }
  }
  rig.run()
  check(rig.outcomes == [.cancelled(.verifiedEmpty)] && rig.isEmpty,
        "Cancellation during loaded readback cannot publish stale installation success")
}
do {
  let rig = InstallationRig()
  rig.begin(Array(repeating: red, count: 9)); rig.installer.advance()
  let id = rig.client.queueSnapshot()!.entries[0].id
  rig.installer.receive(.fileLoaded(entryID: id)); rig.run()
  check(rig.outcomes == [.failed(.loadedMismatch, .verifiedEmpty)], "A synthetic FILE_LOADED without real selected start is rejected")
}
do {
  let rig = InstallationRig(); rig.begin([red, blue])
  rig.client.afterCommand = { [weak rig] arguments in
    guard arguments[0] == "loadfile", let rig else { return }
    rig.client.afterCommand = nil
    rig.current = nil
    _ = rig.client.rawCommand(["loadfile", blue.path, "replace"])
  }
  rig.run()
  check(rig.outcomes == [.superseded], "Superseded installation cannot publish old success")
  check(!rig.client.commandNames.contains("stop") && !rig.client.commandNames.contains("playlist-clear"),
        "Superseded installation never cleans the new owner's playlist")
  check(rig.client.queueSnapshot()?.entries.map(\.path) == [blue.path], "New owner's replacement survives old transaction return")
}
do {
  let rig = InstallationRig(); rig.begin([red, blue])
  rig.client.afterCommand = { [weak rig] arguments in
    guard arguments[0] == "loadfile", let rig else { return }
    rig.client.afterCommand = nil
    _ = rig.client.rawCommand(["loadfile", missing.path, "append"])
  }
  rig.run()
  check(rig.outcomes == [.failed(.prefixMismatch, .unverified)], "Foreign appended entry invalidates the installation prefix")
  check(!rig.client.commandNames.contains("playlist-clear") && rig.client.queueSnapshot()?.entries.count == 2,
        "Unrecognized foreign playlist contents are never erased")
}
do {
  let rig = InstallationRig(); _ = rig.client.rawCommand(["loadfile", red.path, "append"])
  let plan = try NativeQueuePlan(urls: [blue]); var state = try NativeQueueState(plan: plan)
  let checkpoint = state.handoffCheckpoint()!; let token = state.beginHandoff(checkpoint)!
  rig.current = token
  check(rig.installer.begin(checkpoint, installation: token, completion: { _ in check(false, "Rejected admission must not complete") }) == .rejected(.notFreshIdle),
        "Nonempty idle MPV is rejected without clearing its existing queue")
  check(rig.client.queueSnapshot()?.entries.map(\.path) == [red.path] && rig.client.commandNames.isEmpty,
        "Rejected admission has no command side effects")
}
do {
  let rig = InstallationRig(); let old = rig.begin([red])
  let plan = try NativeQueuePlan(urls: [blue]); var state = try NativeQueueState(plan: plan)
  let checkpoint = state.handoffCheckpoint()!; let token = state.beginHandoff(checkpoint)!
  check(rig.installer.begin(checkpoint, installation: token, completion: { _ in check(false, "Busy admission must not complete") }) == .rejected(.busy),
        "Concurrent admission cannot overwrite the original completion")
  rig.installer.cancel(old); rig.run()
  check(rig.outcomes == [.cancelled(.verifiedEmpty)], "Original installation retains its own cancellation completion")
}

do {
  let rig = InstallationRig()
  let plan = try NativeQueuePlan(urls: [red]); var state = try NativeQueueState(plan: plan)
  let checkpoint = state.handoffCheckpoint()!; let token = state.beginHandoff(checkpoint)!
  rig.current = token
  var inner: MPVQueueInstaller.Admission?
  var outerCompletions = 0
  rig.client.beforeSnapshot = { [weak rig] in
    guard let rig else { return }
    rig.client.beforeSnapshot = nil
    inner = rig.installer.begin(checkpoint, installation: token, completion: { [weak rig] in rig?.outcomes.append($0) })
  }
  let outer = rig.installer.begin(checkpoint, installation: token, completion: { _ in outerCompletions += 1 })
  check(inner == .accepted && outer == .rejected(.busy), "Readback reentrant admission cannot overwrite an accepted operation")
  rig.run()
  check(rig.outcomes.count == 1 && outerCompletions == 0, "Reentrant admission preserves exactly the accepted completion")
}
do {
  let rig = InstallationRig(); rig.client.missingActivationResult = true
  rig.client.afterCommand = { [weak rig] arguments in
    guard let rig, arguments[0] == "playlist-play-index" else { return }
    rig.client.afterCommand = nil
    let end = ProcessInfo.processInfo.systemUptime + 2
    while rig.client.actualLoaded == 0 && ProcessInfo.processInfo.systemUptime < end { rig.client.pump(rig.installer) }
    check(rig.client.actualLoaded == 1 && rig.outcomes.isEmpty,
          "Reentrant actual loaded event cannot finish before activation status is returned")
  }
  rig.begin([red]); rig.run()
  check(rig.outcomes == [.failed(.activationFailed, .verifiedEmpty)] && rig.isEmpty,
        "Missing activation status rejects reentrant real loaded success")
}
do {
  let rig = InstallationRig(); let old = rig.begin([red]); rig.installer.advance()
  let oldID = rig.client.queueSnapshot()!.entries[0].id
  let startDeadline = ProcessInfo.processInfo.systemUptime + 2
  while rig.client.queueSnapshot()?.activePath != red.path && ProcessInfo.processInfo.systemUptime < startDeadline {
    Thread.sleep(forTimeInterval: 0.001)
  }
  check(rig.client.queueSnapshot()?.activePath == red.path && rig.client.actualStarts.isEmpty,
        "Old MPV start is real but deliberately retained in the event backlog")
  rig.installer.cancel(old)
  let cleanDeadline = ProcessInfo.processInfo.systemUptime + 2
  while rig.installer.isBusy && ProcessInfo.processInfo.systemUptime < cleanDeadline {
    rig.installer.advance(); Thread.sleep(forTimeInterval: 0.001)
  }
  check(rig.outcomes == [.cancelled(.verifiedEmpty)], "Old transaction cleans before the event backlog is dispatched")
  rig.begin([blue]); rig.run()
  check(rig.client.actualEnds.contains(oldID), "The next operation receives an actual old END_FILE backlog event")
  if case .installed(let receipt) = rig.outcomes.last {
    check(receipt.selectedEntryID != oldID && rig.outcomes.count == 2,
          "Old event backlog cannot cancel or acknowledge the new installation")
  } else { check(false, "Old event backlog cannot cancel or acknowledge the new installation") }
  check(rig.client.queueSnapshot()?.activePath == blue.path, "Old cleanup events preserve the newly loaded selected file")
}
do {
  let rig = InstallationRig(); let token = rig.begin(Array(repeating: red, count: 20)); rig.installer.advance()
  let beforePause = rig.client.pauseCalls
  rig.client.afterSnapshot = { [weak rig] in
    guard let rig else { return }
    rig.client.afterSnapshot = nil; rig.current = nil
    _ = rig.client.rawCommand(["loadfile", blue.path, "replace"])
    _ = mpv_set_property_string(rig.client.handle, "pause", "no")
  }
  rig.installer.cancel(token)
  check(rig.outcomes == [.superseded] && rig.client.pauseCalls == beforePause && rig.client.flag("pause") == false,
        "Cleanup readback ownership loss cannot pause a new owner's playback")
  check(!rig.client.commandNames.contains("stop") && !rig.client.commandNames.contains("playlist-clear"),
        "Cleanup readback ownership loss issues no stop or clear")
}
do {
  let rig = InstallationRig(); let token = rig.begin(Array(repeating: red, count: 20)); rig.installer.advance()
  check(rig.client.appendCalls == MPVQueueInstaller.commandsPerAdvance && rig.client.actualStarts.isEmpty &&
        rig.client.queueSnapshot()?.idle == true && rig.client.queueSnapshot()?.activePath == nil,
        "Each scheduler advance has a bounded eight-command append budget")
  rig.installer.cancel(token); rig.nowOffset = 3; rig.installer.advance()
  check(rig.outcomes == [.cancelled(.unverified)] && !rig.client.commandNames.contains("playlist-clear"),
        "Expired cleanup cannot issue a new clear command or report timely success")
}
do {
  let rig = InstallationRig()
  rig.client.afterCommand = { [weak rig] arguments in
    guard arguments[0] == "loadfile", let rig else { return }
    rig.client.afterCommand = nil; rig.nowOffset = 11
  }
  rig.begin(Array(repeating: red, count: 20)); rig.run()
  check(rig.outcomes == [.failed(.timedOut, .verifiedEmpty)] && rig.client.appendCalls == 1,
        "An expired append batch cannot spend its remaining command budget")
}
do {
  let rig = InstallationRig(); rig.begin([red])
  rig.client.beforeForwardLoaded = { [weak rig] in
    rig?.client.afterSnapshot = { [weak rig] in
      rig?.client.afterSnapshot = nil; rig?.nowOffset = 11
    }
  }
  rig.run()
  check(rig.outcomes == [.failed(.timedOut, .verifiedEmpty)], "Loaded readback crossing the deadline cannot publish success")
}
for boundary in ["snapshot", "pause", "stop", "clear"] {
  let rig = InstallationRig(); let token = rig.begin(Array(repeating: red, count: 20)); rig.installer.advance()
  let expire: () -> Void = { [weak rig] in rig?.nowOffset = 3 }
  if boundary == "snapshot" {
    rig.client.afterSnapshot = { [weak rig] in rig?.client.afterSnapshot = nil; expire() }
  } else if boundary == "pause" {
    rig.client.afterPause = expire
  } else {
    rig.client.afterCommand = { arguments in if arguments[0] == (boundary == "stop" ? "stop" : "playlist-clear") { expire() } }
  }
  rig.installer.cancel(token); rig.run()
  check(rig.outcomes == [.cancelled(.unverified)], "Cleanup \(boundary) crossing its deadline cannot report verified success")
  if boundary == "snapshot" || boundary == "pause" {
    check(!rig.client.commandNames.contains("stop"), "Cleanup \(boundary) timeout prevents a later stop command")
  } else if boundary == "stop" {
    check(!rig.client.commandNames.contains("playlist-clear"), "Cleanup stop timeout prevents a later clear command")
  }
}
do {
  let rig = InstallationRig(); let token = rig.begin(Array(repeating: red, count: 20)); rig.installer.advance()
  rig.client.afterCommand = { [weak rig] arguments in
    guard let rig, arguments[0] == "playlist-clear" else { return }
    rig.client.afterCommand = nil; rig.current = nil
    _ = rig.client.rawCommand(["loadfile", blue.path, "replace"])
  }
  rig.installer.cancel(token); rig.run()
  check(rig.outcomes == [.superseded] && rig.client.queueSnapshot()?.entries.map(\.path) == [blue.path],
        "Clear return ownership loss cannot clean or acknowledge the replacement owner's file")
}
do {
  let rig = InstallationRig(); rig.begin(Array(repeating: red, count: 20)); rig.installer.advance()
  // Controlled notification, not a claim to have overflowed libmpv's real queue.
  rig.installer.receive(.queueOverflow); rig.run()
  check(rig.outcomes == [.failed(.eventQueueOverflow, .verifiedEmpty)] && rig.isEmpty,
        "Reported event loss rejects installation and verifies owned cleanup")
}
do {
  let rig = InstallationRig(); rig.begin([red])
  check(rig.client.rawCommand(["quit"]) >= 0, "Issue real MPV shutdown during accepted installation")
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  while rig.outcomes.isEmpty && ProcessInfo.processInfo.systemUptime < deadline { rig.client.pump(rig.installer) }
  check(rig.outcomes == [.failed(.shutdown, .unverified)] && !rig.installer.isBusy,
        "Actual MPV shutdown ends the installation without fabricated cleanup")
}

print("Queue installer: \(passed + failed) checks, \(failed) failures")
exit(failed == 0 ? 0 : 1)
