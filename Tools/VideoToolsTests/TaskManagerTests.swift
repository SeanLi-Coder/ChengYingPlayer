import Foundation

final class VideoToolsHelperClient {
  static let shared = VideoToolsHelperClient()
  var eventHandler: ((VideoToolsEvent) -> Void)?
  var failureHandler: ((Error) -> Void)?
  var requests: [VideoToolsRequest] = []
  var sendError: Error?

  func send(_ request: VideoToolsRequest) throws {
    if let sendError { throw sendError }
    requests.append(request)
  }

  func emit(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload)
    eventHandler?(try JSONDecoder().decode(VideoToolsEvent.self, from: data))
  }
}

@main
struct TaskManagerTests {
  static func main() throws {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      guard condition() else { fatalError("FAIL: \(message)") }
      count += 1
      print("PASS: \(message)")
    }
    let manager = VideoToolsTaskManager.shared
    let client = VideoToolsHelperClient.shared
    let source = URL(fileURLWithPath: "/tmp/source video.mov")
    let output = URL(fileURLWithPath: "/tmp/output folder", isDirectory: true)
    let updateBarrier = UUID()
    check(UpdateWorkAdmission.shared.acquire(updateBarrier), "An idle update barrier can be acquired")
    do {
      _ = try manager.start(operation: .convert, inputURL: source)
      fatalError("FAIL: Update barrier accepted a new export")
    } catch VideoToolsClientError.busy {
      check(client.requests.isEmpty && manager.snapshot == nil, "Update barrier rejects export before any helper or task side effect")
    }
    UpdateWorkAdmission.shared.release(updateBarrier)
    let id = try manager.start(
      operation: .convert, inputURL: source, targetFormat: "mkv",
      conversionMode: "hevc", outputDirectory: output
    )
    check(manager.snapshot?.id == id && manager.snapshot?.operation == .convert && manager.snapshot?.phase == .starting,
          "The real task manager owns a starting conversion snapshot")
    check(client.requests.last?.operation == .convert && client.requests.last?.inputPath == source.path,
          "The real task manager dispatches the conversion source")
    check(client.requests.last?.targetFormat == "mkv" && client.requests.last?.conversionMode == "hevc" && client.requests.last?.outputDirectory == output.path,
          "The real task manager forwards format, mode and output directory")
    check(client.requests.last?.start == nil && client.requests.last?.end == nil && client.requests.last?.degrees == nil,
          "The real task manager leaves optional ranges and rotation absent")
    do {
      try manager.start(operation: .convert, inputURL: source)
      fatalError("FAIL: A second active conversion was accepted")
    } catch VideoToolsClientError.busy {
      check(client.requests.count == 1, "A busy task is rejected before dispatch")
    }
    try client.emit(["id": id, "type": "accepted", "operation": "convert"])
    check(manager.snapshot?.phase == .running, "Conversion acceptance transitions to running")
    try client.emit([
      "id": id, "type": "progress", "operation": "convert", "progress": 47.5,
      "elapsed_seconds": 14.0, "eta_seconds": 16.0,
    ])
    check(manager.snapshot?.progress == 47.5 && manager.snapshot?.elapsedSeconds == 14 && manager.snapshot?.etaSeconds == 16,
          "Conversion progress, elapsed time and remaining time reach the native snapshot")
    try client.emit(["id": "unrelated", "type": "completed", "operation": "convert"])
    check(manager.snapshot?.phase == .running && manager.snapshot?.progress == 47.5,
          "Another task's terminal event cannot complete this conversion")
    manager.cancelCurrent()
    check(manager.snapshot?.phase == .cancelling && manager.snapshot?.etaSeconds == nil,
          "Conversion cancellation clears the remaining-time estimate")
    check(client.requests.last?.command == "cancel" && client.requests.last?.targetID == id,
          "Conversion cancellation addresses the correct task")
    try client.emit(["id": id, "type": "progress", "operation": "convert", "progress": 48.0])
    check(manager.snapshot?.phase == .cancelling, "Late conversion progress cannot undo cancellation")
    try client.emit(["id": id, "type": "cancelled", "operation": "convert", "progress": 48.0])
    check(manager.snapshot?.phase == .cancelled && manager.snapshot?.outputURL == nil,
          "Cancelled conversion does not expose an output")

    let completedID = try manager.start(operation: .convert, inputURL: source, targetFormat: "mp4", conversionMode: "copy")
    try client.emit([
      "id": completedID, "type": "completed", "operation": "convert",
      "output_path": "/tmp/converted video.mp4", "elapsed_seconds": 3.0,
    ])
    check(manager.snapshot?.phase == .completed && manager.snapshot?.progress == 100 && manager.snapshot?.etaSeconds == 0,
          "Successful conversion reaches a completed snapshot")
    check(manager.snapshot?.outputURL?.path == "/tmp/converted video.mp4" && manager.snapshot?.elapsedSeconds == 3,
          "Successful conversion exposes the backend's actual output path")
    try client.emit(["id": completedID, "type": "failed", "operation": "convert", "error": "Late failure"])
    check(manager.snapshot?.phase == .completed, "A late failure cannot overwrite a completed conversion")

    let failedID = try manager.start(operation: .convert, inputURL: source, targetFormat: "mp4", conversionMode: "copy")
    try client.emit([
      "id": failedID, "type": "failed", "operation": "convert",
      "error_code": "processing_failed", "error": "Subtitle format is not supported; choose MKV.",
    ])
    check(manager.snapshot?.phase == .failed && manager.snapshot?.errorCode == "processing_failed",
          "Backend compatibility failures reach the conversion snapshot")
    check(manager.snapshot?.message.contains("choose MKV") == true && manager.snapshot?.outputURL == nil,
          "Actionable conversion errors remain visible without an output")

    let clipID = try manager.start(operation: .clip, inputURL: source, start: 1, end: 2)
    check(client.requests.last?.targetFormat == nil && client.requests.last?.conversionMode == nil,
          "Existing clip calls remain source compatible and omit conversion options")
    try client.emit(["id": clipID, "type": "cancelled", "operation": "clip"])
    client.sendError = VideoToolsClientError.launchFailed("Test failure")
    do {
      try manager.start(operation: .convert, inputURL: source)
      fatalError("FAIL: A helper launch failure was ignored")
    } catch {
      check(manager.snapshot?.phase == .failed && manager.snapshot?.operation == .convert,
            "Failed conversion dispatch creates a recoverable failed snapshot")
    }
    print("SUCCESS: \(count) task manager checks passed")
  }
}
