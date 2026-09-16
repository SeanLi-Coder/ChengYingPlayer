import Foundation

// Only the playback boundary is replaced. Window, WebKit, helper transport,
// session policy, and output validation are the actual application sources.
final class PlayerCore {
  static let activeOrNew = PlayerCore()
  var opened: [URL] = []
  func openURL(_ url: URL) { opened.append(url) }
}
