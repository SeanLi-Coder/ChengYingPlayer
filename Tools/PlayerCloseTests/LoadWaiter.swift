import Foundation

/// The final read is nonblocking: events queued during the last pump must not be lost.
enum PlayerCloseLoadWaiter {
  static func wait(expected: Int, timeout: Double, loaded: () -> Int,
                   clock: () -> Double, pump: (Double) -> Void, drain: () -> Void) -> Bool {
    let deadline = clock() + timeout
    while loaded() < expected && clock() < deadline { pump(0.01) }
    drain()
    return loaded() == expected
  }
}
