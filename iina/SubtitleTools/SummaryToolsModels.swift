import Foundation
import Darwin

func summaryToolsString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "SummaryTools", comment: "Local video summary")
}

enum SummaryToolsLifecycle {
  /// A shared AI task must survive closing its window; explicit application quit requires consent.
  static func mayTerminate(task: SubtitleToolsTask?, confirmation: () -> Bool) -> Bool {
    guard task?.isActive == true else { return true }
    return confirmation()
  }
}

enum SummaryToolsError: LocalizedError {
  case invalidSource, unsafeOutput, insufficientMemory
  var errorDescription: String? {
    switch self {
    case .invalidSource: return summaryToolsString("error.source")
    case .unsafeOutput: return summaryToolsString("error.output")
    case .insufficientMemory: return summaryToolsString("error.memory")
    }
  }
}

enum SummaryToolsSource {
  /// Accept single-video links only. Credentials and unrelated query data never reach the helper.
  static func normalized(_ value: String) throws -> URL {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 4096, !text.contains("\\"),
          !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
          let parts = URLComponents(string: text), let host = parts.host?.lowercased(),
          ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
          parts.user == nil, parts.password == nil,
          parts.port == nil || [80, 443].contains(parts.port!),
          (parts.queryItems?.count ?? 0) <= 40 else { throw SummaryToolsError.invalidSource }
    let query = parts.queryItems ?? []
    func matches(_ value: String, _ pattern: String) -> Bool {
      value.range(of: pattern, options: .regularExpression) != nil
    }
    if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) {
      let identifier: String
      if host == "youtu.be" { identifier = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      else if parts.path == "/watch", query.filter({ $0.name == "v" }).count == 1 {
        identifier = query.first { $0.name == "v" }?.value ?? ""
      } else if matches(parts.path, "^/(shorts|embed)/[A-Za-z0-9_-]{11}/?$") {
        identifier = String(parts.path.split(separator: "/").last ?? "")
      } else { throw SummaryToolsError.invalidSource }
      guard matches(identifier, "^[A-Za-z0-9_-]{11}$") else { throw SummaryToolsError.invalidSource }
      return URL(string: "https://www.youtube.com/watch?v=\(identifier)")!
    }
    if ["bilibili.com", "www.bilibili.com", "m.bilibili.com"].contains(host) {
      guard matches(parts.path, "^/video/(BV[A-Za-z0-9]{10}|av[0-9]{1,20})/?$") else {
        throw SummaryToolsError.invalidSource
      }
      let pages = query.filter { $0.name == "p" }
      let page = pages.first?.value ?? "1"
      guard pages.count <= 1, matches(page, "^[1-9][0-9]{0,3}$") else { throw SummaryToolsError.invalidSource }
      let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return URL(string: "https://www.bilibili.com/\(path)" + (page == "1" ? "" : "?p=\(page)"))!
    }
    if host == "b23.tv", matches(parts.path, "^/[A-Za-z0-9]{1,32}/?$") {
      return URL(string: "https://b23.tv\(parts.path)")!
    }
    throw SummaryToolsError.invalidSource
  }
}

enum SummaryToolsFiles {
  static let maximumSummaryBytes = 2 * 1024 * 1024

  static func dataDirectory() throws -> URL {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
    return support.appendingPathComponent("io.github.SeanLi-Coder.ChengYingPlayer/SubtitleTools", isDirectory: true)
  }

  /// Open every untrusted path component relative to an already-open parent, never following links.
  static func readResult(_ event: SubtitleToolsEvent, taskID: String, dataDirectory: URL)
    throws -> (text: String, summary: URL, transcript: URL) {
    guard UUID(uuidString: taskID) != nil, taskID.count == 36,
          let report = event.outputs?.summary, let transcript = event.outputs?.transcript,
          event.summaryText.map({ $0.utf8.count <= maximumSummaryBytes }) ?? true else {
      throw SummaryToolsError.unsafeOutput
    }
    let root = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let job = root.appendingPathComponent("summaries", isDirectory: true).appendingPathComponent(taskID, isDirectory: true)
    let reportURL = job.appendingPathComponent("report.md")
    let transcriptURL = job.appendingPathComponent("transcript.json")
    guard report == reportURL.path, transcript == transcriptURL.path else { throw SummaryToolsError.unsafeOutput }
    let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw SummaryToolsError.unsafeOutput }
    defer { close(rootFD) }
    let summariesFD = openat(rootFD, "summaries", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard summariesFD >= 0 else { throw SummaryToolsError.unsafeOutput }
    defer { close(summariesFD) }
    let jobFD = openat(summariesFD, taskID, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard jobFD >= 0 else { throw SummaryToolsError.unsafeOutput }
    defer { close(jobFD) }
    func file(_ name: String, maximum: Int) throws -> Int32 {
      let descriptor = openat(jobFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw SummaryToolsError.unsafeOutput }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximum else {
        close(descriptor)
        throw SummaryToolsError.unsafeOutput
      }
      return descriptor
    }
    let reportFD = try file("report.md", maximum: maximumSummaryBytes)
    defer { close(reportFD) }
    let transcriptFD = try file("transcript.json", maximum: 64 * 1024 * 1024)
    defer { close(transcriptFD) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = Darwin.read(reportFD, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw SummaryToolsError.unsafeOutput
      }
      guard data.count + count <= maximumSummaryBytes else { throw SummaryToolsError.unsafeOutput }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          event.summaryText == nil || event.summaryText == text else { throw SummaryToolsError.unsafeOutput }
    return (text, reportURL, transcriptURL)
  }
}
