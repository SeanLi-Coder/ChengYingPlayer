import Foundation

private typealias QueueEntry = MediaPlaylistRelocation.Entry

private final class QueueFixture {
  var entries: [QueueEntry]
  var inserted: [Int64] = []
  var removed: [Int64] = []
  var snapshots = 0
  var nextID: Int64 = 100
  var onInsert: ((QueueFixture, Int64) -> Void)?
  var onSnapshot: ((QueueFixture, Int) -> Bool)?
  var onRemove: ((QueueFixture) -> Void)?
  var insertionFails = false
  init(_ entries: [QueueEntry]) { self.entries = entries }
  func snapshot() -> [QueueEntry]? {
    snapshots += 1
    if onSnapshot?(self, snapshots) == false { return nil }
    return entries
  }
  func insert(_ filename: String, at index: Int) {
    guard !insertionFails else { return }
    let identifier = nextID
    nextID += 1
    entries.insert(QueueEntry(entryID: identifier, filename: filename, isCurrent: false), at: index)
    inserted.append(identifier)
    onInsert?(self, identifier)
  }
  func remove(_ index: Int) {
    expect(entries.indices.contains(index), "Queue removal is within the current snapshot")
    removed.append(entries.remove(at: index).entryID)
    onRemove?(self)
  }
  func setCurrent(_ identifier: Int64) {
    entries = entries.map { QueueEntry(entryID: $0.entryID, filename: $0.filename, isCurrent: $0.entryID == identifier) }
  }
  func apply(_ report: MediaFileTransfer.Report) -> Bool {
    MediaPlaylistRelocation.apply(report: report, snapshot: snapshot, insert: insert, remove: remove)
  }
}

func runPlaylistRelocationTests() throws {
  let source = try folder("relocation/source")
  let destination = try folder("relocation/destination")
  let a = source.appendingPathComponent("a.mp4"), b = source.appendingPathComponent("b.mp4")
  let aOut = destination.appendingPathComponent("a.mp4"), bOut = destination.appendingPathComponent("b.mp4")
  let report = MediaFileTransfer.Report(successes: [
    MediaFileTransfer.Success(source: a, destination: aOut),
    MediaFileTransfer.Success(source: b, destination: bOut),
  ], failures: [])
  func entry(_ id: Int64, _ url: URL, current: Bool = false) -> QueueEntry {
    QueueEntry(entryID: id, filename: url.path, isCurrent: current)
  }
  let untouched = QueueEntry(entryID: 1, filename: "/synthetic/current.mp4", isCurrent: true)
  let remote = QueueEntry(entryID: 9, filename: "https://example.invalid/video.mp4", isCurrent: false)

  do {
    let fixture = QueueFixture([untouched, entry(2, a), entry(3, b), entry(4, a), remote])
    expect(fixture.apply(report), "Multiple moved queue references are updated successfully")
    expect(fixture.entries.map(\.filename) == [untouched.filename, aOut.path, bOut.path, aOut.path, remote.filename],
           "Relocation preserves queue order including repeated filenames")
    expect(fixture.entries.first == untouched && fixture.entries.last == remote,
           "Current media and remote queue entries are unchanged")
    expect(Set(fixture.removed) == Set([2, 3, 4]) && fixture.inserted.count == 3,
           "Only intended inactive references are removed")
  }
  do {
    let fixture = QueueFixture([entry(1, a, current: true), entry(2, b)])
    expect(fixture.apply(report) && fixture.entries[0] == entry(1, a, current: true),
           "Current target is skipped without reopening media")
    expect(fixture.removed == [2], "Current queue ID is never removed")
  }
  do {
    let original = [untouched, entry(2, a), entry(3, b)]
    let fixture = QueueFixture(original)
    fixture.insertionFails = true
    expect(!fixture.apply(report) && fixture.entries == original && fixture.removed.isEmpty,
           "Failed insert stops safely without removing old references")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a), entry(3, b)])
    fixture.onInsert = { queue, _ in queue.entries.swapAt(0, queue.entries.count - 1) }
    expect(!fixture.apply(report), "Unexpected reorder during insertion stops relocation")
    expect(fixture.removed.isEmpty && Set([Int64(1), 2, 3]).isSubset(of: Set(fixture.entries.map(\.entryID))),
           "An unacknowledged insertion never authorizes removal after reordering")
    expect(fixture.inserted.count == 1, "Unexpected insertion mutation does not continue with a stale count")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a), entry(3, b)])
    fixture.onInsert = { queue, _ in
      queue.entries.append(QueueEntry(entryID: 777, filename: "/synthetic/external.mp4", isCurrent: false))
    }
    expect(!fixture.apply(report) && fixture.removed.isEmpty && fixture.entries.contains { $0.entryID == 777 },
           "A concurrently added external reference is never guessed to belong to the transfer")
    expect(fixture.inserted.count == 1, "External additions stop the batch before later inserts")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a)])
    fixture.onInsert = { queue, _ in queue.setCurrent(2) }
    expect(!fixture.apply(report), "Automatic playback advancing onto the old target aborts replacement")
    expect(fixture.removed == fixture.inserted && fixture.entries.contains { $0.entryID == 2 && $0.isCurrent },
           "Rollback removes only its confirmed new reference, never the newly current old entry")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a)])
    fixture.onInsert = { queue, identifier in queue.setCurrent(identifier) }
    expect(!fixture.apply(report) && fixture.removed.isEmpty,
           "Rollback never removes its own insertion if playback has already advanced onto it")
    expect(fixture.entries.contains { $0.entryID == 2 }, "Current-insertion race preserves the old reference")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a)])
    fixture.onSnapshot = { queue, call in
      if call == 4 { queue.entries.swapAt(0, queue.entries.count - 1) }
      return true
    }
    expect(!fixture.apply(report), "Reorder after confirmed insertion is detected before removing the original")
    expect(fixture.removed == fixture.inserted && Set(fixture.entries.map(\.entryID)) == Set([1, 2]),
           "Confirmed insertion rollback resolves its ID at the new row")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a)])
    fixture.onSnapshot = { queue, call in
      if call == 4, let index = queue.entries.firstIndex(where: { $0.entryID == 2 }) {
        queue.entries[index] = QueueEntry(entryID: 2, filename: "/synthetic/replaced.mp4", isCurrent: false)
      }
      return true
    }
    expect(!fixture.apply(report) && fixture.removed == fixture.inserted,
           "A changed original path cancels removal and rolls back only the known insertion")
    expect(fixture.entries.contains { $0.filename == "/synthetic/replaced.mp4" }, "Changed external path remains untouched")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a)])
    fixture.onSnapshot = { _, call in call != 4 }
    expect(!fixture.apply(report) && fixture.removed == fixture.inserted,
           "Unavailable pre-removal snapshot fails closed and attempts only identity-safe rollback")
  }
  do {
    let fixture = QueueFixture([untouched, entry(2, a), entry(3, b)])
    fixture.onRemove = { queue in
      queue.entries.append(QueueEntry(entryID: 778, filename: "/synthetic/later.mp4", isCurrent: false))
    }
    expect(!fixture.apply(report) && fixture.inserted.count == 1,
           "Mutation after an otherwise correct removal stops the remaining batch")
    expect(fixture.removed == [3] && fixture.entries.contains { $0.entryID == 778 },
           "Post-removal concurrent addition remains intact")
  }
  do {
    let fixture = QueueFixture([entry(1, a), entry(1, b)])
    expect(!fixture.apply(report) && fixture.inserted.isEmpty && fixture.removed.isEmpty,
           "Duplicate queue IDs are rejected before mutation")
    let invalid = QueueFixture([entry(-1, a)])
    expect(!invalid.apply(report) && invalid.inserted.isEmpty, "Unknown queue IDs cannot authorize changes")
    let absent = QueueFixture([entry(1, a)])
    absent.onSnapshot = { _, _ in false }
    expect(!absent.apply(report) && absent.inserted.isEmpty, "Unavailable initial queue fails closed")
  }

  let real = try folder("relocation/real")
  let alias = root.appendingPathComponent("relocation/alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
  let original = try file("relocation/real/photo.jpg")
  let sourceAlias = alias.appendingPathComponent("photo.jpg")
  let destinationFile = destination.appendingPathComponent("photo.jpg")
  let aliasReport = MediaFileTransfer.Report(successes: [
    MediaFileTransfer.Success(source: sourceAlias, destination: destinationFile, canonicalSource: original),
  ], failures: [])
  expect(aliasReport.relocatedURL(original) == destinationFile && aliasReport.relocatedURL(sourceAlias) == destinationFile,
         "A source captured through an alias relocates both canonical and lexical viewers")
  let folderReport = MediaFileTransfer.Report(successes: [
    MediaFileTransfer.Success(source: real, destination: destination, canonicalSource: real),
  ], failures: [])
  expect(folderReport.relocatedURL(sourceAlias) == destinationFile,
         "Existing aliases resolve into moved directory mappings")
  try FileManager.default.removeItem(at: alias)
  expect(folderReport.relocatedURL(sourceAlias, canonicalURL: original) == destinationFile,
         "Known pre-move canonical identity survives a now-dangling alias path")
  expect(folderReport.relocatedURL(real.appendingPathComponent("nested/a.jpg")) == destination.appendingPathComponent("nested/a.jpg"),
         "Folder relocation preserves nested path components")
  expect(folderReport.relocatedURL(real.deletingLastPathComponent().appendingPathComponent("real-other/photo.jpg")) == nil,
         "A shared string prefix is not mistaken for a descendant folder")
  expect(folderReport.relocatedURL(URL(string: "https://example.invalid/photo.jpg")!) == nil,
         "Remote queue entries are never interpreted as local relocation paths")
}
