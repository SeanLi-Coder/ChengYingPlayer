import AppKit
import AVFoundation

var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if value() { passed += 1; print("PASS: \(message)") }
  else { failed += 1; print("FAIL: \(message)") }
}

@discardableResult
func waitUntil(_ seconds: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while ProcessInfo.processInfo.systemUptime < deadline
  return predicate()
}

final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T) { self.value = value }
}

final class MPVSink {
  var available = true
  var flags: [String: Bool] = ["pause": false, "eof-reached": false]
  var doubles: [String: Double] = ["volume": 20, "speed": 1, "time-pos": 2]
  var reads: [String] = []
  var flagWrites: [(String, Bool, PlaybackCommandVerbosity)] = []
  var doubleWrites: [(String, Double, PlaybackCommandVerbosity)] = []
  var commands: [(String, [String], PlaybackCommandContext)] = []
  var writes: Int { flagWrites.count + doubleWrites.count + commands.count }
  lazy var transport = MPVPlaybackTransport(sink: .init(
    isAvailable: { [unowned self] in available },
    getFlag: { [unowned self] key in reads.append(key); return flags[key] ?? false },
    getDouble: { [unowned self] key in reads.append(key); return doubles[key] ?? 0 },
    setFlag: { [unowned self] key, value, verbosity in flagWrites.append((key, value, verbosity)) },
    setDouble: { [unowned self] key, value, verbosity in doubleWrites.append((key, value, verbosity)) },
    command: { [unowned self] key, values, context in commands.append((key, values, context)) }))
}

func testMPV() {
  let sink = MPVSink()
  let transport = sink.transport
  check(transport.kind == .mpv, "MPV adapter identifies its actual backend")
  check(transport.volumePercent == 20 && transport.rate == 1 && transport.position == 2 &&
    !transport.isPaused && !transport.isAtEOF, "MPV queries expose current property values")
  sink.doubles = ["volume": 70, "speed": 1.2, "time-pos": 9]
  sink.flags = ["pause": true, "eof-reached": true]
  check(transport.volumePercent == 70 && transport.rate == 1.2 && transport.position == 9 &&
    transport.isPaused && transport.isAtEOF, "MPV queries are live reads, not stale snapshots")
  sink.doubles["time-pos"] = .nan
  check(transport.position == nil, "Invalid live MPV position becomes unavailable")

  check(transport.setPaused(true, context: .init(verbosity: .verbose)) == .accepted,
    "MPV pause is accepted")
  check(sink.flagWrites.last?.0 == "pause" && sink.flagWrites.last?.1 == true &&
    sink.flagWrites.last?.2 == .verbose, "MPV pause preserves property, value and log level")
  check(transport.setPaused(false) == .accepted && sink.flagWrites.last?.1 == false &&
    sink.flagWrites.last?.2 == .debug, "MPV resume preserves default debug verbosity")
  check(transport.setVolumePercent(170, context: .init(verbosity: .verbose)) == .accepted,
    "MPV keeps existing amplification support")
  check(sink.doubleWrites.last?.0 == "volume" && sink.doubleWrites.last?.1 == 170 &&
    sink.doubleWrites.last?.2 == .verbose, "MPV volume preserves percentage units and verbosity")
  check(transport.setVolumePercent(-10) == .accepted && sink.doubleWrites.last?.1 == -10,
    "MPV leaves legacy unconstrained-volume policy to PlayerCore")
  check(transport.setRate(4) == .accepted && sink.doubleWrites.last?.0 == "speed" &&
    sink.doubleWrites.last?.1 == 4, "MPV rate retains its wider supported range")

  let cases: [(PlaybackSeekRequest.Reference, String)] = [
    (.absoluteSeconds, "absolute"), (.relativeSeconds, "relative"), (.absolutePercent, "absolute-percent")]
  for (reference, mode) in cases {
    for exact in [false, true] {
      let context = PlaybackCommandContext(checkError: false, verbosity: .verbose,
        seekTimingGeneration: UInt64.max - 2)
      check(transport.seek(.init(value: 12.25, reference: reference, exact: exact), context: context) == .accepted,
        "MPV \(mode) exact=\(exact) seek is accepted")
      let command = sink.commands.last!
      check(command.0 == "seek" && command.1 == ["12.25", mode + (exact ? "+exact" : "")],
        "MPV \(mode) exact=\(exact) keeps original argument mapping")
      check(!command.2.checkError && command.2.verbosity == .verbose &&
        command.2.seekTimingGeneration == UInt64.max - 2,
        "MPV \(mode) forwards untruncated generation and dispatch policy")
    }
  }
  check(transport.seek(.init(value: -2, reference: .relativeSeconds, exact: true)) == .accepted &&
    sink.commands.last?.1 == ["-2.0", "relative+exact"], "MPV backwards seek preserves signed delta")
  check(sink.commands.last?.2.checkError == true && sink.commands.last?.2.seekTimingGeneration == nil,
    "Default seek retains checking and does not invent a timing probe")
  let validWrites = sink.writes
  for value in [Double.nan, .infinity, -.infinity] {
    check(transport.setRate(value) == .invalidInput, "MPV rejects non-finite rate")
    check(transport.setVolumePercent(value) == .invalidInput, "MPV rejects non-finite volume")
    check(transport.seek(.init(value: value, reference: .absoluteSeconds, exact: true)) == .invalidInput,
      "MPV rejects non-finite seek")
  }
  check(transport.setRate(0) == .invalidInput && transport.setRate(-1) == .invalidInput,
    "MPV rejects unsupported non-positive rates")
  check(sink.writes == validWrites, "Invalid MPV input has no dispatch side effects")
  sink.available = false
  let readCount = sink.reads.count
  check(transport.volumePercent == 0 && transport.rate == 1 && transport.position == nil &&
    transport.isPaused && !transport.isAtEOF, "Destroyed MPV handle exposes safe query defaults")
  check(sink.reads.count == readCount, "Destroyed MPV handle never invokes property getters")
  check(transport.setPaused(false) == .unavailable && transport.setVolumePercent(50) == .unavailable &&
    transport.setRate(1) == .unavailable &&
    transport.seek(.init(value: 0, reference: .absoluteSeconds, exact: true)) == .unavailable,
    "Destroyed MPV handle rejects every command")
  check(sink.writes == validWrites, "Unavailable MPV has no dispatch side effects")
}

func testNative(_ url: URL) {
  var session: NativePlaybackSession? = NativePlaybackSession()
  var adapter: NativePlaybackTransport? = NativePlaybackTransport(session: session!)
  let weakSession = WeakReference(session!)
  let weakAdapter = WeakReference(adapter!)
  check(adapter!.kind == .native && adapter!.isPaused && adapter!.position == nil &&
    adapter!.volumePercent == 0 && adapter!.rate == 1 && !adapter!.isAtEOF,
    "Native adapter exposes empty defaults without inventing a loaded file")
  check(adapter!.setPaused(false) == .unavailable &&
    adapter!.seek(.init(value: 1, reference: .absoluteSeconds, exact: true)) == .unavailable,
    "Native adapter rejects transport before opening media")
  var idleQuery: NativePlaybackQueryResult?
  adapter!.captureCurrentState { idleQuery = $0 }
  check(waitUntil { idleQuery != nil }, "Idle native query completes without blocking main")
  if case .unavailable? = idleQuery { check(true, "Idle native query explicitly reports unavailable") }
  else { check(false, "Idle native query explicitly reports unavailable") }
  check(adapter!.setRate(1.2) == .accepted, "Native rate preference can be set before open")
  var callbackCount = 0
  adapter!.onSnapshot = { _ in callbackCount += 1 }
  session!.open(url, autoplay: false)
  check(waitUntil { adapter!.snapshot?.phase == .paused || adapter!.snapshot?.phase == .failed },
    "Native real fixture finishes asynchronous open")
  guard adapter!.snapshot?.phase == .paused else {
    check(false, "Native synthetic fixture must decode successfully"); return
  }
  check(callbackCount > 0 && adapter!.snapshot?.media != nil && adapter!.isPaused && !adapter!.isAtEOF,
    "Native snapshot callbacks carry actual decoder metadata")
  check(abs(adapter!.rate - 1.2) < 1e-6 && adapter!.volumePercent == 0,
    "Native open retains speed but starts muted")
  check(adapter!.setVolumePercent(70) == .accepted &&
    waitUntil { abs(adapter!.volumePercent - 70) < 1e-5 }, "Native 70-percent volume reaches real session")
  for _ in 0..<3 { _ = adapter!.setVolumePercent(adapter!.volumePercent + 5) }
  check(abs(adapter!.volumePercent - 85) < 1e-5,
    "Three volume shortcuts in one main turn accumulate immediately")
  check(waitUntil { abs(Double(adapter!.snapshot?.volume ?? 0) * 100 - 85) < 1e-4 },
    "Accumulated volume reaches the real worker snapshot")
  for _ in 0..<3 { _ = adapter!.setRate(adapter!.rate + 0.1) }
  check(abs(adapter!.rate - 1.5) < 1e-5,
    "Three rate shortcuts in one main turn accumulate immediately")
  check(waitUntil { abs(Double(adapter!.snapshot?.rate ?? 0) - 1.5) < 1e-5 && adapter!.snapshot?.phase == .paused },
    "Accumulated speed reaches the real worker and remains paused")
  let shortcutRevision = adapter!.snapshot!.revision
  for _ in 0..<3 { _ = adapter!.seek(.init(value: 0.1, reference: .relativeSeconds, exact: true)) }
  check(abs((adapter!.position ?? -1) - 0.3) < 0.001,
    "Three relative seeks in one main turn accumulate accepted targets")
  check(waitUntil { (adapter!.snapshot?.revision ?? 0) > shortcutRevision &&
    adapter!.snapshot?.phase == .paused && abs((adapter!.snapshot?.position ?? -1) - 0.3) < 0.001 },
    "Rapid relative seeks reach the final real decoded target")
  for _ in 0..<2 { _ = adapter!.setPaused(!adapter!.isPaused) }
  check(adapter!.isPaused, "Two pause toggles in one main turn retain the original paused intent")
  var toggleQuery: NativePlaybackQueryResult?
  adapter!.captureCurrentState { toggleQuery = $0 }
  check(waitUntil { toggleQuery != nil }, "Rapid toggle query reaches the worker after both commands")
  if case .ready(let state)? = toggleQuery {
    check(state.phase == .paused, "Two rapid toggles leave the real session paused")
  } else { check(false, "Two rapid toggles leave the real session paused") }

  func seek(_ value: Double, _ reference: PlaybackSeekRequest.Reference, target: Double) {
    let revision = adapter!.snapshot!.revision
    check(adapter!.seek(.init(value: value, reference: reference, exact: true)) == .accepted,
      "Native \(reference) seek is dispatched")
    check(waitUntil { (adapter!.snapshot?.revision ?? 0) > revision && adapter!.snapshot?.phase == .paused },
      "Native \(reference) seek completes its own decoded preroll")
    check(abs((adapter!.position ?? -100) - target) < 0.001 && adapter!.isPaused,
      "Native \(reference) seek reaches the requested paused timestamp")
  }
  seek(0.7, .absoluteSeconds, target: 0.7)
  seek(-0.2, .relativeSeconds, target: 0.5)
  seek(-20, .relativeSeconds, target: 0)
  seek(50, .absolutePercent, target: 1.5)
  var exactQuery: NativePlaybackQueryResult?
  var queryCount = 0
  var queryOnMain = false
  adapter!.captureCurrentState {
    exactQuery = $0; queryCount += 1; queryOnMain = Thread.isMainThread
  }
  check(exactQuery == nil, "Exact native query never calls back synchronously")
  check(waitUntil { exactQuery != nil }, "Exact native query returns from worker")
  if case .ready(let state)? = exactQuery {
    check(state.phase == .paused && abs(state.position - 1.5) < 0.001 &&
      state.revision == adapter!.snapshot!.revision, "Exact paused query reports the actual target and media revision")
  } else { check(false, "Exact paused query reports the actual target and media revision") }
  check(queryCount == 1 && queryOnMain, "Exact native query completes once on main")

  var obsoleteQuery: NativePlaybackQueryResult?
  var obsoleteCount = 0
  adapter!.captureCurrentState { obsoleteQuery = $0; obsoleteCount += 1 }
  seek(1.5, .absoluteSeconds, target: 1.5)
  check(waitUntil { obsoleteQuery != nil }, "A query superseded by a same-turn seek always completes")
  if case .superseded? = obsoleteQuery {
    check(true, "A same-turn seek cannot return a stale marker snapshot")
  } else { check(false, "A same-turn seek cannot return a stale marker snapshot") }
  check(obsoleteCount == 1, "Superseded seek query completes exactly once")
  let beforeInvalid = adapter!.snapshot!.revision
  for value in [Double.nan, .infinity, -.infinity] {
    check(adapter!.setRate(value) == .invalidInput && adapter!.setVolumePercent(value) == .invalidInput &&
      adapter!.seek(.init(value: value, reference: .absoluteSeconds, exact: true)) == .invalidInput,
      "Native rejects non-finite values before issuing commands")
  }
  check(adapter!.setVolumePercent(101) == .unsupported && adapter!.setVolumePercent(-1) == .unsupported,
    "Native explicitly rejects unsupported amplification instead of clamping silently")
  check(adapter!.setRate(0.49) == .unsupported && adapter!.setRate(2.01) == .unsupported &&
    adapter!.setRate(0) == .invalidInput, "Native explicitly reports supported-rate limits")
  check(adapter!.seek(.init(value: -1, reference: .absoluteSeconds, exact: true)) == .invalidInput &&
    adapter!.seek(.init(value: 101, reference: .absolutePercent, exact: true)) == .invalidInput,
    "Native validates absolute and percentage seek boundaries")
  check(adapter!.snapshot!.revision == beforeInvalid, "Invalid native input does not enqueue a seek")
  check(adapter!.setRate(0.8) == .accepted &&
    waitUntil { abs(adapter!.rate - 0.8) < 1e-6 && adapter!.snapshot?.phase == .paused },
    "Native rate change reaches session and preserves paused state")
  check(adapter!.setPaused(false) == .accepted && waitUntil { !adapter!.isPaused && (adapter!.position ?? 0) > 1.6 },
    "Native resume advances the actual asynchronous session")
  check(adapter!.setPaused(true) == .accepted && waitUntil { adapter!.snapshot?.phase == .paused },
    "Native pause changes the actual session state")
  seek(2.8, .absoluteSeconds, target: 2.8)
  check(adapter!.setPaused(false) == .accepted && waitUntil { adapter!.isAtEOF },
    "Native EOF query follows actual drained media, not command acceptance")
  check(adapter!.setPaused(false) == .accepted && waitUntil { !adapter!.isPaused && (adapter!.position ?? 100) < 1 },
    "Native resume from EOF restarts media")
  var replacedQuery: NativePlaybackQueryResult?
  var replacedCount = 0
  adapter!.captureCurrentState { replacedQuery = $0; replacedCount += 1 }
  session!.open(url, autoplay: false)
  check(waitUntil { adapter!.snapshot?.generation == 2 && adapter!.snapshot?.phase == .paused } &&
    adapter!.volumePercent == 0, "Opening another native file clears previous 70-percent volume")
  check(waitUntil { replacedQuery != nil }, "A query superseded by a same-turn open always completes")
  if case .superseded? = replacedQuery {
    check(true, "A same-turn open never returns the previous media snapshot")
  } else { check(false, "A same-turn open never returns the previous media snapshot") }
  check(replacedCount == 1, "Superseded open query completes exactly once")
  session!.stop()
  check(waitUntil { adapter!.snapshot?.phase == .idle } && adapter!.position == nil && adapter!.isPaused,
    "Native stop clears position without fabricating MPV events")
  check(adapter!.setPaused(false) == .unavailable, "Native stopped media cannot be resumed")
  var closed = false
  var shutdownQuery: NativePlaybackQueryResult?
  var shutdownCount = 0
  var shutdownOnMain = false
  adapter!.captureCurrentState {
    shutdownQuery = $0; shutdownCount += 1; shutdownOnMain = Thread.isMainThread
  }
  session!.shutdown { closed = true }
  check(waitUntil { closed && adapter!.snapshot?.phase == .closed }, "Native shutdown completes asynchronously")
  check(waitUntil { shutdownQuery != nil }, "Query pending during shutdown does not hang")
  if case .superseded? = shutdownQuery {
    check(true, "Shutdown invalidates a pending query instead of returning obsolete state")
  } else { check(false, "Shutdown invalidates a pending query instead of returning obsolete state") }
  check(shutdownCount == 1 && shutdownOnMain, "Shutdown query completes once on main")
  var terminalQuery: NativePlaybackQueryResult?
  var terminalCount = 0
  var terminalOnMain = false
  adapter!.captureCurrentState {
    terminalQuery = $0; terminalCount += 1; terminalOnMain = Thread.isMainThread
  }
  check(terminalQuery == nil && waitUntil { terminalQuery != nil }, "Query after shutdown remains asynchronous and completes")
  if case .unavailable? = terminalQuery { check(true, "Closed native query explicitly reports unavailable") }
  else { check(false, "Closed native query explicitly reports unavailable") }
  check(terminalCount == 1 && terminalOnMain, "Closed native query completes once on main")
  check(adapter!.setRate(1) == .unavailable && adapter!.setVolumePercent(10) == .unavailable &&
    adapter!.setPaused(false) == .unavailable &&
    adapter!.seek(.init(value: 0, reference: .absoluteSeconds, exact: true)) == .unavailable,
    "Native terminal session rejects further commands")
  adapter = nil
  session = nil
  check(waitUntil { weakAdapter.value == nil && weakSession.value == nil }, "Native adapter callbacks do not retain session or adapter")
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
testMPV()
testNative(URL(fileURLWithPath: CommandLine.arguments[1]))
print("RESULT: \(passed) passed; \(failed) failed")
print("LIMIT: Native command and clock checks do not certify displayed pixels or audible output.")
exit(failed == 0 ? 0 : 1)
