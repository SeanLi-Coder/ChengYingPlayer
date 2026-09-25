import AppKit

enum UpdateReadiness: Equatable {
  case ready
  case busy([String])
}

/// The barrier must prevent new work until it is explicitly released.
@MainActor
protocol UpdateActivityChecking: AnyObject {
  var installationBarrierIsSafe: Bool { get }
  func readiness(completion: @escaping (UpdateReadiness) -> Void)
  func acquireInstallationBarrier(completion: @escaping (UpdateReadiness) -> Void)
  func releaseInstallationBarrier()
}

enum AppUpdateText {
  static func string(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Updates", bundle: .main, comment: "Application update")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: string(key), locale: Locale.current, arguments: arguments)
  }
}

struct UpdateDownloadProgress {
  private(set) var received: UInt64 = 0
  var expected: UInt64 = 0

  mutating func receive(_ delta: UInt64) {
    let result = received.addingReportingOverflow(delta)
    received = result.overflow ? UInt64.max : result.partialValue
  }

  /// A server's content length is advisory; extraction marks download completion.
  var fraction: Double? {
    guard expected > 0 else { return nil }
    return min(0.99, Double(received) / Double(expected))
  }

  var description: String {
    func bytes(_ value: UInt64) -> String {
      ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    if expected == 0 { return bytes(received) }
    return "\(bytes(received)) / \(bytes(expected))"
  }
}

enum UpdateInstallationLocation {
  case supported
  case moveToApplications

  static func inspect(bundleURL: URL) -> UpdateInstallationLocation {
    let path = bundleURL.resolvingSymlinksInPath().path
    let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
    return evaluate(path: path, isReadOnly: values?.volumeIsReadOnly ?? true)
  }

  static func evaluate(path: String, isReadOnly: Bool) -> UpdateInstallationLocation {
    // App Translocation is not a durable install location even on writable media.
    if isReadOnly || path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
      return .moveToApplications
    }
    // Sparkle handles normal replacement and administrator authorization.
    return .supported
  }
}

enum AppUpdatePreferences {
  static let automaticChecksKey = "SUEnableAutomaticChecks"
  static let migrationKey = "ChengYingAutomaticUpdatesMigrationV1"

  static func migrate(_ defaults: UserDefaults) {
    // Command-line flags are deliberately respected by smoke tests and support tools.
    guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)[automaticChecksKey] == nil,
          !defaults.bool(forKey: migrationKey) else { return }
    // A missing migration marker does not imply that an existing opt-out was a default.
    // Preserve saved, managed, and registered choices; initialize only an absent value.
    if defaults.object(forKey: automaticChecksKey) == nil {
      defaults.set(true, forKey: automaticChecksKey)
    }
    defaults.set(true, forKey: migrationKey)
    // Our user driver downloads with visible progress, not Sparkle's silent downloader.
    defaults.set(false, forKey: "SUAutomaticallyUpdate")
  }
}
