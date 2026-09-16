import Foundation

func downloadCenterString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "DownloadCenter", comment: "Native download center")
}

enum DownloadCenterError: Error, LocalizedError {
  case unsupportedSystem, missingHelper, startup, alreadyRunning, timeout, stopped, protocolViolation, unsafeOutput, request

  var errorDescription: String? {
    let key: String
    switch self {
    case .unsupportedSystem: key = "error.system"
    case .missingHelper: key = "error.helper"
    case .startup: key = "error.startup"
    case .alreadyRunning: key = "error.already_running"
    case .timeout: key = "error.timeout"
    case .stopped: key = "error.stopped"
    case .protocolViolation: key = "error.protocol"
    case .unsafeOutput: key = "error.output"
    case .request: key = "error.request"
    }
    return downloadCenterString(key)
  }
}

struct DownloadCenterSession: Equatable {
  static let cookieName = "chengying_download_session"
  let url: URL
  let token: String
  let pid: Int32

  init(data: Data) throws {
    struct Ready: Decodable {
      let type: String
      let protocol_version: Int
      let url: String
      let token: String
      let pid: Int32
    }
    let ready = try JSONDecoder().decode(Ready.self, from: data)
    guard ready.type == "ready", ready.protocol_version == 1,
          let url = URL(string: ready.url), url.scheme == "http", url.host == "127.0.0.1",
          let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path == "/", ready.pid > 1,
          ready.token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else {
      throw DownloadCenterError.protocolViolation
    }
    self.url = url
    token = ready.token
    pid = ready.pid
  }

  func contains(_ candidate: URL) -> Bool {
    candidate.scheme == url.scheme && candidate.host == "127.0.0.1" && candidate.port == url.port &&
      candidate.user == nil && candidate.password == nil
  }

  func acceptsOrigin(scheme: String, host: String, port: Int, isMainFrame: Bool) -> Bool {
    isMainFrame && scheme == "http" && host == "127.0.0.1" && port == url.port
  }

  var cookie: HTTPCookie? {
    HTTPCookie(properties: [
      .name: Self.cookieName, .value: token, .domain: "127.0.0.1", .path: "/",
      .discard: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
      .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue,
    ])
  }
}

enum DownloadCenterCommand {
  case chooseDirectory
  case output(action: String, jobID: String, itemID: String, index: Int)

  init?(message: Any) {
    guard let body = message as? [String: Any], let action = body["action"] as? String else { return nil }
    if action == "chooseDirectory", body.count == 1 {
      self = .chooseDirectory
      return
    }
    guard ["play", "reveal"].contains(action), Set(body.keys) == ["action", "jobID", "itemID", "index"],
          let jobID = body["jobID"] as? String, let itemID = body["itemID"] as? String,
          !jobID.isEmpty, !itemID.isEmpty, jobID.utf8.count <= 256, itemID.utf8.count <= 256,
          !jobID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          !itemID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let number = body["index"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
          (0...100000).contains(number.doubleValue) else { return nil }
    self = .output(action: action, jobID: jobID, itemID: itemID, index: number.intValue)
  }
}

struct DownloadCenterOutput: Decodable {
  let path: String
  let media_type: String

  func validatedURL(forPlayback: Bool) throws -> URL {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw DownloadCenterError.unsafeOutput }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path == path, url.resolvingSymlinksInPath().path == path,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw DownloadCenterError.unsafeOutput
    }
    if forPlayback {
      let videoExtensions: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v", "avi", "flv", "ts", "mts", "m2ts", "3gp", "mpeg", "mpg", "ogv"]
      let isVideo = media_type == "video" && videoExtensions.contains(url.pathExtension.lowercased())
      let isImage = media_type == "image" && ImageFileSupport.isImageURL(url)
      guard isVideo || isImage else {
        throw DownloadCenterError.unsafeOutput
      }
    }
    return url
  }
}

extension Notification.Name {
  static let downloadCenterStateChanged = Notification.Name("ChengYingDownloadCenterStateChanged")
}
