import Cocoa
import Darwin

final class SubtitleToolsHelperClient: SubtitleToolsTransport {
  struct Locations {
    let helper: URL
    let ffmpeg: URL
    let ffprobe: URL
    let data: URL
    let downloader: URL
    let downloaderData: URL

    static func bundled() throws -> Locations {
      guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
        throw SubtitleToolsError.helper("The application executable directory is unavailable.")
      }
      let data = try SummaryToolsFiles.dataDirectory()
      // Keep the nested app and shared settings directory identical to DownloadCenterService.
      return Locations(helper: directory.appendingPathComponent("chengying-subtitle-tools-helper"),
                       ffmpeg: directory.appendingPathComponent("ffmpeg"),
                       ffprobe: directory.appendingPathComponent("ffprobe"), data: data,
                       downloader: directory.deletingLastPathComponent()
                         .appendingPathComponent("Helpers/DownloadCenter.app/Contents/MacOS/chengying-download-center-helper"),
                       downloaderData: data.deletingLastPathComponent().appendingPathComponent("DownloadCenter", isDirectory: true))
    }
  }
  var eventHandler: ((SubtitleToolsEvent) -> Void)?
  var failureHandler: ((Error) -> Void)?
  private let queue = DispatchQueue(label: "com.chengying.subtitle-tools-helper", qos: .utility)
  private let queueIdentity = DispatchSpecificKey<Bool>()
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var pending = [Data]()
  private var ready = false
  private var failureReported = false
  var updateActivityIsUncertain: Bool { queue.sync { failureReported && process?.isRunning == true } }
  private var terminationObserver: NSObjectProtocol?
  private let locations: () throws -> Locations

  init(locations: @escaping () throws -> Locations = Locations.bundled) {
    self.locations = locations
    queue.setSpecific(key: queueIdentity, value: true)
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { [weak self] _ in self?.shutdown() }
  }

  deinit {
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    shutdown()
  }

  func send(_ request: SubtitleToolsRequest) throws {
    let data = try JSONEncoder().encode(request) + Data([10])
    try queue.sync {
      try launchIfNeeded()
      if ready { try write(data) } else { pending.append(data) }
    }
  }

  func shutdown() {
    if DispatchQueue.getSpecific(key: queueIdentity) == true { stopProcess() }
    else { queue.sync { stopProcess() } }
  }

  func shutdownForUpdate(completion: @escaping (Bool) -> Void) {
    let reservation = UpdateProcessDrain.reserve()
    queue.async {
      let child = self.process
      self.failureReported = true
      if child?.isRunning == true,
         let data = try? JSONEncoder().encode(SubtitleToolsRequest(id: UUID().uuidString, command: "shutdown")) {
        try? self.write(data + Data([10]))
      }
      try? self.input?.close()
      self.input = nil
      UpdateProcessDrain.wait(for: child, reservation: reservation, completion: completion)
    }
  }

  private func stopProcess() {
    guard let process else { return }
    if process.isRunning {
      if let data = try? JSONEncoder().encode(SubtitleToolsRequest(id: UUID().uuidString, command: "shutdown")) {
        try? write(data + Data([10]))
      }
      try? input?.close()
      process.terminate()
    }
    reset()
  }

  private func launchIfNeeded() throws {
    if process?.isRunning == true { return }
    reset()
    let paths = try locations()
    for url in [paths.helper, paths.ffmpeg, paths.ffprobe] where !FileManager.default.isExecutableFile(atPath: url.path) {
      throw SubtitleToolsError.helper("Missing bundled executable: \(url.lastPathComponent)")
    }
    try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
    // A first-time summary must work before the download-center window has ever been opened.
    // Only create the app-owned directory; do not initialize settings, cookies, or download jobs.
    try FileManager.default.createDirectory(at: paths.downloaderData, withIntermediateDirectories: true)
    let child = Process()
    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    child.executableURL = paths.helper
    child.arguments = ["--ffmpeg", paths.ffmpeg.path, "--ffprobe", paths.ffprobe.path,
                       "--data-dir", paths.data.path, "--stdio", "--downloader-helper", paths.downloader.path,
                       "--downloader-data-dir", paths.downloaderData.path]
    child.standardInput = stdinPipe
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONUTF8"] = "1"
    environment["PYTHONIOENCODING"] = "utf-8"
    environment["LC_ALL"] = "en_US.UTF-8"
    child.environment = environment
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
      let data = handle.availableData
      self?.queue.async { [weak self, weak child] in
        guard let self, let child, self.process === child else { return }
        self.consume(data)
      }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let value = String(data: data, encoding: .utf8) else { return }
      NSLog("Subtitle tools helper: %@", value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    child.terminationHandler = { [weak self] child in
      self?.queue.async { [weak self] in
        guard let self, self.process === child else { return }
        let alreadyReported = self.failureReported
        self.reset()
        if !alreadyReported {
          self.fail(SubtitleToolsError.helper("The subtitle helper exited with status \(child.terminationStatus)."))
        }
      }
    }
    process = child
    input = stdinPipe.fileHandleForWriting
    guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      reset()
      throw SubtitleToolsError.helper("Unable to configure the subtitle helper pipe.")
    }
    do { try child.run() } catch { reset(); throw SubtitleToolsError.helper(error.localizedDescription) }
  }

  private func write(_ data: Data) throws {
    guard process?.isRunning == true, let descriptor = input?.fileDescriptor else {
      throw SubtitleToolsError.helper("The subtitle helper is disconnected.")
    }
    try data.withUnsafeBytes { bytes in
      guard let pointer = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let result = Darwin.write(descriptor, pointer.advanced(by: offset), bytes.count - offset)
        if result > 0 { offset += result; continue }
        if result == -1, errno == EINTR { continue }
        throw SubtitleToolsError.helper("Unable to write to the subtitle helper pipe.")
      }
    }
  }

  private func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    buffer.append(data)
    guard buffer.count <= 8 * 1024 * 1024 else {
      fail(SubtitleToolsError.helper("The subtitle helper response exceeded the protocol size limit."))
      process?.terminate()
      return
    }
    while let newline = buffer.firstIndex(of: 10) {
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }
      do {
        let event = try JSONDecoder().decode(SubtitleToolsEvent.self, from: line)
        if event.type == .failed, event.id == nil {
          throw SubtitleToolsError.helper(event.error ?? event.message ?? "The subtitle helper failed before accepting a request.")
        }
        if event.type == .ready {
          guard event.protocolVersion == nil || event.protocolVersion == 1 else {
            throw SubtitleToolsError.helper("Unsupported subtitle helper protocol version.")
          }
          ready = true
          let waiting = pending
          pending.removeAll()
          for request in waiting { try write(request) }
        }
        DispatchQueue.main.async { [weak self] in self?.eventHandler?(event) }
      } catch {
        fail(SubtitleToolsError.helper(error.localizedDescription))
        process?.terminate()
        return
      }
    }
  }

  private func reset() {
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    try? input?.close()
    process = nil
    input = nil
    ready = false
    failureReported = false
    pending.removeAll()
    buffer.removeAll(keepingCapacity: true)
  }

  private func fail(_ error: Error) {
    failureReported = true
    DispatchQueue.main.async { [weak self] in self?.failureHandler?(error) }
  }
}
