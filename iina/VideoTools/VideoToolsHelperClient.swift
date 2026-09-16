//
//  VideoToolsHelperClient.swift
//  ChengYing
//

import Cocoa
import Darwin

final class VideoToolsHelperClient {
  static let shared = VideoToolsHelperClient()

  var eventHandler: ((VideoToolsEvent) -> Void)?
  var failureHandler: ((Error) -> Void)?

  private static let protocolVersion = 1
  private static let helperName = "chengying-video-tools-helper"

  private let queue = DispatchQueue(label: "com.chengying.video-tools-helper", qos: .utility)
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputBuffer = Data()
  private var pendingRequests: [Data] = []
  private var isReady = false
  private var isStopping = false
  private var terminationObserver: NSObjectProtocol?

  private init() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.shutdown()
    }
  }

  deinit {
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
    shutdown()
  }

  func send(_ request: VideoToolsRequest) throws {
    let payload: Data
    do {
      payload = try encoder.encode(request) + Data([0x0A])
    } catch {
      throw VideoToolsClientError.invalidResponse(error.localizedDescription)
    }

    try queue.sync {
      try ensureRunning()
      if isReady {
        try write(payload)
      } else {
        pendingRequests.append(payload)
      }
    }
  }

  func shutdown() {
    queue.sync {
      guard let process = self.process else { return }
      self.isStopping = true
      if process.isRunning {
        if let payload = try? self.encoder.encode(VideoToolsRequest.shutdown(id: UUID().uuidString)) + Data([0x0A]) {
          try? self.write(payload)
        }
        try? self.inputHandle?.close()
        process.terminate()
      }
      self.resetProcessState()
    }
  }

  private func ensureRunning() throws {
    if let process, process.isRunning {
      return
    }

    resetProcessState()
    let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
    guard let executableDirectory else {
      throw VideoToolsClientError.missingExecutable(Self.helperName)
    }

    let helperURL = executableDirectory.appendingPathComponent(Self.helperName)
    let ffmpegURL = executableDirectory.appendingPathComponent("ffmpeg")
    let ffprobeURL = executableDirectory.appendingPathComponent("ffprobe")
    for executableURL in [helperURL, ffmpegURL, ffprobeURL] {
      guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw VideoToolsClientError.missingExecutable(executableURL.lastPathComponent)
      }
    }

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let process = Process()
    process.executableURL = helperURL
    process.arguments = [
      "--ffmpeg", ffmpegURL.path,
      "--ffprobe", ffprobeURL.path,
      "--stdio",
    ]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "en_US.UTF-8"
    environment["PYTHONUTF8"] = "1"
    process.environment = environment

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      self?.queue.async {
        self?.consumeOutput(data)
      }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
      NSLog("Video tools helper: %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    process.terminationHandler = { [weak self] process in
      self?.queue.async {
        self?.handleTermination(process)
      }
    }

    self.process = process
    let inputHandle = inputPipe.fileHandleForWriting
    if fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
      let code = errno
      resetProcessState()
      throw VideoToolsClientError.launchFailed(
        "Unable to configure the helper input pipe: \(String(cString: strerror(code)))"
      )
    }
    self.inputHandle = inputHandle
    isStopping = false
    do {
      try process.run()
    } catch {
      resetProcessState()
      throw VideoToolsClientError.launchFailed(error.localizedDescription)
    }
  }

  private func write(_ data: Data) throws {
    guard let process, process.isRunning, let inputHandle else {
      throw VideoToolsClientError.disconnected("The helper process is not running.")
    }
    let descriptor = inputHandle.fileDescriptor
    try data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
        if result > 0 {
          offset += result
          continue
        }
        if result == -1, errno == EINTR {
          continue
        }
        let code = result == -1 ? errno : EPIPE
        throw VideoToolsClientError.disconnected(
          "Unable to write to the helper input pipe: \(String(cString: strerror(code)))"
        )
      }
    }
  }

  private func consumeOutput(_ data: Data) {
    guard !data.isEmpty else { return }
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      var line = Data(outputBuffer[..<newline])
      outputBuffer.removeSubrange(...newline)
      if line.last == 0x0D {
        line.removeLast()
      }
      guard !line.isEmpty else { continue }
      do {
        let event = try decoder.decode(VideoToolsEvent.self, from: line)
        handle(event)
      } catch {
        let preview = String(data: line.prefix(512), encoding: .utf8) ?? "<non-UTF-8>"
        NSLog("Invalid video tools helper response: %@", preview)
        reportFailure(VideoToolsClientError.invalidResponse(error.localizedDescription))
        process?.terminate()
      }
    }
  }

  private func handle(_ event: VideoToolsEvent) {
    if event.type == .ready {
      guard event.protocolVersion == Self.protocolVersion else {
        reportFailure(VideoToolsClientError.incompatibleProtocol(event.protocolVersion))
        process?.terminate()
        return
      }
      isReady = true
      let requests = pendingRequests
      pendingRequests.removeAll()
      do {
        for request in requests {
          try write(request)
        }
      } catch {
        reportFailure(error)
        process?.terminate()
        return
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.eventHandler?(event)
    }
  }

  private func handleTermination(_ terminatedProcess: Process) {
    guard process === terminatedProcess else { return }
    let wasStopping = isStopping
    let status = terminatedProcess.terminationStatus
    resetProcessState()
    guard !wasStopping else { return }
    reportFailure(
      VideoToolsClientError.disconnected("The helper exited with status \(status).")
    )
  }

  private func resetProcessState() {
    if let output = process?.standardOutput as? Pipe {
      output.fileHandleForReading.readabilityHandler = nil
    }
    if let error = process?.standardError as? Pipe {
      error.fileHandleForReading.readabilityHandler = nil
    }
    inputHandle = nil
    process = nil
    outputBuffer.removeAll(keepingCapacity: true)
    pendingRequests.removeAll()
    isReady = false
    isStopping = false
  }

  private func reportFailure(_ error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.failureHandler?(error)
    }
  }
}
