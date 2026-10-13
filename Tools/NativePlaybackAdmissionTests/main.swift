import Foundation

var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
  if value() { passed += 1; print("PASS: \(name)") }
  else { failed += 1; print("FAIL: \(name)") }
}
@discardableResult
func wait(_ predicate: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(3)
  while !predicate() && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
  }
  return predicate()
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixture = root.appendingPathComponent("fixture.mp4")
let fm = FileManager.default
precondition(fm.fileExists(atPath: fixture.path), "Missing synthetic fixture")
Utility.watchLaterURL = root.appendingPathComponent("watch-later", isDirectory: true)
try fm.createDirectory(at: Utility.watchLaterURL, withIntermediateDirectories: false)
func folder(_ name: String, sibling: Bool = false, subtitle: Bool = false, child: Bool = false) throws -> URL {
  let folder = root.appendingPathComponent(name, isDirectory: true)
  try fm.createDirectory(at: folder, withIntermediateDirectories: false)
  let first = folder.appendingPathComponent("first.mp4")
  try fm.copyItem(at: fixture, to: first)
  if sibling { try fm.copyItem(at: fixture, to: folder.appendingPathComponent("second.mp4")) }
  if subtitle { try Data("1\n00:00:00,000 --> 00:00:01,000\nSynthetic subtitle\n".utf8).write(to: folder.appendingPathComponent("first.srt")) }
  if child { try fm.createDirectory(at: folder.appendingPathComponent("subtitles"), withIntermediateDirectories: false) }
  return first
}
let isolated = try folder("isolated")
let siblings = try folder("siblings", sibling: true)
let subtitles = try folder("subtitles", subtitle: true)
let child = try folder("child", child: true)
func exercise(_ label: String, url: URL, expected: String, reason: String? = nil,
              configure: (PlayerCore) -> Void = { _ in }) {
  Preference.reset()
  let player = PlayerCore()
  configure(player)
  let scheduled = player.testOpen(url)
  if scheduled { check(wait { player.result != nil }, "\(label): inventory completes") }
  let route = scheduled ? player.result : "declined"
  check(route == expected, "\(label): route")
  check(player.nativeStarts + player.compatibilityStarts == (scheduled ? 1 : 0), "\(label): exactly one destination")
  check(player.mpv.prepareCalls == (route == "compatibility" ? 1 : 0), "\(label): MPV preparation ownership")
  if let reason { check(player.logs == ["Native compatibility: \(reason)"], "\(label): exact compatibility reason") }
}
exercise("Isolated video with automatic siblings enabled", url: isolated, expected: "native")
exercise("Disabled automatic siblings preserves native", url: siblings, expected: "native") {
  _ in Preference.booleans[.playlistAutoAdd] = false
}
exercise("Enabled automatic siblings preserves compatibility", url: siblings, expected: "compatibility", reason: "sibling_playlist")
exercise("Per-open opt-out preserves native", url: siblings, expected: "native") { $0.info.shouldAutoLoadFiles = false }
exercise("Disabled siblings still checks subtitles", url: subtitles, expected: "compatibility", reason: "external_subtitle_search") {
  _ in Preference.booleans[.playlistAutoAdd] = false; Preference.subtitles = 1
}
exercise("Enabled subtitles still checks child directories", url: child, expected: "compatibility", reason: "external_subtitle_search") {
  _ in Preference.booleans[.playlistAutoAdd] = false; Preference.subtitles = 1
}
exercise("Explicitly disabled subtitles do not force compatibility", url: subtitles, expected: "native")
exercise("Used MPV remains rejected", url: siblings, expected: "declined", reason: "mpv_session_already_used") {
  $0.hasIssuedMPVMediaCommand = true; Preference.booleans[.playlistAutoAdd] = false
}
exercise("Multiple input remains rejected", url: siblings, expected: "declined", reason: "multiple_or_playlist_input") {
  $0.nativeSingleInput = false; Preference.booleans[.playlistAutoAdd] = false
}
exercise("Playlist loop remains compatibility", url: isolated, expected: "declined", reason: "playlist_repeat") {
  _ in Preference.loop = .playlist
}
exercise("Custom subtitle paths remain compatibility", url: isolated, expected: "declined", reason: "custom_subtitle_search") {
  _ in Preference.subtitleSearch = "../subtitles"
}
exercise("Non-pristine MPV remains rejected", url: isolated, expected: "declined", reason: "mpv_not_pristine_idle") { $0.mpv.idle = false }
exercise("Closing EOF policy remains compatibility", url: isolated, expected: "declined", reason: "close_window_on_eof") {
  _ in Preference.booleans[.keepOpenOnFileEnd] = false
}
let record = Utility.watchLaterURL.appendingPathComponent("fixture-record")
try Data("Synthetic watch-later record".utf8).write(to: record)
exercise("Watch-later remains compatibility with siblings disabled", url: siblings, expected: "compatibility", reason: "existing_watch_later_configuration") {
  _ in Preference.booleans[.playlistAutoAdd] = false; Preference.booleans[.resumeLastPosition] = true
}
Preference.reset()
Preference.booleans[.playlistAutoAdd] = false
let snapshot = PlayerCore()
check(snapshot.testOpen(siblings), "Preference snapshot schedules inventory")
Preference.booleans[.playlistAutoAdd] = true
check(wait { snapshot.result != nil }, "Preference snapshot completes")
check(snapshot.result == "native", "Preference is captured before background inventory: route")
check(snapshot.nativeStarts == 1 && snapshot.mpv.prepareCalls == 0, "Preference snapshot has one native owner")
print("Admission checks: \(passed + failed), failures: \(failed)")
exit(failed == 0 ? 0 : 1)
