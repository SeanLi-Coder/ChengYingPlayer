import Foundation

var checks = 0
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if condition() {
    print("PASS: \(message)")
  } else {
    failures += 1
    print("FAIL: \(message)")
  }
}

do {
  var clock = 0.0
  var reads = 0
  var pumps = 0
  let result = PlaybackModeWait.until(timeout: 8, now: { clock }, pump: {
    clock += 1
    pumps += 1
  }) {
    reads += 1
    return reads == 1
  }
  expect(result, "A true sample is accepted without a second read")
  expect(reads == 1, "A successful sample is read once")
  expect(pumps == 0, "Immediate success does not pump events")
}

if !CommandLine.arguments.contains("--transient-only") {
  do {
    var clock = 0.0
    var reads = 0
    var pumps = 0
    let result = PlaybackModeWait.until(timeout: 8, now: { clock }, pump: {
      clock += 1
      pumps += 1
    }) {
      reads += 1
      return reads >= 3
    }
    expect(result, "A pending condition succeeds before the deadline")
    expect(reads == 3 && pumps == 2, "Each pending round samples once and pumps once")
  }

  do {
    var clock = 0.0
    var reads = 0
    var pumps = 0
    let result = PlaybackModeWait.until(timeout: 8, now: { clock }, pump: {
      clock += 1
      pumps += 1
    }) {
      reads += 1
      return false
    }
    expect(!result, "An unsatisfied condition fails at the unchanged eight-second deadline")
    expect(clock == 8 && reads == 8 && pumps == 8, "The deadline does not add a final condition sample")
  }

  for elapsed in [8.0, 8.5] {
    var clock = 0.0
    var pumps = 0
    let result = PlaybackModeWait.until(timeout: 8, now: { clock }, pump: { pumps += 1 }) {
      clock = elapsed
      return true
    }
    expect(!result, "A true sample completing at \(elapsed) seconds is too late")
    expect(pumps == 0, "A late property read does not schedule another pump")
  }

  do {
    var clock = 0.0
    var reads = 0
    let result = PlaybackModeWait.until(timeout: 8, now: { clock }, pump: { clock = 9 }) {
      reads += 1
      return clock >= 8
    }
    expect(!result && reads == 1, "A condition that turns true after a late pump cannot pass")
  }

  do {
    var reads = 0
    var pumps = 0
    let result = PlaybackModeWait.until(timeout: 0, now: { 0 }, pump: { pumps += 1 }) {
      reads += 1
      return true
    }
    expect(!result && reads == 0 && pumps == 0, "An expired deadline neither samples nor pumps")
  }
}

print("Playback mode waiter checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
