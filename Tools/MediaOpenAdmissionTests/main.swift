import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  checks += 1
}
func wait(_ semaphore: DispatchSemaphore, _ message: String) {
  check(semaphore.wait(timeout: .now() + 5) == .success, message)
}
let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func file(_ name: String) -> URL { fixture.appendingPathComponent(name) }
let original = file("original.mp4")
let replacement = file("replacement.mp4")
for url in [original, replacement] { check(FileManager.default.createFile(atPath: url.path, contents: Data()), "Create synthetic file") }

// Hold a real recursive lock in the extracted background matcher, exactly at
// the first append. A helper releases it only once the main thread is about to
// wait. This proves cancellation ordering without a fragile timing threshold.
func switchDuringMatching(_ inputs: [URL], currentLast: Bool = false) {
  let player = PlayerCore()
  player.info.currentURL = original
  player.snapshot = [PlaylistItem(filename: original.path)]
  let additional = (0..<64).map { file("sibling-\($0).mp4") }
  let matcher = AutoFileMatcher(player: player, files: currentLast ? additional + [original] : [original] + additional)
  let enteredAppend = DispatchSemaphore(value: 0)
  let releaseAppend = DispatchSemaphore(value: 0)
  let observedLock = DispatchSemaphore(value: 0)
  let workerDone = DispatchSemaphore(value: 0)
  let helperDone = DispatchSemaphore(value: 0)
  let observed = Atomic(wrappedValue: false)
  player.onAppend = { _ in
    if player.appendEvents.count == 1 {
      enteredAppend.signal()
      if releaseAppend.wait(timeout: .now() + 5) != .success { fatalError("Append barrier timed out") }
    }
  }
  DispatchQueue.global().async {
    do { try matcher.addFilesToPlaylist() }
    catch TicketExpiredError.ticketExpired { player.matcherStopped = true }
    catch { fatalError("Unexpected matcher failure") }
    workerDone.signal()
  }
  wait(enteredAppend, "Matcher must enter its first append")
  player.playlistMutationLock.beforeMainLock = { observedLock.signal() }
  DispatchQueue.global().async {
    if observedLock.wait(timeout: .now() + 5) != .success { fatalError("Open lock boundary timed out") }
    observed.wrappedValue = player.backgroundQueueTicket != matcher.ticket
    releaseAppend.signal()
    helperDone.signal()
  }
  let count = player.openMediaURLs(inputs)
  wait(workerDone, "Matcher must leave its lock without deadlock")
  wait(helperDone, "Cancellation observer must finish")
  check(observed.wrappedValue, "accepted open must cancel the old matcher before waiting for its lock")
  check(player.matcherStopped, "Old matcher must stop on its next cancellation boundary")
  check(player.appendEvents.count == 1 + max(0, inputs.count - 1), "Only the in-flight old append and explicit new suffix may run")
  check(player.opened == [inputs[0]], "Open the admitted replacement exactly once")
  check(player.snapshot.map(\.filename) == inputs.map(\.path), "Old matcher writes must not interleave into the replacement list")
  check(player.moveEvents == 0, "A cancelled old append must not be followed by a playlist move")
  check(count == inputs.count, "Preserve explicit list count")
}

switchDuringMatching([replacement])
if CommandLine.arguments.contains("--negative-control") {
  fputs("FAIL: Old source unexpectedly passed the cancellation barrier\n", stderr)
  exit(2)
}
switchDuringMatching([replacement], currentLast: true)
switchDuringMatching([replacement, file("next.mp4")])

// Non-playable inputs and failed admission must not cancel current matching.
for inputs in [[], [URL(string: "https://example.invalid/video.mp4")!], [file("captions.srt")], [file("notes.txt")]] {
  let player = PlayerCore()
  _ = player.openMediaURLs(inputs)
  check(player.backgroundQueueTicket == 1, "Rejected input preserves the current matcher ticket")
  check(player.opened.isEmpty, "Rejected input must not open media")
  check(player.nativeResetCount == 0, "Rejected input preserves current native intent")
}
for blocked in ["update", "termination", "shuttingDown", "shutDown"] {
  let player = PlayerCore()
  UpdateWorkAdmission.shared.isOpeningMediaBlocked = blocked == "update"
  player.nativeTerminationRequested = blocked == "termination"
  if blocked == "shuttingDown" { player.info.state = .shuttingDown }
  if blocked == "shutDown" { player.info.state = .shutDown }
  _ = player.openMediaURLs([replacement])
  check(player.backgroundQueueTicket == 1, "Initial lifecycle rejection preserves the matcher")
  check(player.opened.isEmpty, "Initial lifecycle rejection does not open")
  UpdateWorkAdmission.shared.isOpeningMediaBlocked = false
}

// Recheck after non-mutating preflight and again inside the acquired lock.
for stage in ["preflight", "lock"] {
  for blocked in ["update", "termination", "shuttingDown", "shutDown", "ticket"] {
    let player = PlayerCore()
    let block = {
      switch blocked {
      case "update": UpdateWorkAdmission.shared.isOpeningMediaBlocked = true
      case "termination": player.nativeTerminationRequested = true
      case "shuttingDown": player.info.state = .shuttingDown
      case "shutDown": player.info.state = .shutDown
      default: player.$backgroundQueueTicket.withLock { $0 += 1 }
      }
    }
    if stage == "preflight" { player.onResolve = block }
    else { player.playlistMutationLock.beforeMainLock = block }
    _ = player.openMediaURLs([replacement])
    if blocked != "ticket" || stage == "lock" {
      check(player.opened.isEmpty, "Admission revoked at \(stage) must not open: \(blocked)")
      check(player.nativeResetCount == 0, "Revoked admission must not reset the active native request")
    }
    if stage == "preflight", blocked != "ticket" {
      check(player.backgroundQueueTicket == 1, "Preflight rejection must not cancel current matching")
    }
    UpdateWorkAdmission.shared.isOpeningMediaBlocked = false
  }
}

for special in [file("playlist.m3u"), fixture.appendingPathComponent("disc", isDirectory: true)] {
  let player = PlayerCore()
  if special.hasDirectoryPath { player.discURLs.insert(special) }
  check(player.openMediaURLs([special]) == nil, "Preserve special-input return value")
  check(player.opened == [special], "Disc and playlist inputs open once")
  check(!player.info.shouldAutoLoadFiles, "Disc and playlist inputs disable sibling matching")
  check(player.backgroundQueueTicket == 2, "Disc and playlist requests cancel old matching")
}
let emptyDirectory = fixture.appendingPathComponent("empty", isDirectory: true)
try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
let emptyPlayer = PlayerCore()
check(emptyPlayer.openMediaURLs([emptyDirectory]) == 0 && emptyPlayer.backgroundQueueTicket == 1,
      "Empty folder does not cancel current matching")
let singlePlayer = PlayerCore()
check(singlePlayer.openMediaURLs([replacement]) == 1 && singlePlayer.info.shouldAutoLoadFiles,
      "Single-file opening retains sibling autoload")
let explicitPlayer = PlayerCore()
check(explicitPlayer.openMediaURLs([replacement, original]) == 2 && !explicitPlayer.info.shouldAutoLoadFiles,
      "Explicit multi-file opening retains input order without sibling autoload")

let nativePlayer = PlayerCore()
nativePlayer.nativeTransport = true
check(nativePlayer.openMediaURLs([replacement]) == 1, "Retiring native transport retains admission count")
check(nativePlayer.opened.isEmpty && nativePlayer.retirement != nil, "Existing native retirement remains asynchronous")
nativePlayer.nativeTransport = nil
let retirement = nativePlayer.retirement
nativePlayer.retirement = nil
retirement?()
check(nativePlayer.opened == [replacement], "Native retirement completion opens once")
let queuePlayer = PlayerCore()
queuePlayer.nativePlan = NativeQueuePlan(items: [replacement, original])
queuePlayer.acceptsNativePlan = true
check(queuePlayer.openMediaURLs([replacement, original]) == 2 && queuePlayer.opened.isEmpty,
      "Accepted native explicit queue must not fall through to MPV open")
print("PASS: Media-open admission production regression completed: \(checks) checks")
