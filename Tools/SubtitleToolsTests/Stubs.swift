import Cocoa

enum PlayerState { case loaded, idle; var loaded: Bool { self == .loaded } }
final class PlaybackInfo {
  var state = PlayerState.loaded
  var isNetworkResource = false
  var currentURL: URL?
  var vid: Int? = 1
}
enum MPVCommand { case subAdd }
enum MPVOption { enum Subtitles { static let subVisibility = "sub-visibility" } }
final class MPVController {
  var addedSubtitles = [[String]]()
  var flags = [String: Bool]()
  func command(_ command: MPVCommand, args: [String], checkError: Bool) { addedSubtitles.append(args) }
  func setFlag(_ name: String, _ value: Bool) { flags[name] = value }
}
final class PlayerCore: NSObject {
  let info = PlaybackInfo()
  let mpv = MPVController()
  var videoToolsMediaGeneration: UInt64 = 1
}
extension Notification.Name {
  static let iinaFileLoaded = Notification.Name("loaded")
  static let iinaPlayerStopped = Notification.Name("stopped")
}

final class SubtitleTransportDouble: SubtitleToolsTransport {
  var eventHandler: ((SubtitleToolsEvent) -> Void)?
  var failureHandler: ((Error) -> Void)?
  var requests = [SubtitleToolsRequest]()
  var shutdownCount = 0
  var sendError: Error?
  func send(_ request: SubtitleToolsRequest) throws {
    if let sendError { throw sendError }
    requests.append(request)
  }
  func shutdown() { shutdownCount += 1 }
  func emit(_ event: SubtitleToolsEvent) { eventHandler?(event) }
  func ready() {
    let models = SubtitleToolsModel.fixedModels.map { model -> SubtitleToolsModel in
      var copy = model
      copy.totalBytes = 100
      copy.downloadedBytes = 100
      copy.ready = true
      return copy
    }
    emitStatus(runtimeReady: true, models: models)
  }
  func emitStatus(runtimeReady: Bool, models: [SubtitleToolsModel]) {
    guard let request = requests.last(where: { $0.command == "status" }) else { fatalError("Status must be requested first") }
    emit(SubtitleToolsEvent(type: .status, id: request.id, runtimeReady: runtimeReady, models: models))
  }
}
