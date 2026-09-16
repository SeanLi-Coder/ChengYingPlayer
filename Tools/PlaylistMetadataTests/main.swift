import Foundation
import Darwin

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func encodedTags(_ entries: [Any]) throws -> Data {
  try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
}

let allColors = try encodedTags((0...7).map { "Tag \($0)\n\($0)" })
let parsedColors = PlaylistFileMetadata.tags(fromPropertyList: allColors)!
check(parsedColors.map(\.colorIndex) == Array(0...7), "All Finder tag colors are preserved")
check(parsedColors.map(\.name) == (0...7).map { "Tag \($0)" }, "Color suffixes are not shown as tag names")
let names = PlaylistFileMetadata.tags(fromPropertyList: try encodedTags([
  "Project review\n6", "已完成\n2", "No color", "First\nSecond\n4", "Suffix\n9", "", "\n3", 42,
]))!
check(names == [
  PlaylistFileTag(name: "Project review", colorIndex: 6), PlaylistFileTag(name: "已完成", colorIndex: 2),
  PlaylistFileTag(name: "No color"), PlaylistFileTag(name: "First\nSecond", colorIndex: 4),
  PlaylistFileTag(name: "Suffix\n9"),
], "Custom and multiline tag names survive mixed malformed entries")
check(PlaylistFileMetadata.tags(fromPropertyList: Data("not a plist".utf8)) == nil,
      "Invalid tag data fails independently")
let emptyTags = try encodedTags([])
check(PlaylistFileMetadata.tags(fromPropertyList: emptyTags) == [], "An empty tag array is valid")
check(PlaylistFileTag(name: "Invalid", colorIndex: 99).colorIndex == 0, "Unknown tag colors use no color")

func item(_ name: String, directory: String = "/tmp/playlist-sort", size: Int64? = nil,
          modified: TimeInterval? = nil, created: TimeInterval? = nil) -> PlaylistFileMetadata {
  PlaylistFileMetadata(
    url: URL(fileURLWithPath: directory).appendingPathComponent(name), name: name, fileSize: size,
    modificationDate: modified.map(Date.init(timeIntervalSince1970:)),
    creationDate: created.map(Date.init(timeIntervalSince1970:))
  )
}

let naturalItems = [item("Clip 10.mp4"), item("Clip 2.mp4"), item("Clip 1.mp4")]
check(PlaylistFileMetadata.sortedIndices(for: naturalItems) == [2, 1, 0], "Default order uses natural filename ascending")
check(PlaylistFileMetadata.sortedIndices(for: naturalItems, ascending: false) == [0, 1, 2], "Names can sort descending")
check(PlaylistFileMetadata.sortedIndices(for: [item("片段10.mp4"), item("片段2.mp4")]) == [1, 0],
      "Natural sorting handles localized filenames")

let items = [
  item("Clip 10.mp4", size: 30, modified: 30, created: 300),
  item("Clip 2.mp4", size: nil, modified: nil, created: nil),
  item("Clip 1.mp4", size: 10, modified: 10, created: 100),
  item("Clip 3.mp4", size: 30, modified: 30, created: 300),
  item("Clip 2.mp4", directory: "/tmp/another-path", size: nil, modified: nil, created: nil),
]
for key in [PlaylistFileSortKey.size, .modified, .created] {
  check(PlaylistFileMetadata.sortedIndices(for: items, by: key) == [2, 3, 0, 4, 1],
        "\(key.rawValue) ascending uses name/path ties and keeps unknown values last")
  check(PlaylistFileMetadata.sortedIndices(for: items, by: key, ascending: false) == [3, 0, 2, 4, 1],
        "\(key.rawValue) descending still keeps unknown values last")
}
let duplicates = [items[0], items[0], items[0]]
for key in PlaylistFileSortKey.allCases {
  for ascending in [true, false] {
    check(PlaylistFileMetadata.sortedIndices(for: duplicates, by: key, ascending: ascending) == [0, 1, 2],
          "Duplicate occurrences retain their original indices for \(key.rawValue)")
  }
}
check(PlaylistFileMetadata.sortedIndices(for: []) == [], "Empty playlists sort safely")
check(PlaylistFileMetadata.sortedIndices(for: [item(""), item("Clip.mp4")], ascending: false) == [1, 0],
      "Unknown names sort last even when descending")
let invalid = item("Invalid.mp4", size: -1, modified: .nan, created: .infinity)
check(invalid.fileSize == nil && invalid.modificationDate == nil && invalid.creationDate == nil,
      "Invalid numeric and date attributes become unknown")
let independentValues = [
  item("A.mp4", size: 30, modified: 20, created: 10),
  item("B.mp4", size: 10, modified: 30, created: 20),
  item("C.mp4", size: 20, modified: 10, created: 30),
]
check(PlaylistFileMetadata.sortedIndices(for: independentValues, by: .size) == [1, 2, 0],
      "Size ordering uses byte counts independently of dates")
check(PlaylistFileMetadata.sortedIndices(for: independentValues, by: .modified) == [2, 0, 1],
      "Modification ordering uses the modification date independently")
check(PlaylistFileMetadata.sortedIndices(for: independentValues, by: .created) == [0, 1, 2],
      "Creation ordering uses the creation date independently")

let fileManager = FileManager.default
let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("chengying-tags-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryDirectory) }
let video = temporaryDirectory.appendingPathComponent("Scene 2.mp4")
try Data(repeating: 0x42, count: 4097).write(to: video)
let expectedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
try fileManager.setAttributes([.modificationDate: expectedModificationDate], ofItemAtPath: video.path)

func writeAttribute(_ data: Data) {
  let result = video.withUnsafeFileSystemRepresentation { path in
    data.withUnsafeBytes { buffer in
      setxattr(path!, "com.apple.metadata:_kMDItemUserTags", buffer.baseAddress, buffer.count, 0, 0)
    }
  }
  check(result == 0, "Temporary test file accepts the Finder metadata attribute")
}
writeAttribute(try encodedTags(["Review\n6", "Custom blue\n4", "未完成\n0"]))
let actual = PlaylistFileMetadata.read(from: video)
check(actual.name == "Scene 2.mp4" && actual.fileSize == 4097, "Real file name and byte size are read")
check(actual.modificationDate == expectedModificationDate, "Real modification date is read")
check(actual.creationDate != nil, "Real creation date is available")
check(actual.tags == [
  PlaylistFileTag(name: "Review", colorIndex: 6), PlaylistFileTag(name: "Custom blue", colorIndex: 4),
  PlaylistFileTag(name: "未完成", colorIndex: 0),
], "Real Finder attributes retain multiple colors and custom names")
let unchangedVideo = try Data(contentsOf: video)
check(unchangedVideo == Data(repeating: 0x42, count: 4097), "Metadata reads leave video bytes unchanged")

writeAttribute(try encodedTags(["Changed in Finder\n7"]))
let updated = PlaylistFileMetadata.read(from: video)
check(updated.tags == [PlaylistFileTag(name: "Changed in Finder", colorIndex: 7)],
      "Fresh metadata reads observe changed Finder tags")
writeAttribute(Data("malformed property list".utf8))
let brokenTags = PlaylistFileMetadata.read(from: video)
check(brokenTags.fileSize == 4097 && brokenTags.modificationDate == expectedModificationDate,
      "Invalid Finder tag metadata does not discard file attributes")

let missing = PlaylistFileMetadata.read(from: temporaryDirectory.appendingPathComponent("Missing.mp4"))
check(missing.name == "Missing.mp4" && missing.fileSize == nil && missing.tags.isEmpty,
      "Missing files retain their name and have unknown attributes")
let remote = PlaylistFileMetadata.read(from: URL(string: "https://example.invalid/video.mp4")!)
check(remote.name == "video.mp4" && remote.fileSize == nil && remote.tags.isEmpty,
      "Remote items do not trigger local metadata reads")
let relative = PlaylistFileMetadata.read(from: URL(string: "relative/video.mp4")!)
check(relative.name == "video.mp4" && relative.fileSize == nil, "Relative resource URLs remain safe")
let resource = PlaylistFileMetadata.read(from: URL(string: "edl://mock-resource")!)
check(resource.fileSize == nil && resource.tags.isEmpty, "Playback resource URLs remain safe")
let authority = URL(string: "file://example.invalid\(video.path)")!
check(PlaylistFileMetadata.read(from: authority).fileSize == nil,
      "A remote file authority is not silently redirected to the local filesystem")
let invalidPath = URL(fileURLWithPath: video.path + "\0ignored")
check(PlaylistFileMetadata.read(from: invalidPath).fileSize == nil,
      "Embedded null bytes cannot truncate into a different local file")
print("SUCCESS: \(checks) playlist metadata checks passed")
