import Foundation
import Darwin

/// Filesystem operations are descriptor-relative and never replace an existing item.
/// Callers own permission scopes, activity leases, presentation, and clipboard state.
enum MediaFileTransfer {
  enum Operation { case copy, move }

  enum TransferError: String, LocalizedError {
    case unsupportedItem = "unsupported-item"
    case changed
    case destinationNotDirectory = "destination-not-directory"
    case recursiveDestination = "recursive-destination"
    case conflictingSelection = "conflicting-selection"
    case sameLocation = "same-location"
    case crossVolumeMove = "cross-volume-move"
    case moveIdentityChanged = "move-identity-changed"
    case sourceChangedDuringCopy = "source-changed-during-copy"
    case cleanupFailed = "cleanup-failed"

    var errorDescription: String? {
      let fallback: String
      switch self {
      case .unsupportedItem:
        fallback = "This item is not a regular file or supported folder."
      case .changed:
        fallback = "The item or its containing folder changed. Select it again before retrying."
      case .destinationNotDirectory:
        fallback = "The paste destination is not a folder."
      case .recursiveDestination:
        fallback = "A folder cannot be copied or moved into itself or one of its subfolders."
      case .conflictingSelection:
        fallback = "The selection contains duplicate names or overlapping folders. Transfer them separately."
      case .sameLocation:
        fallback = "The item is already in this folder. No files were replaced."
      case .crossVolumeMove:
        fallback = "Moving between volumes is not supported safely. Copy the item instead; the original will be kept."
      case .moveIdentityChanged:
        fallback = "The source changed during the move. Check both folders; no existing item was overwritten."
      case .sourceChangedDuringCopy:
        fallback = "The source changed while being copied. The incomplete copy was not published."
      case .cleanupFailed:
        fallback = "The temporary copy could not be cleaned. The original is safe; check the destination before retrying."
      }
      return NSLocalizedString("file-transfer.error.\(rawValue)", tableName: "PlaylistBrowser",
                               bundle: .main, value: fallback, comment: "File transfer failure")
    }
  }

  struct Source {
    let url: URL
    let isDirectory: Bool
    fileprivate let canonicalParent: URL
    fileprivate let name: String
    fileprivate let identity: Identity
    fileprivate let parentIdentity: Identity

    init(url: URL) throws {
      guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
            !url.path.contains("\0") else { throw TransferError.unsupportedItem }
      let normalized = url.standardizedFileURL
      let name = normalized.path == "/" ? "." : normalized.lastPathComponent
      guard !name.isEmpty, !name.contains("\0") else { throw TransferError.unsupportedItem }
      let value = try MediaFileTransfer.statURL(normalized)
      let type = value.st_mode & mode_t(S_IFMT)
      guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
        throw TransferError.unsupportedItem
      }
      let parent = normalized.path == "/" ? normalized : normalized.deletingLastPathComponent()
      let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
      let descriptor = try Descriptor.openDirectory(canonicalParent)
      let parentValue = try descriptor.status()
      let anchoredValue = try MediaFileTransfer.statAt(descriptor.value, name)
      guard Identity(value) == Identity(anchoredValue) else { throw TransferError.changed }
      self.url = normalized
      self.isDirectory = type == mode_t(S_IFDIR)
      self.canonicalParent = canonicalParent
      self.name = name
      self.identity = Identity(value)
      self.parentIdentity = Identity(parentValue)
    }

    func validate() throws {
      _ = try openParent()
    }

    fileprivate var canonicalURL: URL {
      canonicalParent.appendingPathComponent(name).standardizedFileURL
    }

    fileprivate func openParent() throws -> Descriptor {
      let parent = url.path == "/" ? url : url.deletingLastPathComponent()
      guard parent.resolvingSymlinksInPath().standardizedFileURL == canonicalParent else {
        throw TransferError.changed
      }
      let descriptor = try Descriptor.openDirectory(canonicalParent)
      guard Identity(try descriptor.status()) == parentIdentity,
            Identity(try MediaFileTransfer.statAt(descriptor.value, name)) == identity else {
        throw TransferError.changed
      }
      return descriptor
    }

    fileprivate func openDirectory() throws -> Descriptor {
      guard isDirectory else { throw TransferError.destinationNotDirectory }
      let parent = try openParent()
      let descriptor = try Descriptor.openAt(parent.value, name, directory: true)
      guard Identity(try descriptor.status()) == identity else { throw TransferError.changed }
      return descriptor
    }
  }

  struct Success {
    let source: URL
    let destination: URL
    let canonicalSource: URL?

    init(source: URL, destination: URL, canonicalSource: URL? = nil) {
      self.source = source
      self.destination = destination
      self.canonicalSource = canonicalSource
    }
  }
  struct Failure { let source: URL; let error: Error }
  struct Report { let successes: [Success]; let failures: [Failure] }

  static func execute(sources: [Source], destination: Source, operation: Operation) -> Report {
    var successes: [Success] = []
    var failures: [Failure] = []
    let conflicts = conflictingIndexes(sources)
    for (index, source) in sources.enumerated() {
      do {
        guard !conflicts.contains(index) else { throw TransferError.conflictingSelection }
        let canonicalSource = source.canonicalURL
        let parent = try source.openParent()
        let target = try destination.openDirectory()
        if try source.isDirectory && (isDescendant(destination.canonicalURL, of: source.canonicalURL)
          || containsAncestor(target, identity: source.identity)) {
          throw TransferError.recursiveDestination
        }
        guard source.parentIdentity != destination.identity else { throw TransferError.sameLocation }
        let published: URL
        switch operation {
        case .copy:
          published = try copy(source, parent: parent, destination: destination, target: target)
        case .move:
          published = try move(source, parent: parent, destination: destination, target: target)
        }
        successes.append(Success(source: source.url, destination: published, canonicalSource: canonicalSource))
      } catch {
        failures.append(Failure(source: source.url, error: error))
      }
    }
    return Report(successes: successes, failures: failures)
  }

  private static func conflictingIndexes(_ sources: [Source]) -> Set<Int> {
    var result: Set<Int> = []
    var names: [String: Int] = [:]
    let ordered = sources.indices.map { ($0, sources[$0].canonicalURL.pathComponents) }
      .sorted { $0.1.lexicographicallyPrecedes($1.1) }
    var ancestors: [(Int, [String])] = []
    for (index, path) in ordered {
      if let previous = names.updateValue(index, forKey: sources[index].name) {
        result.insert(previous)
        result.insert(index)
      }
      while let previous = ancestors.last,
            !path.starts(with: previous.1) { ancestors.removeLast() }
      for (ancestor, _) in ancestors {
        result.insert(ancestor)
        result.insert(index)
      }
      if sources[index].isDirectory { ancestors.append((index, path)) }
    }
    return result
  }

  private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
    let candidateParts = candidate.pathComponents, ancestorParts = ancestor.pathComponents
    return candidateParts.count >= ancestorParts.count
      && candidateParts.prefix(ancestorParts.count).elementsEqual(ancestorParts)
  }

  private static func containsAncestor(_ directory: Descriptor, identity: Identity) throws -> Bool {
    var current = try Descriptor.duplicate(directory)
    while true {
      let currentIdentity = Identity(try current.status())
      if currentIdentity == identity { return true }
      let parent = try Descriptor.openAt(current.value, "..", directory: true)
      if Identity(try parent.status()) == currentIdentity { return false }
      current = parent
    }
  }

  private static func move(_ source: Source, parent: Descriptor,
                           destination: Source, target: Descriptor) throws -> URL {
    guard source.identity.device == destination.identity.device else { throw TransferError.crossVolumeMove }
    try source.validate()
    try destination.validate()
    if renameatx_np(parent.value, source.name, target.value, source.name, UInt32(RENAME_EXCL)) != 0 {
      if errno == EXDEV { throw TransferError.crossVolumeMove }
      throw systemError(errno, url: destination.url.appendingPathComponent(source.name), writing: true)
    }
    // POSIX has no identity-conditional rename. If a non-cooperating process replaced
    // the name in the final race window, restore it only when its old name is free.
    guard Identity(try statAt(target.value, source.name)) == source.identity else {
      _ = renameatx_np(target.value, source.name, parent.value, source.name, UInt32(RENAME_EXCL))
      throw TransferError.moveIdentityChanged
    }
    return publishedURL(in: target, name: source.name, fallback: destination.url)
  }

  private static func copy(_ source: Source, parent: Descriptor,
                           destination: Source, target: Descriptor) throws -> URL {
    // The private container keeps partially copied items inaccessible even when the
    // original directory has permissive ACLs. Only the completed item is published.
    let stageName = ".chengying-transfer-\(UUID().uuidString)"
    guard mkdirat(target.value, stageName, 0o700) == 0 else {
      throw systemError(errno, url: destination.url, writing: true)
    }
    let stageIdentity = Identity(try statAt(target.value, stageName))
    do {
      let stage = try Descriptor.openAt(target.value, stageName, directory: true)
      guard Identity(try stage.status()) == stageIdentity else { throw TransferError.changed }
      let snapshot = try copyNode(parent: parent.value, name: source.name, expected: source.identity,
                                  target: stage.value, targetName: "item", rootDevice: source.identity.device)
      try verifySnapshot(snapshot, parent: parent.value, name: source.name)
      try source.validate()
      try destination.validate()
      guard renameatx_np(stage.value, "item", target.value, source.name, UInt32(RENAME_EXCL)) == 0 else {
        throw systemError(errno, url: destination.url.appendingPathComponent(source.name), writing: true)
      }
    } catch {
      do { try removeOwnedNode(parent: target.value, name: stageName, expected: stageIdentity) }
      catch { throw TransferError.cleanupFailed }
      throw error
    }
    do { try removeOwnedNode(parent: target.value, name: stageName, expected: stageIdentity) }
    catch { throw TransferError.cleanupFailed }
    // Once published, the operation is committed. A renamed destination must not
    // turn a completed move/copy into a claimed no-op or lose its refresh mapping.
    return publishedURL(in: target, name: source.name, fallback: destination.url)
  }

  private static func publishedURL(in directory: Descriptor, name: String, fallback: URL) -> URL {
    if let current = try? directory.status(), let named = try? statURL(fallback),
       Identity(current) == Identity(named) {
      return fallback.appendingPathComponent(name)
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    if fcntl(directory.value, F_GETPATH, &path) == 0,
       let current = String(validatingUTF8: path) {
      return URL(fileURLWithPath: current, isDirectory: true).appendingPathComponent(name)
    }
    return fallback.appendingPathComponent(name)
  }

  private indirect enum Snapshot {
    case file(FileState)
    case link(FileState, String)
    case directory(FileState, [String: Snapshot])
    var state: FileState {
      switch self {
      case .file(let state), .link(let state, _), .directory(let state, _): return state
      }
    }
  }

  private static func copyNode(parent: Int32, name: String, expected: Identity, target: Int32,
                               targetName: String, rootDevice: dev_t) throws -> Snapshot {
    let before = try statAt(parent, name)
    guard Identity(before) == expected else { throw TransferError.sourceChangedDuringCopy }
    let state = FileState(before)
    switch before.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFLNK):
      let link = try readLink(parent: parent, name: name)
      guard FileState(try statAt(parent, name)) == state else { throw TransferError.sourceChangedDuringCopy }
      guard symlinkat(link, target, targetName) == 0 else { throw posixError() }
      return .link(state, link)
    case mode_t(S_IFREG):
      let input = try Descriptor.openAt(parent, name, directory: false)
      guard FileState(try input.status()) == state else { throw TransferError.sourceChangedDuringCopy }
      let outputFD = openat(target, targetName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard outputFD >= 0 else { throw posixError() }
      let output = Descriptor(outputFD)
      guard fcopyfile(input.value, output.value, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
        throw posixError()
      }
      guard FileState(try input.status()) == state,
            FileState(try statAt(parent, name)) == state else { throw TransferError.sourceChangedDuringCopy }
      return .file(state)
    case mode_t(S_IFDIR):
      guard before.st_dev == rootDevice else { throw TransferError.unsupportedItem }
      let input = try Descriptor.openAt(parent, name, directory: true)
      guard FileState(try input.status()) == state else { throw TransferError.sourceChangedDuringCopy }
      guard mkdirat(target, targetName, 0o700) == 0 else { throw posixError() }
      let output = try Descriptor.openAt(target, targetName, directory: true)
      var children: [String: Snapshot] = [:]
      for child in try names(in: input) {
        let identity = Identity(try statAt(input.value, child))
        children[child] = try copyNode(parent: input.value, name: child, expected: identity,
                                       target: output.value, targetName: child, rootDevice: rootDevice)
      }
      guard FileState(try input.status()) == state,
            FileState(try statAt(parent, name)) == state else { throw TransferError.sourceChangedDuringCopy }
      guard fcopyfile(input.value, output.value, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
        throw posixError()
      }
      return .directory(state, children)
    default: throw TransferError.unsupportedItem
    }
  }

  private static func verifySnapshot(_ snapshot: Snapshot, parent: Int32, name: String) throws {
    guard FileState(try statAt(parent, name)) == snapshot.state else {
      throw TransferError.sourceChangedDuringCopy
    }
    switch snapshot {
    case .file: break
    case .link(_, let link):
      guard try readLink(parent: parent, name: name) == link else { throw TransferError.sourceChangedDuringCopy }
    case .directory(_, let children):
      let directory = try Descriptor.openAt(parent, name, directory: true)
      guard FileState(try directory.status()) == snapshot.state,
            Set(try names(in: directory)) == Set(children.keys) else { throw TransferError.sourceChangedDuringCopy }
      for (child, snapshot) in children {
        try verifySnapshot(snapshot, parent: directory.value, name: child)
      }
      guard FileState(try directory.status()) == snapshot.state else { throw TransferError.sourceChangedDuringCopy }
    }
  }

  /// This is only used for the newly created private staging tree, never sources.
  private static func removeOwnedNode(parent: Int32, name: String, expected: Identity) throws {
    let value = try statAt(parent, name)
    guard Identity(value) == expected else { throw TransferError.changed }
    if value.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) {
      let descriptorFD = openat(parent, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptorFD >= 0 else { throw posixError() }
      let descriptor = Descriptor(descriptorFD)
      guard Identity(try descriptor.status()) == expected else { throw TransferError.changed }
      // Only newly created private staging nodes reach this code. Source metadata
      // and completed destination items are never relaxed for cleanup.
      if value.st_flags != 0 && fchflags(descriptor.value, 0) != 0 { throw posixError() }
      guard let emptyACL = acl_init(0) else { throw posixError() }
      defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
      if acl_set_fd_np(descriptor.value, emptyACL, ACL_TYPE_EXTENDED) != 0 && errno != ENOTSUP {
        throw posixError()
      }
      guard fchmod(descriptor.value, 0o700) == 0 else { throw posixError() }
    }
    if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
      let directory = try Descriptor.openAt(parent, name, directory: true)
      guard Identity(try directory.status()) == expected else { throw TransferError.changed }
      for child in try names(in: directory) {
        try removeOwnedNode(parent: directory.value, name: child, expected: Identity(try statAt(directory.value, child)))
      }
      guard Identity(try statAt(parent, name)) == expected,
            unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixError() }
    } else {
      guard unlinkat(parent, name, 0) == 0 else { throw posixError() }
    }
  }

  fileprivate struct Identity: Equatable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      kind = value.st_mode & mode_t(S_IFMT)
      birthSeconds = value.st_birthtimespec.tv_sec
      birthNanoseconds = value.st_birthtimespec.tv_nsec
    }
  }

  private struct FileState: Equatable {
    let identity: Identity
    let size: off_t
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ value: stat) {
      identity = Identity(value)
      size = value.st_size
      mode = value.st_mode
      modifiedSeconds = value.st_mtimespec.tv_sec
      modifiedNanoseconds = value.st_mtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec
      changedNanoseconds = value.st_ctimespec.tv_nsec
    }
  }

  fileprivate final class Descriptor {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
    func status() throws -> stat {
      var result = stat()
      guard fstat(value, &result) == 0 else { throw MediaFileTransfer.posixError() }
      return result
    }
    static func openDirectory(_ url: URL) throws -> Descriptor {
      let result = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard result >= 0 else { throw MediaFileTransfer.systemError(errno, url: url, writing: false) }
      return Descriptor(result)
    }
    static func openAt(_ parent: Int32, _ name: String, directory: Bool) throws -> Descriptor {
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
      let result = openat(parent, name, flags)
      guard result >= 0 else { throw MediaFileTransfer.posixError() }
      return Descriptor(result)
    }
    static func duplicate(_ descriptor: Descriptor) throws -> Descriptor {
      let result = fcntl(descriptor.value, F_DUPFD_CLOEXEC, 0)
      guard result >= 0 else { throw MediaFileTransfer.posixError() }
      return Descriptor(result)
    }
  }

  private static func statURL(_ url: URL) throws -> stat {
    var result = stat()
    guard lstat(url.path, &result) == 0 else { throw systemError(errno, url: url, writing: false) }
    return result
  }

  private static func statAt(_ parent: Int32, _ name: String) throws -> stat {
    var result = stat()
    guard fstatat(parent, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
    return result
  }

  private static func names(in directory: Descriptor) throws -> [String] {
    // Open a new description: dup would share the directory stream offset.
    let scan = try Descriptor.openAt(directory.value, ".", directory: true)
    let duplicate = dup(scan.value)
    guard duplicate >= 0 else { throw posixError() }
    guard let stream = fdopendir(duplicate) else { close(duplicate); throw posixError() }
    defer { closedir(stream) }
    var result: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw posixError() }
        return result
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
      }
      guard let name = name else { throw TransferError.unsupportedItem }
      if name != "." && name != ".." { result.append(name) }
    }
  }

  private static func readLink(parent: Int32, name: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(parent, name, &buffer, buffer.count - 1)
    guard count >= 0 else { throw posixError() }
    guard count < buffer.count - 1, let result = String(validatingUTF8: buffer) else {
      throw TransferError.unsupportedItem
    }
    return result
  }

  private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

  private static func systemError(_ code: Int32, url: URL, writing: Bool) -> NSError {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    let cocoa: CocoaError.Code
    switch code {
    case EEXIST: cocoa = .fileWriteFileExists
    case ENOENT: cocoa = .fileNoSuchFile
    case EACCES, EPERM: cocoa = writing ? .fileWriteNoPermission : .fileReadNoPermission
    case ENOSPC: cocoa = .fileWriteOutOfSpace
    case EROFS: cocoa = .fileWriteVolumeReadOnly
    default: cocoa = writing ? .fileWriteUnknown : .fileReadUnknown
    }
    return NSError(domain: NSCocoaErrorDomain, code: cocoa.rawValue,
                   userInfo: [NSUnderlyingErrorKey: underlying, NSFilePathErrorKey: url.path])
  }
}
