import Foundation

protocol SubtitleToolsTransport: AnyObject {
  var eventHandler: ((SubtitleToolsEvent) -> Void)? { get set }
  var failureHandler: ((Error) -> Void)? { get set }
  func send(_ request: SubtitleToolsRequest) throws
  func shutdown()
}

final class SubtitleToolsService {
  static let shared = SubtitleToolsService(transport: SubtitleToolsHelperClient(), hardware: .current)
  let hardware: SubtitleToolsHardware
  private(set) var models = SubtitleToolsModel.allModels
  private(set) var runtimeReady = false
  private(set) var task: SubtitleToolsTask?
  private(set) var statusError: String?
  private let transport: SubtitleToolsTransport
  private var statusRequestID: String?
  private var existingSiblingNames = Set<String>()
  private var lastModelRefresh = Date.distantPast
  private let dataDirectory: () throws -> URL

  var subtitleModels: [SubtitleToolsModel] { models.filter { $0.id != "summarizer" } }
  var summaryModels: [SubtitleToolsModel] { models.filter { $0.id != "translator" } }
  var isReady: Bool { runtimeReady && subtitleModels.allSatisfy(\.ready) }
  var summaryReady: Bool { runtimeReady && models.first { $0.id == "summarizer" }?.ready == true }
  var updateActivityIsUncertain: Bool { (transport as? SubtitleToolsHelperClient)?.updateActivityIsUncertain ?? true }

  init(transport: SubtitleToolsTransport, hardware: SubtitleToolsHardware,
       dataDirectory: @escaping () throws -> URL = SummaryToolsFiles.dataDirectory) {
    self.transport = transport
    self.hardware = hardware
    self.dataDirectory = dataDirectory
    transport.eventHandler = { [weak self] in self?.handle($0) }
    transport.failureHandler = { [weak self] in self?.handleFailure($0) }
  }

  func refreshStatus() {
    precondition(Thread.isMainThread)
    guard !UpdateWorkAdmission.shared.isHelperRestartBlocked else { return }
    guard hardware.supportsRuntime, statusRequestID == nil else { return }
    let id = UUID().uuidString
    statusRequestID = id
    do { try transport.send(SubtitleToolsRequest(id: id, command: "status")) }
    catch { statusRequestID = nil; handleFailure(error) }
  }

  @discardableResult
  func prepareModels() throws -> String {
    try requireAvailable()
    return try launch(operation: .prepare, inputURL: nil, language: nil, burnSubtitles: nil)
  }

  @discardableResult
  func prepareSummaryModels() throws -> String {
    try requireAvailable()
    return try launch(operation: .prepare, inputURL: nil, language: nil, burnSubtitles: nil, purpose: "summary")
  }

  @discardableResult
  func summarize(source: String) throws -> String {
    try requireAvailable()
    guard hardware.canGenerate else { throw SummaryToolsError.insufficientMemory }
    let url = try SummaryToolsSource.normalized(source)
    guard summaryReady else { throw SubtitleToolsError.modelsNotReady }
    return try launch(operation: .summary, inputURL: nil, language: nil, burnSubtitles: nil, sourceURL: url)
  }

  @discardableResult
  func start(inputURL: URL, language: String, burnSubtitles: Bool) throws -> String {
    try requireAvailable()
    guard hardware.canGenerate else { throw SubtitleToolsError.insufficientMemory }
    guard isReady else { throw SubtitleToolsError.modelsNotReady }
    guard ["auto", "zh", "yue", "en", "ja", "ko"].contains(language), inputURL.isFileURL,
          (try? inputURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw SubtitleToolsError.invalidInput
    }
    let input = inputURL.standardizedFileURL.resolvingSymlinksInPath()
    existingSiblingNames = Set(try FileManager.default.contentsOfDirectory(atPath: input.deletingLastPathComponent().path))
    return try launch(operation: .subtitles, inputURL: input, language: language, burnSubtitles: burnSubtitles)
  }

  func cancelCurrent() {
    precondition(Thread.isMainThread)
    guard var current = task, current.isActive, current.phase != .cancelling else { return }
    current.phase = .cancelling
    current.etaSeconds = nil
    task = current
    notify()
    do {
      try transport.send(SubtitleToolsRequest(id: UUID().uuidString, command: "cancel", targetID: current.id))
    } catch { handleFailure(error) }
  }

  func shutdown() {
    transport.shutdown()
  }

  func shutdownForUpdate(completion: @escaping (Bool) -> Void) {
    precondition(Thread.isMainThread)
    guard task?.isActive != true,
          let client = transport as? SubtitleToolsHelperClient else { completion(false); return }
    statusRequestID = nil
    client.shutdownForUpdate(completion: completion)
  }

  private func requireAvailable() throws {
    precondition(Thread.isMainThread)
    guard !UpdateWorkAdmission.shared.isHelperRestartBlocked else { throw SubtitleToolsError.busy }
    guard hardware.supportsRuntime else { throw SubtitleToolsError.unsupportedHardware }
    guard task?.isActive != true else { throw SubtitleToolsError.busy }
  }

  private func launch(operation: SubtitleToolsOperation, inputURL: URL?, language: String?, burnSubtitles: Bool?,
                      sourceURL: URL? = nil, purpose: String? = nil) throws -> String {
    let id = UUID().uuidString
    task = SubtitleToolsTask(id: id, operation: operation, inputURL: inputURL)
    task?.burnSubtitles = burnSubtitles == true
    task?.sourceURL = sourceURL
    task?.purpose = purpose
    statusError = nil
    notify()
    do {
      try transport.send(SubtitleToolsRequest(
        id: id, command: operation == .prepare ? "prepare" : operation == .summary ? "summarize" : "start",
        inputPath: inputURL?.path, language: language, burnSubtitles: burnSubtitles,
        sourceURL: sourceURL?.absoluteString, purpose: purpose
      ))
    } catch {
      handleFailure(error)
      throw error
    }
    return id
  }

  private func handle(_ event: SubtitleToolsEvent) {
    precondition(Thread.isMainThread)
    if event.type == .ready { notify(); return }
    let matchesStatus = event.id != nil && event.id == statusRequestID
    if event.type == .status, !matchesStatus { return }
    let matchesTask = task.map { current in
      current.isActive && event.id == current.id &&
        (event.operation == nil || event.operation == current.operation)
    } ?? false
    if (event.type == .status && matchesStatus) || matchesTask {
      if let ready = event.runtimeReady { runtimeReady = ready }
      if let updates = event.models {
        models = models.map { current in
          guard let update = updates.first(where: { $0.id == current.id }) else { return current }
          var result = current
          result.totalBytes = max(0, update.totalBytes)
          result.downloadedBytes = max(0, update.downloadedBytes)
          result.ready = update.ready
          return result
        }
      }
    }
    if event.type == .status {
      statusRequestID = nil
      statusError = event.error
      notify()
      return
    }
    if event.type == .failed, matchesStatus {
      statusRequestID = nil
      statusError = event.error ?? event.message
      notify()
      return
    }
    guard var current = task, current.isActive, event.id == current.id else { return }
    if let operation = event.operation, operation != current.operation { return }
    if (current.operation == .summary || current.purpose == "summary"),
       let stage = event.stage, stage != current.stage {
      current.downloadedBytes = 0
      current.totalBytes = 0
    }
    current.stage = event.stage ?? current.stage
    current.message = event.message ?? current.message
    if current.operation == .summary || current.purpose == "summary" {
      // Missing progress means unknown, including when the next stage has no denominator.
      current.progress = event.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    } else if let progress = event.progress, progress.isFinite { current.progress = min(1, max(0, progress)) }
    if let bytes = event.downloadedBytes { current.downloadedBytes = max(0, bytes) }
    if let bytes = event.totalBytes { current.totalBytes = max(0, bytes) }
    current.bytesPerSecond = event.bytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    current.etaSeconds = event.etaSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    current.etaScope = event.etaScope
    current.tokensGenerated = event.tokensGenerated.flatMap { $0 >= 0 ? $0 : nil }
    current.chunkIndex = event.chunkIndex.flatMap { $0 >= 0 ? $0 : nil }
    current.chunkCount = event.chunkCount.flatMap { $0 > 0 ? $0 : nil }
    current.elapsedSeconds = event.elapsedSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    switch event.type {
    case .accepted, .progress:
      if current.phase != .cancelling { current.phase = .running }
    case .completed:
      if current.operation == .subtitles {
        do {
          guard let outputs = event.outputs, outputs.ass != nil, outputs.srt != nil else { throw SubtitleToolsError.unsafeOutput }
          current.assURL = try validateOutput(outputs.ass, extension: "ass", input: current.inputURL)
          current.srtURL = try validateOutput(outputs.srt, extension: "srt", input: current.inputURL)
          current.videoURL = try validateOutput(outputs.video, extension: nil, input: current.inputURL)
          current.warnings = event.warnings ?? []
          if current.burnSubtitles, current.videoURL == nil, current.warnings.isEmpty {
            current.warnings.append(subtitleToolsString("status.burn_missing"))
          }
          current.phase = .completed
          current.progress = 1
        } catch {
          current.phase = .failed
          current.error = error.localizedDescription
          current.assURL = nil
          current.srtURL = nil
          current.videoURL = nil
        }
      } else if current.operation == .summary {
        do {
          let result = try SummaryToolsFiles.readResult(event, taskID: current.id, dataDirectory: dataDirectory())
          current.summaryText = result.text
          current.summaryURL = result.summary
          current.transcriptURL = result.transcript
          current.summaryTitle = event.title.map { String($0.prefix(512)) }
          current.contentSource = event.contentSource.map { String($0.prefix(128)) }
          current.warnings = event.warnings ?? []
          current.phase = .completed
          current.progress = 1
        } catch {
          current.phase = .failed
          current.error = error.localizedDescription
        }
      } else {
        current.phase = .completed
        current.progress = 1
      }
    case .failed:
      current.phase = .failed
      current.error = event.error ?? event.message ?? subtitleToolsString("status.failed")
    case .cancelled:
      current.phase = .cancelled
    case .ready, .status: break
    }
    if !current.isActive { current.etaSeconds = nil }
    task = current
    notify()
    if current.operation == .prepare,
       !current.isActive || Date().timeIntervalSince(lastModelRefresh) >= 1 {
      lastModelRefresh = Date()
      refreshStatus()
    }
  }

  private func validateOutput(_ path: String?, extension expectedExtension: String?, input: URL?) throws -> URL? {
    guard let path else { return nil }
    guard path.hasPrefix("/"), let input else { throw SubtitleToolsError.unsafeOutput }
    let output = URL(fileURLWithPath: path).standardizedFileURL
    let canonical = output.resolvingSymlinksInPath()
    let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          canonical.deletingLastPathComponent() == input.deletingLastPathComponent(),
          canonical != input, !existingSiblingNames.contains(output.lastPathComponent),
          expectedExtension == nil || output.pathExtension.lowercased() == expectedExtension else {
      throw SubtitleToolsError.unsafeOutput
    }
    return canonical
  }

  private func handleFailure(_ error: Error) {
    precondition(Thread.isMainThread)
    statusRequestID = nil
    runtimeReady = false
    models = models.map { model in
      var invalidated = model
      invalidated.ready = false
      return invalidated
    }
    statusError = error.localizedDescription
    if var current = task, current.isActive {
      current.phase = .failed
      current.error = error.localizedDescription
      current.etaSeconds = nil
      task = current
    }
    notify()
  }

  private func notify() {
    NotificationCenter.default.post(name: .subtitleToolsChanged, object: self)
  }
}
