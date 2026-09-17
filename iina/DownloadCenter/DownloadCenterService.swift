import Foundation
import Darwin

final class DownloadCenterService {
  static let shared = DownloadCenterService()
  static var supportsRuntime: Bool {
    #if arch(arm64)
    if #available(macOS 13.5, *) { return true }
    #endif
    return false
  }
  struct Locations {
    let helper: URL
    let ffmpeg: URL
    let ffprobe: URL
    let data: URL
    let downloads: URL

    static func bundled() throws -> Locations {
      guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
        throw DownloadCenterError.missingHelper
      }
      let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      return Locations(helper: directory.deletingLastPathComponent().appendingPathComponent("Helpers/DownloadCenter.app/Contents/MacOS/chengying-download-center-helper"),
                       ffmpeg: directory.appendingPathComponent("ffmpeg"), ffprobe: directory.appendingPathComponent("ffprobe"),
                       data: support.appendingPathComponent("io.github.SeanLi-Coder.ChengYingPlayer/DownloadCenter", isDirectory: true),
                       downloads: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ChengYing", isDirectory: true))
    }
  }
  enum State {
    case idle, starting, ready(DownloadCenterSession), failed(DownloadCenterError)
  }

  private(set) var state: State = .idle {
    didSet { NotificationCenter.default.post(name: .downloadCenterStateChanged, object: self) }
  }
  var isRunning: Bool {
    switch state { case .starting, .ready: return true; default: return false }
  }
  private let queue = DispatchQueue(label: "io.github.SeanLi-Coder.ChengYingPlayer.download-center", qos: .utility)
  private var generation = UUID()
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var startupTimeout: DispatchWorkItem?
  private var receivedReady = false
  private var requests: [UUID: DownloadCenterRequest] = [:]
  private var updateLease: UUID?
  private var updateDrainingLease: UUID?
  private let locations: () throws -> Locations
  private let startupTimeoutInterval: TimeInterval

  init(locations: @escaping () throws -> Locations = Locations.bundled, startupTimeoutInterval: TimeInterval = 45) {
    self.locations = locations
    self.startupTimeoutInterval = startupTimeoutInterval
  }

  func start() {
    precondition(Thread.isMainThread)
    guard !UpdateWorkAdmission.shared.isHelperRestartBlocked else { return }
    guard !isRunning else { return }
    guard Self.supportsRuntime else { state = .failed(.unsupportedSystem); return }
    generation = UUID()
    let identifier = generation
    state = .starting
    queue.async { [weak self] in
      guard let self else { return }
      self.stopProcess()
      do { try self.launch(identifier: identifier) }
      catch let error as DownloadCenterError { self.publish(.failed(error), identifier: identifier) }
      catch { self.publish(.failed(.startup), identifier: identifier) }
    }
  }

  func shutdown() {
    precondition(Thread.isMainThread)
    generation = UUID()
    for request in requests.values { request.cancel() }
    requests.removeAll()
    queue.sync { stopProcess() }
    state = .idle
  }

  /// Nil means that the backend could not authoritatively report its activity.
  func updateActivity(completion: @escaping (Bool?) -> Void) {
    precondition(Thread.isMainThread)
    switch state {
    case .failed(.alreadyRunning):
      // Another owner may still be writing the shared download store.
      completion(nil)
    case .idle, .failed:
      let identifier = generation
      queue.async { [weak self] in
        let running = self?.process?.isRunning == true || UpdateWorkAdmission.shared.hasDrainingProcesses
        DispatchQueue.main.async { [weak self] in
          completion(self?.generation != identifier || running ? nil : false)
        }
      }
    case .starting:
      completion(nil)
    case .ready:
      updateRequest(path: "api/native/activity", method: "GET") { result in
        guard let data = try? result.get(),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["known"] as? Bool == true, let busy = value["busy"] as? Bool else {
          completion(nil); return
        }
        completion(busy)
      }
    }
  }

  func acquireUpdateLease(_ identifier: UUID, completion: @escaping (Bool) -> Void) {
    precondition(Thread.isMainThread)
    guard updateLease == nil else { completion(false); return }
    updateLease = identifier
    switch state {
    case .idle, .failed:
      updateActivity { [weak self] busy in
        guard let self, self.updateLease == identifier, busy == false else { completion(false); return }
        // A failed startup with a confirmed dead child has no backend left to lease.
        self.state = .idle
        completion(true)
      }
      return
    case .starting:
      completion(false)
      return
    case .ready:
      break
    }
    updateRequest(path: "api/native/maintenance/\(identifier.uuidString.lowercased())", method: "PUT") { result in
      guard let data = try? result.get(),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        completion(false); return
      }
      completion(value["acquired"] as? Bool == true)
    }
  }

  func releaseUpdateLease(_ identifier: UUID) {
    precondition(Thread.isMainThread)
    guard updateLease == identifier else { return }
    updateLease = nil
    // EOF has committed this helper to exit. Reopening its backend admission now
    // could accept a download just before the helper's shutdown cancels workers.
    guard updateDrainingLease != identifier else { return }
    releaseUpdateLeaseRequest(identifier, generation: generation)
  }

  private func releaseUpdateLeaseRequest(_ identifier: UUID, generation: UUID) {
    guard self.generation == generation, case .ready = state else { return }
    updateRequest(path: "api/native/maintenance/\(identifier.uuidString.lowercased())", method: "DELETE") { [weak self] result in
      guard let self, self.generation == generation else { return }
      if let data = try? result.get(),
         let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         value["released"] as? Bool == true { return }
      // Retry an uncertain release using the same identity, never somebody else's lease.
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.releaseUpdateLeaseRequest(identifier, generation: generation)
      }
    }
  }

  func shutdownForUpdate(_ identifier: UUID, completion: @escaping (Bool) -> Void) {
    precondition(Thread.isMainThread)
    guard updateLease == identifier else { completion(false); return }
    if case .idle = state { drainForUpdate(identifier, completion: completion); return }
    updateRequest(path: "api/native/maintenance/\(identifier.uuidString.lowercased())/commit", method: "PUT") { [weak self] result in
      guard let self, self.updateLease == identifier,
            let data = try? result.get(),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["acquired"] as? Bool == true else { completion(false); return }
      self.drainForUpdate(identifier, completion: completion)
    }
  }

  private func drainForUpdate(_ identifier: UUID, completion: @escaping (Bool) -> Void) {
    guard updateLease == identifier else { completion(false); return }
    updateDrainingLease = identifier
    generation = UUID()
    let drainGeneration = generation
    let reservation = UpdateProcessDrain.reserve()
    queue.async { [weak self] in
      guard let self else {
        UpdateProcessDrain.wait(for: nil, reservation: reservation) { _ in completion(false) }
        return
      }
      let child = self.process
      // A held idle lease excludes both queued workers and new browser submissions.
      // EOF is graceful; unlike normal shutdown this never schedules termination.
      self.detachProcess()
      UpdateProcessDrain.wait(for: child, reservation: reservation, onExit: { [weak self] in
        guard let self else { return }
        if self.updateDrainingLease == identifier { self.updateDrainingLease = nil }
        guard self.generation == drainGeneration else { return }
        self.state = .idle
      }) { [weak self] success in
        if !success, self?.generation == drainGeneration { self?.state = .failed(.timeout) }
        completion(success)
      }
    }
  }

  private func updateRequest(path: String, method: String,
                             completion: @escaping (Result<Data, Error>) -> Void) {
    guard case .ready(let session) = state else { completion(.failure(DownloadCenterError.stopped)); return }
    let identifier = generation
    let requestID = UUID()
    let request = DownloadCenterRequest(url: session.url.appendingPathComponent(path), session: session, method: method) { [weak self] result in
      guard let self else { completion(.failure(DownloadCenterError.stopped)); return }
      self.requests.removeValue(forKey: requestID)
      guard self.generation == identifier else { completion(.failure(DownloadCenterError.stopped)); return }
      completion(result)
    }
    requests[requestID] = request
    request.start()
  }

  func resolveOutput(jobID: String, itemID: String, index: Int,
                     completion: @escaping (Result<DownloadCenterOutput, Error>) -> Void) {
    precondition(Thread.isMainThread)
    guard case .ready(let session) = state else { completion(.failure(DownloadCenterError.stopped)); return }
    let identifier = generation
    var components = URLComponents(url: session.url.appendingPathComponent("api/native/output"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "job_id", value: jobID),
                             URLQueryItem(name: "item_id", value: itemID),
                             URLQueryItem(name: "index", value: String(index))]
    let requestID = UUID()
    let request = DownloadCenterRequest(url: components.url!, session: session) { [weak self] result in
      guard let self else { return }
      self.requests.removeValue(forKey: requestID)
      guard self.generation == identifier else { completion(.failure(DownloadCenterError.stopped)); return }
      completion(result.flatMap { data in
        Result { try JSONDecoder().decode(DownloadCenterOutput.self, from: data) }
      })
    }
    requests[requestID] = request
    request.start()
  }

  private func launch(identifier: UUID) throws {
    let locations = try self.locations()
    let helper = locations.helper, ffmpeg = locations.ffmpeg, ffprobe = locations.ffprobe
    guard [helper, ffmpeg, ffprobe].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw DownloadCenterError.missingHelper
    }
    let data = locations.data, downloads = locations.downloads
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let child = Process()
    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    child.executableURL = helper
    child.arguments = ["--stdio", "--data-dir", data.path, "--download-dir", downloads.path,
                       "--ffmpeg", ffmpeg.path, "--ffprobe", ffprobe.path]
    child.currentDirectoryURL = data
    child.standardInput = stdinPipe
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONUTF8"] = "1"
    environment["PYTHONIOENCODING"] = "utf-8"
    environment["PATH"] = ffmpeg.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    // Local control requests must never be sent through a user-configured proxy.
    let bypass = "127.0.0.1,localhost,::1"
    environment["NO_PROXY"] = [environment["NO_PROXY"], bypass].compactMap { $0 }.joined(separator: ",")
    environment["no_proxy"] = [environment["no_proxy"], bypass].compactMap { $0 }.joined(separator: ",")
    child.environment = environment
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
      let data = handle.availableData
      self?.queue.async { [weak self, weak child] in
        guard let self, let child, self.process === child else { return }
        self.consume(data, identifier: identifier)
      }
    }
    // Drain diagnostics to avoid blocking the helper, but never log raw cookie,
    // signed URL, browser profile, or HTTP authentication information.
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    child.terminationHandler = { [weak self] child in
      self?.queue.async { [weak self] in
        guard let self, self.process === child else { return }
        self.detachProcess()
        self.publish(.failed(.stopped), identifier: identifier)
      }
    }
    guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw DownloadCenterError.startup
    }
    process = child
    input = stdinPipe.fileHandleForWriting
    do { try child.run() } catch { detachProcess(); throw DownloadCenterError.startup }
    let timeout = DispatchWorkItem { [weak self, weak child] in
      guard let self, let child, self.process === child, !self.receivedReady else { return }
      self.stopProcess()
      self.publish(.failed(.timeout), identifier: identifier)
    }
    startupTimeout = timeout
    queue.asyncAfter(deadline: .now() + startupTimeoutInterval, execute: timeout)
  }

  private func consume(_ data: Data, identifier: UUID) {
    guard !data.isEmpty else { return }
    guard !receivedReady, buffer.count + data.count <= 64 * 1024 else {
      stopProcess()
      publish(.failed(.protocolViolation), identifier: identifier)
      return
    }
    buffer.append(data)
    guard let newline = buffer.firstIndex(of: 10) else { return }
    let line = Data(buffer[..<newline])
    buffer.removeSubrange(...newline)
    do {
      if let failure = try JSONSerialization.jsonObject(with: line) as? [String: Any], failure["type"] as? String == "failed" {
        let error: DownloadCenterError = failure["code"] as? String == "already_running" ? .alreadyRunning : .startup
        stopProcess()
        publish(.failed(error), identifier: identifier)
        return
      }
      let session = try DownloadCenterSession(data: line)
      guard buffer.isEmpty, session.pid == process?.processIdentifier else { throw DownloadCenterError.protocolViolation }
      receivedReady = true
      startupTimeout?.cancel()
      startupTimeout = nil
      publish(.ready(session), identifier: identifier)
    } catch {
      stopProcess()
      publish(.failed(.protocolViolation), identifier: identifier)
    }
  }

  private func publish(_ next: State, identifier: UUID) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == identifier else { return }
      self.state = next
    }
  }

  private func detachProcess() {
    startupTimeout?.cancel()
    startupTimeout = nil
    (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    try? input?.close()
    input = nil
    process = nil
    receivedReady = false
    buffer.removeAll(keepingCapacity: true)
  }

  private func stopProcess() {
    let child = process
    // EOF is the helper's graceful shutdown signal. Its parent watchdog owns
    // subprocess-tree cleanup; never kill arbitrary Chrome or Python processes.
    detachProcess()
    guard let child, child.isRunning else { return }
    // Keep retired children visible to the updater after detaching their transport.
    UpdateProcessDrain.wait(for: child) { _ in }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
      guard child.isRunning else { return }
      child.terminate()
    }
  }
}

private final class DownloadCenterRequest: NSObject, URLSessionDataDelegate {
  private let url: URL
  private let credentials: DownloadCenterSession
  private var completion: ((Result<Data, Error>) -> Void)?
  private var connection: URLSession?
  private var task: URLSessionDataTask?
  private var received = Data()
  private var acceptedResponse = false
  private let method: String

  init(url: URL, session: DownloadCenterSession, method: String = "GET", completion: @escaping (Result<Data, Error>) -> Void) {
    self.url = url
    self.method = method
    credentials = session
    self.completion = completion
    super.init()
  }

  func start() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    connection = session
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("\(DownloadCenterSession.cookieName)=\(credentials.token)", forHTTPHeaderField: "Cookie")
    task = session.dataTask(with: request)
    task?.resume()
  }

  func cancel() { task?.cancel() }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          response.url == url, response.mimeType == "application/json", response.expectedContentLength <= 64 * 1024 else {
      completionHandler(.cancel)
      return
    }
    acceptedResponse = true
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard received.count + data.count <= 64 * 1024 else { task?.cancel(); return }
    received.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let result: Result<Data, Error> = error == nil && acceptedResponse ? .success(received) : .failure(DownloadCenterError.request)
    let callback = completion
    completion = nil
    connection?.finishTasksAndInvalidate()
    connection = nil
    self.task = nil
    callback?(result)
  }
}
