import Foundation

private final class RotationTaskDouble: NSObject, VideoToolsRotationTaskManaging {
  struct Request {
    let id: String
    let inputURL: URL
    let degrees: Int
  }

  let notifications = NotificationCenter()
  var snapshot: VideoToolsTaskSnapshot?
  var requests: [Request] = []
  var cancellations: [String] = []
  var startError: Error?

  func startRotation(inputURL: URL, degrees: Int) throws -> String {
    if let error = startError { throw error }
    if snapshot?.isActive == true { throw VideoToolsClientError.busy }
    let id = "rotation-\(requests.count + 1)"
    requests.append(Request(id: id, inputURL: inputURL, degrees: degrees))
    snapshot = VideoToolsTaskSnapshot(
      id: id, operation: .rotate, inputURL: inputURL, phase: .starting,
      progress: 0, message: "Starting", elapsedSeconds: nil, etaSeconds: nil,
      frameCount: nil, outputURL: nil, errorCode: nil, error: nil
    )
    notify()
    return id
  }

  func cancelRotation(taskID: String) {
    guard snapshot?.id == taskID, snapshot?.isActive == true else { return }
    cancellations.append(taskID)
    finish(.cancelling)
  }

  func finish(_ phase: VideoToolsTaskPhase) {
    snapshot?.phase = phase
    if phase == .completed {
      snapshot?.outputURL = URL(fileURLWithPath: "/video/export-\(requests.count).mkv")
    } else if phase == .failed {
      snapshot?.error = "Export failed"
    }
    notify()
  }

  func notify() {
    notifications.post(name: .videoToolsTaskChanged, object: self)
  }

  func coordinator(debounceInterval: TimeInterval = 0) -> VideoToolsRotationCoordinator {
    VideoToolsRotationCoordinator(
      taskManager: self, notificationCenter: notifications, debounceInterval: debounceInterval
    )
  }
}

@main
private enum RotationCoordinatorTests {
  static var checks = 0
  static let source = URL(fileURLWithPath: "/video/original.mov")

  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
  }

  static func pump(until predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(1)
    while !predicate(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    expect(predicate(), "The scheduled export did not run")
  }

  static func assertNoDeferredExport(_ manager: RotationTaskDouble, count: Int) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    expect(manager.requests.count == count, "Unexpected deferred export")
  }

  static func main() throws {
    // Repeated shortcuts are merged and use the original source only.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator(debounceInterval: 0.01)
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: -1)
      expect(coordinator.state.desiredDegrees == 270, "Left must mean counterclockwise")
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: -1)
      expect(coordinator.state.desiredDegrees == 180, "Two left presses must mean 180 degrees")
      expect(manager.requests.isEmpty, "The debounce must combine rapid presses")
      pump { manager.requests.count == 1 }
      expect(manager.requests[0].degrees == 180, "The merged request must export 180 degrees")
      manager.finish(.completed)
      expect(coordinator.state.phase == .completed, "Completion must be observed")
      expect(coordinator.state.completedDegrees == 180, "Successful orientation must be remembered")
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 2 }
      expect(manager.requests[1].degrees == 270, "Later presses must accumulate")
      expect(manager.requests.allSatisfy { $0.inputURL == source }, "Never recompress the last export")
    }

    // Presses during an export are not lost and do not interrupt its output.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      expect(coordinator.state.desiredDegrees == 270, "In-flight presses must accumulate")
      expect(coordinator.state.hasQueuedRotation, "An updated target must be visibly queued")
      expect(manager.requests.count == 1, "Do not start two helper jobs concurrently")
      manager.finish(.completed)
      let firstOutput = coordinator.state.outputURL
      expect(firstOutput != nil, "Completed output must be retained while another export is pending")
      pump { manager.requests.count == 2 }
      expect(manager.requests[1].degrees == 270, "Only the latest queued orientation must export")
      expect(manager.requests[1].inputURL == source, "Queued work must use the original source")
      manager.finish(.completed)
      expect(coordinator.state.completedDegrees == 270, "Queued export must commit its orientation")
      expect(coordinator.state.outputURL != firstOutput, "Each completed export has its own file")
    }

    // A queued right/left pair that returns to the active orientation needs no second encode.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: -1)
      expect(!coordinator.state.hasQueuedRotation, "A redundant queued target must collapse")
      manager.finish(.completed)
      assertNoDeferredExport(manager, count: 1)
    }

    // Four turns produce a valid helper angle rather than the unsupported value zero.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      for _ in 0..<4 { try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1) }
      expect(coordinator.state.desiredDegrees == 0, "A full turn must restore the preview orientation")
      pump { manager.requests.count == 1 }
      expect(manager.requests[0].degrees == 360, "A full turn must send a supported helper angle")
    }

    // Failure clears queued work, rolls the preview back, and preserves the last output.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      manager.finish(.completed)
      let output = coordinator.state.outputURL
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 2 }
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      manager.finish(.failed)
      expect(coordinator.state.phase == .failed, "Failure must be reported")
      expect(coordinator.state.error != nil, "Failure detail must reach the UI")
      expect(coordinator.state.desiredDegrees == 90, "Failure must restore the last completed orientation")
      expect(coordinator.state.outputURL == output, "Failure must not discard an existing output")
      expect(!coordinator.state.hasQueuedRotation, "Failure must discard queued requests")
      assertNoDeferredExport(manager, count: 2)
    }

    // Cancellation through either interface discards deferred requests.
    for throughCoordinator in [true, false] {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      if throughCoordinator { coordinator.cancel() } else { manager.finish(.cancelling) }
      expect(!coordinator.state.hasQueuedRotation, "Cancelling must clear queued requests immediately")
      do {
        try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
        fatalError("A cancelling task must reject new requests")
      } catch VideoToolsClientError.busy { checks += 1 }
      manager.finish(.cancelled)
      expect(coordinator.state.phase == .cancelled, "Cancellation must reach the UI")
      expect(coordinator.state.desiredDegrees == 0, "Cancellation must reset an uncommitted preview")
      assertNoDeferredExport(manager, count: 1)
    }

    // Changing files invalidates both timers and old task notifications.
    do {
      let manager = RotationTaskDouble()
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      coordinator.reset()
      assertNoDeferredExport(manager, count: 0)
      expect(coordinator.state.inputURL == nil, "A media reset must forget the old source")
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      coordinator.reset()
      expect(manager.cancellations == ["rotation-1"], "Reset must cancel only the owned export")
      manager.finish(.completed)
      expect(coordinator.state.phase == .idle, "A late completion must not restore the old media state")
      assertNoDeferredExport(manager, count: 1)
      let nextSource = URL(fileURLWithPath: "/video/next.mov")
      try coordinator.request(inputURL: nextSource, clockwiseQuarterTurns: -1)
      pump { manager.requests.count == 2 }
      expect(manager.requests[1].inputURL == nextSource, "The new source must be independent")
      expect(manager.requests[1].degrees == 270, "The new source must start at zero cumulative rotation")
    }

    // Two player windows must not cancel or append requests to each other's export.
    do {
      let manager = RotationTaskDouble()
      let first = manager.coordinator()
      let second = manager.coordinator()
      try first.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { manager.requests.count == 1 }
      do {
        try second.request(inputURL: source, clockwiseQuarterTurns: -1)
        fatalError("A second player must not take ownership of an active export")
      } catch VideoToolsClientError.busy { checks += 1 }
      expect(second.state.desiredDegrees == 0, "A rejected request must not alter the second preview")
      second.reset()
      expect(manager.cancellations.isEmpty, "Resetting another player must not cancel the first export")
      manager.finish(.completed)
      expect(first.state.completedDegrees == 90, "The owning player must receive completion")
      expect(second.state.completedDegrees == 0, "The other player must ignore completion")
    }

    // Helper launch failures must also be visible and leave no pending work.
    do {
      let manager = RotationTaskDouble()
      manager.startError = VideoToolsClientError.disconnected("Test error")
      let coordinator = manager.coordinator()
      try coordinator.request(inputURL: source, clockwiseQuarterTurns: 1)
      pump { coordinator.state.phase == .failed }
      expect(coordinator.state.error != nil, "Launch errors must be reported")
      expect(coordinator.state.desiredDegrees == 0, "Launch errors must restore the preview")
      expect(!coordinator.state.hasQueuedRotation, "Launch errors must discard pending work")
    }

    print("Rotation coordinator tests passed: \(checks) checks")
  }
}
