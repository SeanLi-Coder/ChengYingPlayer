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
    for (stage, key) in [
      ("Inspecting Dolby Vision frames in the selected range", "videotools.status.hdr_inspection"),
      ("Verifying Dolby Vision metadata and selected frame timestamps", "videotools.status.hdr_verification"),
    ] {
      try client.emit(["id": id, "type": "progress", "operation": "convert", "progress": 90, "eta_seconds": 4.0])
      check(manager.snapshot?.etaSeconds == 4, "Encoding progress can have an ETA before HDR validation")
      try client.emit(["id": id, "type": "progress", "operation": "convert", "progress": 99, "message": stage])
      let explanation = NSLocalizedString(key, comment: "HDR validation stage test")
      check(explanation != key && manager.snapshot?.message == explanation,
            "Known HDR validation progress displays its localized stage instead of raw helper text")
      check(manager.snapshot?.etaSeconds == nil && manager.snapshot?.phase == .running && manager.snapshot?.progress == 99,
            "Validation without an ETA clears the previous estimate and remains unfinished")
      try client.emit([
        "id": id, "type": "progress", "operation": "convert", "progress": 99,
        "message": stage, "eta_seconds": 1.0,
      ])
      check(manager.snapshot?.etaSeconds == nil, "A stale encoding ETA cannot appear beside a known HDR validation stage")
    }
    for message in ["Unknown helper progress", "Inspecting Dolby Vision frames in the selected range: future detail"] {
      try client.emit([
        "id": id, "type": "progress", "operation": "convert", "progress": 91,
        "message": message, "eta_seconds": 12.0,
      ])
      check(manager.snapshot?.message == NSLocalizedString("videotools.status.running", comment: "") && manager.snapshot?.etaSeconds == 12,
            "Unknown progress retains the existing generic message and reported ETA")
    }
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
    check(client.requests.last?.targetFormat == nil && client.requests.last?.conversionMode == nil && client.requests.last?.frameFormat == nil,
          "Existing clip calls remain source compatible and omit conversion options")
    try client.emit(["id": clipID, "type": "cancelled", "operation": "clip"])
    let jpgID = try manager.start(operation: .frames, inputURL: source, start: 1, end: 2)
    check(client.requests.last?.frameFormat == "jpg", "Existing frame callers default to JPG through the real manager")
    try client.emit(["id": jpgID, "type": "completed", "operation": "frames"])
    let pngID = try manager.start(operation: .frames, inputURL: source, start: 1, end: 2, frameFormat: "png")
    check(client.requests.last?.frameFormat == "png", "Explicit lossless frame format reaches the helper request")
    try client.emit(["id": pngID, "type": "completed", "operation": "frames"])
    let dolbyVisionFailures: [(String, String)] = [
      ("Dynamic HDR clipping currently supports only single-layer Dolby Vision profile 8.1 or 8.4", "profile"),
      ("Dolby Vision clipping requires progressive video", "progressive"),
      ("Dolby Vision profile 8.1 clipping requires verified static HDR metadata", "static_metadata"),
      ("Dolby Vision clipping requires MP4-compatible mono or stereo audio up to 24 bits", "audio"),
      ("Dolby Vision clipping exceeds the supported picture size or frame rate", "dimensions"),
      ("Dolby Vision frames have missing presentation timestamps", "timestamps"),
      ("Dolby Vision frames have ambiguous presentation timestamps", "timestamps"),
      ("Dolby Vision packets have ambiguous presentation timestamps", "timestamps"),
      ("A selected frame is missing Dolby Vision metadata", "missing_metadata"),
      ("A selected packet is missing Dolby Vision RPU data", "missing_metadata"),
      ("The selected range contains no Dolby Vision video frames", "empty_range"),
      ("Dolby Vision metadata inspection failed; no output was published", "inspection"),
      ("Invalid Dolby Vision metadata fingerprint", "inspection"),
      ("Dolby Vision metadata fingerprints are unavailable", "inspection"),
      ("Output verification detected a changed Dolby Vision profile", "verification"),
      ("Output verification detected a changed Dolby Vision display matrix", "verification"),
      ("Output verification detected a changed Dolby Vision frame count", "verification"),
      ("Output verification detected changed Dolby Vision frame timestamps", "verification"),
      ("Output verification detected changed Dolby Vision RPU metadata", "verification"),
      ("Output verification found no Dolby Vision frames", "verification"),
      ("Output verification detected missing or hidden Dolby Vision frames", "verification"),
    ]
    for (detail, suffix) in dolbyVisionFailures {
      let key = "videotools.error.dovi.\(suffix)"
      let translated = NSLocalizedString(key, comment: "Dolby Vision diagnostic test")
      check(translated != key, "Dolby Vision \(suffix) has a loaded localized explanation")
      let failedClip = try manager.start(operation: .clip, inputURL: source, start: 1, end: 2)
      try client.emit([
        "id": failedClip, "type": "failed", "operation": "clip",
        "error_code": "processing_failed", "error": detail,
      ])
      check(manager.snapshot?.message == String(format:
        NSLocalizedString("videotools.status.failed_detail", comment: ""), "\(translated)\n\(detail)"),
        "Known Dolby Vision failures display an explanation and their exact technical detail")
      check(manager.snapshot?.error == detail && manager.snapshot?.errorCode == "processing_failed" && manager.snapshot?.outputURL == nil,
            "Localization preserves raw failure evidence and never exposes an unverified output")
    }
    for detail in ["Unexpected future Dolby Vision failure", "Output verification detected an unknown Dolby Vision problem", "A different export failed"] {
      check(VideoToolsFailureMessage.localizedDetail(detail) == detail,
            "Unknown helper errors remain unmodified instead of being generalized")
    }
    let variableHDRDetail = "Variable static HDR metadata cannot be preserved safely"
    let variableHDRKey = "videotools.error.hdr.variable_static_metadata"
    let variableHDRExplanation = NSLocalizedString(variableHDRKey, comment: "Variable static HDR diagnostic test")
    check(variableHDRExplanation != variableHDRKey, "Variable static HDR has a loaded localized explanation")
    let variableHDRClip = try manager.start(operation: .clip, inputURL: source, start: 1, end: 2)
    try client.emit([
      "id": variableHDRClip, "type": "failed", "operation": "clip",
      "error_code": "processing_failed", "error": variableHDRDetail,
    ])
    check(manager.snapshot?.message == String(format:
      NSLocalizedString("videotools.status.failed_detail", comment: ""), "\(variableHDRExplanation)\n\(variableHDRDetail)"),
      "Variable static HDR failures keep an explanation and exact technical detail")
    check(manager.snapshot?.error == variableHDRDetail && manager.snapshot?.errorCode == "processing_failed" && manager.snapshot?.outputURL == nil,
          "Variable HDR localization retains failure evidence without exposing an unverified output")
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
