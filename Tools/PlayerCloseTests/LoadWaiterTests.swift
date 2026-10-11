import Foundation

@main
enum LoadWaiterTests {
  static var checks = 0
  static func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    checks += 1
  }

  static func main() {
    var now = 0.0
    var loaded = 0
    var queued = 0
    var pumps = 0
    var drains = 0
    func pump(_ duration: Double) {
      check(duration == 0.01, "The pump cadence remains unchanged")
      pumps += 1
      now = 3
      queued += 1
    }
    func drain() { drains += 1; loaded += queued; queued = 0 }

    // Negative control: an event arrives inside the last run-loop turn, after
    // that turn's event drain. The old loop exits without observing it.
    let deadline = now + 3
    while loaded < 1 && now < deadline { pump(0.01) }
    check(loaded == 0 && queued == 1, "The old loop misses the queued completion")
    check(now == 3 && pumps == 1 && drains == 0, "The negative control uses the original deadline")

    now = 0; loaded = 0; queued = 0; pumps = 0; drains = 0
    let ready = PlayerCloseLoadWaiter.wait(expected: 1, timeout: 3, loaded: { loaded },
      clock: { now }, pump: pump, drain: drain)
    check(ready && loaded == 1 && queued == 0, "The production waiter observes the final queued event")
    check(now == 3 && pumps == 1 && drains == 1, "The final drain adds no sleep or timeout extension")

    now = 0; loaded = 0; queued = 0; pumps = 0; drains = 0
    let absent = PlayerCloseLoadWaiter.wait(expected: 1, timeout: 3, loaded: { loaded },
      clock: { now }, pump: { _ in pumps += 1; now = 3 }, drain: drain)
    check(!absent && loaded == 0, "A genuinely missing load event still fails")
    check(now == 3 && pumps == 1 && drains == 1, "A missing event never earns a grace period")

    now = 0; loaded = 2; queued = 0; pumps = 0; drains = 0
    let duplicate = PlayerCloseLoadWaiter.wait(expected: 1, timeout: 3, loaded: { loaded },
      clock: { now }, pump: pump, drain: drain)
    check(!duplicate && pumps == 0, "Extra loaded events cannot satisfy the strict expected count")

    now = 0; loaded = 1; queued = 1; pumps = 0; drains = 0
    let queuedDuplicate = PlayerCloseLoadWaiter.wait(expected: 1, timeout: 3, loaded: { loaded },
      clock: { now }, pump: pump, drain: drain)
    check(!queuedDuplicate && loaded == 2, "The final drain cannot hide a duplicate completion")

    now = 0; loaded = 0; queued = 1; pumps = 0; drains = 0
    let immediate = PlayerCloseLoadWaiter.wait(expected: 1, timeout: 0, loaded: { loaded },
      clock: { now }, pump: pump, drain: drain)
    check(immediate && now == 0 && pumps == 0 && drains == 1, "A zero-wait read does not advance time")
    print("PASS: Load waiter regression completed: \(checks) checks")
  }
}
