import Cocoa

struct FixtureImagePlan { let mediaURLs: [URL]; let imageCount: Int }
var urlFixtureActiveCore: PlayerCore?
extension PlayerCore {
  static var lastActive: PlayerCore { urlFixtureActiveCore! }
  func getPlayableFiles(in urls: [URL]) -> [URL] { urls }
  func openMediaURLs(_ urls: [URL]) { urlFallbackOpens += 1; open(urls.first) }
  func openURLString(_ path: String) { urlFallbackOpens += 1; open(URL(fileURLWithPath: path)) }
}
extension MainWindowBoundary {
  func displayOSD(_ message: OSDMessage, autoHide: Bool, forcedTimeout: Float?,
                  accessoryView: NSView?, context: Any?) {
    if case .addToPlaylist = message { quickSettingView.videoToolsViewController?.player?.displayedOSDs += 1 }
  }
}
