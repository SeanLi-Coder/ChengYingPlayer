import Foundation

var checks = 0
func check(_ condition: Bool, _ message: String) {
  guard condition else { fatalError("FAIL: \(message)") }
  checks += 1
}

typealias Policy = ImageSlideshowPolicy
check(Policy.defaultInterval == 5, "The default dwell is five seconds")
for value: Double in [0, -1, -.infinity, .infinity, .nan] {
  check(Policy.normalizedInterval(value) == nil, "Malformed intervals are rejected")
  check(Policy(interval: value).interval == 5, "Malformed persisted intervals use the default")
}
for (input, expected): (Double, Double) in [(0.1, 0.5), (0.5, 0.5), (1, 1), (2.75, 2.75),
                                           (5, 5), (120, 120), (121, 120), (.greatestFiniteMagnitude, 120)] {
  check(Policy.normalizedInterval(input) == expected, "Valid intervals normalize to the supported range")
}
check(Policy.nextIndex(current: 0, count: 3, loops: false) == 1, "Advance follows the current list order")
check(Policy.nextIndex(current: 2, count: 3, loops: false) == nil, "Non-looping slideshows end at the last image")
check(Policy.nextIndex(current: 2, count: 3, loops: true) == 0, "Looping slideshows wrap to the first image")
check(Policy.nextIndex(current: 0, count: 1, loops: true) == 0, "A one-image loop remains in bounds")
check(Policy.nextIndex(current: 0, count: 1, loops: false) == nil, "A one-image non-looping show ends")
check(Policy.nextIndex(current: Int.max - 1, count: Int.max, loops: false) == nil, "Index arithmetic does not overflow")
for (current, count) in [(-1, 3), (3, 3), (Int.max, 3), (0, 0), (0, -1), (Int.min, Int.max)] {
  check(Policy.nextIndex(current: current, count: count, loops: true) == nil, "Stale or invalid rows are rejected")
}

var policy = Policy()
check(!policy.isRunning && policy.deadline == nil, "A new slideshow is stopped")
check(!policy.consumeAdvance(now: 1), "A stopped slideshow cannot advance")
check(policy.start(now: 10, imageIsReady: false), "A slideshow can start while decoding")
check(policy.isRunning && policy.deadline == nil, "Pending decoding has no dwell timer")
check(!policy.consumeAdvance(now: 1_000), "An arbitrarily slow decode is never skipped by the timer")
check(policy.imageDidDisplay(now: 1_000), "A decoded frame starts its full dwell")
check(policy.deadline == 1_005, "Dwell begins at presentation, not at load request")
check(!policy.consumeAdvance(now: 1_004.999), "A frame remains visible for the entire dwell")
check(policy.consumeAdvance(now: 1_005), "The deadline allows the next image")
check(policy.deadline == nil && policy.isRunning, "Advancing waits for the next decoded frame")
check(!policy.consumeAdvance(now: 2_000), "Repeated timer callbacks cannot skip pending frames")
check(policy.imageDidDisplay(now: 2_000), "A subsequent frame starts a new dwell")
check(policy.setInterval(2.75, now: 2_001), "Fractional dwell changes are supported")
check(policy.interval == 2.75 && policy.deadline == 2_003.75, "Editing restarts timing from now")
check(!policy.consumeAdvance(now: 2_003.74), "An edited interval does not fire early")
check(policy.consumeAdvance(now: 2_003.75), "An edited interval fires at its new deadline")
check(policy.setInterval(8, now: 3_000), "The interval can change while loading")
check(policy.deadline == nil, "An interval edit does not race an unfinished load")
check(policy.imageDidDisplay(now: 3_010) && policy.deadline == 3_018, "The next displayed frame uses the edited interval")
policy.imageWillLoad()
check(policy.isRunning && policy.deadline == nil, "Manual navigation clears the old deadline without stopping")
check(!policy.consumeAdvance(now: 4_000), "A manual load does not inherit the previous timer")
policy.imageDidDisplay(now: 4_000)
for invalid: Double in [0, -2, .nan, -.infinity, .infinity] {
  check(!policy.setInterval(invalid, now: 4_001), "Invalid edits are rejected")
  check(policy.interval == 8 && policy.deadline == 4_008, "Invalid edits preserve the active dwell")
}
for invalid: Double in [.nan, -.infinity, .infinity] {
  check(!policy.consumeAdvance(now: invalid), "Invalid clock values cannot advance")
  check(!policy.setInterval(10, now: invalid), "Invalid clock values cannot reschedule")
  check(policy.interval == 8 && policy.deadline == 4_008, "Invalid clocks preserve state")
}
check(!policy.setInterval(10, now: .greatestFiniteMagnitude), "Unrepresentable deadlines are rejected")
check(policy.interval == 8 && policy.deadline == 4_008, "Unrepresentable edits preserve state")
policy.stop()
check(!policy.isRunning && policy.deadline == nil && policy.interval == 8, "Stopping clears timing but keeps the interval")
check(!policy.imageDidDisplay(now: 5_000), "A decode finishing after stop cannot restart playback")
check(policy.deadline == nil && !policy.isRunning, "Late completion remains stopped")
check(policy.setInterval(3, now: 5_000) && policy.deadline == nil, "An interval edit while stopped does not start playback")
check(policy.start(now: 5_000, imageIsReady: true) && policy.deadline == 5_003, "A ready image starts its dwell immediately")
check(policy.start(now: 5_001, imageIsReady: false) && policy.deadline == nil, "Restarting during decoding drops an old timer")
check(!policy.start(now: .nan, imageIsReady: true) && !policy.isRunning, "Invalid starts fail safely")
check(!policy.start(now: .greatestFiniteMagnitude, imageIsReady: true), "A ready start requires a representable deadline")
check(!policy.isRunning && policy.deadline == nil, "Unrepresentable starts remain stopped")
policy.start(now: 10, imageIsReady: false)
check(!policy.imageDidDisplay(now: .infinity) && !policy.isRunning, "Invalid presentation time stops safely")

let a = URL(fileURLWithPath: "/fixtures/a.png")
let b = URL(fileURLWithPath: "/fixtures/b.png")
let c = URL(fileURLWithPath: "/fixtures/c.png")
let candidates = [a, b, c]
policy.start(now: 10, imageIsReady: false)
check(policy.recordFailure(of: a, among: candidates), "The first broken image is skipped")
check(policy.recordFailure(of: a, among: candidates), "Duplicate failure callbacks cannot exhaust other files")
check(policy.recordFailure(of: b, among: candidates), "A second failure still permits remaining candidates")
check(!policy.recordFailure(of: c, among: candidates), "A complete failed pass stops the slideshow")
check(!policy.isRunning && policy.deadline == nil, "An all-broken folder does not loop forever")
check(!policy.recordFailure(of: a, among: candidates), "Late failures cannot restart a stopped slideshow")
policy.start(now: 20, imageIsReady: false)
check(policy.recordFailure(of: a, among: candidates), "Starting again resets failed-file history")
policy.imageDidDisplay(now: 21)
policy.imageWillLoad()
check(policy.recordFailure(of: b, among: candidates), "A valid displayed image resets the failed pass")
check(policy.recordFailure(of: c, among: candidates), "Previously failed files can be retried after successful display")
check(!policy.recordFailure(of: a, among: candidates), "The next complete failed pass still stops")
policy.start(now: 30, imageIsReady: false)
check(!policy.recordFailure(of: a, among: []), "A disappearing folder stops safely")
policy.start(now: 30, imageIsReady: false)
check(!policy.recordFailure(of: a, among: [a, a]), "Duplicate list entries do not prevent failure exhaustion")
policy.start(now: 30, imageIsReady: false)
check(policy.recordFailure(of: a, among: candidates), "A failure is tracked by URL")
check(!policy.recordFailure(of: b, among: [b, a]), "Folder changes do not leave a stale failure count")

// A sorting caller resolves the same URL in its new order instead of reusing an old row.
let sorted = [c, a, b]
let selectedURL = b
check(Policy.nextIndex(current: sorted.firstIndex(of: selectedURL)!, count: sorted.count, loops: true) == 0,
      "Reordering advances from the selected URL's current index")
print("Image slideshow policy checks passed: \(checks)")
