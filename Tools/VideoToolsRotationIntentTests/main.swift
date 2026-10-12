import Foundation

private var checks = 0
private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
  checks += 1
  if !condition() { failures += 1; print("FAIL: \(label)") }
}

private let source = URL(fileURLWithPath: "/synthetic-media/original.mov")
private let otherSource = URL(fileURLWithPath: "/synthetic-media/other.mov")

private func firstTicket(_ intent: inout VideoToolsRotationIntent, turns: Int = 1) -> VideoToolsRotationIntent.Ticket {
  guard case .begin(let ticket) = intent.append(clockwiseQuarterTurns: turns) else {
    fatalError("Expected the first press to request one handoff")
  }
  return ticket
}

private final class TaskBoundary: NSObject, VideoToolsRotationTaskManaging {
  struct Request { let inputURL: URL; let degrees: Int }
  let notifications = NotificationCenter()
  var snapshot: VideoToolsTaskSnapshot?
  var requests: [Request] = []
  var cancellations = 0

  func startRotation(inputURL: URL, degrees: Int) throws -> String {
    guard snapshot?.isActive != true else { throw VideoToolsClientError.busy }
    let id = "intent-export-\(requests.count + 1)"
    requests.append(.init(inputURL: inputURL, degrees: degrees))
    snapshot = VideoToolsTaskSnapshot(id: id, operation: .rotate, inputURL: inputURL,
      phase: .starting, progress: 0, message: "Starting", elapsedSeconds: nil,
      etaSeconds: nil, frameCount: nil, outputURL: nil, errorCode: nil, error: nil)
    return id
  }

  func cancelRotation(taskID: String) {
    guard snapshot?.id == taskID, snapshot?.isActive == true else { return }
    cancellations += 1
    snapshot?.phase = .cancelled
    notifications.post(name: .videoToolsTaskChanged, object: self)
  }

  func complete() {
    snapshot?.phase = .completed
    snapshot?.outputURL = URL(fileURLWithPath: "/synthetic-output/result-\(requests.count).mov")
    notifications.post(name: .videoToolsTaskChanged, object: self)
  }
}

private func pump(until condition: () -> Bool) {
  let deadline = ProcessInfo.processInfo.systemUptime + 1
  while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
  }
  expect(condition(), "The real coordinator completes its bounded debounce")
}

@main
private enum Tests {
  static func main() throws {
    if CommandLine.arguments.dropFirst() == ["--ownership-probe"] {
      var probe = VideoToolsRotationIntent()
      probe.resetMedia(to: source)
      let old = firstTicket(&probe)
      expect(probe.consume(ticket: old, currentURL: source) != nil, "The first completion owns one submission")
      expect(probe.consume(ticket: old, currentURL: source) == nil, "Repeated completion must not replay a submission")
      probe.cancel()
      let current = firstTicket(&probe, turns: -1)
      expect(probe.consume(ticket: old, currentURL: source) == nil, "A stale completion must not consume a newer request")
      expect(probe.isCurrent(current), "The current request must survive an unrelated callback")
      print("Ownership probe: \(checks) checks, \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    var intent = VideoToolsRotationIntent()
    expect(!intent.hasPending && intent.inputURL == nil, "An empty owner has no media or pending request")
    expect(intent.append(clockwiseQuarterTurns: 1) == .rejected, "Presses before admission are rejected")
    intent.resetMedia(to: URL(string: "https://example.invalid/video.mov")!)
    expect(intent.append(clockwiseQuarterTurns: 1) == .rejected, "Network input cannot acquire rotation ownership")
    intent.resetMedia(to: source)
    let epoch = intent.mediaEpoch
    expect(intent.append(clockwiseQuarterTurns: 0) == .rejected && !intent.hasPending,
           "Zero input does not allocate a handoff")
    let first = firstTicket(&intent, turns: -1)
    expect(first.mediaEpoch == epoch && first.inputURL == source, "The immutable ticket binds the admitted media")
    expect(intent.append(clockwiseQuarterTurns: -1) == .accumulated(first), "A second left press reuses the first handoff")
    expect(intent.isCurrent(first) && intent.pendingTicket == first, "Accumulation preserves request identity")
    expect(intent.consume(ticket: first, currentURL: otherSource) == nil && intent.hasPending,
           "A wrong-media completion cannot consume or discard the current request")
    expect(intent.consume(ticket: first, currentURL: URL(string: "https://example.invalid")!) == nil,
           "A nonlocal completion is rejected")
    let halfTurn = intent.consume(ticket: first, currentURL: source)
    expect(halfTurn?.clockwiseQuarterTurns == 2 && halfTurn?.ticket == first, "Two left presses consume one half turn")
    expect(!intent.hasPending && !intent.isCurrent(first), "Consumption clears ownership before external work")
    expect(intent.consume(ticket: first, currentURL: source) == nil, "Repeated completion cannot consume twice")

    let second = firstTicket(&intent)
    expect(second.requestID != first.requestID && second.mediaEpoch == first.mediaEpoch,
           "A new request on the same media owns a fresh request ID")
    expect(!intent.cancel(requestID: first.requestID) && intent.isCurrent(second), "An old timeout cannot cancel a newer request")
    expect(intent.consume(ticket: first, currentURL: source) == nil && intent.isCurrent(second),
           "An old successful callback cannot consume a newer request")
    expect(intent.cancel(requestID: second.requestID) && !intent.hasPending, "A matching failure cancels once")
    expect(!intent.cancel(requestID: second.requestID), "A duplicate failure is a no-op")
    let beforeReopen = firstTicket(&intent)
    intent.resetMedia(to: source)
    expect(intent.mediaEpoch != epoch && !intent.hasPending, "Same-path user reopen changes media epoch")
    let afterReopen = firstTicket(&intent, turns: -1)
    expect(intent.consume(ticket: beforeReopen, currentURL: source) == nil && intent.isCurrent(afterReopen),
           "A stale same-path callback cannot claim the reopened media")
    intent.resetMedia(to: otherSource)
    expect(!intent.hasPending && intent.inputURL == otherSource, "New media discards only the pending intent")
    expect(intent.consume(ticket: afterReopen, currentURL: otherSource) == nil, "A stale cross-media callback is rejected")
    let beforeCancel = firstTicket(&intent)
    intent.cancel()
    expect(!intent.hasPending && intent.inputURL == otherSource, "Navigation cancellation retains media admission")
    expect(intent.consume(ticket: beforeCancel, currentURL: otherSource) == nil, "A cancelled request cannot be replayed")
    intent.resetMedia(to: nil)
    expect(intent.inputURL == nil && !intent.hasPending, "Closing removes media and pending intent")

    var anotherPlayer = VideoToolsRotationIntent()
    intent.resetMedia(to: source)
    anotherPlayer.resetMedia(to: source)
    let ownTicket = firstTicket(&intent)
    let otherTicket = firstTicket(&anotherPlayer)
    expect(ownTicket.mediaEpoch != otherTicket.mediaEpoch && ownTicket.requestID != otherTicket.requestID,
           "Two owners opening one path retain distinct media and request identity")
    expect(intent.consume(ticket: otherTicket, currentURL: source) == nil && intent.isCurrent(ownTicket),
           "Another player's completion cannot steal local pending intent")
    intent.cancel()
    expect(anotherPlayer.isCurrent(otherTicket), "Cancelling one owner does not affect another")

    // Independently calculate modulo-four orientation using unsigned bit patterns.
    // Includes extreme integers; no unbounded sum is needed in either implementation.
    let deltas = [Int.min, Int.max, -9, -4, -1, 0, 1, 4, 9]
    for delta in deltas where delta != 0 {
      intent.resetMedia(to: source)
      let ticket = firstTicket(&intent, turns: delta)
      let expected = Int(UInt(bitPattern: delta) & 3)
      expect(intent.consume(ticket: ticket, currentURL: source)?.clockwiseQuarterTurns == (expected == 0 ? 4 : expected),
             "Extreme signed input has the correct bounded orientation")
    }
    intent.resetMedia(to: source)
    let stress = firstTicket(&intent)
    var expected = 1
    for index in 0..<50_000 {
      let delta = deltas[index % deltas.count]
      let result = intent.append(clockwiseQuarterTurns: delta)
      expect(result == (delta == 0 ? .rejected : .accumulated(stress)), "Stress presses never allocate another handoff")
      expected = (expected + Int(UInt(bitPattern: delta) & 3)) & 3
    }
    expect(intent.consume(ticket: stress, currentURL: source)?.clockwiseQuarterTurns == (expected == 0 ? 4 : expected),
           "A long mixed sequence preserves its exact final orientation")

    for sequence in [[1, 1, 1, 1], [-1, 1], [-1, -1, -1, -1]] {
      intent.resetMedia(to: source)
      let ticket = firstTicket(&intent, turns: sequence[0])
      for delta in sequence.dropFirst() { _ = intent.append(clockwiseQuarterTurns: delta) }
      expect(intent.consume(ticket: ticket, currentURL: source)?.clockwiseQuarterTurns == 4,
             "Accepted presses with net-zero orientation retain the explicit full-turn export")
    }

    // Use the existing production coordinator, with only the external export task
    // represented by a boundary. This is not an actual native-to-MPV handoff test.
    let tasks = TaskBoundary()
    let coordinator = VideoToolsRotationCoordinator(taskManager: tasks,
      notificationCenter: tasks.notifications, debounceInterval: 0)
    defer { coordinator.reset(cancelActive: false) }
    intent.resetMedia(to: source)
    let rotation = firstTicket(&intent, turns: -1)
    _ = intent.append(clockwiseQuarterTurns: -1)
    let submission = intent.consume(ticket: rotation, currentURL: source)!
    try coordinator.request(inputURL: submission.ticket.inputURL,
                            clockwiseQuarterTurns: submission.clockwiseQuarterTurns)
    pump { tasks.requests.count == 1 }
    expect(tasks.requests.first?.degrees == 180, "One accumulated submission produces one coordinator export")
    expect(intent.consume(ticket: rotation, currentURL: source) == nil, "A duplicate handoff cannot submit an export twice")
    try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
    expect(tasks.requests.count == 1 && coordinator.state.hasQueuedRotation, "Later MPV presses retain the existing active-task queue")
    tasks.complete()
    let completedOutput = coordinator.state.outputURL
    pump { tasks.requests.count == 2 }
    expect(tasks.requests.last?.degrees == 270, "The existing coordinator accumulates subsequent rotation")
    expect(tasks.requests.allSatisfy { $0.inputURL == source }, "All exports use the original source, never an output")
    tasks.complete()
    let latestOutput = coordinator.state.outputURL
    let cancelled = firstTicket(&intent)
    intent.cancel()
    expect(intent.consume(ticket: cancelled, currentURL: source) == nil, "An unsubmitted cancellation produces no task")
    expect(tasks.requests.count == 2 && tasks.cancellations == 0 && coordinator.state.outputURL == latestOutput,
           "Intent cancellation never touches already exported files or tasks")
    expect(completedOutput != nil && latestOutput != nil && completedOutput != latestOutput,
           "Both completed outputs remain separately represented")

    let fullTurnTasks = TaskBoundary()
    let fullTurnCoordinator = VideoToolsRotationCoordinator(taskManager: fullTurnTasks,
      notificationCenter: fullTurnTasks.notifications, debounceInterval: 0)
    defer { fullTurnCoordinator.reset(cancelActive: false) }
    intent.resetMedia(to: source)
    let fullTurn = firstTicket(&intent, turns: 4)
    let fullTurnSubmission = intent.consume(ticket: fullTurn, currentURL: source)!
    try fullTurnCoordinator.request(inputURL: source, clockwiseQuarterTurns: fullTurnSubmission.clockwiseQuarterTurns)
    pump { fullTurnTasks.requests.count == 1 }
    expect(fullTurnTasks.requests.first?.degrees == 360, "The production coordinator exports a net-zero submission as 360 degrees")
    fullTurnTasks.complete()

    print("Rotation intent: \(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
}
