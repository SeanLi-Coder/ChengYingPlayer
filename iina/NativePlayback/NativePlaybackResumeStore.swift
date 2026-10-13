import Foundation
import Darwin

struct NativePlaybackResumeTicket: Equatable {
  let digest: String
  let owner: UUID
  let mediaGeneration: UInt64
  fileprivate let storeID: UUID
  fileprivate let serial: UInt64
  fileprivate let epoch: UInt64

  fileprivate init(digest: String, owner: UUID, mediaGeneration: UInt64,
                   storeID: UUID, serial: UInt64, epoch: UInt64) {
    self.digest = digest
    self.owner = owner
    self.mediaGeneration = mediaGeneration
    self.storeID = storeID
    self.serial = serial
    self.epoch = epoch
  }
}

enum NativePlaybackResumeResult: Equatable {
  case saved
  case conflict
  case stale
  case disabled
  case ioError(Int32)
}

enum NativePlaybackResumeClearResult: Equatable {
  case cleared
  case ioError(Int32)
}

/// Pure ownership policy. The store serializes access with its publication lock.
struct NativePlaybackResumePolicy {
  private let storeID = UUID()
  private var enabled: Bool
  private var epoch: UInt64 = 0
  private var serial: UInt64 = 0
  private var latest: [String: NativePlaybackResumeTicket] = [:]
  private var clearing: Set<UUID> = []

  init(enabled: Bool) { self.enabled = enabled }

  static func isCanonicalDigest(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...70).contains($0)
    }
  }

  static func record(position: Double, speed: Double) -> Data? {
    guard position.isFinite, position >= 0, speed.isFinite, (0.5...2).contains(speed) else { return nil }
    // Swift's Double conversion is locale-independent. Never include media paths,
    // volume, temporary preview loops, or any other per-player state.
    return Data("start=\(position == 0 ? 0.0 : position)\nspeed=\(speed)\n".utf8)
  }

  mutating func begin(digest: String, owner: UUID, mediaGeneration: UInt64) -> NativePlaybackResumeTicket? {
    guard enabled, clearing.isEmpty, Self.isCanonicalDigest(digest),
          serial < UInt64.max, epoch < UInt64.max else { return nil }
    serial += 1
    let ticket = NativePlaybackResumeTicket(digest: digest, owner: owner, mediaGeneration: mediaGeneration,
                                          storeID: storeID, serial: serial, epoch: epoch)
    latest[digest] = ticket
    return ticket
  }

  func rejection(for ticket: NativePlaybackResumeTicket) -> NativePlaybackResumeResult? {
    guard enabled else { return .disabled }
    guard clearing.isEmpty, ticket.storeID == storeID, ticket.epoch == epoch,
          latest[ticket.digest] == ticket else { return .stale }
    return nil
  }

  mutating func invalidate(_ ticket: NativePlaybackResumeTicket) {
    if latest[ticket.digest] == ticket { latest.removeValue(forKey: ticket.digest) }
  }

  mutating func setEnabled(_ value: Bool) {
    enabled = value
    if !value { invalidateAll() }
  }

  mutating func beginClear() -> UUID {
    let identifier = UUID()
    clearing.insert(identifier)
    invalidateAll()
    return identifier
  }

  mutating func endClear(_ identifier: UUID) { clearing.remove(identifier) }

  private mutating func invalidateAll() {
    if epoch < UInt64.max { epoch += 1 }
    latest.removeAll()
  }
}

/// Publishes new MPV-compatible records without overwriting unknown existing state.
/// Call begin/enqueue/invalidate/performClear on main. Preference opt-out is also
/// safe from a KVO thread and synchronizes with the final publication operation.
final class NativePlaybackResumeStore {
  private let root: URL
  private let worker = DispatchQueue(label: "com.chengying.native-resume-store", qos: .utility)
  private let lock = NSLock()
  private var policy: NativePlaybackResumePolicy

  #if NATIVE_RESUME_STORE_TESTING
  enum TestStage { case beforePublication }
  var testStage: ((TestStage) -> Void)?
  #endif

  init(rootURL: URL, initiallyEnabled: Bool) {
    root = rootURL.standardizedFileURL
    policy = NativePlaybackResumePolicy(enabled: initiallyEnabled)
  }

  func begin(digest: String, owner: UUID, mediaGeneration: UInt64) -> NativePlaybackResumeTicket? {
    precondition(Thread.isMainThread)
    return synchronized { policy.begin(digest: digest, owner: owner, mediaGeneration: mediaGeneration) }
  }

  func invalidate(_ ticket: NativePlaybackResumeTicket) {
    precondition(Thread.isMainThread)
    synchronized { policy.invalidate(ticket) }
  }

  /// Once opt-out returns, no older queued receipt can publish. Re-enabling does
  /// not revive a ticket invalidated by opt-out or a clear operation.
  func setResumeEnabled(_ enabled: Bool) {
    synchronized { policy.setEnabled(enabled) }
  }

  func enqueue(_ ticket: NativePlaybackResumeTicket, position: Double, speed: Double,
               completion: @escaping (NativePlaybackResumeResult) -> Void) {
    precondition(Thread.isMainThread)
    let data = NativePlaybackResumePolicy.record(position: position, speed: speed)
    worker.async {
      let result: NativePlaybackResumeResult
      if let rejection = self.synchronized({ self.policy.rejection(for: ticket) }) {
        result = rejection
      } else if let data {
        result = self.publish(ticket, data: data)
      } else {
        result = .ioError(EINVAL)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// The caller supplies its existing, explicitly authorized watch-later clear.
  /// This class does not recursively remove any directory. The gate closes
  /// immediately; already queued work settles before the operation runs off-main.
  /// Concurrent clear IDs keep it closed until all corresponding main completions.
  /// This coordinates native writers only, not MPV or external processes.
  func performClear(operation: @escaping () throws -> Void,
                    completion: @escaping (NativePlaybackResumeClearResult) -> Void) {
    precondition(Thread.isMainThread)
    let identifier = synchronized { policy.beginClear() }
    worker.async {
      let result: NativePlaybackResumeClearResult
      do { try operation(); result = .cleared }
      catch {
        let error = error as NSError
        result = .ioError(error.domain == NSPOSIXErrorDomain ? Int32(clamping: error.code) : EIO)
      }
      DispatchQueue.main.async {
        self.synchronized { self.policy.endClear(identifier) }
        completion(result)
      }
    }
  }

  /// A drain is asynchronous: callers must keep their shutdown lifecycle alive
  /// until completion rather than blocking main and starving delivery callbacks.
  func drain(completion: @escaping () -> Void) {
    precondition(Thread.isMainThread)
    worker.async { DispatchQueue.main.async(execute: completion) }
  }

  private func synchronized<T>(_ action: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return action()
  }

  private func publish(_ ticket: NativePlaybackResumeTicket, data: Data) -> NativePlaybackResumeResult {
    precondition(!Thread.isMainThread)
    let directory = openDirectory()
    guard directory >= 0 else { return .ioError(errno) }
    defer { close(directory) }
    var directoryStatus = stat()
    guard fstat(directory, &directoryStatus) == 0 else { return .ioError(errno) }
    guard directoryStatus.st_uid == geteuid(), directoryStatus.st_mode & 0o022 == 0 else { return .ioError(EACCES) }
    if let conflict = existingRecord(in: directory, digest: ticket.digest) { return conflict }

    let temporary = ".native-resume-\(UUID().uuidString)"
    let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return .ioError(errno) }
    defer { close(descriptor); unlinkat(directory, temporary, 0) }
    guard fchmod(descriptor, 0o600) == 0 else { return .ioError(errno) }
    let writeError = data.withUnsafeBytes { bytes -> Int32? in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          return errno
        }
        guard count > 0 else { return EIO }
        offset += count
      }
      return nil
    }
    if let writeError { return .ioError(writeError) }
    guard fsync(descriptor) == 0 else { return .ioError(errno) }

    #if NATIVE_RESUME_STORE_TESTING
    testStage?(.beforePublication)
    #endif

    // Root replacement and unknown spelling conflicts fail closed. An explicit
    // clear cannot race this worker; external writers still get no-overwrite link.
    let currentDirectory = openDirectory()
    guard currentDirectory >= 0 else { return .ioError(errno) }
    defer { close(currentDirectory) }
    var currentStatus = stat()
    guard fstat(currentDirectory, &currentStatus) == 0 else { return .ioError(errno) }
    guard currentStatus.st_dev == directoryStatus.st_dev, currentStatus.st_ino == directoryStatus.st_ino else {
      return .ioError(ESTALE)
    }
    if let conflict = existingRecord(in: directory, digest: ticket.digest) { return conflict }
    var temporaryStatus = stat(), descriptorStatus = stat()
    guard fstat(descriptor, &descriptorStatus) == 0,
          fstatat(directory, temporary, &temporaryStatus, AT_SYMLINK_NOFOLLOW) == 0 else { return .ioError(errno) }
    guard temporaryStatus.st_mode & S_IFMT == S_IFREG, temporaryStatus.st_nlink == 1,
          temporaryStatus.st_dev == descriptorStatus.st_dev, temporaryStatus.st_ino == descriptorStatus.st_ino else {
      return .ioError(ESTALE)
    }
    return synchronized {
      guard let rejection = policy.rejection(for: ticket) else {
        guard linkat(directory, temporary, directory, ticket.digest, 0) == 0 else {
          return errno == EEXIST ? .conflict : .ioError(errno)
        }
        policy.invalidate(ticket)
        return .saved
      }
      return rejection
    }
  }

  private func existingRecord(in directory: Int32, digest: String) -> NativePlaybackResumeResult? {
    for name in [digest, digest.lowercased()] {
      var status = stat()
      if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return .conflict }
      if errno != ENOENT { return .ioError(errno) }
    }
    return nil
  }

  /// Walk absolute components without following even an ancestor symlink. The
  /// store never creates or repairs its root, and never emits its path in errors.
  private func openDirectory() -> Int32 {
    guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else { errno = EINVAL; return -1 }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return -1 }
    for component in root.pathComponents.dropFirst() {
      let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let failure = errno
      close(descriptor)
      guard child >= 0 else { errno = failure; return -1 }
      descriptor = child
    }
    return descriptor
  }
}
