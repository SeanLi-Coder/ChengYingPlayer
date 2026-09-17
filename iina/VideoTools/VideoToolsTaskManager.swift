//
//  VideoToolsTaskManager.swift
//  ChengYing
//

import Foundation

final class VideoToolsTaskManager {
  static let shared = VideoToolsTaskManager()

  private(set) var snapshot: VideoToolsTaskSnapshot?
  private let client = VideoToolsHelperClient.shared

  private init() {
    client.eventHandler = { [weak self] event in
      self?.handle(event)
    }
    client.failureHandler = { [weak self] error in
      self?.handleClientFailure(error)
    }
  }

  @discardableResult
  func start(
    operation: VideoToolsOperation,
    inputURL: URL,
    start: Double? = nil,
    end: Double? = nil,
    degrees: Int? = nil,
    targetFormat: String? = nil,
    conversionMode: String? = nil,
    outputDirectory: URL? = nil
  ) throws -> String {
    precondition(Thread.isMainThread)
    if UpdateWorkAdmission.shared.isHelperRestartBlocked || snapshot?.isActive == true {
      throw VideoToolsClientError.busy
    }

    let id = UUID().uuidString
    let request = VideoToolsRequest.start(
      id: id,
      operation: operation,
      inputURL: inputURL,
      start: start,
      end: end,
      degrees: degrees,
      targetFormat: targetFormat,
      conversionMode: conversionMode,
      outputDirectory: outputDirectory
    )
    let initial = VideoToolsTaskSnapshot(
      id: id,
      operation: operation,
      inputURL: inputURL,
      phase: .starting,
      progress: 0,
      message: NSLocalizedString("videotools.status.starting", comment: "Starting"),
      elapsedSeconds: nil,
      etaSeconds: nil,
      frameCount: nil,
      outputURL: nil,
      errorCode: nil,
      error: nil
    )
    do {
      try client.send(request)
      snapshot = initial
      notify()
      return id
    } catch {
      snapshot = initial
      snapshot?.phase = .failed
      snapshot?.message = error.localizedDescription
      snapshot?.error = error.localizedDescription
      notify()
      throw error
    }
  }

  func cancelCurrent() {
    precondition(Thread.isMainThread)
    guard var current = snapshot, current.isActive else { return }
    current.phase = .cancelling
    current.message = NSLocalizedString("videotools.status.cancelling", comment: "Cancelling")
    current.etaSeconds = nil
    snapshot = current
    notify()
    do {
      try client.send(.cancel(id: UUID().uuidString, targetID: current.id))
    } catch {
      handleClientFailure(error)
    }
  }

  private func handle(_ event: VideoToolsEvent) {
    precondition(Thread.isMainThread)
    guard event.type != .ready, event.type != .pong else { return }
    guard var current = snapshot, current.isActive else { return }
    if let eventID = event.id, eventID != current.id {
      return
    }

    switch event.type {
    case .accepted:
      if event.action == "cancel" {
        current.phase = .cancelling
        current.message = NSLocalizedString("videotools.status.cancelling", comment: "Cancelling")
      } else {
        current.phase = .running
        current.message = NSLocalizedString("videotools.status.running", comment: "Processing")
      }
    case .progress:
      if current.phase != .cancelling {
        current.phase = .running
        current.message = NSLocalizedString("videotools.status.running", comment: "Processing")
      }
      current.progress = normalizedProgress(event.progress)
      current.elapsedSeconds = event.elapsedSeconds
      current.etaSeconds = event.etaSeconds
      current.frameCount = event.frameCount
    case .completed:
      current.phase = .completed
      current.progress = 100
      current.message = NSLocalizedString("videotools.status.completed", comment: "Completed")
      current.elapsedSeconds = event.elapsedSeconds
      current.etaSeconds = 0
      current.frameCount = event.frameCount
      if let outputPath = event.outputPath {
        current.outputURL = URL(fileURLWithPath: outputPath)
      }
    case .failed:
      current.phase = .failed
      if let detail = event.error, !detail.isEmpty {
        current.message = String(
          format: NSLocalizedString("videotools.status.failed_detail", comment: "Failed with detail"),
          detail
        )
      } else {
        current.message = NSLocalizedString("videotools.status.failed", comment: "Failed")
      }
      current.errorCode = event.errorCode
      current.error = event.error
      current.etaSeconds = nil
    case .cancelled:
      current.phase = .cancelled
      current.message = NSLocalizedString("videotools.status.cancelled", comment: "Cancelled")
      current.progress = normalizedProgress(event.progress)
      current.elapsedSeconds = event.elapsedSeconds
      current.etaSeconds = nil
    case .ready, .pong:
      return
    }
    snapshot = current
    notify()
  }

  private func handleClientFailure(_ error: Error) {
    precondition(Thread.isMainThread)
    guard var current = snapshot, current.isActive else { return }
    current.phase = .failed
    current.message = error.localizedDescription
    current.error = error.localizedDescription
    current.etaSeconds = nil
    snapshot = current
    notify()
  }

  private func normalizedProgress(_ progress: Double?) -> Double {
    min(100, max(0, progress ?? 0))
  }

  private func notify() {
    NotificationCenter.default.post(name: .videoToolsTaskChanged, object: self)
  }
}

extension VideoToolsTaskManager: VideoToolsRotationTaskManaging {
  func startRotation(inputURL: URL, degrees: Int) throws -> String {
    try start(operation: .rotate, inputURL: inputURL, degrees: degrees)
  }

  func cancelRotation(taskID: String) {
    guard snapshot?.id == taskID else { return }
    cancelCurrent()
  }
}
