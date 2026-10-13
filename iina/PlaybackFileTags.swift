import Foundation
import Darwin

/// Finder tag editing for a single explicitly selected local media file.
/// All filesystem work runs off the main thread; callbacks run on the main queue.
/// No media data, FinderInfo flags, other attributes, or filesystem permissions are written.
enum PlaybackFileTags {
  struct Tag: Equatable {
    let name: String
    let colorIndex: Int
    fileprivate let storedValue: String

    fileprivate init(_ value: String) {
      storedValue = value
      if let separator = value.range(of: "\n", options: .backwards),
         let index = Int(value[separator.upperBound...]),
         value[separator.upperBound...].count == 1, (0...7).contains(index) {
        name = String(value[..<separator.lowerBound])
        colorIndex = index
      } else {
        name = value
        colorIndex = 0
      }
    }
  }

  final class Snapshot {
    let url: URL
    let tags: [Tag]
    /// Legacy FinderInfo label, independent of modern named tags. Nil means unknown.
    let legacyColor: Int?
    var colors: Set<Int> { Set(tags.map(\.colorIndex).filter { $0 != 0 }) }
    fileprivate let descriptor: Descriptor
    fileprivate let identity: FileIdentity
    fileprivate let attribute: Data?

    fileprivate init(url: URL, descriptor: Descriptor, identity: FileIdentity,
                     attribute: Data?, tags: [Tag], legacyColor: Int?) {
      self.url = url
      self.descriptor = descriptor
      self.identity = identity
      self.attribute = attribute
      self.tags = tags
      self.legacyColor = legacyColor
    }
  }

  enum Mutation {
    case addColor(Int, name: String)
    case removeTag(Tag)
  }

  enum TagError: String, Error {
    case unsupportedURL = "unsupported-url"
    case unsupportedFile = "unsupported-file"
    case changed
    case invalidMetadata = "invalid-metadata"
    case metadataTooLarge = "metadata-too-large"
    case invalidTag = "invalid-tag"
    case nameConflict = "name-conflict"
    case permissionDenied = "permission-denied"
    case readOnly = "read-only"
    case unavailable
    case writeUnverified = "write-unverified"
  }

  private static let worker = DispatchQueue(label: "io.chengying.playback-file-tags", qos: .utility)
  private static let attributeName = "com.apple.metadata:_kMDItemUserTags"
  private static let maximumAttributeBytes = 1_048_576
  private static let maximumTagCount = 4096
  private static let maximumTagBytes = 8192
  private(set) static var pendingWriteCount = 0

  static func read(url: URL, completion: @escaping (Result<Snapshot, TagError>) -> Void) {
    worker.async {
      let result = resultOf {
        let target = try normalizedLocalURL(url)
        let scoped = target.startAccessingSecurityScopedResource()
        defer { if scoped { target.stopAccessingSecurityScopedResource() } }
        let descriptor = try openFile(target)
        let identity = try FileIdentity(descriptor.status())
        let attribute = try readAttribute(descriptor)
        let tags = try decode(attribute)
        let legacyColor = try readLegacyColor(descriptor)
        try validatePath(target, descriptor: descriptor, identity: identity)
        return Snapshot(url: target, descriptor: descriptor, identity: identity,
                        attribute: attribute, tags: tags, legacyColor: legacyColor)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  static func apply(_ mutation: Mutation, to snapshot: Snapshot,
                    completion: @escaping (Result<Snapshot, TagError>) -> Void) {
    precondition(Thread.isMainThread)
    pendingWriteCount += 1
    worker.async {
      let result = resultOf {
        let scoped = snapshot.url.startAccessingSecurityScopedResource()
        defer { if scoped { snapshot.url.stopAccessingSecurityScopedResource() } }
        try validatePath(snapshot.url, descriptor: snapshot.descriptor, identity: snapshot.identity)
        guard try readAttribute(snapshot.descriptor) == snapshot.attribute else { throw TagError.changed }
        var tags = snapshot.tags
        switch mutation {
        case .addColor(let index, let name):
          guard (1...7).contains(index), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !name.contains("\0"), !name.contains("\n"), !name.contains("\r"),
                name.utf8.count <= maximumTagBytes - 2 else { throw TagError.invalidTag }
          if tags.contains(where: { $0.colorIndex == index }) { return snapshot }
          guard !tags.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            throw TagError.nameConflict
          }
          tags.append(Tag(name + "\n" + String(index)))
        case .removeTag(let tag):
          guard tags.contains(tag) else { throw TagError.changed }
          // A menu item identifies an exact stored tag, not all tags of that color.
          tags.removeAll { $0 == tag }
        }
        guard tags.count <= maximumTagCount else { throw TagError.metadataTooLarge }
        let data = try PropertyListSerialization.data(fromPropertyList: tags.map(\.storedValue),
                                                     format: .binary, options: 0)
        guard data.count <= maximumAttributeBytes else { throw TagError.metadataTooLarge }
        try validatePath(snapshot.url, descriptor: snapshot.descriptor, identity: snapshot.identity)
        guard try readAttribute(snapshot.descriptor) == snapshot.attribute else { throw TagError.changed }

        #if PLAYBACK_FILE_TAG_TESTING
        testBeforeWrite?()
        try validatePath(snapshot.url, descriptor: snapshot.descriptor, identity: snapshot.identity)
        guard try readAttribute(snapshot.descriptor) == snapshot.attribute else { throw TagError.changed }
        #endif

        // The descriptor pins the original inode even if the path changes during this syscall.
        // xattrs have no compare-and-swap primitive: the preceding check detects observed
        // external changes, not a simultaneous Finder write inside this final syscall window.
        let status = data.withUnsafeBytes {
          fsetxattr(snapshot.descriptor.value, attributeName, $0.baseAddress, $0.count, 0,
                    snapshot.attribute == nil ? XATTR_CREATE : XATTR_REPLACE)
        }
        guard status == 0 else { throw systemError(errno) }
        #if PLAYBACK_FILE_TAG_TESTING
        testAfterWrite?()
        #endif
        do {
          guard try readAttribute(snapshot.descriptor) == data else { throw TagError.writeUnverified }
          try validatePath(snapshot.url, descriptor: snapshot.descriptor, identity: snapshot.identity)
          return Snapshot(url: snapshot.url, descriptor: snapshot.descriptor, identity: snapshot.identity,
                          attribute: data, tags: tags, legacyColor: try readLegacyColor(snapshot.descriptor))
        } catch {
          // Do not roll back over concurrent Finder edits after a successful system write.
          throw TagError.writeUnverified
        }
      }
      DispatchQueue.main.async {
        pendingWriteCount -= 1
        completion(result)
      }
    }
  }

  #if PLAYBACK_FILE_TAG_TESTING
  // Called on the serial worker, before the final identity/attribute check.
  static var testBeforeWrite: (() -> Void)?
  static var testAfterWrite: (() -> Void)?
  #endif

  private static func normalizedLocalURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
          !url.path.contains("\0"), url.query == nil, url.fragment == nil,
          url.path.hasPrefix("/") else { throw TagError.unsupportedURL }
    let normalized = url.standardizedFileURL
    guard normalized.path != "/" else { throw TagError.unsupportedFile }
    return normalized
  }

  /// Walk every path component without following a symbolic link or opening special files.
  private static func openFile(_ url: URL) throws -> Descriptor {
    let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard root >= 0 else { throw systemError(errno) }
    var current = Descriptor(root)
    let components = url.pathComponents.dropFirst()
    for (index, component) in components.enumerated() {
      let directory = index != components.count - 1
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
      let next = openat(current.value, component, flags)
      guard next >= 0 else { throw systemError(errno) }
      current = Descriptor(next)
    }
    _ = try FileIdentity(current.status())
    return current
  }

  private static func validatePath(_ url: URL, descriptor: Descriptor, identity: FileIdentity) throws {
    guard try FileIdentity(descriptor.status()) == identity else { throw TagError.changed }
    let current = try openFile(url)
    guard try FileIdentity(current.status()) == identity else { throw TagError.changed }
  }

  private static func readAttribute(_ descriptor: Descriptor) throws -> Data? {
    for _ in 0..<3 {
      let count = fgetxattr(descriptor.value, attributeName, nil, 0, 0, 0)
      if count < 0 {
        if errno == ENOATTR { return nil }
        throw systemError(errno)
      }
      guard count <= maximumAttributeBytes else { throw TagError.metadataTooLarge }
      guard count > 0 else { throw TagError.invalidMetadata }
      var data = Data(count: count)
      let result = data.withUnsafeMutableBytes {
        fgetxattr(descriptor.value, attributeName, $0.baseAddress, $0.count, 0, 0)
      }
      if result >= 0 {
        data.count = result
        return data
      }
      if errno != ERANGE { throw systemError(errno) }
    }
    throw TagError.changed
  }

  private static func decode(_ data: Data?) throws -> [Tag] {
    guard let data else { return [] }
    guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let entries = value as? [String] else { throw TagError.invalidMetadata }
    guard entries.count <= maximumTagCount else { throw TagError.metadataTooLarge }
    return try entries.map {
      guard !$0.isEmpty, !$0.contains("\0") else { throw TagError.invalidMetadata }
      guard $0.utf8.count <= maximumTagBytes else { throw TagError.metadataTooLarge }
      let tag = Tag($0)
      guard !tag.name.isEmpty else { throw TagError.invalidMetadata }
      return tag
    }
  }

  private static func readLegacyColor(_ descriptor: Descriptor) throws -> Int? {
    var bytes = [UInt8](repeating: 0, count: 32)
    let count = fgetxattr(descriptor.value, "com.apple.FinderInfo", &bytes, bytes.count, 0, 0)
    if count == 32 { return Int((bytes[9] & 0x0e) >> 1) }
    if count >= 0 || errno == ERANGE { return nil }
    if errno == ENOATTR { return 0 }
    throw systemError(errno)
  }

  fileprivate struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let birth: timespec
    let modified: timespec
    let size: off_t

    init(_ value: stat) throws {
      guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1 else {
        throw TagError.unsupportedFile
      }
      device = value.st_dev
      inode = value.st_ino
      birth = value.st_birthtimespec
      modified = value.st_mtimespec
      size = value.st_size
    }
    static func == (left: Self, right: Self) -> Bool {
      left.device == right.device && left.inode == right.inode && left.size == right.size &&
        left.birth.tv_sec == right.birth.tv_sec && left.birth.tv_nsec == right.birth.tv_nsec &&
        left.modified.tv_sec == right.modified.tv_sec && left.modified.tv_nsec == right.modified.tv_nsec
    }
  }

  fileprivate final class Descriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
    func status() throws -> stat {
      var result = stat()
      guard fstat(value, &result) == 0 else { throw systemError(errno) }
      return result
    }
  }

  private static func systemError(_ code: Int32) -> TagError {
    switch code {
    case EACCES, EPERM: return .permissionDenied
    case EROFS: return .readOnly
    case ENOENT, ENOTDIR, EEXIST, ENOATTR: return .changed
    case ELOOP: return .unsupportedFile
    default: return .unavailable
    }
  }

  private static func resultOf(_ body: () throws -> Snapshot) -> Result<Snapshot, TagError> {
    do { return .success(try body()) }
    catch let error as TagError { return .failure(error) }
    catch { return .failure(.unavailable) }
  }
}
