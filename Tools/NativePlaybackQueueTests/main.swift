import Foundation

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  if condition() { passed += 1; print("PASS: \(label)") }
  else { failed += 1; print("FAIL: \(label)") }
}
func rejectsPlan(_ urls: [URL], _ expected: NativeQueuePlan.ValidationError, _ label: String) {
  do { _ = try NativeQueuePlan(urls: urls); check(false, label) }
  catch { check(error as? NativeQueuePlan.ValidationError == expected, label) }
}
let a = URL(fileURLWithPath: "/synthetic-only/A.mp4")
let b = URL(fileURLWithPath: "/synthetic-only/B.mp4")
let c = URL(fileURLWithPath: "/synthetic-only/C.mp4")
let plan = try NativeQueuePlan(urls: [a, b, c])
let single = try NativeQueuePlan(urls: [a])
let duplicate = try NativeQueuePlan(urls: [a, a])
let maximum = try NativeQueuePlan(urls: Array(repeating: a, count: 256))
let localAuthority = try NativeQueuePlan(urls: [URL(string: "file://localhost/synthetic-only/A.mp4")!])
check(single.items.count == 1, "One entry is accepted")
check(maximum.items.count == 256, "256 entries are accepted")
check(localAuthority.items.count == 1, "The explicit localhost file authority remains local")
rejectsPlan([], .empty, "Empty plan is rejected")
rejectsPlan(Array(repeating: a, count: 257), .tooManyItems, "257 entries are rejected")
rejectsPlan([URL(string: "https://example.invalid/A.mp4")!], .nonLocalFile, "Network inputs are rejected")
rejectsPlan([URL(string: "file://remote.invalid/A.mp4")!], .nonLocalFile, "Remote file authorities are rejected")
rejectsPlan([URL(string: "file:///A.mp4?option=1")!], .nonLocalFile, "URL query options are rejected")
rejectsPlan([URL(string: "file:///A.mp4#fragment")!], .nonLocalFile, "URL fragments are rejected")
rejectsPlan([URL(fileURLWithPath: "/synthetic-only", isDirectory: true)], .directory, "Explicit directories are rejected")
let prefix = "file:///"
let exactURL = URL(string: prefix + String(repeating: "a", count: NativeQueuePlan.maximumUTF8Bytes - prefix.utf8.count))!
let exactPlan = try NativeQueuePlan(urls: [exactURL])
check(exactPlan.items.count == 1, "Exact UTF-8 byte budget is accepted")
rejectsPlan([exactURL, a], .tooManyBytes, "Aggregate URL bytes beyond the budget are rejected")
rejectsPlan([URL(string: exactURL.absoluteString + "a")!], .tooManyBytes, "One oversized URL is rejected")
check(plan.items.map(\.url) == [a, b, c], "Explicit input order is preserved")
check(Set(plan.items.map(\.id)).count == 3, "Item identities are unique")
check(duplicate.items[0].url == duplicate.items[1].url && duplicate.items[0].id != duplicate.items[1].id,
      "Same URL entries retain distinct stable identities")
check(plan.id != single.id, "Independent plans have distinct identities")
for index in [-1, 3, Int.max] {
  do { _ = try NativeQueueState(plan: plan, selectedIndex: index); check(false, "Out-of-range index \(index) rejected") }
  catch { check(error as? NativeQueueState.ValidationError == .invalidIndex, "Out-of-range index \(index) rejected") }
}
check(NativeQueueState.successor(0) == 1 && NativeQueueState.successor(UInt64.max - 1) == UInt64.max,
      "Version increment is exact up to the maximum")
check(NativeQueueState.successor(UInt64.max) == nil, "Version counters never wrap")

var opening = try NativeQueueState(plan: plan)
let initial = opening.currentRequest
check(opening.phase == .loading && initial.url == a, "Initial request starts at the selected item")
check(opening.setIntent(.paused) == .intentUpdated && opening.setIntent(.playing) == .intentUpdated &&
      opening.setIntent(.paused) == .intentUpdated, "Opening intent accepts ordered changes")
check(opening.acceptLoaded(initial.token), "Opening intent changes preserve the current media load token")
check(opening.intent == .paused && opening.phase == .ready, "Loaded completion preserves the latest opening pause")
check(!opening.acceptLoaded(initial.token), "Loaded completion is accepted only once")
let unchangedRevision = opening.revision
check(opening.setIntent(.paused) == .unchanged && opening.revision == unchangedRevision, "An identical intent does not create a false revision")
check(opening.ended(initial.token) == .ended && opening.phase == .ended && opening.selectedIndex == 0,
      "Paused EOF records termination without advancing the queue")
check(opening.setIntent(.playing) == .rewind(opening.currentRequest) && opening.intent == .playing,
      "Explicit resume after paused EOF returns a rewind request")

var rapid = try NativeQueueState(plan: plan)
let oldA = rapid.mediaToken
let oldEpoch = rapid.epoch
_ = rapid.select(plan.items[1].id)
let oldB = rapid.mediaToken
_ = rapid.select(plan.items[0].id)
let newA = rapid.mediaToken
check(oldA != newA && rapid.epoch == oldEpoch, "Same-item reselection has a new generation in the same queue epoch")
check(!rapid.acceptLoaded(oldA), "Old same-URL load callback cannot accept the new generation")
check(!rapid.acceptLoaded(oldB), "Old intermediate load callback cannot accept the final selection")
check(rapid.acceptLoaded(newA), "Only the latest rapid selection becomes ready")
check(rapid.selectedItem.id == plan.items[0].id && rapid.plan == plan, "Selection never rewrites stable item identities")

var reopen = try NativeQueueState(plan: single)
let beforeReopen = reopen.mediaToken
let beforeCheckpoint = reopen.handoffCheckpoint()!
let reopened = try reopen.replace(with: single, intent: .paused)
check(beforeReopen != reopened.token && beforeReopen.epoch != reopened.token.epoch, "Same-plan same-URL open starts a new queue epoch")
check(!reopen.acceptLoaded(beforeReopen) && reopen.acceptLoaded(reopened.token), "Same-URL reopen rejects the old load result")
check(reopen.beginHandoff(beforeCheckpoint) == nil, "Same-URL reopen rejects an old handoff checkpoint")
let previousToken = reopen.mediaToken
let previousRevision = reopen.revision
do { _ = try reopen.replace(with: plan, selectedIndex: -1); check(false, "Invalid replacement is rejected atomically") }
catch { check(reopen.mediaToken == previousToken && reopen.revision == previousRevision, "Invalid replacement is rejected atomically") }
check(reopen.select(UUID()) == .rejected(.invalidItem) && reopen.mediaToken == previousToken,
      "Unknown item selection leaves the current media unchanged")

let modes: [(String, LoopMode)] = [("off", .off), ("file", .file), ("playlist", .playlist)]
for (modeName, mode) in modes {
  for index in 0..<3 {
    for advance in [false, true] {
      let label = "EOF \(modeName) index \(index) auto \(advance)"
      var state = try NativeQueueState(plan: plan, selectedIndex: index, repeatMode: mode, autoAdvance: advance)
      let token = state.mediaToken
      check(state.acceptLoaded(token), "\(label): ready")
      let decision = state.ended(token)
      if mode == .file {
        check(decision == .rewind(state.currentRequest) && state.selectedIndex == index, "\(label): file repetition rewinds current")
      } else if advance && index < 2 {
        check(decision == .load(state.currentRequest) && state.selectedIndex == index + 1, "\(label): advances in order")
      } else if advance && mode == .playlist {
        check(decision == .load(state.currentRequest) && state.selectedIndex == 0, "\(label): playlist wraps at the end")
      } else {
        check(decision == .ended && state.phase == .ended && state.intent == .paused && state.selectedIndex == index,
              "\(label): terminal end stays selected and paused")
      }
      let indexAfter = state.selectedIndex
      let revisionAfter = state.revision
      _ = state.ended(token)
      check(state.selectedIndex == indexAfter && state.revision == revisionAfter, "\(label): duplicate EOF has no second effect")
    }
  }
  var first = try NativeQueueState(plan: plan, intent: .paused, repeatMode: mode)
  check(first.previous() == .rewind(first.currentRequest) && first.selectedIndex == 0 && first.intent == .paused,
        "Manual first previous \(modeName) rewinds and preserves pause")
  var middle = try NativeQueueState(plan: plan, selectedIndex: 1, repeatMode: mode)
  check(middle.previous() == .load(middle.currentRequest) && middle.selectedIndex == 0,
        "Manual middle previous \(modeName) selects the prior entry")
  check(middle.next() == .load(middle.currentRequest) && middle.selectedIndex == 1,
        "Manual next \(modeName) ignores file-repeat and advances")
  var last = try NativeQueueState(plan: plan, selectedIndex: 2, repeatMode: mode)
  _ = last.acceptLoaded(last.mediaToken)
  if mode == .playlist {
    check(last.next() == .load(last.currentRequest) && last.selectedIndex == 0,
          "Manual last next playlist wraps as actual MPV does")
  } else {
    check(last.next() == .intentUpdated && last.intent == .paused && last.selectedIndex == 2 && last.phase == .ready,
          "Manual last next \(modeName) preserves PlayerCore boundary pause")
  }
}
var staleEOF = try NativeQueueState(plan: plan)
let staleEnd = staleEOF.mediaToken
_ = staleEOF.select(plan.items[1].id)
_ = staleEOF.acceptLoaded(staleEOF.mediaToken)
check(staleEOF.ended(staleEnd) == .rejected(.stale) && staleEOF.selectedIndex == 1,
      "Stale EOF cannot skip the newly selected item")

// Each stale-checkpoint scenario uses an independent copy. A broken negative
// control can fail a check without altering subsequent scenarios or crashing.
var base = try NativeQueueState(plan: plan, selectedIndex: 1)
_ = base.acceptLoaded(base.mediaToken)
let checkpoint = base.handoffCheckpoint()!
check(checkpoint.plan == plan && checkpoint.selectedIndex == 1 && checkpoint.plan.items.map(\.url) == [a, b, c],
      "Handoff snapshot preserves the whole ordered queue and current index")
check(base.handoffCheckpoint()!.id != checkpoint.id, "Separate checkpoint attempts have separate identities")
var pauseABA = base
_ = pauseABA.setIntent(.paused); _ = pauseABA.setIntent(.playing)
check(pauseABA.beginHandoff(checkpoint) == nil, "Pause ABA rejects the stale checkpoint revision")
var modeABA = base
_ = modeABA.setRepeatMode(.file); _ = modeABA.setRepeatMode(.off)
check(modeABA.beginHandoff(checkpoint) == nil, "Repeat ABA rejects the stale checkpoint revision")
var autoABA = base
_ = autoABA.setAutoAdvance(false); _ = autoABA.setAutoAdvance(true)
check(autoABA.beginHandoff(checkpoint) == nil, "Autoplay ABA rejects the stale checkpoint revision")
var selectedAgain = base
_ = selectedAgain.select(base.selectedItem.id)
check(selectedAgain.beginHandoff(checkpoint) == nil, "Same-item reload rejects the earlier checkpoint generation")
var independent = try NativeQueueState(plan: plan, selectedIndex: 1)
check(independent.beginHandoff(checkpoint) == nil, "Another owner of the same plan rejects the checkpoint epoch")

var install = base
if let ticket = install.beginHandoff(checkpoint) {
  check(install.phase == .installing && install.handoffCheckpoint() == nil, "Checkpoint is consumed before external side effects")
  check(install.beginHandoff(checkpoint) == nil, "One checkpoint cannot begin two installations")
  check(install.next() == .rejected(.busy) && install.previous() == .rejected(.busy) &&
        install.select(plan.items[0].id) == .rejected(.busy), "Installation explicitly rejects racing navigation")
  check(!install.acceptLoaded(checkpoint.media), "Native ready callbacks cannot reclaim an installing queue")
  _ = install.setIntent(.paused); _ = install.setIntent(.playing); _ = install.setIntent(.paused)
  _ = install.setRepeatMode(.playlist); _ = install.setAutoAdvance(false)
  let completion = install.completeHandoff(ticket, verified: true)
  check(completion?.verified == true && install.phase == .compatibility, "Only explicit verified completion transfers ownership")
  check(completion?.intent == .paused && completion?.repeatMode == .playlist && completion?.autoAdvance == false,
        "Installation completion returns the latest accepted intents")
  check(completion?.selectedItem == plan.items[1] && install.plan == plan, "Verified handoff preserves all entries and selection")
  check(install.completeHandoff(ticket, verified: true) == nil, "Installation completion is consumed exactly once")
  check(install.next() == .rejected(.inactive) && install.setIntent(.playing) == .rejected(.inactive),
        "Compatibility-owned queues reject native mutation")
} else { check(false, "Fresh checkpoint starts installation") }

var retry = base
if let firstTicket = retry.beginHandoff(checkpoint) {
  let failure = retry.completeHandoff(firstTicket, verified: false)
  check(failure?.verified == false && retry.phase == .handoffFailed && retry.plan == plan,
        "Installation failure retains the queue without claiming compatibility success")
  check(retry.next() == .rejected(.busy), "Failed external installation never silently restarts native")
  let retryCheckpoint = retry.handoffCheckpoint()!
  check(retryCheckpoint.id != checkpoint.id && retryCheckpoint.revision != checkpoint.revision,
        "Retry obtains a new checkpoint and revision")
  if let retryTicket = retry.beginHandoff(retryCheckpoint) {
    check(retryTicket.id != firstTicket.id, "Retry installation has a new owner ticket")
    check(retry.completeHandoff(firstTicket, verified: true) == nil && retry.phase == .installing,
          "Late success from a failed attempt cannot complete its replacement")
    check(retry.completeHandoff(retryTicket, verified: true)?.verified == true, "A new explicitly verified attempt can recover")
  } else { check(false, "Failed installation can start a bounded explicit retry") }
} else { check(false, "Retry scenario begins handoff") }

for replace in [false, true] {
  var state = base
  let token = state.mediaToken
  let ticket = state.beginHandoff(checkpoint)!
  if replace { _ = try state.replace(with: single, intent: .paused) }
  else { state.stop() }
  let newEpoch = state.epoch
  check(state.completeHandoff(ticket, verified: true) == nil, "\(replace ? "Replacement" : "Stop") rejects stale installation acknowledgement")
  check(!state.acceptLoaded(token) && state.beginHandoff(checkpoint) == nil,
        "\(replace ? "Replacement" : "Stop") rejects old native and checkpoint callbacks")
  check(state.epoch == newEpoch && state.intent == .paused, "Rejected callbacks preserve the latest owner and pause")
}
var stopped = base
stopped.stop()
check(stopped.phase == .stopped && stopped.handoffCheckpoint() == nil && stopped.next() == .rejected(.inactive),
      "Stop leaves no native or handoff work eligible")

var readyPolicy = try NativeQueueState(plan: plan)
let loadingCheckpoint = readyPolicy.handoffCheckpoint()!
_ = readyPolicy.acceptLoaded(readyPolicy.mediaToken)
check(readyPolicy.beginHandoff(loadingCheckpoint) == nil, "Ready transition invalidates an earlier checkpoint revision")
var unopened = try NativeQueueState(plan: plan)
let unopenedRequest = unopened.currentRequest
check(unopened.ended(unopenedRequest.token) == .rejected(.inactive), "Unaccepted loading media cannot emit EOF")
if let pending = unopened.handoffCheckpoint(), let ticket = unopened.beginHandoff(pending) {
  check(unopened.phase == .installing && unopened.completeHandoff(ticket, verified: false)?.verified == false,
        "Initial unsupported admission can request handoff without fabricating native readiness")
} else { check(false, "Initial unsupported admission can request handoff without fabricating native readiness") }
var singletonLoop = try NativeQueueState(plan: single, repeatMode: .playlist)
let singletonToken = singletonLoop.mediaToken
_ = singletonLoop.acceptLoaded(singletonToken)
check(singletonLoop.ended(singletonToken) == .load(singletonLoop.currentRequest) && singletonLoop.generation > singletonToken.generation,
      "A one-item playlist repeat creates a fresh playback generation")
for (name, mode) in modes {
  var pauseBeforeEnd = try NativeQueueState(plan: plan, repeatMode: mode)
  let token = pauseBeforeEnd.mediaToken
  _ = pauseBeforeEnd.acceptLoaded(token)
  _ = pauseBeforeEnd.setIntent(.paused)
  check(pauseBeforeEnd.ended(token) == .ended && pauseBeforeEnd.phase == .ended && pauseBeforeEnd.selectedIndex == 0,
        "Pause before delayed EOF \(name) reaches an ended state without advancing")
  check(pauseBeforeEnd.setIntent(.playing) == .rewind(pauseBeforeEnd.currentRequest) && pauseBeforeEnd.mediaToken != token,
        "Resume after delayed EOF \(name) starts a new rewind generation")
  let rewindToken = pauseBeforeEnd.mediaToken
  _ = pauseBeforeEnd.setIntent(.paused)
  check(pauseBeforeEnd.acceptLoaded(rewindToken) && pauseBeforeEnd.intent == .paused,
        "A later pause wins the EOF rewind completion \(name)")
}
var endBeforePause = try NativeQueueState(plan: plan)
let endFirstToken = endBeforePause.mediaToken
_ = endBeforePause.acceptLoaded(endFirstToken)
_ = endBeforePause.ended(endFirstToken)
let nextToken = endBeforePause.mediaToken
_ = endBeforePause.setIntent(.paused)
check(endBeforePause.selectedIndex == 1 && endBeforePause.acceptLoaded(nextToken) && endBeforePause.intent == .paused,
      "Pause after EOF advancement still wins the pending next-file completion")

print("Native queue model checks: \(passed + failed), failures: \(failed)")
exit(failed == 0 ? 0 : 1)
