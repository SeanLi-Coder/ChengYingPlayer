import Foundation

func subtitleToolsString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "SubtitleTools", bundle: .main, comment: "Native subtitle tools")
}

enum SubtitleToolsOperation: String, Codable {
  case prepare
  case subtitles
  case summary
}

struct SubtitleToolsRequest: Encodable {
  let id: String
  let command: String
  var inputPath: String? = nil
  var language: String? = nil
  var burnSubtitles: Bool? = nil
  var targetID: String? = nil
  var sourceURL: String? = nil
  var purpose: String? = nil

  enum CodingKeys: String, CodingKey {
    case id, command, language, purpose
    case sourceURL = "source_url"
    case inputPath = "input_path"
    case burnSubtitles = "burn_subtitles"
    case targetID = "target_id"
  }
}

struct SubtitleToolsModel: Decodable, Equatable {
  let id: String
  let name: String
  var totalBytes: Int64
  var downloadedBytes: Int64
  var ready: Bool

  enum CodingKeys: String, CodingKey {
    case id, name, ready
    case totalBytes = "total_bytes"
    case downloadedBytes = "downloaded_bytes"
  }

  static let fixedModels = [
    SubtitleToolsModel(id: "asr", name: "Qwen3-ASR 1.7B BF16", totalBytes: 0, downloadedBytes: 0, ready: false),
    SubtitleToolsModel(id: "aligner", name: "Qwen3-ForcedAligner 0.6B BF16", totalBytes: 0, downloadedBytes: 0, ready: false),
    SubtitleToolsModel(id: "translator", name: "HY-MT2 30B-A3B BF16", totalBytes: 0, downloadedBytes: 0, ready: false),
  ]
  static let summarizer = SubtitleToolsModel(id: "summarizer", name: "Qwen3.8 27B BF16",
                                             totalBytes: 0, downloadedBytes: 0, ready: false)
  static var allModels: [SubtitleToolsModel] { fixedModels + [summarizer] }
  static var summaryModels: [SubtitleToolsModel] { fixedModels.filter { $0.id != "translator" } + [summarizer] }
}

struct SubtitleToolsOutputs: Decodable {
  var srt: String? = nil
  var ass: String? = nil
  var video: String? = nil
  var summary: String? = nil
  var transcript: String? = nil
}

struct SubtitleToolsEvent: Decodable {
  enum Kind: String, Decodable {
    case ready, status, accepted, progress, completed, failed, cancelled
  }
  let type: Kind
  var id: String? = nil
  var operation: SubtitleToolsOperation? = nil
  var protocolVersion: Int? = nil
  var stage: String? = nil
  var progress: Double? = nil
  var message: String? = nil
  var downloadedBytes: Int64? = nil
  var totalBytes: Int64? = nil
  var bytesPerSecond: Double? = nil
  var etaSeconds: Double? = nil
  var etaScope: String? = nil
  var runtimeReady: Bool? = nil
  var models: [SubtitleToolsModel]? = nil
  var outputs: SubtitleToolsOutputs? = nil
  var warnings: [String]? = nil
  var partial: Bool? = nil
  var error: String? = nil
  var summaryText: String? = nil
  var title: String? = nil
  var sourceURL: String? = nil
  var contentSource: String? = nil
  var tokensGenerated: Int? = nil
  var chunkIndex: Int? = nil
  var chunkCount: Int? = nil
  var elapsedSeconds: Double? = nil

  enum CodingKeys: String, CodingKey {
    case type, id, operation, stage, progress, message, models, outputs, warnings, partial, error
    case protocolVersion = "protocol_version"
    case downloadedBytes = "downloaded_bytes"
    case totalBytes = "total_bytes"
    case bytesPerSecond = "bytes_per_second"
    case etaSeconds = "eta_seconds"
    case etaScope = "eta_scope"
    case runtimeReady = "runtime_ready"
    case summaryText = "summary_text"
    case title
    case sourceURL = "source_url"
    case contentSource = "content_source"
    case tokensGenerated = "tokens_generated"
    case chunkIndex = "chunk_index"
    case chunkCount = "chunk_count"
    case elapsedSeconds = "elapsed_seconds"
  }
}

struct SubtitleToolsHardware {
  var supportsRuntime: Bool
  var physicalMemory: UInt64
  static let requiredMemory: UInt64 = 96 * 1024 * 1024 * 1024

  static var current: SubtitleToolsHardware {
    var supported = false
    #if arch(arm64)
    if #available(macOS 14, *) { supported = true }
    #endif
    return SubtitleToolsHardware(supportsRuntime: supported, physicalMemory: ProcessInfo.processInfo.physicalMemory)
  }

  var canGenerate: Bool { supportsRuntime && physicalMemory >= Self.requiredMemory }
}

enum SubtitleToolsError: LocalizedError {
  case busy, unsupportedHardware, insufficientMemory, modelsNotReady, invalidInput, unsafeOutput
  case helper(String)

  var errorDescription: String? {
    switch self {
    case .busy: return subtitleToolsString("error.busy")
    case .unsupportedHardware: return subtitleToolsString("error.hardware")
    case .insufficientMemory: return subtitleToolsString("error.memory")
    case .modelsNotReady: return subtitleToolsString("error.models")
    case .invalidInput: return subtitleToolsString("error.input")
    case .unsafeOutput: return subtitleToolsString("error.output")
    case .helper(let detail): return String(format: subtitleToolsString("error.helper"), detail)
    }
  }
}

struct SubtitleToolsTask {
  enum Phase { case starting, running, cancelling, completed, failed, cancelled }
  let id: String
  let operation: SubtitleToolsOperation
  let inputURL: URL?
  var phase: Phase = .starting
  var progress: Double?
  var stage: String?
  var message: String?
  var downloadedBytes: Int64 = 0
  var totalBytes: Int64 = 0
  var bytesPerSecond: Double?
  var etaSeconds: Double?
  var etaScope: String?
  var assURL: URL?
  var srtURL: URL?
  var videoURL: URL?
  var error: String?
  var burnSubtitles = false
  var warnings = [String]()
  var purpose: String?
  var sourceURL: URL?
  var summaryText: String?
  var summaryURL: URL?
  var transcriptURL: URL?
  var summaryTitle: String?
  var contentSource: String?
  var tokensGenerated: Int?
  var chunkIndex: Int?
  var chunkCount: Int?
  var elapsedSeconds: Double?
  var isActive: Bool { phase == .starting || phase == .running || phase == .cancelling }
}

extension Notification.Name {
  static let subtitleToolsChanged = Notification.Name("ChengYingSubtitleToolsChanged")
}
