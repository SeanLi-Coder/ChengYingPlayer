import Foundation

/// A process-wide admission lock. Existing work is never cancelled by an update.
final class UpdateWorkAdmission {
  static let shared = UpdateWorkAdmission()
  private let lock = NSLock()
  private var owner: UUID?
  private var drains = Set<UUID>()
  private var activities = [UUID: String]()

  var activeReasons: [String] {
    lock.lock(); defer { lock.unlock() }
    return Array(Set(activities.values)).sorted()
  }

  func beginActivity(reason: String) -> UUID? {
    lock.lock(); defer { lock.unlock() }
    guard owner == nil else { return nil }
    let identifier = UUID()
    activities[identifier] = reason
    return identifier
  }

  func endActivity(_ identifier: UUID) {
    lock.lock(); defer { lock.unlock() }
    activities.removeValue(forKey: identifier)
  }

  var isBlocked: Bool {
    lock.lock(); defer { lock.unlock() }
    return owner != nil
  }

  var hasDrainingProcesses: Bool {
    lock.lock(); defer { lock.unlock() }
    return !drains.isEmpty
  }

  var isHelperRestartBlocked: Bool {
    lock.lock(); defer { lock.unlock() }
    return owner != nil || !drains.isEmpty
  }

  func acquire(_ identifier: UUID) -> Bool {
    precondition(Thread.isMainThread)
    lock.lock(); defer { lock.unlock() }
    guard owner == nil, activities.isEmpty, drains.isEmpty else { return false }
    owner = identifier
    return true
  }

  func release(_ identifier: UUID) {
    precondition(Thread.isMainThread)
    lock.lock(); defer { lock.unlock() }
    if owner == identifier { owner = nil }
  }

  fileprivate func trackDrain(_ identifier: UUID, active: Bool) {
    lock.lock(); defer { lock.unlock() }
    if active { drains.insert(identifier) } else { drains.remove(identifier) }
  }
}

/// Wait for an owned, already idle helper to actually exit. Never terminate or kill it.
/// A timeout vetoes installation but continues tracking the process until it exits.
final class UpdateProcessDrain {
  private let process: Process
  private let identifier: UUID
  private let deadline: DispatchTime
  private var completion: ((Bool) -> Void)?
  private let onExit: (() -> Void)?

  static func reserve() -> UUID {
    let identifier = UUID()
    UpdateWorkAdmission.shared.trackDrain(identifier, active: true)
    return identifier
  }

  static func wait(for process: Process?, timeout: TimeInterval = 15, reservation: UUID? = nil, onExit: (() -> Void)? = nil,
                   completion: @escaping (Bool) -> Void) {
    let identifier = reservation ?? reserve()
    guard let process, process.isRunning else {
      UpdateWorkAdmission.shared.trackDrain(identifier, active: false)
      DispatchQueue.main.async { onExit?(); completion(true) }
      return
    }
    let drain = UpdateProcessDrain(process: process, identifier: identifier, timeout: timeout, onExit: onExit, completion: completion)
    drain.poll()
  }

  private init(process: Process, identifier: UUID, timeout: TimeInterval, onExit: (() -> Void)?, completion: @escaping (Bool) -> Void) {
    self.process = process
    self.identifier = identifier
    self.onExit = onExit
    deadline = .now() + timeout
    self.completion = completion
  }

  private func poll() {
    if !process.isRunning {
      UpdateWorkAdmission.shared.trackDrain(identifier, active: false)
      if let onExit { DispatchQueue.main.async(execute: onExit) }
      finish(true)
      return
    }
    if DispatchTime.now() >= deadline { finish(false) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { self.poll() }
  }

  private func finish(_ success: Bool) {
    guard let completion else { return }
    self.completion = nil
    DispatchQueue.main.async { completion(success) }
  }
}
