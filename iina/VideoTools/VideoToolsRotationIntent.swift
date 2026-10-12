//
//  VideoToolsRotationIntent.swift
//  ChengYing
//

import Foundation

/// Bounded, per-player ownership of rotation presses waiting for a backend handoff.
/// This value does not start playback, restore a preview, or export a file. Its owner
/// must reset the media on every new open, including reopening the same URL, and
/// cancel pending intent on explicit navigation or close. Keep it on the main queue.
struct VideoToolsRotationIntent {
  struct Ticket: Equatable {
    let requestID: UUID
    let mediaEpoch: UUID
    let inputURL: URL
  }

  struct Submission: Equatable {
    let ticket: Ticket
    /// Always 1...4. Four preserves the coordinator's explicit 360-degree export.
    let clockwiseQuarterTurns: Int
  }

  enum AppendResult: Equatable {
    case begin(Ticket)
    case accumulated(Ticket)
    case rejected
  }

  private struct Pending {
    let ticket: Ticket
    var quarterTurns: Int
  }

  private(set) var mediaEpoch = UUID()
  private(set) var inputURL: URL?
  private var pending: Pending?

  var pendingTicket: Ticket? { pending?.ticket }
  var hasPending: Bool { pending != nil }

  /// Only explicit media admission calls this. The same-file compatibility reload
  /// must retain the epoch; a user's same-file reopen must create a new one.
  mutating func resetMedia(to url: URL?) {
    mediaEpoch = UUID()
    inputURL = url?.isFileURL == true ? url?.standardizedFileURL : nil
    pending = nil
  }

  /// Only the first accepted press asks the owner to start one compatibility request.
  /// Reduction before addition handles Int.min/Int.max without overflow. No event
  /// list or unbounded press counter is retained while the backend is unavailable.
  mutating func append(clockwiseQuarterTurns turns: Int) -> AppendResult {
    guard turns != 0, let inputURL else { return .rejected }
    let delta = turns % 4
    if var pending {
      pending.quarterTurns = (pending.quarterTurns + delta + 4) % 4
      self.pending = pending
      return .accumulated(pending.ticket)
    }
    let ticket = Ticket(requestID: UUID(), mediaEpoch: mediaEpoch, inputURL: inputURL)
    pending = Pending(ticket: ticket, quarterTurns: (delta + 4) % 4)
    return .begin(ticket)
  }

  /// A successful callback must own the request, not merely refer to the same path.
  func isCurrent(_ ticket: Ticket) -> Bool {
    pending?.ticket == ticket && ticket.mediaEpoch == mediaEpoch && ticket.inputURL == inputURL
  }

  /// Consume before invoking any external callback or export code. A duplicate or
  /// stale completion cannot replay the request, including after a newer request.
  /// A mismatched callback is rejected without discarding another live request.
  mutating func consume(ticket: Ticket, currentURL: URL) -> Submission? {
    guard currentURL.isFileURL, isCurrent(ticket),
          currentURL.standardizedFileURL == ticket.inputURL, let pending else { return nil }
    self.pending = nil
    return Submission(ticket: ticket,
                      clockwiseQuarterTurns: pending.quarterTurns == 0 ? 4 : pending.quarterTurns)
  }

  /// Cancel only commands not yet handed to the rotation coordinator. Already
  /// exported files and the coordinator's active task are outside this value.
  mutating func cancel() { pending = nil }

  /// Failure/timeout callbacks may cancel only the request that created them.
  @discardableResult
  mutating func cancel(requestID: UUID) -> Bool {
    guard pending?.ticket.requestID == requestID else { return false }
    pending = nil
    return true
  }
}
