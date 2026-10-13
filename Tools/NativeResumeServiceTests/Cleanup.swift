import Foundation

@main
enum Cleanup {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Expected owned domain registry") }
    let registry = URL(fileURLWithPath: CommandLine.arguments[1])
    guard FileManager.default.fileExists(atPath: registry.path) else {
      print("CLEANUP: no domains created")
      return
    }
    let names = try String(contentsOf: registry, encoding: .utf8).split(separator: "\n").map(String.init)
    let prefix = "com.chengying.resume-service-test."
    guard names.allSatisfy({ $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil }),
          Set(names).count == names.count else { fatalError("Invalid owned domain registry") }
    for name in names {
      guard let defaults = UserDefaults(suiteName: name) else { fatalError("Owned domain unavailable") }
      defaults.removePersistentDomain(forName: name)
      _ = defaults.synchronize()
      guard defaults.persistentDomain(forName: name)?.isEmpty != false else { fatalError("Owned domain cleanup failed") }
    }
    print("CLEANUP: verified \(names.count) owned domains")
  }
}
