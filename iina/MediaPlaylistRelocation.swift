import Foundation

extension MediaFileTransfer.Report {
  /// Only call for move reports. Capture canonicalURL before moving through an alias.
  func relocatedURL(_ url: URL, canonicalURL: URL? = nil) -> URL? {
    guard url.isFileURL else { return nil }
    var candidates = [url.standardizedFileURL, url.standardizedFileURL.resolvingSymlinksInPath()]
    if let canonicalURL, canonicalURL.isFileURL { candidates.append(canonicalURL.standardizedFileURL) }
    for item in successes {
      let sources = [item.source.standardizedFileURL, item.canonicalSource?.standardizedFileURL].compactMap { $0 }
      for source in sources {
        let sourceParts = source.pathComponents
        for candidate in candidates {
          let parts = candidate.pathComponents
          guard parts.count >= sourceParts.count, parts.starts(with: sourceParts) else { continue }
          return parts.dropFirst(sourceParts.count).reduce(item.destination) { $0.appendingPathComponent($1) }
        }
      }
    }
    return nil
  }
}

/// Preserve queue identity while replacing references to moved local files.
/// The caller serializes mutations; callbacks must synchronously query/modify the same player.
enum MediaPlaylistRelocation {
  struct Entry: Equatable {
    let entryID: Int64
    let filename: String
    let isCurrent: Bool
  }

  @discardableResult
  static func apply(report: MediaFileTransfer.Report, snapshot: () -> [Entry]?,
                    insert: (String, Int) -> Void, remove: (Int) -> Void) -> Bool {
    guard let original = snapshot(), valid(original) else { return false }
    let targets = original.reversed().compactMap { item -> (Entry, String)? in
      guard !item.isCurrent, item.filename.hasPrefix("/"),
            let destination = report.relocatedURL(URL(fileURLWithPath: item.filename)) else { return nil }
      return (item, destination.path)
    }
    for (item, destination) in targets {
      guard let before = snapshot(), valid(before),
            let index = before.firstIndex(where: { sameIdentity($0, item) }),
            !before[index].isCurrent else { return false }
      insert(destination, index)
      guard let inserted = snapshot(), valid(inserted), inserted.count == before.count + 1,
            inserted.indices.contains(index), inserted[index].filename == destination,
            !before.contains(where: { $0.entryID == inserted[index].entryID }) else { return false }
      var withoutInsertion = inserted
      let newEntry = withoutInsertion.remove(at: index)
      // An unacknowledged insert plus an external edit is ambiguous: do not guess
      // that another process's newly added same-name reference belongs to us.
      guard sameOrder(withoutInsertion, before) else { return false }
      guard let ready = snapshot(), valid(ready), sameOrder(ready, inserted),
            let oldIndex = ready.firstIndex(where: { sameIdentity($0, item) }),
            !ready[oldIndex].isCurrent, !ready.contains(where: {
              $0.entryID == newEntry.entryID && $0.isCurrent
            }) else {
        rollback(newEntry, snapshot: snapshot, remove: remove)
        return false
      }
      var expected = ready
      expected.remove(at: oldIndex)
      remove(oldIndex)
      guard let completed = snapshot(), valid(completed), sameOrder(completed, expected) else { return false }
    }
    return true
  }

  private static func rollback(_ inserted: Entry, snapshot: () -> [Entry]?, remove: (Int) -> Void) {
    guard let current = snapshot(), valid(current),
          let index = current.firstIndex(where: { sameIdentity($0, inserted) }), !current[index].isCurrent else { return }
    remove(index)
  }

  private static func valid(_ entries: [Entry]) -> Bool {
    entries.allSatisfy { $0.entryID >= 0 } && Set(entries.map(\.entryID)).count == entries.count
  }

  private static func sameIdentity(_ lhs: Entry, _ rhs: Entry) -> Bool {
    lhs.entryID == rhs.entryID && lhs.filename == rhs.filename
  }

  private static func sameOrder(_ lhs: [Entry], _ rhs: [Entry]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(sameIdentity)
  }
}
