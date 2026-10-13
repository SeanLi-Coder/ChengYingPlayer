import Foundation

enum PlaybackModeWait {
  static func until(timeout: TimeInterval,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    pump: () -> Void,
                    condition: () -> Bool) -> Bool {
    let deadline = now() + timeout
    while now() < deadline {
      let satisfied = condition()
      // A property read can block; do not accept a result obtained after the deadline.
      guard now() < deadline else { return false }
      if satisfied { return true }
      pump()
    }
    return false
  }
}
