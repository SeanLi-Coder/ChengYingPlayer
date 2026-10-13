import Foundation

// These are configuration boundaries only. KVO, UserDefaults, the service,
// receipt, ownership policy and filesystem writer all execute real code.
enum Preference {
  struct Key {
    let rawValue: String
    static let resumeLastPosition = Key(rawValue: "resumeLastPosition")
  }
}

enum ResumeServiceFixture {
  static var root: URL!
  static var defaults: UserDefaults!
}
