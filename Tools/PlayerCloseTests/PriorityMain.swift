import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  checks += 1
}

final class AcquisitionOrder {
  private let lock = NSLock()
  private var entries: [String] = []
  func append(_ value: String) { lock.lock(); entries.append(value); lock.unlock() }
  var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

@main struct PriorityRegression {
  static func main() {
    let priority = MainThreadPriorityLock()
    let display = NSRecursiveLock()
    let outerEntered = DispatchSemaphore(value: 0)
    let allowReentry = DispatchSemaphore(value: 0)
    let workerFinished = DispatchSemaphore(value: 0)
    let otherStarted = DispatchSemaphore(value: 0)
    let otherPassedPriority = DispatchSemaphore(value: 0)
    let otherFinished = DispatchSemaphore(value: 0)
    let order = AcquisitionOrder()
    DispatchQueue.global().async {
      priority.beforeLocking()
      display.lock()
      priority.afterLocked()
      outerEntered.signal()
      precondition(allowReentry.wait(timeout: .now() + 3) == .success)
      // Core Animation can synchronously reenter display from CATransaction.flush.
      // This is the owner of the recursive display lock, not another contender.
      priority.beforeLocking()
      display.lock()
      priority.afterLocked()
      priority.beforeUnlocking()
      display.unlock()
      // Returning from the inner call must not erase ownership of the outer one.
      priority.beforeLocking()
      display.lock()
      priority.afterLocked()
      priority.beforeUnlocking()
      display.unlock()
      priority.beforeUnlocking()
      display.unlock()
      workerFinished.signal()
    }
    check(outerEntered.wait(timeout: .now() + 3) == .success, "The background renderer owns the display lock")
    priority.beforeLocking()
    DispatchQueue.global().async {
      otherStarted.signal()
      priority.beforeLocking()
      otherPassedPriority.signal()
      display.lock()
      priority.afterLocked()
      order.append("other")
      priority.beforeUnlocking()
      display.unlock()
      otherFinished.signal()
    }
    check(otherStarted.wait(timeout: .now() + 3) == .success, "A separate background contender starts")
    check(otherPassedPriority.wait(timeout: .now() + 0.1) == .timedOut,
          "Ordinary background contenders still wait behind the main thread")
    allowReentry.signal()
    let acquired = display.lock(before: Date().addingTimeInterval(1))
    // Let the historical implementation unwind after a bounded failed acquisition.
    // This is not success: the final check rejects the deadlocked ordering.
    priority.afterLocked()
    if acquired {
      order.append("main")
      priority.beforeUnlocking()
      display.unlock()
    }
    check(workerFinished.wait(timeout: .now() + 3) == .success, "The renderer can finish after the bounded probe")
    check(acquired, "A reentrant render owner cannot deadlock the waiting main thread")
    check(otherFinished.wait(timeout: .now() + 3) == .success, "A separate background contender can finish later")
    check(order.values == ["main", "other"], "Main-thread priority survives recursive background drawing")
    priority.beforeLocking()
    display.lock()
    priority.afterLocked()
    priority.beforeLocking()
    display.lock()
    priority.afterLocked()
    priority.beforeUnlocking()
    display.unlock()
    priority.beforeUnlocking()
    display.unlock()
    check(true, "Main-thread recursive drawing also balances its ownership")
    print("PASS: Render priority lock checks: \(checks)")
  }
}
