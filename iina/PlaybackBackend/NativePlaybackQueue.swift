import Foundation

/// A bounded explicit selection, not a folder scanner or a media capability probe.
/// File identity/access and format admission remain the caller's responsibility.
struct NativeQueuePlan: Equatable {
  struct Item: Equatable {
    let id: UUID
    let url: URL
  }

  enum ValidationError: Error, Equatable { case empty, tooManyItems, tooManyBytes, nonLocalFile, directory }
  static let maximumItems = 256
  static let maximumUTF8Bytes = 1_048_576
  let id: UUID
  let items: [Item]

  init(urls: [URL]) throws {
    guard !urls.isEmpty else { throw ValidationError.empty }
    guard urls.count <= Self.maximumItems else { throw ValidationError.tooManyItems }
    guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host?.lowercased() == "localhost") &&
      $0.query == nil && $0.fragment == nil && $0.user == nil && $0.password == nil }) else {
      throw ValidationError.nonLocalFile
    }
    guard urls.allSatisfy({ !$0.hasDirectoryPath }) else { throw ValidationError.directory }
    var bytes = 0
    for url in urls {
      let count = url.absoluteString.utf8.count
      guard count <= Self.maximumUTF8Bytes - bytes else { throw ValidationError.tooManyBytes }
      bytes += count
    }
    id = UUID()
    // Preserve explicit order and duplicate URLs. IDs identify entries rather
    // than paths; upstream selection policy can deduplicate before construction.
    items = urls.map { Item(id: UUID(), url: $0.standardizedFileURL) }
  }
}

/// Main-owner value model only. It issues decisions, never decoder or MPV calls.
/// A successful model handoff is not proof that an external playlist was installed.
struct NativeQueueState {
  enum Intent: Equatable { case playing, paused }
  enum Phase: Equatable { case loading, ready, ended, installing, handoffFailed, compatibility, stopped }
  enum Rejection: Equatable { case stale, invalidItem, busy, inactive, counterExhausted }
  enum Decision: Equatable {
    case load(MediaRequest)
    case rewind(MediaRequest)
    case ended
    case intentUpdated
    case unchanged
    case rejected(Rejection)
  }
  struct MediaToken: Equatable {
    let planID: UUID
    let epoch: UUID
    let generation: UInt64
    let itemID: UUID
  }
  struct MediaRequest: Equatable {
    let token: MediaToken
    let url: URL
    let revision: UInt64
  }
  struct HandoffCheckpoint: Equatable {
    let id: UUID
    let plan: NativeQueuePlan
    let media: MediaToken
    let revision: UInt64
    let selectedIndex: Int
    let intent: Intent
    let repeatMode: LoopMode
    let autoAdvance: Bool

    fileprivate init(_ state: NativeQueueState) {
      id = UUID(); plan = state.plan; media = state.mediaToken
      revision = state.revision; selectedIndex = state.selectedIndex
      intent = state.intent; repeatMode = state.repeatMode; autoAdvance = state.autoAdvance
    }
  }
  struct InstallationToken: Equatable {
    let id: UUID
    let checkpointID: UUID
    let media: MediaToken

    fileprivate init(_ checkpoint: HandoffCheckpoint) {
      id = UUID(); checkpointID = checkpoint.id; media = checkpoint.media
    }
  }
  struct InstallationCompletion: Equatable {
    let verified: Bool
    let selectedItem: NativeQueuePlan.Item
    let intent: Intent
    let repeatMode: LoopMode
    let autoAdvance: Bool
  }
  enum ValidationError: Error, Equatable { case invalidIndex }

  private(set) var plan: NativeQueuePlan
  private(set) var epoch = UUID()
  private(set) var revision: UInt64 = 1
  private(set) var generation: UInt64 = 1
  private(set) var selectedIndex: Int
  private(set) var intent: Intent
  private(set) var repeatMode: LoopMode
  private(set) var autoAdvance: Bool
  private(set) var phase = Phase.loading
  private var installation: InstallationToken?
  private var pendingRewind: (revision: UInt64, phase: Phase)?

  init(plan: NativeQueuePlan, selectedIndex: Int = 0, intent: Intent = .playing,
       repeatMode: LoopMode = .off, autoAdvance: Bool = true) throws {
    guard plan.items.indices.contains(selectedIndex) else { throw ValidationError.invalidIndex }
    self.plan = plan; self.selectedIndex = selectedIndex; self.intent = intent
    self.repeatMode = repeatMode; self.autoAdvance = autoAdvance
  }

  var selectedItem: NativeQueuePlan.Item { plan.items[selectedIndex] }
  var mediaToken: MediaToken {
    MediaToken(planID: plan.id, epoch: epoch, generation: generation, itemID: selectedItem.id)
  }
  var currentRequest: MediaRequest { MediaRequest(token: mediaToken, url: selectedItem.url, revision: revision) }

  // Keep overflow explicit; callbacks must never alias an ancient generation.
  static func successor(_ value: UInt64) -> UInt64? {
    let result = value.addingReportingOverflow(1)
    return result.overflow ? nil : result.partialValue
  }

  /// Validate before replacing so a malformed index cannot discard a live plan.
  mutating func replace(with plan: NativeQueuePlan, selectedIndex: Int = 0,
                        intent: Intent = .playing, repeatMode: LoopMode = .off,
                        autoAdvance: Bool = true) throws -> MediaRequest {
    self = try Self(plan: plan, selectedIndex: selectedIndex, intent: intent,
                    repeatMode: repeatMode, autoAdvance: autoAdvance)
    return currentRequest
  }

  /// Opening pause/resume changes do not invalidate the same media's load token.
  /// The consumer reads `intent` only after accepting the actual ready callback.
  mutating func acceptLoaded(_ token: MediaToken) -> Bool {
    guard phase == .loading, pendingRewind == nil, token == mediaToken,
          let next = Self.successor(revision) else { return false }
    revision = next; phase = .ready
    return true
  }

  @discardableResult
  mutating func setIntent(_ value: Intent) -> Decision {
    guard phase != .stopped, phase != .compatibility else { return .rejected(.inactive) }
    if value == .playing, phase == .ended {
      let decision = request(selectedIndex, rewind: true)
      if case .rewind = decision { intent = .playing }
      return decision
    }
    if intent == value { return .unchanged }
    guard let next = Self.successor(revision) else { return .rejected(.counterExhausted) }
    revision = next; intent = value
    return .intentUpdated
  }

  @discardableResult
  mutating func setRepeatMode(_ value: LoopMode) -> Bool {
    guard phase != .stopped, phase != .compatibility else { return false }
    if repeatMode == value { return true }
    guard let next = Self.successor(revision) else { return false }
    revision = next; repeatMode = value
    return true
  }

  @discardableResult
  mutating func setAutoAdvance(_ value: Bool) -> Bool {
    guard phase != .stopped, phase != .compatibility else { return false }
    if autoAdvance == value { return true }
    guard let next = Self.successor(revision) else { return false }
    revision = next; autoAdvance = value
    return true
  }

  mutating func select(_ itemID: UUID) -> Decision {
    guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { return .rejected(.invalidItem) }
    return request(index, rewind: false)
  }

  /// First previous rewinds, matching the explicit PlayerCore boundary.
  mutating func previous() -> Decision {
    if let rejection = selectionRejection { return .rejected(rejection) }
    return request(max(0, selectedIndex - 1), rewind: selectedIndex == 0)
  }

  mutating func next() -> Decision {
    if let rejection = selectionRejection { return .rejected(rejection) }
    guard selectedIndex + 1 < plan.items.count else {
      // Real MPV + PlayerCore verification: playlist repeat wraps, while off/file
      // return a command error after PlayerCore has already applied pause.
      if repeatMode == .playlist { return request(0, rewind: false) }
      return setIntent(.paused)
    }
    return request(selectedIndex + 1, rewind: false)
  }

  /// The source token and ready state consume EOF once. A late EOF from
  /// a cancelled selection cannot advance the current queue a second time.
  mutating func ended(_ token: MediaToken) -> Decision {
    guard token == mediaToken else { return .rejected(.stale) }
    guard phase == .ready else { return .rejected(.inactive) }
    // If pause wins the race with the current media's real EOF, remember the
    // terminal state without advancing. Explicit resume must rewind rather than
    // leave a ready-but-exhausted decoder waiting forever.
    if intent == .paused { return markEnded() }
    if repeatMode == .file { return request(selectedIndex, rewind: true) }
    if autoAdvance {
      if selectedIndex + 1 < plan.items.count { return request(selectedIndex + 1, rewind: false) }
      if repeatMode == .playlist { return request(0, rewind: false) }
    }
    return markEnded()
  }

  /// An accepted seek invalidates the worker's old EOF revision. Keep the same
  /// media identity so resuming after seeking away from EOF does not reopen it.
  mutating func acceptedSeek(_ token: MediaToken) -> Bool {
    guard token == mediaToken, phase == .ready || phase == .ended,
          let next = Self.successor(revision) else { return false }
    revision = next
    phase = .ready
    return true
  }

  /// A rewind is an accepted seek on the existing Session, never a media open.
  /// The request revision prevents a late acknowledgement from consuming a
  /// later same-media rewind. User pause/resume may still update live intent.
  mutating func completeRewind(_ request: MediaRequest, accepted: Bool) -> Bool {
    guard let pending = pendingRewind, phase == .loading,
          request.token == mediaToken, request.revision == pending.revision,
          let next = Self.successor(revision) else { return false }
    pendingRewind = nil; revision = next
    phase = accepted ? .ready : pending.phase
    return true
  }

  /// This snapshot has no transport position/volume/viewport. Integration must
  /// pair it with a real captured transport snapshot and its own intent fence.
  func handoffCheckpoint() -> HandoffCheckpoint? {
    guard phase == .loading || phase == .ready || phase == .ended || phase == .handoffFailed else { return nil }
    return HandoffCheckpoint(self)
  }

  /// Consume-before-effects: only after this returns may the external owner
  /// retire native and install the entire MPV list. No other selection can race
  /// that installation; a new open or stop invalidates its acknowledgement.
  mutating func beginHandoff(_ checkpoint: HandoffCheckpoint) -> InstallationToken? {
    guard phase == .loading || phase == .ready || phase == .ended || phase == .handoffFailed,
          checkpoint.media == mediaToken, checkpoint.plan == plan,
          checkpoint.revision == revision,
          checkpoint.selectedIndex == selectedIndex, checkpoint.intent == intent,
          checkpoint.repeatMode == repeatMode, checkpoint.autoAdvance == autoAdvance,
          let next = Self.successor(revision) else { return nil }
    let token = InstallationToken(checkpoint)
    installation = token; revision = next; phase = .installing
    return token
  }

  /// `verified` must mean the actual external list, current item, and command
  /// results were checked. Failure retains the plan for a new bounded attempt.
  /// Installation-time pause/repeat changes are returned from live state, never
  /// copied back from the older checkpoint. Repeated/stale acknowledgements fail.
  mutating func completeHandoff(_ token: InstallationToken, verified: Bool) -> InstallationCompletion? {
    guard phase == .installing, installation == token, token.media == mediaToken,
          let next = Self.successor(revision) else { return nil }
    installation = nil; revision = next; phase = verified ? .compatibility : .handoffFailed
    return InstallationCompletion(verified: verified, selectedItem: selectedItem,
                                  intent: intent, repeatMode: repeatMode, autoAdvance: autoAdvance)
  }

  mutating func stop() {
    epoch = UUID(); revision = 0; generation = 0
    installation = nil; pendingRewind = nil; intent = .paused; phase = .stopped
  }

  private var selectionRejection: Rejection? {
    switch phase {
    case .installing, .handoffFailed: return .busy
    case .compatibility, .stopped: return .inactive
    case .loading, .ready, .ended: return nil
    }
  }

  private mutating func request(_ index: Int, rewind: Bool) -> Decision {
    if let rejection = selectionRejection { return .rejected(rejection) }
    if rewind {
      guard phase == .ready || phase == .ended else { return .rejected(.inactive) }
      guard let next = Self.successor(revision) else { return .rejected(.counterExhausted) }
      pendingRewind = (revision: next, phase: phase)
      revision = next; phase = .loading
      return .rewind(currentRequest)
    }
    guard let nextRevision = Self.successor(revision), let nextGeneration = Self.successor(generation) else {
      return .rejected(.counterExhausted)
    }
    selectedIndex = index; revision = nextRevision; generation = nextGeneration; phase = .loading
    installation = nil; pendingRewind = nil
    return .load(currentRequest)
  }

  private mutating func markEnded() -> Decision {
    guard let next = Self.successor(revision) else { return .rejected(.counterExhausted) }
    revision = next; phase = .ended; intent = .paused
    return .ended
  }
}
