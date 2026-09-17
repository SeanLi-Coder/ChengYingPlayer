//
//  VideoToolsRotationCoordinator.swift
//  ChengYing
//

import Foundation

protocol VideoToolsRotationTaskManaging: AnyObject {
  var snapshot: VideoToolsTaskSnapshot? { get }
  func startRotation(inputURL: URL, degrees: Int) throws -> String
  func cancelRotation(taskID: String)
}

/// Owns one player's cumulative rotation without ever using an exported file as its input.
final class VideoToolsRotationCoordinator {
  private static let instances = NSHashTable<VideoToolsRotationCoordinator>.weakObjects()
  static var hasPendingUpdateWork: Bool {
    precondition(Thread.isMainThread)
    return instances.allObjects.contains {
      $0.state.phase == .pending || $0.state.phase == .exporting || $0.state.hasQueuedRotation
    }
  }
  enum Phase: Equatable {
    case idle
    case pending
    case exporting
    case completed
    case failed
    case cancelled
  }

  struct State {
    var inputURL: URL?
    var desiredDegrees = 0
    var completedDegrees = 0
    var phase = Phase.idle
    var task: VideoToolsTaskSnapshot?
    var outputURL: URL?
    var error: Error?
    var hasQueuedRotation = false
  }

  private(set) var state = State()
  var stateHandler: ((State) -> Void)?

  private let taskManager: VideoToolsRotationTaskManaging
  private let notificationCenter: NotificationCenter
  private let debounceInterval: TimeInterval
  private var observer: NSObjectProtocol?
  private var scheduledExport: DispatchWorkItem?
  private var activeTaskID: String?
  private var activeDegrees: Int?
  private var generation: UInt64 = 0

  init(
    taskManager: VideoToolsRotationTaskManaging,
    notificationCenter: NotificationCenter = .default,
    debounceInterval: TimeInterval = 0.25
  ) {
    self.taskManager = taskManager
    self.notificationCenter = notificationCenter
    self.debounceInterval = max(0, debounceInterval)
    Self.instances.add(self)
    observer = notificationCenter.addObserver(forName: .videoToolsTaskChanged, object: nil, queue: nil) {
      [weak self] notification in
      guard let self = self,
            let sender = notification.object as AnyObject?,
            sender === self.taskManager else { return }
      self.taskDidChange()
    }
  }

  deinit {
    scheduledExport?.cancel()
    if let observer = observer { notificationCenter.removeObserver(observer) }
  }

  /// Positive turns rotate clockwise; negative turns rotate counterclockwise.
  /// A busy error means the request was not accepted and the preview must not change.
  func request(inputURL: URL, clockwiseQuarterTurns: Int) throws {
    precondition(Thread.isMainThread)
    guard !UpdateWorkAdmission.shared.isHelperRestartBlocked else { throw VideoToolsClientError.busy }
    guard inputURL.isFileURL else {
      throw VideoToolsClientError.invalidResponse("Permanent rotation requires a local video.")
    }
    guard clockwiseQuarterTurns != 0 else { return }
    let sourceURL = inputURL.standardizedFileURL
    if let previousURL = state.inputURL, previousURL != sourceURL {
      reset(cancelActive: true)
    }
    if let task = taskManager.snapshot, task.isActive {
      guard task.id == activeTaskID, task.phase != .cancelling else {
        throw VideoToolsClientError.busy
      }
    }

    state.inputURL = sourceURL
    // Reduce before multiplying so an arbitrary caller cannot overflow Int.
    state.desiredDegrees = Self.normalizedDegrees(state.desiredDegrees + (clockwiseQuarterTurns % 4) * 90)
    state.error = nil
    if activeTaskID != nil {
      state.hasQueuedRotation = state.desiredDegrees != activeDegrees
      publish()
    } else {
      state.phase = .pending
      state.hasQueuedRotation = true
      scheduleExport()
      publish()
    }
  }

  /// Cancels only this player's export. Already completed output files are never removed.
  func cancel() {
    precondition(Thread.isMainThread)
    scheduledExport?.cancel()
    scheduledExport = nil
    state.desiredDegrees = state.completedDegrees
    state.hasQueuedRotation = false
    if let taskID = activeTaskID {
      taskManager.cancelRotation(taskID: taskID)
    } else {
      state.phase = .cancelled
      publish()
    }
  }

  /// Call on media changes and player shutdown so pending work cannot outlive its source.
  func reset(cancelActive: Bool = true) {
    precondition(Thread.isMainThread)
    generation &+= 1
    scheduledExport?.cancel()
    scheduledExport = nil
    let previousTaskID = activeTaskID
    activeTaskID = nil
    activeDegrees = nil
    state = State()
    if cancelActive, let taskID = previousTaskID {
      taskManager.cancelRotation(taskID: taskID)
    }
    publish()
  }

  private func scheduleExport() {
    scheduledExport?.cancel()
    let scheduledGeneration = generation
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == scheduledGeneration else { return }
      self.scheduledExport = nil
      self.startExport()
    }
    scheduledExport = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
  }

  private func startExport() {
    precondition(Thread.isMainThread)
    guard activeTaskID == nil, let inputURL = state.inputURL else { return }
    let degrees = state.desiredDegrees
    do {
      // The helper accepts 360, not 0, for an export with the original orientation.
      let taskID = try taskManager.startRotation(inputURL: inputURL, degrees: degrees == 0 ? 360 : degrees)
      activeTaskID = taskID
      activeDegrees = degrees
      state.phase = .exporting
      state.task = taskManager.snapshot
      state.hasQueuedRotation = false
      publish()
    } catch {
      finishUnsuccessfully(phase: .failed, error: error)
    }
  }

  private func taskDidChange() {
    precondition(Thread.isMainThread)
    guard let task = taskManager.snapshot, task.id == activeTaskID else { return }
    state.task = task
    switch task.phase {
    case .starting, .running:
      publish()
    case .cancelling:
      // Cancellation from the tools panel must also discard queued shortcut presses.
      state.desiredDegrees = state.completedDegrees
      state.hasQueuedRotation = false
      publish()
    case .completed:
      let degrees = activeDegrees ?? state.desiredDegrees
      let queuedDegrees = state.hasQueuedRotation ? state.desiredDegrees : nil
      activeTaskID = nil
      activeDegrees = nil
      state.completedDegrees = degrees
      state.outputURL = task.outputURL
      state.error = nil
      state.phase = .completed
      state.hasQueuedRotation = false
      if let queuedDegrees = queuedDegrees, queuedDegrees != degrees {
        state.desiredDegrees = queuedDegrees
        state.phase = .pending
        state.hasQueuedRotation = true
        scheduleExport()
      } else {
        state.desiredDegrees = degrees
      }
      publish()
    case .failed:
      finishUnsuccessfully(
        phase: .failed,
        error: VideoToolsClientError.invalidResponse(task.error ?? task.message)
      )
    case .cancelled:
      finishUnsuccessfully(phase: .cancelled, error: nil)
    }
  }

  private func finishUnsuccessfully(phase: Phase, error: Error?) {
    scheduledExport?.cancel()
    scheduledExport = nil
    activeTaskID = nil
    activeDegrees = nil
    state.desiredDegrees = state.completedDegrees
    state.hasQueuedRotation = false
    state.phase = phase
    state.error = error
    publish()
  }

  private func publish() {
    stateHandler?(state)
  }

  private static func normalizedDegrees(_ degrees: Int) -> Int {
    (degrees % 360 + 360) % 360
  }
}
