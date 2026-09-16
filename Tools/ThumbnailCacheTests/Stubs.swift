import Cocoa

enum Logger {
  enum Level { case debug, warning, error }
  static func makeSubsystem(_ name: String) -> String { name }
  static func log(_ message: String, level: Level = .debug, subsystem: String) {}
  static func log(_ message: () -> String, level: Level = .debug, subsystem: String) {}
}

enum Preference {
  enum Key { case maxThumbnailPreviewCacheSize }
  static var cacheMegabytes = 500
  static func integer(for key: Key) -> Int { cacheMegabytes }
}

enum FloatingPointByteCountFormatter {
  enum PrefixFactor: Int { case mi = 1_048_576 }
}

enum Utility {
  static var thumbnailCacheURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
}

final class FFThumbnail: NSObject {
  var image: NSImage?
  var realTime = 0.0
}
