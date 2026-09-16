import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  guard condition() else { fatalError("FAIL: \(description)") }
  checks += 1
}

let fm = FileManager.default
let folder = fm.temporaryDirectory.appendingPathComponent("PlaylistPlaybackTests-\(UUID().uuidString)")
try fm.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: folder) }
for name in ["Episode 10.mp4", "Episode 2.MP4", "Episode 1.mkv", "song.mp3", "Episode 2.srt", ".hidden.mp4"] {
  try Data().write(to: folder.appendingPathComponent(name))
}
for name in ["fake.mp4", "subfolder", ".hidden-folder"] {
  let nested = folder.appendingPathComponent(name, isDirectory: true)
  try fm.createDirectory(at: nested, withIntermediateDirectories: true)
  try Data().write(to: nested.appendingPathComponent("nested.mp4"))
}
let videoExtensions: Set<String> = ["mp4", "mkv"]
let blacklist: Set<String> = ["srt", "ass", "m3u", "m3u8"]
let expected = ["Episode 1.mkv", "Episode 2.MP4", "Episode 10.mp4"]
let siblings = PlaylistPlaybackPolicy.regularFiles(in: folder, extensions: videoExtensions)
check(siblings.map(\.lastPathComponent) == expected, "Folder loading contains only direct videos in natural order")
check(!siblings.contains(where: { $0.lastPathComponent == "fake.mp4" }), "A directory named like a video is not a video")
check(PlaylistPlaybackPolicy.regularFiles(in: folder).count == 5, "Hidden files and directories are excluded without extension filtering")
check(PlaylistPlaybackPolicy.regularFiles(in: folder.appendingPathComponent("missing")).isEmpty,
      "An unreadable or missing folder is safely empty")

let one = folder.appendingPathComponent("Episode 1.mkv")
let two = folder.appendingPathComponent("Episode 2.MP4")
let ten = folder.appendingPathComponent("Episode 10.mp4")
let audio = folder.appendingPathComponent("song.mp3")
let subtitle = folder.appendingPathComponent("Episode 2.srt")
func playable(_ urls: [URL]) -> [URL] {
  return PlaylistPlaybackPolicy.playableFiles(in: urls, videoExtensions: videoExtensions,
                                             blacklistedExtensions: blacklist)
}
check(playable([ten, one, two]) == [ten, one, two], "Explicit multi-selection order is preserved")
check(playable([ten, one, ten, two]) == [ten, one, two], "Stable de-duplication keeps the first occurrence")
check(playable([folder]).map(\.lastPathComponent) == expected, "Explicit folder loading is shallow and video-only")
check(playable([ten, folder]).map(\.path) == [ten, one, two].map(\.path),
      "A directory expands in place without re-sorting explicit files")
check(playable([audio, subtitle, ten]) == [audio, ten], "Explicit audio remains supported and subtitles stay out of the playlist")
let missingDirectory = folder.appendingPathComponent("missing", isDirectory: true)
check(playable([missingDirectory, ten]) == [ten], "One bad input does not discard subsequent files")
check(PlaylistPlaybackPolicy.shouldAutoLoadSiblings(inputURLs: [two], playableFileCount: 1, requested: true),
      "A single selected local file allows sibling loading")
check(!PlaylistPlaybackPolicy.shouldAutoLoadSiblings(inputURLs: [two], playableFileCount: 1, requested: false),
      "An explicit autoload opt-out is preserved")
check(!PlaylistPlaybackPolicy.shouldAutoLoadSiblings(inputURLs: [two, subtitle], playableFileCount: 1, requested: true),
      "Multiple explicit inputs never turn back into automatic folder loading")
check(!PlaylistPlaybackPolicy.shouldAutoLoadSiblings(inputURLs: [folder], playableFileCount: 1, requested: true),
      "A selected folder does not trigger a second sibling scan")

let nativeNode: [Any?] = [
  ["filename": two.path, "id": Int64(41), "current": true, "playing": true] as [String: Any?],
  ["filename": two.path, "id": Int64(42), "title": "Second copy"] as [String: Any?],
  ["filename": one.path, "id": Int64(43)] as [String: Any?]
]
let snapshot = MPVPlaylistItem.playlist(from: nativeNode)!
check(snapshot.map(\.entryID) == [41, 42, 43], "Native mpv node parsing retains stable entry IDs")
check(snapshot[0].filename == snapshot[1].filename && snapshot[0].id != snapshot[1].id,
      "Duplicate paths remain different playlist entries")
check(snapshot[0].isPlaying && snapshot[0].isCurrent && !snapshot[1].isPlaying,
      "Optional native flags are parsed correctly")
check(snapshot[1].title == "Second copy", "Imported playlist titles are preserved")
check(snapshot.allSatisfy { $0.snapshotEntryIDs == [41, 42, 43] }, "Items retain their source order for stale-result detection")
check(MPVPlaylistItem.playlist(from: nativeNode)!.map(\.id) == snapshot.map(\.id),
      "Identity survives native playlist refreshes")
check(MPVPlaylistItem.playlist(from: [] as [Any?])?.isEmpty == true, "Empty native playlists parse successfully")
check(MPVPlaylistItem.playlist(from: nil) == nil, "Unavailable native playlist reads fail safely")
check(MPVPlaylistItem.playlist(from: [["filename": two.path]]) == nil, "Missing entry identity is rejected")
check(MPVPlaylistItem.playlist(from: [["id": Int64(41)]]) == nil, "Missing filenames are rejected without a forced unwrap")
check(MPVPlaylistItem.playlist(from: [nativeNode[0], nativeNode[0]]) == nil, "Duplicate native IDs are rejected")
let legacy = MPVPlaylistItem(filename: one.path, isCurrent: false, isPlaying: false, title: nil)
check(legacy.id != MPVPlaylistItem(filename: one.path, isCurrent: false, isPlaying: false, title: nil).id,
      "Legacy items without mpv IDs still have distinct fallback identities")

func permutations(_ values: [Int64]) -> [[Int64]] {
  guard !values.isEmpty else { return [[]] }
  return values.indices.flatMap { index -> [[Int64]] in
    var remaining = values
    let head = remaining.remove(at: index)
    return permutations(remaining).map { [head] + $0 }
  }
}
for count in 0...6 {
  let original = (0..<count).map(Int64.init)
  for desired in permutations(original) {
    var actual = original
    let result = PlaylistPlaybackPolicy.reorder(to: desired, expectedIDs: original, readIDs: { actual }, move: { step in
      check(step.from > step.to, "Every move uses mpv's unambiguous backward insertion semantics")
      actual.insert(actual.remove(at: step.from), at: step.to)
      return true
    })
    check(result && actual == desired, "All permutations through six entries reorder exactly")
  }
}
check(PlaylistPlaybackPolicy.moves(from: [1, 2], to: [2, 1], expectedIDs: [2, 1]) == nil,
      "An older snapshot cannot overwrite a newer manual reorder")
check(PlaylistPlaybackPolicy.moves(from: [1, 2, 3], to: [2, 1], expectedIDs: [1, 2]) == nil,
      "New entries invalidate a pending reorder")
check(PlaylistPlaybackPolicy.moves(from: [1, 2], to: [2, 2], expectedIDs: [1, 2]) == nil,
      "Duplicate requested IDs are rejected")
check(PlaylistPlaybackPolicy.moves(from: [1, 2], to: [2, 3], expectedIDs: [1, 2]) == nil,
      "Replacement entries invalidate a pending reorder")
check(PlaylistPlaybackPolicy.moves(from: [-1], to: [-1], expectedIDs: [-1]) == nil,
      "Unassigned IDs cannot issue playlist commands")
var changing: [Int64] = [1, 2, 3]
var performedMoves = 0
let interrupted = PlaylistPlaybackPolicy.reorder(to: [3, 2, 1], expectedIDs: changing, readIDs: { changing }, move: { step in
  changing.insert(changing.remove(at: step.from), at: step.to)
  changing.append(4)
  performedMoves += 1
  return true
})
check(!interrupted && performedMoves == 1, "A concurrent change aborts before another stale index is used")
var failedMoves = 0
check(!PlaylistPlaybackPolicy.reorder(to: [2, 1], expectedIDs: [1, 2], readIDs: { [1, 2] }, move: { _ in
  failedMoves += 1
  return false
}) && failedMoves == 1, "A failed mpv command stops the reorder")

let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let playerSource = try String(contentsOf: project.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let reorderSource = playerSource.components(separatedBy: "func playlistReorder(newPlaylist:")[1]
  .components(separatedBy: "func addToPlaylist(")[0]
check(reorderSource.contains("PlaylistPlaybackPolicy.reorder") && reorderSource.contains(".playlistMove"),
      "Production reordering uses the tested move-only engine")
for forbidden in [".playlistClear", ".loadfile", ".playlistAppend", ".playlistInsert", ".playlistPlayIndex", ".seek", "setFlag", "setDouble"] {
  check(!reorderSource.contains(forbidden), "Sorting cannot reset playback via \(forbidden)")
}
let matcher = try String(contentsOf: project.appendingPathComponent("iina/AutoFileMatcher.swift"), encoding: .utf8)
check(matcher.contains("Preference.bool(for: .playlistAutoAdd)"), "Folder loading still respects the user's stored preference")
check(matcher.contains("snapshot.count == 1"), "Background loading cannot replace an explicitly imported or edited playlist")
print("PASS: \(checks) playlist playback checks")
