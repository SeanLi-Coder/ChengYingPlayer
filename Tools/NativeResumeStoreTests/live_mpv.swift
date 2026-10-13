import Foundation
import CryptoKit

@main
enum LiveResumeStoreCheck {
  static func main() {
    var checks = 0
    var failures = 0
    func check(_ condition: Bool, _ label: String) {
      checks += 1
      if condition { print("PASS: \(label)") }
      else { failures += 1; print("FAIL: \(label)") }
    }
    guard CommandLine.arguments.count == 2 else { fatalError("Expected owned artifact directory") }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let media = root.appendingPathComponent("synthetic.mp4")
    let directory = root.appendingPathComponent("watch-later", isDirectory: true)
    let key = Insecure.MD5.hash(data: Data(media.path.utf8)).map { String(format: "%02X", $0) }.joined()
    let target = directory.appendingPathComponent(key)
    do {
      let before = try Data(contentsOf: media)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let store = NativePlaybackResumeStore(rootURL: directory, initiallyEnabled: true)
      guard let ticket = store.begin(digest: key, owner: UUID(), mediaGeneration: 1) else { fatalError("No receipt") }
      var result: NativePlaybackResumeResult?
      store.enqueue(ticket, position: 2.5, speed: 1.25) { result = $0 }
      let deadline = Date().addingTimeInterval(5)
      while result == nil && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
      }
      check(result == .saved, "live: production store actually saved")
      check((try? Data(contentsOf: target)) == Data("start=2.5\nspeed=1.25\n".utf8), "live: production bytes match narrow format")
      let engine = try ResumeClient(directory: root)
      check(try engine.load(media), "live: MPV loaded synthetic media")
      check(engine.number("time-pos").map { abs($0 - 2.5) <= 0.051 } == true, "live: MPV restored stored position")
      check(engine.number("speed").map { abs($0 - 1.25) < 0.000001 } == true, "live: MPV restored stored speed")
      check(!FileManager.default.fileExists(atPath: target.path), "live: successful load consumed production record")
      check(try engine.quit(), "live: actual MPV shutdown completed")
      check(SHA256.hash(data: try Data(contentsOf: media)) == SHA256.hash(data: before), "live: fixture hash unchanged")
    } catch {
      print("HARNESS_ERROR: \(error)")
      exit(2)
    }
    print("Resume store live: \(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
}
