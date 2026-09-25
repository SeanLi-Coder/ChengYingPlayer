//
//  VideoToolsModels.swift
//  ChengYing
//

import Foundation

enum VideoToolsOperation: String, Codable {
  case probe
  case clip
  case frames
  case rotate
  case convert

  var localizedName: String {
    switch self {
    case .probe:
      return NSLocalizedString("videotools.operation.probe", comment: "Probe video")
    case .clip:
      return NSLocalizedString("videotools.operation.clip", comment: "Clip video")
    case .frames:
      return NSLocalizedString("videotools.operation.frames", comment: "Extract frames")
    case .rotate:
      return NSLocalizedString("videotools.operation.rotate", comment: "Rotate video")
    case .convert:
      return NSLocalizedString("videotools.operation.convert", comment: "Convert video format")
    }
  }
}

enum VideoToolsEventType: String, Codable {
  case ready
  case accepted
  case progress
  case completed
  case failed
  case cancelled
  case pong
}

struct VideoToolsRequest: Encodable {
  let id: String
  let command: String
  let operation: VideoToolsOperation?
  let inputPath: String?
  let start: Double?
  let end: Double?
  let degrees: Int?
  let targetFormat: String?
  let conversionMode: String?
  let frameFormat: String?
  let outputDirectory: String?
  let targetID: String?

  enum CodingKeys: String, CodingKey {
    case id
    case command
    case operation
    case inputPath = "input_path"
    case start
    case end
    case degrees
    case targetFormat = "target_format"
    case conversionMode = "conversion_mode"
    case frameFormat = "frame_format"
    case outputDirectory = "output_directory"
    case targetID = "target_id"
  }

  static func start(
    id: String,
    operation: VideoToolsOperation,
    inputURL: URL,
    start: Double? = nil,
    end: Double? = nil,
    degrees: Int? = nil,
    targetFormat: String? = nil,
    conversionMode: String? = nil,
    frameFormat: String? = nil,
    outputDirectory: URL? = nil
  ) -> VideoToolsRequest {
    VideoToolsRequest(
      id: id,
      command: "start",
      operation: operation,
      inputPath: inputURL.path,
      start: start,
      end: end,
      degrees: degrees,
      targetFormat: targetFormat,
      conversionMode: conversionMode,
      frameFormat: operation == .frames ? (frameFormat ?? "jpg") : nil,
      outputDirectory: outputDirectory?.path,
      targetID: nil
    )
  }

  static func cancel(id: String, targetID: String) -> VideoToolsRequest {
    VideoToolsRequest(
      id: id,
      command: "cancel",
      operation: nil,
      inputPath: nil,
      start: nil,
      end: nil,
      degrees: nil,
      targetFormat: nil,
      conversionMode: nil,
      frameFormat: nil,
      outputDirectory: nil,
      targetID: targetID
    )
  }

  static func shutdown(id: String) -> VideoToolsRequest {
    VideoToolsRequest(
      id: id,
      command: "shutdown",
      operation: nil,
      inputPath: nil,
      start: nil,
      end: nil,
      degrees: nil,
      targetFormat: nil,
      conversionMode: nil,
      frameFormat: nil,
      outputDirectory: nil,
      targetID: nil
    )
  }
}

struct VideoToolsEvent: Decodable {
  let id: String?
  let type: VideoToolsEventType
  let operation: VideoToolsOperation?
  let protocolVersion: Int?
  let action: String?
  let status: String?
  let progress: Double?
  let message: String?
  let elapsedSeconds: Double?
  let etaSeconds: Double?
  let frameCount: Int?
  let outputPath: String?
  let outputName: String?
  let errorCode: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case operation
    case protocolVersion = "protocol_version"
    case action
    case status
    case progress
    case message
    case elapsedSeconds = "elapsed_seconds"
    case etaSeconds = "eta_seconds"
    case frameCount = "frame_count"
    case outputPath = "output_path"
    case outputName = "output_name"
    case errorCode = "error_code"
    case error
  }
}

enum VideoToolsTaskPhase: Equatable {
  case starting
  case running
  case cancelling
  case completed
  case failed
  case cancelled

  var isActive: Bool {
    switch self {
    case .starting, .running, .cancelling:
      return true
    case .completed, .failed, .cancelled:
      return false
    }
  }
}

struct VideoToolsTaskSnapshot {
  let id: String
  let operation: VideoToolsOperation
  let inputURL: URL
  var phase: VideoToolsTaskPhase
  var progress: Double
  var message: String
  var elapsedSeconds: Double?
  var etaSeconds: Double?
  var frameCount: Int?
  var outputURL: URL?
  var errorCode: String?
  var error: String?

  var isActive: Bool { phase.isActive }
}

enum VideoToolsClientError: LocalizedError {
  case missingExecutable(String)
  case launchFailed(String)
  case disconnected(String)
  case incompatibleProtocol(Int?)
  case invalidResponse(String)
  case busy

  var errorDescription: String? {
    switch self {
    case .missingExecutable(let name):
      return String(
        format: NSLocalizedString("videotools.error.missing_executable", comment: "Missing bundled executable"),
        name
      )
    case .launchFailed(let detail):
      return String(
        format: NSLocalizedString("videotools.error.launch_failed", comment: "Failed to launch helper"),
        detail
      )
    case .disconnected(let detail):
      return String(
        format: NSLocalizedString("videotools.error.disconnected", comment: "Helper disconnected"),
        detail
      )
    case .incompatibleProtocol(let version):
      let value = version.map(String.init) ?? NSLocalizedString("general.na", comment: "N/A")
      return String(
        format: NSLocalizedString("videotools.error.protocol", comment: "Unsupported protocol"),
        value
      )
    case .invalidResponse(let detail):
      return String(
        format: NSLocalizedString("videotools.error.invalid_response", comment: "Invalid helper response"),
        detail
      )
    case .busy:
      return NSLocalizedString("videotools.error.busy", comment: "A video task is already running")
    }
  }
}

extension Notification.Name {
  static let videoToolsTaskChanged = Notification.Name("ChengYingVideoToolsTaskChanged")
}
