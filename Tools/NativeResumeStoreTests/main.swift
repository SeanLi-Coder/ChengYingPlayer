import Foundation
import CryptoKit
import Darwin

var checks = 0
var failures = 0
func check(_ value: Bool, _ label: String) {
  checks += 1
  if value { print("PASS: \(label)") }
  else { failures += 1; print("FAIL: \(label)") }
}
enum HarnessError: Error { case failed(String) }
func require(_ value: Bool, _ label: String) throws {
  guard value else { throw HarnessError.failed(label) }
}
func wait(_ condition: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(5)
  while !condition(), Date() < deadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
  }
  try require(condition(), "Main completion timed out")
}
let digest = String(repeating: "A1", count: 16)
let otherDigest = String(repeating: "B2", count: 16)
let owner = UUID()
let fm = FileManager.default
guard CommandLine.arguments.count == 2 else { fatalError("Expected owned test directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
var protected: [(URL, Data)] = []
var callbackCount = 0

func folder(_ name: String) throws -> URL {
  let url = root.appendingPathComponent(name, isDirectory: true)
  try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}
func seed(_ url: URL, content: String = "Unknown retained bytes\n", protect: Bool = true) throws {
  let bytes = Data(content.utf8)
  try bytes.write(to: url, options: .withoutOverwriting)
  if protect { protected.append((url, bytes)) }
}
func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }
func record(_ directory: URL, _ key: String = digest) -> URL { directory.appendingPathComponent(key) }
func ticket(_ store: NativePlaybackResumeStore, key: String = digest, generation: UInt64 = 1) throws -> NativePlaybackResumeTicket {
  guard let value = store.begin(digest: key, owner: owner, mediaGeneration: generation) else {
    throw HarnessError.failed("Ticket not issued")
  }
  return value
}
func save(_ store: NativePlaybackResumeStore, _ ticket: NativePlaybackResumeTicket,
          position: Double = 2.5, speed: Double = 1.25) throws -> NativePlaybackResumeResult {
  var results: [NativePlaybackResumeResult] = []
  store.enqueue(ticket, position: position, speed: speed) {
    check(Thread.isMainThread, "completion: save delivered on main")
    callbackCount += 1
    results.append($0)
  }
  try wait { !results.isEmpty }
  var drained = false
  store.drain { drained = true }
  try wait { drained }
  check(results.count == 1, "completion: save delivered exactly once")
  return results[0]
}
func noTemporaryFiles(_ directory: URL) -> Bool {
  guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
  return !names.contains { $0.hasPrefix(".native-resume-") }
}
final class Gate {
  let entered = DispatchSemaphore(value: 0)
  let released = DispatchSemaphore(value: 0)
  func pause() {
    entered.signal()
    if released.wait(timeout: .now() + 5) != .success { fatalError("Worker gate timed out") }
  }
  func awaitEntry() throws { try require(entered.wait(timeout: .now() + 5) == .success, "Worker never reached publication") }
}

do {
  // Pure policy checks do not use a real or synthetic media path.
  for value in [digest, otherDigest, String(repeating: "0", count: 32)] {
    check(NativePlaybackResumePolicy.isCanonicalDigest(value), "policy: canonical digest accepted")
  }
  for value in [digest.lowercased(), "../" + digest, digest + "A", String(digest.dropLast()),
                String(repeating: "G", count: 32), String(repeating: "Ａ", count: 32), ""] {
    check(!NativePlaybackResumePolicy.isCanonicalDigest(value), "policy: unsafe digest rejected")
  }
  for (position, speed) in [(Double.nan, 1.0), (.infinity, 1), (-1, 1), (1, .nan), (1, .infinity), (1, 0.49), (1, 2.01)] {
    check(NativePlaybackResumePolicy.record(position: position, speed: speed) == nil, "policy: invalid numeric state rejected")
  }
  check(NativePlaybackResumePolicy.record(position: -0.0, speed: 0.5) == Data("start=0.0\nspeed=0.5\n".utf8), "policy: zero normalized with minimum speed")
  check(NativePlaybackResumePolicy.record(position: 2.5, speed: 2) == Data("start=2.5\nspeed=2.0\n".utf8), "policy: exact locale-independent whitelist format")
  var policy = NativePlaybackResumePolicy(enabled: true)
  let first = policy.begin(digest: digest, owner: owner, mediaGeneration: 1)!
  check(first.owner == owner && first.mediaGeneration == 1 && first.digest == digest, "policy: immutable identity retained")
  check(policy.rejection(for: first) == nil, "policy: current owner accepted")
  let newer = policy.begin(digest: digest, owner: UUID(), mediaGeneration: 1)!
  check(policy.rejection(for: first) == .stale, "policy: different owner at same generation supersedes")
  check(policy.rejection(for: newer) == nil, "policy: newest owner accepted")
  policy.invalidate(first)
  check(policy.rejection(for: newer) == nil, "policy: stale invalidation cannot cancel newest owner")
  let independent = policy.begin(digest: otherDigest, owner: owner, mediaGeneration: 2)!
  check(policy.rejection(for: newer) == nil && policy.rejection(for: independent) == nil, "policy: distinct digests remain independent")
  var another = NativePlaybackResumePolicy(enabled: true)
  _ = another.begin(digest: digest, owner: newer.owner, mediaGeneration: newer.mediaGeneration)
  check(another.rejection(for: newer) == .stale, "policy: cross-store ticket rejected")
  policy.setEnabled(false)
  check(policy.rejection(for: newer) == .disabled, "policy: opt-out rejects existing owner")
  check(policy.begin(digest: digest, owner: owner, mediaGeneration: 3) == nil, "policy: opt-out denies admission")
  policy.setEnabled(true)
  check(policy.rejection(for: newer) == .stale, "policy: re-enable does not revive receipt")
  let beforeClear = policy.begin(digest: digest, owner: owner, mediaGeneration: 4)!
  let clearA = policy.beginClear(), clearB = policy.beginClear()
  check(policy.rejection(for: beforeClear) == .stale, "policy: clear invalidates old epoch")
  policy.endClear(clearA)
  check(policy.begin(digest: digest, owner: owner, mediaGeneration: 5) == nil, "policy: overlapping clear keeps gate closed")
  policy.endClear(UUID())
  check(policy.begin(digest: digest, owner: owner, mediaGeneration: 5) == nil, "policy: unknown completion cannot reopen gate")
  policy.endClear(clearB)
  check(policy.begin(digest: digest, owner: owner, mediaGeneration: 5) != nil, "policy: final matching completion allows new admission")

  let valid = try folder("valid")
  let store = NativePlaybackResumeStore(rootURL: valid, initiallyEnabled: true)
  let validTicket = try ticket(store)
  check(try save(store, validTicket) == .saved, "publication: valid receipt saved")
  check(contents(record(valid)) == Data("start=2.5\nspeed=1.25\n".utf8), "publication: only start and speed written")
  var savedStatus = stat()
  check(lstat(record(valid).path, &savedStatus) == 0 && savedStatus.st_mode & 0o777 == 0o600,
        "publication: record mode is private 0600")
  check(savedStatus.st_nlink == 1 && savedStatus.st_mode & S_IFMT == S_IFREG, "publication: final record is a single regular inode")
  check(noTemporaryFiles(valid), "publication: temporary link removed")
  check(try save(store, validTicket) == .stale, "publication: consumed ticket cannot publish twice")

  let badNumbers = try folder("bad-numbers")
  let badStore = NativePlaybackResumeStore(rootURL: badNumbers, initiallyEnabled: true)
  check(try save(badStore, ticket(badStore), position: .nan) == .ioError(EINVAL), "publication: invalid number fails closed")
  check((try fm.contentsOfDirectory(atPath: badNumbers.path)).isEmpty, "publication: invalid number creates no temporary record")

  for (name, spelling) in [("uppercase-conflict", digest), ("lowercase-conflict", digest.lowercased())] {
    let directory = try folder(name)
    try seed(record(directory, spelling))
    let writer = NativePlaybackResumeStore(rootURL: directory, initiallyEnabled: true)
    check(try save(writer, ticket(writer)) == .conflict, "\(name): unknown record blocks publication")
    check(contents(record(directory, spelling)) == Data("Unknown retained bytes\n".utf8), "\(name): unknown bytes preserved")
    check(noTemporaryFiles(directory), "\(name): no temporary leak")
  }
  let victim = try folder("victim")
  let victimFile = victim.appendingPathComponent("untouched.txt")
  try seed(victimFile)
  for name in ["symlink-conflict", "dangling-conflict"] {
    let directory = try folder(name)
    let target = name == "symlink-conflict" ? victimFile : victim.appendingPathComponent("absent.txt")
    try fm.createSymbolicLink(at: record(directory), withDestinationURL: target)
    let writer = NativePlaybackResumeStore(rootURL: directory, initiallyEnabled: true)
    check(try save(writer, ticket(writer)) == .conflict, "\(name): symlink blocks publication without following")
    check((try? fm.destinationOfSymbolicLink(atPath: record(directory).path)) == target.path, "\(name): original symlink preserved")
  }
  let directoryConflict = try folder("directory-conflict")
  try fm.createDirectory(at: record(directoryConflict), withIntermediateDirectories: false)
  let directoryWriter = NativePlaybackResumeStore(rootURL: directoryConflict, initiallyEnabled: true)
  check(try save(directoryWriter, ticket(directoryWriter)) == .conflict, "directory-conflict: existing directory preserved")

  let rootLink = root.appendingPathComponent("root-link")
  try fm.createSymbolicLink(at: rootLink, withDestinationURL: victim)
  let rootLinkStore = NativePlaybackResumeStore(rootURL: rootLink, initiallyEnabled: true)
  if case .ioError = try save(rootLinkStore, ticket(rootLinkStore)) { check(true, "root-symlink: root rejected") }
  else { check(false, "root-symlink: root rejected") }
  let nestedVictim = victim.appendingPathComponent("nested")
  try fm.createDirectory(at: nestedVictim, withIntermediateDirectories: false)
  let parentLinkStore = NativePlaybackResumeStore(rootURL: rootLink.appendingPathComponent("nested"), initiallyEnabled: true)
  if case .ioError = try save(parentLinkStore, ticket(parentLinkStore)) { check(true, "root-symlink: ancestor rejected") }
  else { check(false, "root-symlink: ancestor rejected") }
  check(!fm.fileExists(atPath: record(victim).path) && !fm.fileExists(atPath: record(nestedVictim).path), "root-symlink: destinations remain untouched")

  let absentRoot = root.appendingPathComponent("absent-root")
  let absentStore = NativePlaybackResumeStore(rootURL: absentRoot, initiallyEnabled: true)
  check(try save(absentStore, ticket(absentStore)) == .ioError(ENOENT), "root-failure: missing directory rejected")
  check(!fm.fileExists(atPath: absentRoot.path), "root-failure: store never creates missing root")
  let unwriteable = try folder("unwriteable")
  try require(chmod(unwriteable.path, 0o500) == 0, "Cannot restrict owned directory")
  let restrictedStore = NativePlaybackResumeStore(rootURL: unwriteable, initiallyEnabled: true)
  let restrictedResult = try save(restrictedStore, ticket(restrictedStore))
  try require(chmod(unwriteable.path, 0o700) == 0, "Cannot restore owned directory")
  check(restrictedResult == .ioError(EACCES), "permissions: actual denied write reported")
  check(noTemporaryFiles(unwriteable), "permissions: denied write creates no temporary leak")
  let shared = try folder("shared")
  try require(chmod(shared.path, 0o777) == 0, "Cannot set shared owned directory")
  let sharedStore = NativePlaybackResumeStore(rootURL: shared, initiallyEnabled: true)
  check(try save(sharedStore, ticket(sharedStore)) == .ioError(EACCES), "permissions: group or world writable root rejected")
  try require(chmod(shared.path, 0o700) == 0, "Cannot restore private owned directory")

  // The real worker pauses after writing its private temporary file, before the
  // final production ownership gate and POSIX publication. No result is mocked.
  for scenario in ["cancel", "opt-out", "opt-out-reenable", "new-owner", "external-conflict", "root-replacement", "temporary-symlink"] {
    let directory = try folder(scenario)
    let writer = NativePlaybackResumeStore(rootURL: directory, initiallyEnabled: true)
    let gate = Gate()
    writer.testStage = { _ in gate.pause() }
    let receipt = try ticket(writer)
    var result: NativePlaybackResumeResult?
    var completions = 0
    writer.enqueue(receipt, position: 2.5, speed: 1.25) {
      check(Thread.isMainThread, "\(scenario): callback on main")
      result = $0; completions += 1
    }
    try gate.awaitEntry()
    var expected: NativePlaybackResumeResult = .stale
    var retired: URL?
    switch scenario {
    case "cancel": writer.invalidate(receipt)
    case "opt-out", "opt-out-reenable":
      let optOutDone = DispatchSemaphore(value: 0)
      DispatchQueue.global().async { writer.setResumeEnabled(false); optOutDone.signal() }
      try require(optOutDone.wait(timeout: .now() + 5) == .success, "Off-main opt-out timed out")
      if scenario == "opt-out-reenable" { writer.setResumeEnabled(true) }
      else { expected = .disabled }
    case "new-owner": _ = try ticket(writer, generation: 2)
    case "external-conflict":
      try seed(record(directory))
      expected = .conflict
    case "root-replacement":
      let moved = root.appendingPathComponent("retired-root")
      try fm.moveItem(at: directory, to: moved)
      try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      retired = moved
      expected = .ioError(ESTALE)
    default:
      let name = try fm.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(".native-resume-") }!
      let temporary = directory.appendingPathComponent(name)
      try fm.removeItem(at: temporary)
      try fm.createSymbolicLink(at: temporary, withDestinationURL: victimFile)
      expected = .ioError(ESTALE)
    }
    gate.released.signal()
    try wait { result != nil }
    var drained = false
    writer.drain { drained = true }
    try wait { drained }
    check(result == expected, "\(scenario): publication honors late state change")
    check(completions == 1, "\(scenario): completion exactly once")
    check(noTemporaryFiles(directory) && (retired.map(noTemporaryFiles) ?? true), "\(scenario): owned temporary file removed")
    if scenario == "external-conflict" {
      check(contents(record(directory)) == Data("Unknown retained bytes\n".utf8), "external-conflict: racing external bytes preserved")
    } else {
      check(!fm.fileExists(atPath: record(directory).path) && (retired.map { !fm.fileExists(atPath: record($0).path) } ?? true),
            "\(scenario): no late record published")
    }
  }

  let ownersRoot = try folder("multi-owner")
  let ownersStore = NativePlaybackResumeStore(rootURL: ownersRoot, initiallyEnabled: true)
  let olderOwner = try ticket(ownersStore, generation: 1)
  let newestOwner = try ticket(ownersStore, generation: 2)
  let differentFile = try ticket(ownersStore, key: otherDigest, generation: 1)
  check(try save(ownersStore, olderOwner) == .stale, "multi-owner: obsolete queued receipt rejected")
  check(try save(ownersStore, newestOwner, position: 3) == .saved, "multi-owner: latest receipt actually saved")
  check(try save(ownersStore, differentFile, position: 4) == .saved, "multi-owner: different media actually saved independently")
  check(contents(record(ownersRoot)) == Data("start=3.0\nspeed=1.25\n".utf8) &&
        contents(record(ownersRoot, otherDigest)) == Data("start=4.0\nspeed=1.25\n".utf8),
        "multi-owner: final bytes belong to the correct media owners")

  let clearRoot = try folder("clear")
  let clearStore = NativePlaybackResumeStore(rootURL: clearRoot, initiallyEnabled: true)
  let clearGate = Gate()
  clearStore.testStage = { _ in clearGate.pause() }
  let before = try ticket(clearStore)
  var clearedWrite: NativePlaybackResumeResult?
  clearStore.enqueue(before, position: 2.5, speed: 1.25) { clearedWrite = $0 }
  try clearGate.awaitEntry()
  var clearResults: [NativePlaybackResumeClearResult] = []
  var operationOnWorker = false
  clearStore.performClear(operation: {
    operationOnWorker = !Thread.isMainThread
    // This is the exact owned synthetic directory, never a user directory.
    try fm.removeItem(at: clearRoot)
    try fm.createDirectory(at: clearRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }) {
    check(Thread.isMainThread, "clear: completion on main")
    clearResults.append($0)
  }
  check(clearStore.begin(digest: digest, owner: owner, mediaGeneration: 2) == nil, "clear: admission denied before barrier completion")
  clearGate.released.signal()
  try wait { !clearResults.isEmpty && clearedWrite != nil }
  check(operationOnWorker, "clear: deletion operation ran off-main")
  check(clearResults == [.cleared], "clear: successful operation delivered once")
  check(clearedWrite == .stale, "clear: staged pre-clear write rejected")
  check((try fm.contentsOfDirectory(atPath: clearRoot.path)).isEmpty, "clear: no pre-clear record resurrected")
  check(try save(clearStore, before) == .stale, "clear: old receipt remains invalid after completion")
  clearStore.testStage = nil
  check(try save(clearStore, ticket(clearStore, generation: 3)) == .saved, "clear: new owner can save after completed clear")

  let failedClearRoot = try folder("failed-clear")
  try seed(record(failedClearRoot))
  let failedClearStore = NativePlaybackResumeStore(rootURL: failedClearRoot, initiallyEnabled: true)
  let failedReceipt = try ticket(failedClearStore)
  var failedClear: NativePlaybackResumeClearResult?
  failedClearStore.performClear(operation: { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }) { failedClear = $0 }
  try wait { failedClear != nil }
  check(failedClear == .ioError(EACCES), "clear-failure: sanitized errno returned")
  check(contents(record(failedClearRoot)) == Data("Unknown retained bytes\n".utf8), "clear-failure: retained bytes unchanged")
  check(try save(failedClearStore, failedReceipt) == .stale, "clear-failure: failed clear still invalidates old receipts")
  check(failedClearStore.begin(digest: otherDigest, owner: owner, mediaGeneration: 2) != nil, "clear-failure: gate reopens without falsifying clear success")

  let overlappingRoot = try folder("overlapping-clear")
  let overlapping = NativePlaybackResumeStore(rootURL: overlappingRoot, initiallyEnabled: true)
  var clearOrder: [Int] = []
  overlapping.performClear(operation: {}) { _ in
    clearOrder.append(1)
    check(overlapping.begin(digest: digest, owner: owner, mediaGeneration: 1) == nil, "overlapping-clear: first completion cannot reopen second gate")
    overlapping.setResumeEnabled(false)
  }
  overlapping.performClear(operation: {}) { _ in clearOrder.append(2) }
  try wait { clearOrder.count == 2 }
  check(clearOrder == [1, 2], "overlapping-clear: serial completion order retained")
  check(overlapping.begin(digest: digest, owner: owner, mediaGeneration: 2) == nil, "overlapping-clear: clear never changes opt-out preference")
  overlapping.setResumeEnabled(true)
  check(overlapping.begin(digest: digest, owner: owner, mediaGeneration: 2) != nil, "overlapping-clear: explicit enable permits fresh owner")

  for (index, entry) in protected.enumerated() {
    let actual = contents(entry.0)
    let expectedHash = SHA256.hash(data: entry.1)
    check(actual.map { SHA256.hash(data: $0) == expectedHash } == true, "identity: protected fixture \(index) hash unchanged")
  }
  print("COMPLETION_COUNT: \(callbackCount)")
} catch {
  print("HARNESS_ERROR: \(error)")
  exit(2)
}
print("Resume store: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
