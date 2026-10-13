import Foundation
import CryptoKit
import Darwin

var checks = 0
var failures = 0
func check(_ condition: Bool, _ label: String) {
  checks += 1
  if condition { print("PASS: \(label)") }
  else { failures += 1; print("FAIL: \(label)") }
}
enum HarnessError: Error { case setup(String) }
func require(_ condition: Bool, _ label: String) throws {
  if !condition { throw HarnessError.setup(label) }
}
func wait(_ condition: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(5)
  while !condition() && Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
  }
  try require(condition(), "Main callback timed out")
}
let fm = FileManager.default
let key = Preference.Key.resumeLastPosition.rawValue
let digest = String(repeating: "C3", count: 16)
let otherDigest = String(repeating: "D4", count: 16)
guard CommandLine.arguments.count == 2 else { fatalError("Expected owned artifact directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var suites: [(String, UserDefaults)] = []
var registeredDomains: [String] = []
var protected: [(URL, Data)] = []
let finalPoint = NativePlaybackResumePoint(position: 8, duration: 10, speed: 1.5)!
let baselinePoint = NativePlaybackResumePoint(position: 2, duration: 10, speed: 1.25)!

func context(_ name: String, enabled: Bool = true, registeredOnly: Bool = false) throws -> (URL, UserDefaults, NativePlaybackResumeService) {
  let directory = root.appendingPathComponent(name, isDirectory: true)
  try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let domain = "com.chengying.resume-service-test.\(UUID().uuidString)"
  registeredDomains.append(domain)
  try Data((registeredDomains.joined(separator: "\n") + "\n").utf8)
    .write(to: root.appendingPathComponent("owned-domains.txt"), options: .atomic)
  guard let defaults = UserDefaults(suiteName: domain) else { throw HarnessError.setup("Isolated defaults unavailable") }
  suites.append((domain, defaults))
  try require(defaults.persistentDomain(forName: domain) == nil, "Owned preference domain was not empty")
  defaults.register(defaults: [key: enabled])
  if !registeredOnly { defaults.set(enabled, forKey: key) }
  return (directory, defaults, NativePlaybackResumeService(rootURL: directory, defaults: defaults))
}
func receipt(_ directory: URL, _ service: NativePlaybackResumeService, generation: UInt64 = 1,
             hash: String = digest) -> NativePlaybackResumeReceipt {
  NativePlaybackResumeReceipt(url: directory.appendingPathComponent("synthetic.mp4"), generation: generation,
                              digest: hash, service: service)
}
func file(_ directory: URL, _ hash: String = digest) -> URL { directory.appendingPathComponent(hash) }
func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }
func finish(_ value: NativePlaybackResumeReceipt, _ service: NativePlaybackResumeService) throws {
  var callbacks = 0
  value.finishIfRequested {
    check(Thread.isMainThread, "finish: callback delivered on main")
    callbacks += 1
  }
  try wait { callbacks != 0 }
  var drained = false
  service.store.drain { drained = true }
  try wait { drained }
  check(callbacks == 1, "finish: completion delivered exactly once")
}
final class Gate {
  let entered = DispatchSemaphore(value: 0)
  let released = DispatchSemaphore(value: 0)
  func pause() {
    entered.signal()
    if released.wait(timeout: .now() + 5) != .success { fatalError("Worker gate timed out") }
  }
  func awaitEntry() throws { try require(entered.wait(timeout: .now() + 5) == .success, "No real publication reached gate") }
}

do {
  for (position, duration, speed) in [(Double.nan, 10.0, 1.0), (.infinity, 10, 1), (-1, 10, 1),
                                    (1, .nan, 1), (1, .infinity, 1), (0, 0, 1), (0, -1, 1),
                                    (10.11, 10, 1), (1, 10, .nan), (1, 10, .infinity), (1, 10, 0.49), (1, 10, 2.01)] {
    check(NativePlaybackResumePoint(position: position, duration: duration, speed: speed) == nil,
          "point: invalid worker state rejected")
  }
  let clamped = NativePlaybackResumePoint(position: 10.05, duration: 10, speed: 2)
  check(clamped?.position == 10 && clamped?.duration == 10 && clamped?.speed == 2, "point: small EOF clock excess clamps to duration")
  check(NativePlaybackResumePoint(position: 0, duration: 10, speed: 0.5) != nil, "point: valid zero and minimum speed accepted")

  let (sharedRoot, sharedDefaults, _) = try context("shared", registeredOnly: true)
  ResumeServiceFixture.root = sharedRoot
  ResumeServiceFixture.defaults = sharedDefaults
  check(NativePlaybackResumeService.shared.store.begin(digest: digest, owner: UUID(), mediaGeneration: 1) != nil,
        "service: registered defaults honored by isolated shared boundary")

  for scenario in ["arm-before-capture", "arm-after-capture", "finish-before-capture"] {
    let (directory, _, service) = try context(scenario)
    let value = receipt(directory, service, generation: 7)
    check(value.url == directory.appendingPathComponent("synthetic.mp4") && value.generation == 7,
          "\(scenario): media identity retained")
    check(!value.claimResultDelivery(), "\(scenario): unfinished receipt cannot claim metadata")
    if scenario == "arm-after-capture" { value.captureFinal(finalPoint) }
    value.requestSave(replacement: false, overriding: nil)
    var earlyCallbacks = 0
    if scenario == "finish-before-capture" {
      value.finishIfRequested { earlyCallbacks += 1 }
      check(earlyCallbacks == 0 && value.result == nil, "finish-before-capture: waiter remains pending")
    }
    if scenario != "arm-after-capture" { value.captureFinal(finalPoint) }
    try finish(value, service)
    check(value.result == .saved, "\(scenario): armed final point saved")
    check(bytes(file(directory)) == Data("start=8.0\nspeed=1.5\n".utf8), "\(scenario): actual final bytes match")
    check(value.claimResultDelivery(), "\(scenario): completed receipt permits one metadata claim")
    check(!value.claimResultDelivery(), "\(scenario): repeated metadata claim rejected")
    if scenario == "finish-before-capture" { check(earlyCallbacks == 1, "finish-before-capture: pending completion delivered once") }
  }

  let (compatRoot, _, compatService) = try context("compatibility")
  let compat = receipt(compatRoot, compatService)
  compat.compatibilityRestoreID = UUID()
  compat.captureFinal(finalPoint)
  try finish(compat, compatService)
  check(!compat.saveRequested && compat.result == nil, "compatibility: capture alone does not arm saving")
  check(!fm.fileExists(atPath: file(compatRoot).path), "compatibility: handoff alone creates no record")
  compat.requestSave(replacement: false, overriding: baselinePoint)
  try finish(compat, compatService)
  check(compat.result == .saved && bytes(file(compatRoot)) == Data("start=2.0\nspeed=1.25\n".utf8),
        "compatibility: later user close saves owned override")

  for scenario in ["preview-before-capture", "preview-after-capture"] {
    let (directory, _, service) = try context(scenario)
    let value = receipt(directory, service)
    if scenario == "preview-after-capture" { value.captureFinal(finalPoint) }
    value.requestSave(replacement: true, overriding: baselinePoint)
    if scenario == "preview-before-capture" { value.captureFinal(finalPoint) }
    value.requestSave(replacement: false, overriding: nil)
    try finish(value, service)
    check(value.result == .saved && value.isReplacement, "\(scenario): first exit reason retained")
    check(value.point?.position == 2 && bytes(file(directory)) == Data("start=2.0\nspeed=1.25\n".utf8),
          "\(scenario): preview baseline wins over temporary clock")
  }

  for scenario in ["authoritative-nil-before-capture", "authoritative-nil-after-capture"] {
    let (directory, _, service) = try context(scenario)
    let value = receipt(directory, service)
    if scenario == "authoritative-nil-after-capture" { value.captureFinal(finalPoint) }
    value.requestSave(replacement: false, overriding: nil, authoritative: true)
    if scenario == "authoritative-nil-before-capture" { value.captureFinal(finalPoint) }
    value.requestSave(replacement: true, overriding: nil)
    try finish(value, service)
    check(value.saveRequested && !value.isReplacement, "\(scenario): explicit close intent retained")
    check(value.point == nil && value.result == nil, "\(scenario): unavailable authoritative point never falls back")
    check(!fm.fileExists(atPath: file(directory).path), "\(scenario): unrelated final clock never persisted")
  }

  let (reentrantRoot, _, reentrantService) = try context("reentrant")
  let reentrant = receipt(reentrantRoot, reentrantService)
  reentrant.requestSave(replacement: false, overriding: baselinePoint)
  reentrant.captureFinal(finalPoint)
  var order: [String] = []
  var claims: [Bool] = []
  reentrant.finishIfRequested {
    order.append("first")
    claims.append(reentrant.claimResultDelivery())
    reentrant.finishIfRequested {
      order.append("nested")
      claims.append(reentrant.claimResultDelivery())
    }
  }
  reentrant.finishIfRequested {
    order.append("second")
    claims.append(reentrant.claimResultDelivery())
  }
  check(!reentrant.claimResultDelivery(), "reentrant: in-flight publication cannot claim metadata")
  reentrant.requestSave(replacement: true, overriding: finalPoint)
  try wait { order.count == 3 }
  check(order == ["first", "nested", "second"], "reentrant: all completions execute once in owned order")
  check(claims == [true, false, false], "reentrant: nested completion consumes metadata exactly once")
  check(reentrant.result == .saved && !reentrant.isReplacement && reentrant.point?.position == 2,
        "reentrant: in-flight request cannot mutate committed intent")
  let committedBytes = try Data(contentsOf: file(reentrantRoot))
  try finish(reentrant, reentrantService)
  check(bytes(file(reentrantRoot)) == committedBytes, "reentrant: repeated finish does not rewrite bytes")

  let (unavailableRoot, _, unavailableService) = try context("unavailable")
  let unavailable = receipt(unavailableRoot, unavailableService)
  unavailable.requestSave(replacement: false, overriding: nil)
  unavailable.captureFinal(nil)
  unavailable.captureFinal(finalPoint)
  try finish(unavailable, unavailableService)
  check(unavailable.result == nil && unavailable.point == nil, "unavailable: duplicate capture cannot resurrect discarded clock")
  check(!fm.fileExists(atPath: file(unavailableRoot).path), "unavailable: no fabricated resume point written")
  check(unavailable.claimResultDelivery() && !unavailable.claimResultDelivery(),
        "unavailable: nil result still consumes delivery only once")

  let (disabledRoot, disabledDefaults, disabledService) = try context("disabled", enabled: false)
  let disabled = receipt(disabledRoot, disabledService)
  disabledDefaults.set(true, forKey: key)
  disabled.requestSave(replacement: false, overriding: nil)
  disabled.captureFinal(finalPoint)
  try finish(disabled, disabledService)
  check(disabled.result == nil && !fm.fileExists(atPath: file(disabledRoot).path), "disabled: nil admission ticket never revives after enable")
  let enabled = receipt(disabledRoot, disabledService, generation: 2)
  enabled.requestSave(replacement: false, overriding: nil)
  enabled.captureFinal(finalPoint)
  try finish(enabled, disabledService)
  check(enabled.result == .saved, "disabled: explicit enable applies to a fresh receipt")

  let (ownersRoot, _, ownersService) = try context("owners")
  let older = receipt(ownersRoot, ownersService), newer = receipt(ownersRoot, ownersService, generation: 2)
  for value in [older, newer] {
    value.requestSave(replacement: false, overriding: nil)
    value.captureFinal(value === older ? finalPoint : baselinePoint)
    try finish(value, ownersService)
  }
  check(older.result == .stale && newer.result == .saved, "owners: latest receipt owns publication")
  check(bytes(file(ownersRoot)) == Data("start=2.0\nspeed=1.25\n".utf8), "owners: old completion cannot write the new owner's file")

  for scenario in ["invalidate", "kvo-opt-out", "clear-late"] {
    let (directory, defaults, service) = try context(scenario)
    let value = receipt(directory, service)
    let gate = Gate()
    service.store.testStage = { _ in gate.pause() }
    value.requestSave(replacement: false, overriding: nil)
    value.captureFinal(finalPoint)
    var callbacks = 0
    value.finishIfRequested { callbacks += 1 }
    try gate.awaitEntry()
    var clearResult: NativePlaybackResumeClearResult?
    if scenario == "invalidate" {
      value.invalidate()
    } else if scenario == "kvo-opt-out" {
      let changed = DispatchSemaphore(value: 0)
      DispatchQueue.global().async { defaults.set(false, forKey: key); changed.signal() }
      try require(changed.wait(timeout: .now() + 5) == .success, "Actual defaults KVO setter timed out")
      check(service.store.begin(digest: otherDigest, owner: UUID(), mediaGeneration: 2) == nil,
            "kvo-opt-out: off-main setter synchronously closes admission")
    } else {
      service.clearPlaybackProgress(operation: {
        try fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }) { clearResult = $0 }
      check(service.progressRecordsEpoch == value.progressRecordsEpoch + 1, "clear-late: progress epoch advances synchronously")
    }
    gate.released.signal()
    try wait { callbacks == 1 }
    if scenario == "clear-late" { try wait { clearResult != nil } }
    check(value.result == (scenario == "kvo-opt-out" ? .disabled : .stale), "\(scenario): late receipt result propagated")
    check(!fm.fileExists(atPath: file(directory).path), "\(scenario): no late record written")
    var drained = false
    service.store.drain { drained = true }
    try wait { drained }
    check(callbacks == 1, "\(scenario): completion remains exactly once")
    if scenario == "kvo-opt-out" {
      defaults.set(true, forKey: key)
      check(service.store.begin(digest: otherDigest, owner: UUID(), mediaGeneration: 3) != nil,
            "kvo-opt-out: real preference enable permits new admission")
      try finish(value, service)
      check(!fm.fileExists(atPath: file(directory).path), "kvo-opt-out: re-enable does not retry completed receipt")
    }
    if scenario == "clear-late" { check(clearResult == .cleared, "clear-late: service propagates real clear completion") }
  }

  let (toggleRoot, toggleDefaults, toggleService) = try context("kvo-opt-out-reenable")
  let toggled = receipt(toggleRoot, toggleService)
  let toggleGate = Gate()
  toggleService.store.testStage = { _ in toggleGate.pause() }
  toggled.requestSave(replacement: false, overriding: nil)
  toggled.captureFinal(finalPoint)
  var toggleCallbacks = 0
  toggled.finishIfRequested { toggleCallbacks += 1 }
  try toggleGate.awaitEntry()
  let changed = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    toggleDefaults.set(false, forKey: key)
    toggleDefaults.set(true, forKey: key)
    changed.signal()
  }
  try require(changed.wait(timeout: .now() + 5) == .success, "Actual false-to-true KVO setter timed out")
  check(toggleDefaults.bool(forKey: key), "kvo-opt-out-reenable: persisted preference is enabled")
  check(toggleService.store.begin(digest: otherDigest, owner: UUID(), mediaGeneration: 2) != nil,
        "kvo-opt-out-reenable: future admission reopens")
  toggleGate.released.signal()
  try wait { toggleCallbacks == 1 }
  check(toggled.result == .stale, "kvo-opt-out-reenable: old receipt remains invalid after re-enable")
  check(!fm.fileExists(atPath: file(toggleRoot).path), "kvo-opt-out-reenable: old position is not resurrected")
  try finish(toggled, toggleService)
  check(toggleCallbacks == 1, "kvo-opt-out-reenable: original completion stays exactly once")

  let (epochsRoot, _, epochsService) = try context("epochs")
  let oldEpoch = receipt(epochsRoot, epochsService)
  epochsService.invalidateRecentRecords()
  check(oldEpoch.recentRecordsEpoch != epochsService.recentRecordsEpoch, "epochs: old metadata receipt detects history clear")
  check(oldEpoch.progressRecordsEpoch == epochsService.progressRecordsEpoch, "epochs: history clear does not falsely claim progress clear")
  let currentEpoch = receipt(epochsRoot, epochsService, generation: 2)
  check(currentEpoch.recentRecordsEpoch == epochsService.recentRecordsEpoch, "epochs: new receipt captures current metadata epoch")
  var clearFailure: NativePlaybackResumeClearResult?
  epochsService.clearPlaybackProgress(operation: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }) { clearFailure = $0 }
  try wait { clearFailure != nil }
  check(clearFailure == .ioError(EACCES), "epochs: real failed clear result propagated")
  check(currentEpoch.progressRecordsEpoch != epochsService.progressRecordsEpoch, "epochs: failed clear also invalidates old progress metadata")
  check(currentEpoch.recentRecordsEpoch == epochsService.recentRecordsEpoch, "epochs: progress clear preserves independent history epoch")

  let (conflictRoot, _, conflictService) = try context("conflict")
  let original = Data("Unknown retained bytes\n".utf8)
  try original.write(to: file(conflictRoot), options: .withoutOverwriting)
  protected.append((file(conflictRoot), original))
  let conflicting = receipt(conflictRoot, conflictService)
  conflicting.requestSave(replacement: false, overriding: nil)
  conflicting.captureFinal(finalPoint)
  try finish(conflicting, conflictService)
  check(conflicting.result == .conflict, "failure: conflict returned through receipt")

  let (lifetimeRoot, lifetimeDefaults, _) = try context("observer-lifetime")
  weak var releasedObserver: NativePlaybackResumeService?
  autoreleasepool {
    var observer: NativePlaybackResumeService? = NativePlaybackResumeService(rootURL: lifetimeRoot, defaults: lifetimeDefaults)
    releasedObserver = observer
    observer = nil
  }
  check(releasedObserver == nil, "lifetime: real KVO observer releases without retention cycle")
  lifetimeDefaults.set(false, forKey: key)
  lifetimeDefaults.set(true, forKey: key)
  check(lifetimeDefaults.bool(forKey: key), "lifetime: preference change after observer release remains safe")

  for (index, item) in protected.enumerated() {
    check(bytes(item.0).map { SHA256.hash(data: $0) == SHA256.hash(data: item.1) } == true,
          "identity: protected fixture \(index) hash unchanged")
  }
} catch {
  print("HARNESS_ERROR: \(error)")
  failures += 1
}
// Remove only the unique domains this process created. Retain owned filesystem
// evidence; never reset standard defaults or any existing application domain.
for (name, defaults) in suites {
  defaults.removePersistentDomain(forName: name)
  _ = defaults.synchronize()
  check(defaults.persistentDomain(forName: name)?.isEmpty != false, "cleanup: owned defaults domain removed")
}
print("Resume service: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
