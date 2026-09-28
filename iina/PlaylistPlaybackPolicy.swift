//
//  PlaylistPlaybackPolicy.swift
//  ChengYingPlayer
//

import Foundation

enum LoopMode {
  case off
  case file
  case playlist

  func next() -> LoopMode {
    switch self {
    case .off: return .file
    case .file: return .playlist
    case .playlist: return .off
    }
  }

  /// Recognize the standard three-state shortcuts without interpreting arbitrary mpv scripts.
  /// Finite counts and compound commands remain untouched for advanced configurations.
  static func fromKeyBinding(_ tokens: [String], current: LoopMode) -> LoopMode? {
    var args = tokens
    while let first = args.first, ["no-osd", "osd-auto", "osd-bar", "osd-msg", "osd-msg-bar"].contains(first) {
      args.removeFirst()
    }
    guard args.count >= 2 else { return nil }
    let backwards = args[0] == "cycle-values" && args[1] == "!reverse"
    if backwards { args.remove(at: 1) }
    guard args.count >= 2 else { return nil }
    let property = args[1]
    guard ["loop", "loop-file", "loop-playlist"].contains(property) else { return nil }
    let enabled: LoopMode = property == "loop-playlist" ? .playlist : .file
    func value(_ token: String) -> String {
      if token.count >= 2, let first = token.first, let last = token.last,
         (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        return String(token.dropFirst().dropLast())
      }
      return token
    }
    func mode(_ token: String) -> LoopMode? {
      switch value(token) {
      case "no", "0": return .off
      case "inf": return enabled
      default: return nil
      }
    }
    switch args[0] {
    case "set" where args.count == 3:
      guard let requested = mode(args[2]) else { return nil }
      return requested == .off && current != enabled ? current : requested
    case "cycle" where args.count == 2 || (args.count == 3 && ["up", "down"].contains(args[2])):
      return current == enabled ? .off : enabled
    case "cycle-values" where args.count >= 4:
      let values = Array(args.dropFirst(2))
      let modes = values.compactMap(mode)
      guard modes.count == values.count, modes.count >= 2, Set(modes).count == 2 else { return nil }
      let effective = current == enabled ? enabled : .off
      guard let index = modes.firstIndex(of: effective) else { return modes.first }
      return modes[(index + (backwards ? modes.count - 1 : 1)) % modes.count]
    default:
      return nil
    }
  }
}

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
