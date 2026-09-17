import Foundation
import Darwin

/// Finder color indices are 0 (none), 1 (gray), 2 (green), 3 (purple),
/// 4 (blue), 5 (yellow), 6 (red), and 7 (orange).
struct PlaylistFileTag: Equatable {
  let name: String
  let colorIndex: Int

  init(name: String, colorIndex: Int = 0) {
    self.name = name
    self.colorIndex = (0...7).contains(colorIndex) ? colorIndex : 0
  }
}

enum PlaylistFileSortKey: String, CaseIterable {
  case name, size, modified, created
}

/// Color matching uses Finder metadata, never the user-editable tag name.
enum PlaylistTagFilter: Equatable, CaseIterable {
  case all
  case untagged
  case color(Int)

  static let allCases: [PlaylistTagFilter] = [
    .all, .color(6), .color(7), .color(5), .color(2),
    .color(4), .color(3), .color(1), .color(0), .untagged,
  ]

  func includes(_ metadata: PlaylistFileMetadata?) -> Bool {
    switch self {
    case .all:
      return true
    case .untagged:
      return metadata?.tags.isEmpty ?? false
    case .color(let index):
      guard (0...7).contains(index), let metadata else { return false }
      return metadata.tags.contains { $0.colorIndex == index }
    }
  }
}

/// A read-only snapshot, independent of playback state and playlist item identity.
struct PlaylistFileMetadata: Equatable {
  let url: URL
  let name: String
  let fileSize: Int64?
  let modificationDate: Date?
  let creationDate: Date?
  let tags: [PlaylistFileTag]

  init(url: URL, name: String? = nil, fileSize: Int64? = nil,
       modificationDate: Date? = nil, creationDate: Date? = nil,
       tags: [PlaylistFileTag] = []) {
    self.url = url
    self.name = name ?? url.lastPathComponent
    self.fileSize = fileSize.flatMap { $0 >= 0 ? $0 : nil }
    self.modificationDate = Self.validDate(modificationDate)
    self.creationDate = Self.validDate(creationDate)
    self.tags = tags
  }

  static func read(from url: URL) -> PlaylistFileMetadata {
    guard url.isFileURL, !url.path.contains("\0"),
          url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
      return PlaylistFileMetadata(url: url)
    }

    // A fresh URL avoids retaining previously cached resource values after Finder edits.
    let freshURL = URL(fileURLWithPath: url.path)
    let values = try? freshURL.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ])

    // Tags are intentionally read separately; unsupported tag metadata must never
    // discard otherwise available size or date values.
    let tags: [PlaylistFileTag]
    if let storedTags = readStoredTags(from: freshURL), !storedTags.isEmpty {
      tags = storedTags
    } else {
      let tagValues = try? freshURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey, .localizedLabelKey])
      tags = Self.tags(fromResourceNames: tagValues?.tagNames ?? [], labelNumber: tagValues?.labelNumber ?? 0,
                       localizedLabel: tagValues?.localizedLabel)
    }

    return PlaylistFileMetadata(
      url: url,
      fileSize: values?.fileSize.map(Int64.init),
      modificationDate: values?.contentModificationDate,
      creationDate: values?.creationDate,
      tags: tags
    )
  }

  /// Unknown primary values sort last in either direction. Equal primary values
  /// use natural name order, then the full path, then their original index.
  /// Returning indices preserves distinct playlist occurrences of the same file.
  static func sortedIndices(for items: [PlaylistFileMetadata], by key: PlaylistFileSortKey = .name,
                            ascending: Bool = true) -> [Int] {
    items.indices.sorted { leftIndex, rightIndex in
      let left = items[leftIndex]
      let right = items[rightIndex]
      let primary: ComparisonResult
      switch key {
      case .name:
        primary = compareOptional(left.name.isEmpty ? nil : left.name,
                                  right.name.isEmpty ? nil : right.name,
                                  ascending: ascending) { $0.localizedStandardCompare($1) }
      case .size:
        primary = compareOptional(left.fileSize, right.fileSize, ascending: ascending, compare: compareValues)
      case .modified:
        primary = compareOptional(left.modificationDate, right.modificationDate,
                                  ascending: ascending, compare: compareValues)
      case .created:
        primary = compareOptional(left.creationDate, right.creationDate,
                                  ascending: ascending, compare: compareValues)
      }
      if primary != .orderedSame { return primary == .orderedAscending }
      let nameOrder = left.name.localizedStandardCompare(right.name)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      let pathOrder = left.sortPath.compare(right.sortPath, options: .literal)
      if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
      return leftIndex < rightIndex
    }
  }

  /// Decode the final color suffix only. Earlier newlines belong to the tag name.
  static func tags(fromPropertyList data: Data) -> [PlaylistFileTag]? {
    guard let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let entries = propertyList as? [Any] else { return nil }
    return entries.compactMap { entry in
      guard let storedName = entry as? String, !storedName.isEmpty else { return nil }
      if let separator = storedName.range(of: "\n", options: .backwards) {
        let suffix = String(storedName[separator.upperBound...])
        if suffix.count == 1, let color = Int(suffix), (0...7).contains(color) {
          let name = String(storedName[..<separator.lowerBound])
          return name.isEmpty ? nil : PlaylistFileTag(name: name, colorIndex: color)
        }
      }
      return PlaylistFileTag(name: storedName)
    }
  }

  /// Older Finder labels may have a color without the modern named-tag attribute.
  /// Preserve that color while avoiding a synthetic tag for an unlabeled file.
  static func tags(fromResourceNames names: [String], labelNumber: Int,
                   localizedLabel: String?) -> [PlaylistFileTag] {
    let nonemptyNames = names.filter { !$0.isEmpty }
    if !nonemptyNames.isEmpty {
      return nonemptyNames.map {
        PlaylistFileTag(name: $0, colorIndex: nonemptyNames.count == 1 ? labelNumber : 0)
      }
    }
    guard (1...7).contains(labelNumber) else { return [] }
    let colorNames = [
      ("gray", "Gray"), ("green", "Green"), ("purple", "Purple"), ("blue", "Blue"),
      ("yellow", "Yellow"), ("red", "Red"), ("orange", "Orange"),
    ]
    let colorName = colorNames[labelNumber - 1]
    let fallbackName = NSLocalizedString("filter." + colorName.0, tableName: "PlaylistBrowser", bundle: .main,
                                        value: colorName.1, comment: "Finder label color")
    let label = localizedLabel.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    return [PlaylistFileTag(name: label ?? fallbackName, colorIndex: labelNumber)]
  }

  private var sortPath: String {
    url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
  }

  private static func validDate(_ date: Date?) -> Date? {
    date.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
  }

  private static func compareValues<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
    if left == right { return .orderedSame }
    return left < right ? .orderedAscending : .orderedDescending
  }

  private static func compareOptional<T>(_ left: T?, _ right: T?, ascending: Bool,
                                         compare: (T, T) -> ComparisonResult) -> ComparisonResult {
    switch (left, right) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (left?, right?):
      let result = compare(left, right)
      guard !ascending else { return result }
      switch result {
      case .orderedAscending: return .orderedDescending
      case .orderedDescending: return .orderedAscending
      case .orderedSame: return .orderedSame
      }
    }
  }

  private static func readStoredTags(from url: URL) -> [PlaylistFileTag]? {
    let attributeName = "com.apple.metadata:_kMDItemUserTags"
    let maximumAttributeBytes = 1_048_576
    return url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return nil }
      // Finder may update the attribute between the size probe and the read.
      for _ in 0..<3 {
        let count = getxattr(path, attributeName, nil, 0, 0, 0)
        guard count > 0, count <= maximumAttributeBytes else { return nil }
        var data = Data(count: count)
        let (actualCount, readError) = data.withUnsafeMutableBytes { buffer in
          let result = getxattr(path, attributeName, buffer.baseAddress, buffer.count, 0, 0)
          return (result, errno)
        }
        if actualCount >= 0 {
          data.count = actualCount
          return tags(fromPropertyList: data)
        }
        if readError != ERANGE { return nil }
      }
      return nil
    }
  }
}
