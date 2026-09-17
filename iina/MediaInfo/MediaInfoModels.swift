import Foundation

func mediaInfoText(_ key: String, _ fallback: String) -> String {
  NSLocalizedString(key, tableName: "MediaInfo", bundle: .main, value: fallback, comment: "Media information")
}

struct MediaInfoRow: Equatable {
  let id: String
  let label: String
  let value: String
}

struct MediaInfoSection: Equatable {
  let id: String
  let title: String
  let rows: [MediaInfoRow]
}

struct MediaInfoContent: Equatable {
  let sections: [MediaInfoSection]
  var notes: [String] = []
}

enum MediaInfoKind {
  case video, image
}

extension Notification.Name {
  static let chengyingImageSourceChanged = Notification.Name("ChengYingImageSourceChanged")
  static let chengyingMediaSourceChanged = Notification.Name("ChengYingMediaSourceChanged")
}

struct MediaInfoSnapshot {
  let url: URL
  let kind: MediaInfoKind
  let content: MediaInfoContent

  var plainText: String {
    ([url.lastPathComponent] + content.sections.map { section in
      section.title + "\n" + section.rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    } + content.notes).joined(separator: "\n\n")
  }
}

enum MediaInfoError: LocalizedError {
  case cancelled
  case invalidSource
  case changedSource
  case unavailable(String)
  case readFailed(String)

  var errorDescription: String? {
    switch self {
    case .cancelled: return mediaInfoText("error.cancelled", "Reading was cancelled.")
    case .invalidSource: return mediaInfoText("error.local_file", "Open an existing local video or image first.")
    case .changedSource: return mediaInfoText("error.changed", "The file changed while reading. Refresh to read its current information.")
    case .unavailable(let detail), .readFailed(let detail): return detail
    }
  }
}

/// Readers check the token without accessing or retaining any AppKit objects.
final class MediaInfoCancellation {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func check() throws {
    if isCancelled { throw MediaInfoError.cancelled }
  }
}

enum MediaInfoValue {
  static var unknown: String { mediaInfoText("value.unknown", "Not provided") }

  static func text(_ value: String?) -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return unknown }
    return String(value.prefix(4096))
  }
}

/// Compare source identity before and after the background metadata read.
struct MediaInfoFileIdentity: Equatable {
  let device: UInt64
  let inode: UInt64
  let size: UInt64
  let modified: Date

  init(url: URL) throws {
    var currentURL = url
    currentURL.removeAllCachedResourceValues()
    guard url.isFileURL,
          (try? currentURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw MediaInfoError.invalidSource
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          let size = attributes[.size] as? NSNumber,
          let modified = attributes[.modificationDate] as? Date else {
      throw MediaInfoError.invalidSource
    }
    self.device = device.uint64Value
    self.inode = inode.uint64Value
    self.size = size.uint64Value
    self.modified = modified
  }
}

enum MediaInfoFileDetails {
  static func section(url: URL) throws -> MediaInfoSection {
    // URL resource values are cached; Refresh must inspect the file as it exists now.
    var currentURL = url
    currentURL.removeAllCachedResourceValues()
    let values = try currentURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
    let date = DateFormatter()
    date.dateStyle = .medium
    date.timeStyle = .medium
    let size = values.fileSize.map { bytes in
      ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " (" +
        String(format: mediaInfoText("file.exact_bytes", "%@ bytes"), String(bytes)) + ")"
    } ?? MediaInfoValue.unknown
    return MediaInfoSection(id: "file", title: mediaInfoText("section.file", "File"), rows: [
      MediaInfoRow(id: "file.name", label: mediaInfoText("file.name", "Name"), value: url.lastPathComponent),
      MediaInfoRow(id: "file.path", label: mediaInfoText("file.path", "Location"), value: url.path),
      MediaInfoRow(id: "file.size", label: mediaInfoText("file.size", "File size"), value: size),
      MediaInfoRow(id: "file.created", label: mediaInfoText("file.created", "Created"), value: values.creationDate.map(date.string) ?? MediaInfoValue.unknown),
      MediaInfoRow(id: "file.modified", label: mediaInfoText("file.modified", "Modified"), value: values.contentModificationDate.map(date.string) ?? MediaInfoValue.unknown),
    ])
  }
}
