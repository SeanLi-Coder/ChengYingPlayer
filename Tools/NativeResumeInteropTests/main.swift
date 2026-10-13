import Foundation
import CryptoKit

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
  checks += 1
  if condition { print("PASS: \(name)") }
  else { failures += 1; print("FAIL: \(name)") }
}
func close(_ value: Double?, to target: Double, tolerance: Double = 0.051) -> Bool {
  value.map { $0.isFinite && abs($0 - target) <= tolerance } == true
}

guard CommandLine.arguments.count == 4 else { fatalError("Expected owned artifact directory, fixture directory and control") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
let control = CommandLine.arguments[3]
let allowed = ["positive", "wrong-start", "disable-resume", "suppress-explicit-save", "suppress-quit-save"]
guard allowed.contains(control) else { fatalError("Unknown control") }
let fm = FileManager.default
let first = fixtures.appendingPathComponent("first.mp4")
let second = fixtures.appendingPathComponent("second.mp4")
let fixtureBefore = [first, second].map { try! Data(contentsOf: $0) }
let marker = root.appendingPathComponent("case-probe-Aa")
try Data("Owned case-sensitivity probe\n".utf8).write(to: marker, options: .withoutOverwriting)
let caseSensitive = !fm.fileExists(atPath: root.appendingPathComponent("case-probe-aa").path)
print("FILESYSTEM_CASE_SENSITIVE: \(caseSensitive)")
print("CONTROL: \(control)")

func digest(_ url: URL) -> String {
  Insecure.MD5.hash(data: Data(url.path.utf8)).map { String(format: "%02X", $0) }.joined()
}
func folder(_ name: String) throws -> URL {
  let directory = root.appendingPathComponent(name, isDirectory: true)
  try fm.createDirectory(at: directory.appendingPathComponent("watch-later"), withIntermediateDirectories: true)
  return directory
}
func record(_ directory: URL, _ media: URL = first, lowercase: Bool = false) -> URL {
  let name = lowercase ? digest(media).lowercased() : digest(media)
  return directory.appendingPathComponent("watch-later").appendingPathComponent(name)
}
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func start(_ url: URL) -> Double? {
  guard let line = text(url)?.split(separator: "\n").first, line.hasPrefix("start=") else { return nil }
  return Double(line.dropFirst(6))
}
func speed(_ url: URL) -> Double? {
  guard let line = text(url)?.split(separator: "\n").first(where: { $0.hasPrefix("speed=") }) else { return nil }
  return Double(line.dropFirst(6))
}
func seed(_ directory: URL, _ media: URL = first, position: Double = 2, lowercase: Bool = false) throws -> Data {
  let data = Data("start=\(position)\nspeed=1.250000\n".utf8)
  try data.write(to: record(directory, media, lowercase: lowercase), options: .withoutOverwriting)
  return data
}
func prepared(_ directory: URL, save: Bool = false) throws -> ResumeClient {
  let engine = try ResumeClient(directory: directory, save: save)
  check(try engine.load(first), "\(directory.lastPathComponent): real load and restart")
  check(try engine.seek(2.5), "\(directory.lastPathComponent): exact seek reaches stable position")
  try engine.set("speed", "1.5")
  return engine
}

do {
  let directory = try folder("restore")
  _ = try seed(directory, position: control == "wrong-start" ? 3 : 2)
  let engine = try ResumeClient(directory: directory, resume: control != "disable-resume")
  check(try engine.load(first), "restore: real load and restart")
  check(close(engine.number("time-pos"), to: 2), "restore: saved position applied")
  check(close(engine.number("speed"), to: 1.25, tolerance: 0.000001), "restore: saved speed applied")
  check(!exists(record(directory)), "restore: successful load consumes record")
  check(try engine.quit(), "restore: real shutdown")

  let failed = try folder("failed-load")
  let missing = failed.appendingPathComponent("missing.mp4")
  let original = try seed(failed, missing)
  let failingEngine = try ResumeClient(directory: failed)
  try failingEngine.command(["loadfile", missing.path, "replace"])
  check(failingEngine.wait { failingEngine.errors == 1 }, "failed-load: real error event")
  check(failingEngine.loaded == 0, "failed-load: no fabricated loaded event")
  check((try? Data(contentsOf: record(failed, missing))) == original, "failed-load: record retained unchanged")
  check(try failingEngine.quit(expectedErrors: 1), "failed-load: real shutdown")
  check((try? Data(contentsOf: record(failed, missing))) == original, "failed-load: shutdown preserves record")

  let disabled = try folder("resume-disabled")
  let disabledBytes = try seed(disabled)
  let disabledEngine = try ResumeClient(directory: disabled, resume: false)
  check(try disabledEngine.load(first), "resume-disabled: real load and restart")
  check(close(disabledEngine.number("time-pos"), to: 0), "resume-disabled: starts at beginning")
  check(close(disabledEngine.number("speed"), to: 1, tolerance: 0.000001), "resume-disabled: ignores saved speed")
  check((try? Data(contentsOf: record(disabled))) == disabledBytes, "resume-disabled: does not consume record")
  check(try disabledEngine.quit(), "resume-disabled: real shutdown")
  check((try? Data(contentsOf: record(disabled))) == disabledBytes, "resume-disabled: shutdown leaves original bytes")

  let rawStop = try folder("raw-stop")
  let rawStopEngine = try prepared(rawStop, save: true)
  check(try rawStopEngine.stop(), "raw-stop: real stop unloads media")
  check(!exists(record(rawStop)), "raw-stop: idle=yes stop alone does not save")
  check(try rawStopEngine.quit(), "raw-stop: real shutdown")
  check(!exists(record(rawStop)), "raw-stop: later idle quit cannot fabricate a position")

  let explicit = try folder("explicit-stop")
  let explicitEngine = try prepared(explicit, save: true)
  if control != "suppress-explicit-save" { try explicitEngine.command(["write-watch-later-config"]) }
  check(try explicitEngine.stop(), "explicit-stop: real stop unloads media")
  check(exists(record(explicit)), "explicit-stop: pre-stop write persists record")
  check(close(start(record(explicit)), to: 2.5), "explicit-stop: start is first line and matches position")
  check(close(speed(record(explicit)), to: 1.5, tolerance: 0.000001), "explicit-stop: changed speed is preserved")
  let savedBytes = try? Data(contentsOf: record(explicit))
  check(try explicitEngine.quit(), "explicit-stop: real shutdown")
  check((try? Data(contentsOf: record(explicit))) == savedBytes, "explicit-stop: stop then quit does not overwrite saved bytes")

  let quitting = try folder("quit-save")
  let quittingEngine = try prepared(quitting, save: control != "suppress-quit-save")
  check(try quittingEngine.quit(), "quit-save: real shutdown")
  check(exists(record(quitting)), "quit-save: quit writes record")
  check(close(start(record(quitting)), to: 2.5), "quit-save: writes live position")
  check(close(speed(record(quitting)), to: 1.5, tolerance: 0.000001), "quit-save: writes changed speed")

  let replacement = try folder("replace-save")
  let replacementEngine = try prepared(replacement, save: true)
  check(try replacementEngine.load(second), "replace-save: replacement actually loads")
  check(close(start(record(replacement)), to: 2.5), "replace-save: replacement saves outgoing position")
  check(!exists(record(replacement, second)), "replace-save: does not save incoming position prematurely")
  try replacementEngine.set("save-position-on-quit", "no")
  check(try replacementEngine.quit(), "replace-save: real shutdown")

  for (label, arguments) in [("playlist-next", ["playlist-next"]),
                             ("playlist-select", ["playlist-play-index", "1"])] {
    let list = try folder(label)
    let listEngine = try prepared(list, save: true)
    try listEngine.command(["loadfile", second.path, "append"])
    let previous = listEngine.loaded
    try listEngine.command(arguments)
    check(listEngine.wait { listEngine.loaded == previous + 1 && listEngine.string("path") == second.path }, "\(label): real next file loads")
    check(!exists(record(list)), "\(label): outgoing position is not saved")
    try listEngine.set("save-position-on-quit", "no")
    check(try listEngine.quit(), "\(label): real shutdown")
  }

  for mode in ["quit", "explicit-stop"] {
    let end = try folder("eof-\(mode)")
    let endEngine = try ResumeClient(directory: end, save: true)
    check(try endEngine.load(first), "eof-\(mode): real load and restart")
    check(try endEngine.seek(7.6), "eof-\(mode): seek near actual end")
    try endEngine.set("pause", "no")
    check(endEngine.wait { endEngine.flag("eof-reached") == true }, "eof-\(mode): actual EOF reached")
    let endPosition = endEngine.number("time-pos")
    check(endPosition.map { $0 >= 7.6 && $0 <= 8.051 } == true, "eof-\(mode): final position remains available")
    check(!exists(record(end)), "eof-\(mode): natural EOF does not itself save")
    if mode == "explicit-stop" {
      try endEngine.command(["write-watch-later-config"])
      check(try endEngine.stop(), "eof-\(mode): explicit close sequence stops")
    }
    check(try endEngine.quit(), "eof-\(mode): real shutdown")
    check(exists(record(end)), "eof-\(mode): user close writes a record")
    check(endPosition.map { close(start(record(end)), to: $0) } == true, "eof-\(mode): saved position matches observed EOF clock")
    print("EOF_POSITION: mode=\(mode) actual=\(endPosition ?? -1) saved=\(start(record(end)) ?? -1)")
  }

  let capital = try folder("filename-case")
  let capitalEngine = try prepared(capital)
  try capitalEngine.command(["write-watch-later-config"])
  let filenames = try fm.contentsOfDirectory(atPath: capital.appendingPathComponent("watch-later").path)
  check(filenames.contains(digest(first)), "filename-case: actual MPV filename is uppercase MD5")
  check(!filenames.contains(digest(first).lowercased()), "filename-case: enumeration contains no lowercase spelling")
  check(exists(record(capital, lowercase: true)) == !caseSensitive, "filename-case: lowercase lookup follows actual filesystem semantics")
  check(try capitalEngine.quit(), "filename-case: real shutdown")

  let lower = try folder("lowercase-record")
  let lowerBytes = try seed(lower, lowercase: true)
  let lowerEngine = try ResumeClient(directory: lower)
  check(try lowerEngine.load(first), "lowercase-record: real load and restart")
  check(close(lowerEngine.number("time-pos"), to: caseSensitive ? 0 : 2), "lowercase-record: restoration matches actual case sensitivity")
  check(close(lowerEngine.number("speed"), to: caseSensitive ? 1 : 1.25, tolerance: 0.000001), "lowercase-record: speed matches actual case sensitivity")
  check(exists(record(lower, lowercase: true)) == caseSensitive, "lowercase-record: consumption matches actual case sensitivity")
  check(!caseSensitive || (try? Data(contentsOf: record(lower, lowercase: true))) == lowerBytes, "lowercase-record: unconsumed lowercase bytes are preserved")
  check(try lowerEngine.quit(), "lowercase-record: real shutdown")

  for (index, media) in [first, second].enumerated() {
    check((try? Data(contentsOf: media)) == fixtureBefore[index], "identity: synthetic fixture \(index) remains byte-identical")
  }
} catch {
  print("HARNESS_ERROR: \(error)")
  exit(2)
}
print("Resume interop: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
