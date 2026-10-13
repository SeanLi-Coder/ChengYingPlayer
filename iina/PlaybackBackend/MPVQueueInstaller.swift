import Foundation

/// Only the playlist node is an atomic readback. The client must serialize all
/// playlist writers with this transaction and copy MPV event payloads promptly.
struct MPVQueueInstallationSnapshot: Equatable {
  struct Entry: Equatable {
    let id: Int64
    let path: String
    let current: Bool
    let playing: Bool
  }
  let entries: [Entry]
  let idle: Bool
  let paused: Bool
  let activePath: String?
}

/// Production integration must retain MPVController's media-command accounting
/// and event gate. A missing handle/result is a failure, never implicit success.
protocol MPVQueueInstallationBackend: AnyObject {
  func queueCommand(_ arguments: [String]) -> Int32?
  func queueSetPaused() -> Int32?
  func queueSnapshot() -> MPVQueueInstallationSnapshot?
}

/// A bounded, main-owner installer for an unused, empty, idle MPV client. It
/// never owns a decoder, changes repeat policy, or restores transport settings.
/// Call advance from a bounded scheduler and forward real MPV events. No event
/// callback, model acknowledgement, or successful append alone proves loading.
final class MPVQueueInstaller {
  enum Failure: Equatable {
    case invalidRequest, busy, notFreshIdle, backendUnavailable, pauseFailed
    case appendFailed(Int), prefixMismatch, activationFailed, unexpectedStart
    case loadedMismatch, loadFailed, timedOut, shutdown, eventQueueOverflow
  }
  enum Cleanup: Equatable { case verifiedEmpty, unverified }
  struct Receipt: Equatable {
    let installation: NativeQueueState.InstallationToken
    let itemIDs: [UUID]
    let entryIDs: [Int64]
    let selectedIndex: Int
    var selectedEntryID: Int64 { entryIDs[selectedIndex] }
  }
  enum Outcome: Equatable {
    case installed(Receipt)
    case failed(Failure, Cleanup)
    case cancelled(Cleanup)
    // The new owner alone may mutate or clean its MPV client.
    case superseded
  }
  /// FILE_LOADED has no native payload. The MPV event reader must attach the
  /// entry ID copied from its preceding START_FILE, before dispatch to main.
  /// Never attach the current operation token to an already queued old event.
  enum Event { case startFile(entryID: Int64), fileLoaded(entryID: Int64), endFile(entryID: Int64), shutdown, queueOverflow }
  enum Admission: Equatable { case accepted, rejected(Failure) }
  private enum Phase { case appending, awaitingStart, awaitingLoaded, cleaning }
  private enum Terminal { case failed(Failure), cancelled }
  private final class Operation {
    let checkpoint: NativeQueueState.HandoffCheckpoint
    let token: NativeQueueState.InstallationToken
    let completion: (Outcome) -> Void
    var entryIDs: [Int64] = []
    var phase = Phase.appending
    var deadline: TimeInterval
    var terminal: Terminal?
    var activationAcknowledged = false
    var receivedLoaded = false
    init(_ checkpoint: NativeQueueState.HandoffCheckpoint, _ token: NativeQueueState.InstallationToken,
         deadline: TimeInterval, completion: @escaping (Outcome) -> Void) {
      self.checkpoint = checkpoint; self.token = token; self.deadline = deadline; self.completion = completion
    }
  }
  private let backend: MPVQueueInstallationBackend
  private let isCurrent: (NativeQueueState.InstallationToken) -> Bool
  private let clock: () -> TimeInterval
  private var operation: Operation?
  static let commandsPerAdvance = 8
  static let loadTimeout: TimeInterval = 10
  static let cleanupTimeout: TimeInterval = 2

  init(backend: MPVQueueInstallationBackend,
       isCurrent: @escaping (NativeQueueState.InstallationToken) -> Bool,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.backend = backend; self.isCurrent = isCurrent; self.clock = clock
  }

  var isBusy: Bool { operation != nil }

  /// Rejected admissions do not invoke completion or mutate MPV. The owner must
  /// retire native before acceptance and keep the installation token current.
  func begin(_ checkpoint: NativeQueueState.HandoffCheckpoint,
             installation: NativeQueueState.InstallationToken,
             completion: @escaping (Outcome) -> Void) -> Admission {
    dispatchPrecondition(condition: .onQueue(.main))
    guard operation == nil else { return .rejected(.busy) }
    guard installation.checkpointID == checkpoint.id, installation.media == checkpoint.media,
          checkpoint.plan.items.indices.contains(checkpoint.selectedIndex), isCurrent(installation) else {
      return .rejected(.invalidRequest)
    }
    guard let snapshot = backend.queueSnapshot() else { return .rejected(.backendUnavailable) }
    guard operation == nil else { return .rejected(.busy) }
    guard snapshot.entries.isEmpty, snapshot.idle, snapshot.activePath == nil else { return .rejected(.notFreshIdle) }
    guard isCurrent(installation) else { return .rejected(.invalidRequest) }
    let value = Operation(checkpoint, installation, deadline: clock() + Self.loadTimeout, completion: completion)
    operation = value
    let status = backend.queueSetPaused()
    guard owns(value) else { return .accepted }
    guard status.map({ $0 >= 0 }) == true, backend.queueSnapshot()?.paused == true else {
      fail(value, .pauseFailed); return .accepted
    }
    return .accepted
  }

  /// At most eight appends per call. Each readback checks the entire observed
  /// prefix from one playlist node; IDs distinguish duplicate source paths.
  func advance() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let value = operation, owns(value) else { return }
    if value.phase == .cleaning { advanceCleanup(value); return }
    guard beforeDeadline(value) else { fail(value, .timedOut); return }
    guard value.phase == .appending else { return }
    for _ in 0..<Self.commandsPerAdvance {
      guard owns(value), value.phase == .appending else { return }
      guard beforeDeadline(value) else { fail(value, .timedOut); return }
      let index = value.entryIDs.count
      if index == value.checkpoint.plan.items.count { activate(value); return }
      let status = backend.queueCommand(["loadfile", value.checkpoint.plan.items[index].url.path, "append"])
      guard owns(value), value.phase == .appending else { return }
      guard status.map({ $0 >= 0 }) == true else { fail(value, .appendFailed(index)); return }
      guard let snapshot = backend.queueSnapshot(),
            matchesPrefix(snapshot, value: value, count: index + 1), snapshot.idle, snapshot.activePath == nil else {
        fail(value, .prefixMismatch); return
      }
      guard owns(value), value.phase == .appending else { return }
      value.entryIDs = snapshot.entries.map(\.id)
    }
  }

  func receive(_ event: Event) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let value = operation, owns(value) else { return }
    if case .shutdown = event {
      finish(value, .failed(.shutdown, .unverified)); return
    }
    guard value.phase != .cleaning else { return }
    switch event {
    case .startFile(let entryID):
      guard value.entryIDs.contains(entryID) else { return }
      guard beforeDeadline(value) else { fail(value, .timedOut); return }
      guard value.phase == .awaitingStart,
            entryID == value.entryIDs[value.checkpoint.selectedIndex] else {
        fail(value, .unexpectedStart); return
      }
      value.phase = .awaitingLoaded
    case .fileLoaded(let entryID):
      guard value.entryIDs.contains(entryID) else { return }
      guard beforeDeadline(value) else { fail(value, .timedOut); return }
      guard value.phase == .awaitingLoaded, entryID == value.entryIDs[value.checkpoint.selectedIndex] else {
        fail(value, .loadedMismatch); return
      }
      value.receivedLoaded = true
      if value.activationAcknowledged { completeLoaded(value) }
    case .endFile(let entryID):
      guard value.entryIDs.contains(entryID) else { return }
      fail(value, .loadFailed)
    case .queueOverflow: fail(value, .eventQueueOverflow)
    case .shutdown: break
    }
  }

  func cancel(_ token: NativeQueueState.InstallationToken) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let value = operation, value.token == token, owns(value) else { return }
    beginCleanup(value, terminal: .cancelled)
  }

  private func activate(_ value: Operation) {
    guard let snapshot = backend.queueSnapshot(),
          matchesPrefix(snapshot, value: value, count: value.checkpoint.plan.items.count),
          snapshot.idle, snapshot.activePath == nil, snapshot.paused else { fail(value, .prefixMismatch); return }
    guard owns(value), value.phase == .appending else { return }
    guard beforeDeadline(value) else { fail(value, .timedOut); return }
    value.phase = .awaitingStart
    let status = backend.queueCommand(["playlist-play-index", String(value.checkpoint.selectedIndex)])
    guard owns(value), value.phase != .cleaning else { return }
    guard status.map({ $0 >= 0 }) == true else { fail(value, .activationFailed); return }
    value.activationAcknowledged = true
    if value.receivedLoaded { completeLoaded(value) }
  }

  private func completeLoaded(_ value: Operation) {
    guard owns(value), value.phase == .awaitingLoaded, value.activationAcknowledged, value.receivedLoaded else { return }
    guard beforeDeadline(value) else { fail(value, .timedOut); return }
    guard let snapshot = backend.queueSnapshot(),
          matchesPrefix(snapshot, value: value, count: value.checkpoint.plan.items.count),
          snapshot.paused, !snapshot.idle,
          snapshot.activePath == value.checkpoint.plan.items[value.checkpoint.selectedIndex].url.path,
          snapshot.entries.filter(\.current).map(\.id) == [value.entryIDs[value.checkpoint.selectedIndex]],
          snapshot.entries.filter(\.playing).map(\.id) == [value.entryIDs[value.checkpoint.selectedIndex]] else {
      fail(value, .loadedMismatch); return
    }
    guard owns(value), value.phase == .awaitingLoaded else { return }
    guard beforeDeadline(value) else { fail(value, .timedOut); return }
    let receipt = Receipt(installation: value.token, itemIDs: value.checkpoint.plan.items.map(\.id),
                          entryIDs: value.entryIDs, selectedIndex: value.checkpoint.selectedIndex)
    finish(value, .installed(receipt))
  }

  private func matchesPrefix(_ snapshot: MPVQueueInstallationSnapshot, value: Operation, count: Int) -> Bool {
    guard snapshot.entries.count == count, count <= value.checkpoint.plan.items.count,
          snapshot.entries.allSatisfy({ $0.id >= 0 }), Set(snapshot.entries.map(\.id)).count == count,
          snapshot.entries.map(\.path) == Array(value.checkpoint.plan.items.prefix(count)).map({ $0.url.path }),
          Array(snapshot.entries.prefix(value.entryIDs.count)).map(\.id) == value.entryIDs else { return false }
    return true
  }

  private func fail(_ value: Operation, _ failure: Failure) { beginCleanup(value, terminal: .failed(failure)) }

  private func beginCleanup(_ value: Operation, terminal: Terminal) {
    guard owns(value), value.phase != .cleaning else { return }
    value.terminal = terminal; value.phase = .cleaning; value.deadline = clock() + Self.cleanupTimeout
    // A failing append may have returned an error after appending its one item.
    // Claim only that exact prefix; a foreign/reordered list is never erased.
    guard let snapshot = backend.queueSnapshot(),
          snapshot.entries.count <= min(value.entryIDs.count + 1, value.checkpoint.plan.items.count),
          matchesPrefix(snapshot, value: value, count: snapshot.entries.count) else {
      finishCleanup(value, .unverified); return
    }
    guard owns(value) else { return }
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    value.entryIDs = snapshot.entries.map(\.id)
    let pauseStatus = backend.queueSetPaused()
    guard owns(value) else { return }
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    guard pauseStatus.map({ $0 >= 0 }) == true else { finishCleanup(value, .unverified); return }
    let stopStatus = backend.queueCommand(["stop", "keep-playlist"])
    guard owns(value) else { return }
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    if stopStatus.map({ $0 >= 0 }) != true { finishCleanup(value, .unverified) }
  }

  private func advanceCleanup(_ value: Operation) {
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    guard let snapshot = backend.queueSnapshot(), matchesPrefix(snapshot, value: value, count: value.entryIDs.count) else {
      finishCleanup(value, .unverified); return
    }
    guard owns(value) else { return }
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    // stop sets idle-active before unload hooks finish; keep-playlist retains
    // current until the worker has actually left the old playback operation.
    guard snapshot.idle, snapshot.activePath == nil,
          snapshot.entries.allSatisfy({ !$0.current && !$0.playing }) else {
      if !beforeDeadline(value) { finishCleanup(value, .unverified) }
      return
    }
    let status = backend.queueCommand(["playlist-clear"])
    guard owns(value) else { return }
    guard status.map({ $0 >= 0 }) == true, let empty = backend.queueSnapshot(), empty.entries.isEmpty,
          empty.idle, empty.activePath == nil else { finishCleanup(value, .unverified); return }
    guard beforeDeadline(value) else { finishCleanup(value, .unverified); return }
    finishCleanup(value, .verifiedEmpty)
  }

  private func finishCleanup(_ value: Operation, _ cleanup: Cleanup) {
    switch value.terminal {
    case .failed(let error): finish(value, .failed(error, cleanup))
    case .cancelled: finish(value, .cancelled(cleanup))
    case nil: preconditionFailure("Missing queue cleanup outcome")
    }
  }

  private func owns(_ value: Operation) -> Bool {
    guard operation === value else { return false }
    guard isCurrent(value.token) else { finish(value, .superseded); return false }
    return true
  }

  private func beforeDeadline(_ value: Operation) -> Bool { clock() < value.deadline }

  private func finish(_ value: Operation, _ result: Outcome) {
    guard operation === value else { return }
    operation = nil
    // Consume before arbitrary completion code, including a same-URL new open.
    value.completion(isCurrent(value.token) ? result : .superseded)
  }
}
