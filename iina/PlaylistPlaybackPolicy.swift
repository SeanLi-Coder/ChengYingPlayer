//
//  PlaylistPlaybackPolicy.swift
//  ChengYingPlayer
//

import Foundation

/// Shared, testable rules for local folder loading and non-destructive playlist ordering.
enum PlaylistPlaybackPolicy {
  struct Move: Equatable {
    let from: Int
    let to: Int
  }

  static func isDirectory(_ url: URL) -> Bool {
    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  /// Only direct, visible regular files belong to a folder's automatic playlist.
  static func regularFiles(in folder: URL, extensions: Set<String>? = nil) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]) else { return [] }
    return contents.filter { url in
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
            values.isRegularFile == true, values.isHidden != true else { return false }
      return extensions.map { $0.contains(url.pathExtension.lowercased()) } ?? true
    }.map { folder.appendingPathComponent($0.lastPathComponent, isDirectory: false) }
      .sorted(by: naturalNameOrder)
  }

  static func naturalNameOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
    return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
  }

  /// Preserve explicit multi-selection order; only folder contents receive an automatic sort.
  static func playableFiles(in urls: [URL], videoExtensions: Set<String>,
                            blacklistedExtensions: Set<String>) -> [URL] {
    var seen = Set<URL>()
    var result: [URL] = []
    for url in urls {
      let candidates: [URL]
      if url.isFileURL && (url.hasDirectoryPath || isDirectory(url)) {
        candidates = regularFiles(in: url, extensions: videoExtensions)
      } else if !url.isFileURL || !blacklistedExtensions.contains(url.pathExtension.lowercased()) {
        candidates = [url]
      } else {
        candidates = []
      }
      for candidate in candidates {
        let identity = candidate.isFileURL ? candidate.standardizedFileURL : candidate
        if seen.insert(identity).inserted { result.append(candidate) }
      }
    }
    return result
  }

  static func shouldAutoLoadSiblings(inputURLs: [URL], playableFileCount: Int, requested: Bool) -> Bool {
    guard requested, inputURLs.count == 1, playableFileCount == 1,
          let url = inputURLs.first, url.isFileURL else { return false }
    return !url.hasDirectoryPath && !isDirectory(url)
  }

  /// A stale snapshot must not overwrite a newer manual edit, even if it contains the same entries.
  /// Moves always go toward the front, matching mpv's insertion-before-target semantics exactly.
  static func moves(from currentIDs: [Int64], to desiredIDs: [Int64],
                    expectedIDs: [Int64]) -> [Move]? {
    guard currentIDs == expectedIDs, currentIDs.count == desiredIDs.count,
          currentIDs.allSatisfy({ $0 >= 0 }), desiredIDs.allSatisfy({ $0 >= 0 }),
          Set(currentIDs).count == currentIDs.count,
          Set(desiredIDs).count == desiredIDs.count,
          Set(currentIDs) == Set(desiredIDs) else { return nil }
    var working = currentIDs
    var result: [Move] = []
    for target in desiredIDs.indices where working[target] != desiredIDs[target] {
      guard let source = working[(target + 1)...].firstIndex(of: desiredIDs[target]) else { return nil }
      result.append(Move(from: source, to: target))
      working.insert(working.remove(at: source), at: target)
    }
    return result
  }

  /// Recheck the live order before every command. A changed playlist aborts without reloading media.
  static func reorder(to desiredIDs: [Int64], expectedIDs: [Int64],
                      readIDs: () -> [Int64]?, move: (Move) -> Bool) -> Bool {
    guard let currentIDs = readIDs(),
          let plan = moves(from: currentIDs, to: desiredIDs, expectedIDs: expectedIDs) else { return false }
    var working = currentIDs
    for step in plan {
      guard readIDs() == working, move(step) else { return false }
      working.insert(working.remove(at: step.from), at: step.to)
    }
    return readIDs() == desiredIDs
  }
}
