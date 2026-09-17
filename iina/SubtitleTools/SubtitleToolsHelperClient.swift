import Cocoa
import Darwin

final class SubtitleToolsHelperClient: SubtitleToolsTransport {
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

  init() {
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
    guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
      throw SubtitleToolsError.helper("The application executable directory is unavailable.")
    }
    let helper = directory.appendingPathComponent("chengying-subtitle-tools-helper")
    let ffmpeg = directory.appendingPathComponent("ffmpeg")
    let ffprobe = directory.appendingPathComponent("ffprobe")
    for url in [helper, ffmpeg, ffprobe] where !FileManager.default.isExecutableFile(atPath: url.path) {
      throw SubtitleToolsError.helper("Missing bundled executable: \(url.lastPathComponent)")
    }
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dataDirectory = support.appendingPathComponent("io.github.SeanLi-Coder.ChengYingPlayer/SubtitleTools", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    let child = Process()
    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    child.executableURL = helper
    child.arguments = ["--ffmpeg", ffmpeg.path, "--ffprobe", ffprobe.path, "--data-dir", dataDirectory.path, "--stdio"]
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
