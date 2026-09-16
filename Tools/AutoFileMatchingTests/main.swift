import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("AutoFileMatchingTests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func match(videos: [String], subtitles: [String], action: Preference.IINAAutoLoadAction = .iina,
           autoAdd: Bool = true) throws -> [String: [String]] {
  let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  for name in videos + subtitles {
    try Data().write(to: folder.appendingPathComponent(name))
  }
  Preference.action = action
  Preference.autoAdd = autoAdd
  Logger.messages = []
  let player = PlayerCore()
  player.info.currentURL = folder.appendingPathComponent(videos[0])
  try AutoFileMatcher(player: player, ticket: 1).startMatching()
  check(!player.info.isMatchingSubtitles, "The production matcher completes its lifecycle")
  check(Logger.messages.contains(where: { $0.hasPrefix("Force matching unmatched videos,") }) == autoAdd,
        "The real final unmatched-file stage runs when automatic folder loading is enabled")
  var result: [String: [String]] = [:]
  for video in videos {
    let path = folder.appendingPathComponent(video).path
    result[video] = player.info.matchedSubs[path, default: []].map(\.lastPathComponent)
  }
  return result
}

let episodeNames = ["Episode 1.mp4", "Episode 10.mp4"]
let numeric = try match(videos: episodeNames, subtitles: ["Episode 10.srt"])
check(numeric[episodeNames[0]] == [], "Episode 1 cannot claim Episode 10's subtitle in the default matching mode")
check(numeric[episodeNames[1]] == ["Episode 10.srt"], "The intended later episode retains its subtitle")

let seasonNames = ["Show.S01E01.mkv", "Show.S01E010.mkv"]
let season = try match(videos: seasonNames, subtitles: ["Show.S01E010.zh-Hans.ass"])
check(season[seasonNames[0]] == [] && season[seasonNames[1]] == ["Show.S01E010.zh-Hans.ass"],
      "Zero-padded season and episode names do not match a longer episode number")

let multilingual = try match(videos: episodeNames,
                             subtitles: ["Episode 1.zh-Hans.srt", "[Release] Episode 1.en.ass", "Episode 10.zh-Hans.srt"])
check(Set(multilingual[episodeNames[0]] ?? []) == ["Episode 1.zh-Hans.srt", "[Release] Episode 1.en.ass"],
      "Language suffixes and release prefixes remain valid for the shorter episode")
check(multilingual[episodeNames[1]] == ["Episode 10.zh-Hans.srt"],
      "Language suffixes do not disable the longer episode's numeric boundary")

let seriesVideos = ["Series 1.mp4", "Series 2.mp4", "Series 10.mp4"]
let seriesSubtitles = ["Series 1.zh.srt", "Series 2.zh.srt", "Series 10.zh.srt"]
let series = try match(videos: seriesVideos, subtitles: seriesSubtitles)
for (video, subtitle) in zip(seriesVideos, seriesSubtitles) {
  check(series[video] == [subtitle], "Production FileGroup series matching is preserved for \(video)")
}

let escaped = try match(videos: ["[Show]+(Part).1.mp4", "[Show]+(Part).10.mp4"],
                        subtitles: ["[Show]+(Part).1.en.srt", "[Show]+(Part).10.en.srt"])
check(escaped["[Show]+(Part).1.mp4"] == ["[Show]+(Part).1.en.srt"] &&
      escaped["[Show]+(Part).10.mp4"] == ["[Show]+(Part).10.en.srt"],
      "Filename punctuation retains literal matching semantics")

let composedTitle = "Café Episode"
let decomposedTitle = "Cafe\u{0301} Episode"
for (videoTitle, subtitleTitle) in [(composedTitle, decomposedTitle), (decomposedTitle, composedTitle)] {
  let normalized = try match(videos: ["\(videoTitle) 1.mp4", "\(videoTitle) 10.mp4"],
                             subtitles: ["\(subtitleTitle) 1.zh.srt", "\(subtitleTitle) 10.zh.srt"])
  check(normalized["\(videoTitle) 1.mp4"] == ["\(subtitleTitle) 1.zh.srt"] &&
        normalized["\(videoTitle) 10.mp4"] == ["\(subtitleTitle) 10.zh.srt"],
        "Canonically equivalent NFC and NFD filenames retain matching and numeric boundaries")
}

let leading = try match(videos: ["1 Movie.mp4", "11 Movie.mp4"], subtitles: ["11 Movie.zh.srt"])
check(leading["1 Movie.mp4"] == [] && leading["11 Movie.mp4"] == ["11 Movie.zh.srt"],
      "A numeric prefix is not taken from the middle of a longer number")

let repeated = try match(videos: ["Episode 1.mp4"], subtitles: ["Episode 10 extras - Episode 1.en.srt"])
check(repeated["Episode 1.mp4"] == ["Episode 10 extras - Episode 1.en.srt"],
      "A later complete occurrence remains valid after an earlier partial numeric occurrence")

let letters = try match(videos: ["Movie.mp4"], subtitles: ["ReleaseMovieExtended.en.srt"])
check(letters["Movie.mp4"] == ["ReleaseMovieExtended.en.srt"],
      "Existing nonnumeric substring matching is intentionally unchanged")

let fuzzy = try match(videos: episodeNames, subtitles: ["Episode 10.srt"], action: .mpvFuzzy, autoAdd: false)
check(fuzzy[episodeNames[0]] == [] && fuzzy[episodeNames[1]] == ["Episode 10.srt"],
      "Contains-only matching also respects numeric boundaries")

let disabled = try match(videos: episodeNames, subtitles: ["Episode 1.srt", "Episode 10.srt"], action: .disabled)
check(disabled.values.allSatisfy(\.isEmpty), "Disabling subtitle autoload remains effective")

print("PASS: \(checks) automatic subtitle matching checks")
