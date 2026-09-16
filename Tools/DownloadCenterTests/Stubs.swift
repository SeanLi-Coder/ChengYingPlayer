import Foundation

// Only the playback boundary is replaced. Window, WebKit, helper transport,
// session policy, and output validation are the actual application sources.
final class PlayerCore {
  static var opened: [URL] = []
  @discardableResult
  static func openURLs(_ urls: [URL]) -> Int? { opened.append(contentsOf: urls); return urls.count }
}
