import Foundation
import Darwin

var checks = 0
var failures = 0
let checkLock = NSLock()
func check(_ value: Bool, _ label: String) {
  checkLock.lock()
  defer { checkLock.unlock() }
  checks += 1
  if value { print("PASS \(label)") }
  else { failures += 1; print("FAIL \(label)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
let attribute = "com.apple.metadata:_kMDItemUserTags"
let payload = Data((0..<8192).map { UInt8($0 % 251) })
var serial = 0
func file() throws -> URL {
  serial += 1
  let url = root.appendingPathComponent("synthetic-\(serial).mp4")
  try payload.write(to: url, options: .withoutOverwriting)
  return url
}
func setAttribute(_ url: URL, _ name: String, _ data: Data) throws {
  let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
  guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
func raw(_ url: URL, _ name: String = attribute) throws -> Data? {
  let count = getxattr(url.path, name, nil, 0, 0, 0)
  if count < 0 && errno == ENOATTR { return nil }
  guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  var data = Data(count: count)
  let result = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
  guard result == count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  return data
}
func setTags(_ url: URL, _ entries: Any) throws {
  try setAttribute(url, attribute, PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0))
}
func tags(_ url: URL) throws -> [String] {
  guard let data = try raw(url) else { return [] }
  return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String]
}
func wait<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
  var result: T?
  var delivered = false
  operation {
    check(Thread.isMainThread, "callback runs on main thread")
    check(!delivered, "callback delivered exactly once")
    delivered = true
    result = $0
  }
  let deadline = Date().addingTimeInterval(12)
  while result == nil && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  }
  guard let result else { fatalError("Asynchronous operation timed out") }
  return result
}
func read(_ url: URL) -> Result<PlaybackFileTags.Snapshot, PlaybackFileTags.TagError> {
  wait { PlaybackFileTags.read(url: url, completion: $0) }
}
func edit(_ snapshot: PlaybackFileTags.Snapshot, _ mutation: PlaybackFileTags.Mutation)
  -> Result<PlaybackFileTags.Snapshot, PlaybackFileTags.TagError> {
  let result = wait { completion in
    PlaybackFileTags.apply(mutation, to: snapshot, completion: completion)
    check(PlaybackFileTags.pendingWriteCount == 1, "write activity registered before return")
  }
  check(PlaybackFileTags.pendingWriteCount == 0, "write activity released on completion")
  return result
}
func expectFailure(_ result: Result<PlaybackFileTags.Snapshot, PlaybackFileTags.TagError>,
                   _ error: PlaybackFileTags.TagError, _ label: String) {
  if case .failure(let actual) = result { check(actual == error, label) }
  else { check(false, label) }
}

let media = try file()
var finderInfo = Data(repeating: 0, count: 32)
finderInfo[8] = 0x04
finderInfo[9] = 0x0c
finderInfo[16] = 0x42
try setAttribute(media, "com.apple.FinderInfo", finderInfo)
let customAttribute = Data("Preserve unrelated metadata".utf8)
try setAttribute(media, "io.chengying.synthetic-test", customAttribute)
let originalDate = try media.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
let originals = ["Project Q\n0", "Custom green\n2", "Line\nbreak\n0", "Legacy plain", "Second green\n2"]
try setTags(media, originals)
var snapshot = try read(media).get()
check(snapshot.tags.count == 5, "existing tags retained")
check(snapshot.tags[2].name == "Line\nbreak", "embedded newline preserved")
check(snapshot.colors == [2], "existing named color decoded")
check(snapshot.legacyColor == 6, "independent legacy Finder label decoded")
check(PlaybackFileTags.pendingWriteCount == 0, "read does not acquire write activity")
let colors = [1: "Gray", 2: "Green", 3: "Purple", 4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange"]
for index in 1...7 {
  let before = try raw(media)
  snapshot = try edit(snapshot, .addColor(index, name: colors[index]!)).get()
  check(snapshot.colors.contains(index), "Finder color \(index) added")
  check(Array(try tags(media).prefix(originals.count)) == originals, "color \(index) preserves existing tag entries")
  if index == 2 { check(try raw(media) == before, "existing custom color is byte-identical no-op") }
  let systemValues = try URL(fileURLWithPath: media.path).resourceValues(forKeys: [.tagNamesKey])
  check(systemValues.tagNames?.contains(index == 2 ? "Custom green" : colors[index]!) == true,
        "system resource API reads color \(index) name")
  check(PlaylistFileMetadata.read(from: media).tags.contains { $0.colorIndex == index },
        "production file list sees color \(index)")
  check(try raw(media, "com.apple.FinderInfo") == finderInfo, "color \(index) preserves FinderInfo")
  check(try raw(media, "io.chengying.synthetic-test") == customAttribute, "color \(index) preserves unrelated xattr")
  check(try Data(contentsOf: media) == payload, "color \(index) preserves media bytes")
}
check(snapshot.colors == Set(1...7), "all seven colors coexist")
let red = snapshot.tags.first { $0.name == "Red" }!
snapshot = try edit(snapshot, .removeTag(red)).get()
check(!snapshot.colors.contains(6), "exact red tag removed")
check(snapshot.legacyColor == 6, "legacy label not silently cleared")
check(snapshot.tags.first { $0.name == "Custom green" } != nil, "custom colored tag preserved")
let customGreen = snapshot.tags.first { $0.name == "Custom green" }!
snapshot = try edit(snapshot, .removeTag(customGreen)).get()
check(snapshot.tags.contains { $0.name == "Second green" }, "unselected same-color custom tag preserved")
check(!snapshot.tags.contains { $0.name == "Custom green" }, "explicitly selected custom tag removed")
for tag in snapshot.tags { snapshot = try edit(snapshot, .removeTag(tag)).get() }
check(try snapshot.tags.isEmpty && tags(media).isEmpty, "last named tag removal writes empty plist")
check(try raw(media, "com.apple.FinderInfo") == finderInfo, "all removals preserve FinderInfo bytes")
check(try Data(contentsOf: media) == payload, "all removals preserve media payload")
check(try URL(fileURLWithPath: media.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate,
      "content modification date preserved")

let noTags = try file()
var noTagSnapshot = try read(noTags).get()
check(noTagSnapshot.tags.isEmpty && noTagSnapshot.legacyColor == 0, "absent attributes handled")
noTagSnapshot = try edit(noTagSnapshot, .addColor(4, name: "Blue")).get()
check(noTagSnapshot.colors == [4], "absent attribute created")
let staleAttribute = noTagSnapshot
try setTags(noTags, ["Finder new edit\n3"])
expectFailure(edit(staleAttribute, .addColor(6, name: "Red")), .changed, "concurrent Finder attribute edit rejected")
check(try tags(noTags) == ["Finder new edit\n3"], "concurrent Finder edit not overwritten")
// Isolate subsequent cases from the deliberately broken conflict control.
try setTags(noTags, ["Finder new edit\n3"])
noTagSnapshot = try read(noTags).get()
let beforeInvalid = try raw(noTags)
for (index, name) in [(0, "None"), (8, "Bad"), (4, ""), (4, " "), (4, "Bad\n6"), (4, "Bad\rName"),
                      (4, "Bad\0Name"), (4, String(repeating: "x", count: 8192))] {
  expectFailure(edit(noTagSnapshot, .addColor(index, name: name)), .invalidTag, "invalid proposed tag rejected")
}
check(try raw(noTags) == beforeInvalid, "invalid mutations leave attributes unchanged")
expectFailure(edit(noTagSnapshot, .removeTag(red)), .changed, "foreign exact tag not removed")

for oldTag in ["Red\n0", "Red\n4", "red\n0"] {
  let collision = try file()
  try setTags(collision, [oldTag])
  let collisionSnapshot = try read(collision).get()
  let original = try raw(collision)
  expectFailure(edit(collisionSnapshot, .addColor(6, name: "Red")), .nameConflict,
                "existing differently colored name is not duplicated or recolored")
  check(try raw(collision) == original, "colliding tag preserves original bytes")
}

let replaced = try file()
let replacedSnapshot = try read(replaced).get()
let moved = replaced.appendingPathExtension("old")
try FileManager.default.moveItem(at: replaced, to: moved)
try payload.write(to: replaced, options: .withoutOverwriting)
expectFailure(edit(replacedSnapshot, .addColor(1, name: "Gray")), .changed, "replaced path rejected")
check(try raw(replaced) == nil && raw(moved) == nil, "neither replacement nor old inode modified")

let removed = try file()
let removedSnapshot = try read(removed).get()
try FileManager.default.removeItem(at: removed)
expectFailure(edit(removedSnapshot, .addColor(1, name: "Gray")), .unsupportedFile, "unlinked pinned file rejected")
let contentChanged = try file()
let contentSnapshot = try read(contentChanged).get()
try Data("Changed content".utf8).write(to: contentChanged)
expectFailure(edit(contentSnapshot, .addColor(1, name: "Gray")), .changed, "in-place content edit rejected")
check(try raw(contentChanged) == nil, "changed content receives no metadata write")

let link = root.appendingPathComponent("symlink.mp4")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: noTags)
expectFailure(read(link), .unsupportedFile, "leaf symlink rejected")
let linkParent = root.appendingPathComponent("symlink-parent")
try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: root)
if case .failure = read(linkParent.appendingPathComponent(noTags.lastPathComponent)) {
  check(true, "ancestor symlink rejected")
} else { check(false, "ancestor symlink rejected") }
let hardSource = try file()
let hardLink = root.appendingPathComponent("hard-link.mp4")
try FileManager.default.linkItem(at: hardSource, to: hardLink)
expectFailure(read(hardSource), .unsupportedFile, "hard-linked file rejected")
expectFailure(read(root), .unsupportedFile, "directory rejected")
let fifo = root.appendingPathComponent("fifo")
check(mkfifo(fifo.path, 0o600) == 0, "synthetic fifo created")
expectFailure(read(fifo), .unsupportedFile, "fifo rejected without blocking")
expectFailure(read(URL(string: "https://example.invalid/video.mp4")!), .unsupportedURL, "network URL rejected")
expectFailure(read(URL(string: "file://remote-host/movie.mp4")!), .unsupportedURL, "remote file URL rejected")
expectFailure(read(URL(string: "file:///synthetic.mp4?query=1")!), .unsupportedURL, "file URL query rejected")

for invalid in [Data(), Data("not a plist".utf8), try PropertyListSerialization.data(fromPropertyList: [42], format: .binary, options: 0),
                try PropertyListSerialization.data(fromPropertyList: [""], format: .binary, options: 0),
                try PropertyListSerialization.data(fromPropertyList: ["\n6"], format: .binary, options: 0),
                try PropertyListSerialization.data(fromPropertyList: ["Nul\0name\n6"], format: .binary, options: 0)] {
  let malformed = try file()
  try setAttribute(malformed, attribute, invalid)
  expectFailure(read(malformed), .invalidMetadata, "malformed metadata rejected rather than overwritten")
  check(try raw(malformed) == invalid, "malformed attribute bytes preserved")
}
let longTag = try file()
try setTags(longTag, [String(repeating: "x", count: 8193)])
expectFailure(read(longTag), .metadataTooLarge, "oversized tag rejected")
let manyTags = try file()
try setTags(manyTags, (0...4096).map { "Tag \($0)\n0" })
expectFailure(read(manyTags), .metadataTooLarge, "oversized tag count rejected")

let permission = try file()
let permissionSnapshot = try read(permission).get()
check(chmod(permission.path, 0o400) == 0, "synthetic read-only mode set")
expectFailure(edit(permissionSnapshot, .addColor(4, name: "Blue")), .permissionDenied, "write permission failure surfaced")
check(try raw(permission) == nil, "permission failure leaves tags absent")
check(chmod(permission.path, 0o600) == 0, "synthetic mode restored for test cleanup")

let race = try file()
try setTags(race, ["Race baseline\n0"])
let raceSnapshot = try read(race).get()
PlaybackFileTags.testBeforeWrite = {
  check(!Thread.isMainThread, "mutation IO runs off main thread")
  try! setTags(race, ["Race winner\n5"])
}
expectFailure(edit(raceSnapshot, .addColor(4, name: "Blue")), .changed, "late attribute conflict before syscall rejected")
PlaybackFileTags.testBeforeWrite = nil
check(try tags(race) == ["Race winner\n5"], "late external tag preserved")
try setTags(race, ["Race winner\n5"])
let refreshedRace = try read(race).get()
PlaybackFileTags.testAfterWrite = { try! setTags(race, ["Post-write winner\n3"]) }
expectFailure(edit(refreshedRace, .addColor(4, name: "Blue")), .writeUnverified, "post-write divergence not falsely successful")
PlaybackFileTags.testAfterWrite = nil
check(try tags(race) == ["Post-write winner\n3"], "post-write divergence not rolled back over external tag")

let held = try file()
let heldSnapshot = try read(held).get()
let gate = DispatchSemaphore(value: 0)
let entered = DispatchSemaphore(value: 0)
PlaybackFileTags.testBeforeWrite = { entered.signal(); _ = gate.wait(timeout: .now() + 5) }
var heldResult: Result<PlaybackFileTags.Snapshot, PlaybackFileTags.TagError>?
PlaybackFileTags.apply(.addColor(4, name: "Blue"), to: heldSnapshot) { heldResult = $0 }
check(entered.wait(timeout: .now() + 3) == .success, "background write reaches test gate")
check(PlaybackFileTags.pendingWriteCount == 1, "pending write remains visible while IO waits")
var mainQueueProgress = false
DispatchQueue.main.async { mainQueueProgress = true }
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
check(mainQueueProgress, "main queue remains responsive during tag IO")
gate.signal()
let heldDeadline = Date().addingTimeInterval(5)
while heldResult == nil && Date() < heldDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
check(heldResult != nil && PlaybackFileTags.pendingWriteCount == 0, "held write completes and releases activity")
PlaybackFileTags.testBeforeWrite = nil

print("SUMMARY checks=\(checks) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
