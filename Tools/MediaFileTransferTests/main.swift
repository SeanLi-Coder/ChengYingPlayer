import Foundation
import Darwin
import Dispatch

typealias Transfer = MediaFileTransfer
let manager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var checks = 0
enum TestError: Error { case assertion(String) }

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw TestError.assertion(message) }
  checks += 1
  print("PASS: \(message)")
}

func fixture(_ name: String) throws -> (URL, URL) {
  let base = root.appendingPathComponent(name)
  let input = base.appendingPathComponent("input"), output = base.appendingPathComponent("output")
  try manager.createDirectory(at: input, withIntermediateDirectories: true)
  try manager.createDirectory(at: output, withIntermediateDirectories: true)
  return (input, output)
}

@discardableResult
func file(_ directory: URL, _ name: String, _ contents: String = "synthetic-media-bytes") throws -> URL {
  let result = directory.appendingPathComponent(name)
  try Data(contents.utf8).write(to: result, options: .withoutOverwriting)
  return result
}

@discardableResult
func folder(_ directory: URL, _ name: String) throws -> URL {
  let result = directory.appendingPathComponent(name)
  try manager.createDirectory(at: result, withIntermediateDirectories: false)
  return result
}

func transfer(_ urls: [URL], _ output: URL, _ operation: Transfer.Operation = .copy) throws -> Transfer.Report {
  Transfer.execute(sources: try urls.map { try Transfer.Source(url: $0) },
                   destination: try Transfer.Source(url: output), operation: operation)
}

func noStaging(_ output: URL) throws {
  try check(!manager.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".chengying-transfer-") },
            "Private staging entries are cleaned")
}

func rejectsSource(_ url: URL, _ message: String) throws {
  do {
    _ = try Transfer.Source(url: url)
    fatalError("FAIL: \(message)")
  } catch { try check(true, message) }
}

func failed(_ report: Transfer.Report, _ expected: Transfer.TransferError, _ message: String) throws {
  try check(report.successes.isEmpty && report.failures.count == 1, message)
  try check(report.failures.first?.error as? Transfer.TransferError == expected,
            "Failure explains the rejected operation")
}

do {
  let (input, output) = try fixture("regular-copy")
  let original = try file(input, "movie.mp4")
  let report = try transfer([original], output)
  try check(report.successes.count == 1 && report.failures.isEmpty, "Regular file copy succeeds")
  try check(report.successes[0].source == original && report.successes[0].destination == output.appendingPathComponent("movie.mp4"),
            "Success reports exact source and destination URLs")
  try check(Data(contentsOf: original) == Data(contentsOf: report.successes[0].destination), "Copied bytes match the source")
  try check(manager.fileExists(atPath: original.path), "Copy retains the source")
  let empty = Transfer.execute(sources: [], destination: try Transfer.Source(url: output), operation: .copy)
  try check(empty.successes.isEmpty && empty.failures.isEmpty, "Empty batches are harmless")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("copy-metadata")
  let original = try file(input, "tagged.jpg", "synthetic-image")
  let key = "com.apple.metadata:_kMDItemUserTags"
  let tags = try PropertyListSerialization.data(fromPropertyList: ["Review\n6"], format: .binary, options: 0)
  let set = tags.withUnsafeBytes { setxattr(original.path, key, $0.baseAddress, $0.count, 0, 0) }
  try check(set == 0, "Synthetic Finder tags are created")
  let date = Date(timeIntervalSince1970: 1_600_000_000)
  try manager.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: original.path)
  let report = try transfer([original], output)
  try check(report.successes.count == 1, "Tagged regular file is copied")
  let copied = output.appendingPathComponent("tagged.jpg")
  var recovered = Data(count: tags.count)
  let count = recovered.withUnsafeMutableBytes { getxattr(copied.path, key, $0.baseAddress, $0.count, 0, 0) }
  try check(count == tags.count && recovered == tags, "Finder tag bytes are preserved")
  let attributes = try manager.attributesOfItem(atPath: copied.path)
  try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "Regular file permissions are preserved")
  try check((attributes[.modificationDate] as? Date) == date, "Modification date is preserved")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("directory-copy")
  let tree = try folder(input, "Album")
  let child = try folder(tree, "Nested")
  let regular = try file(child, "frame.png")
  _ = try file(tree, "zero.bin", "")
  _ = try file(tree, ".hidden", "hidden-fixture")
  let outside = try file(input, "outside.txt", "external-target-must-not-change")
  try manager.createSymbolicLink(atPath: child.appendingPathComponent("relative-link").path, withDestinationPath: "frame.png")
  try manager.createSymbolicLink(atPath: tree.appendingPathComponent("external-link").path, withDestinationPath: outside.path)
  try manager.createSymbolicLink(atPath: tree.appendingPathComponent("dangling-link").path, withDestinationPath: "/no-fixture-target")
  let report = try transfer([tree], output)
  try check(report.successes.count == 1 && report.failures.isEmpty, "Recursive directory copy succeeds")
  let copied = output.appendingPathComponent("Album")
  try check(Data(contentsOf: regular) == Data(contentsOf: copied.appendingPathComponent("Nested/frame.png")), "Nested file bytes are preserved")
  try check(manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("Nested/relative-link").path) == "frame.png",
            "Relative links are copied as links")
  try check(manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("external-link").path) == outside.path,
            "External links are preserved without following the target")
  try check(manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("dangling-link").path) == "/no-fixture-target",
            "Dangling links remain links")
  try check(String(contentsOf: outside, encoding: .utf8) == "external-target-must-not-change", "External target bytes stay untouched")
  try check(Data(contentsOf: copied.appendingPathComponent("zero.bin")).isEmpty, "Empty files are retained")
  try check(manager.fileExists(atPath: copied.appendingPathComponent(".hidden").path), "Hidden directory contents are retained")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("canonical-source-mapping")
  let real = try folder(input, "Real")
  let alias = input.appendingPathComponent("Alias")
  try manager.createSymbolicLink(at: alias, withDestinationURL: real)
  let original = try file(real, "portrait.jpg", "synthetic-portrait")
  let aliasSource = alias.appendingPathComponent("portrait.jpg")
  let canonicalOriginal = real.resolvingSymlinksInPath().appendingPathComponent("portrait.jpg").standardizedFileURL
  let report = try transfer([aliasSource], output, .move)
  try check(report.successes.count == 1 && report.failures.isEmpty, "Moving through an ancestor alias succeeds")
  try check(report.successes[0].source == aliasSource, "Move mapping retains the originally selected alias path")
  try check(report.successes[0].canonicalSource == canonicalOriginal, "Move mapping retains its pre-mutation canonical file identity path")
  try check(!manager.fileExists(atPath: original.path) && !manager.fileExists(atPath: aliasSource.path),
            "Canonical source mapping survives removal of both old lookup paths")
  try check(String(contentsOf: report.successes[0].destination, encoding: .utf8) == "synthetic-portrait",
            "Mapped file destination contains the original bytes")
  let tree = try folder(real, "Album")
  _ = try file(tree, "child.png", "synthetic-child")
  let aliasTree = alias.appendingPathComponent("Album")
  let canonicalTree = real.resolvingSymlinksInPath().appendingPathComponent("Album").standardizedFileURL
  let directoryReport = try transfer([aliasTree], output, .move)
  try check(directoryReport.successes.count == 1 && directoryReport.failures.isEmpty, "Moving a directory through an ancestor alias succeeds")
  try check(directoryReport.successes[0].source == aliasTree, "Directory mapping retains the selected alias path")
  try check(directoryReport.successes[0].canonicalSource == canonicalTree, "Directory mapping retains its pre-mutation canonical path")
  try check(!manager.fileExists(atPath: tree.path), "Directory canonical mapping survives removal of its old path")
  try check(String(contentsOf: directoryReport.successes[0].destination.appendingPathComponent("child.png"), encoding: .utf8) == "synthetic-child",
            "Mapped directory destination preserves child contents")
  let legacy = Transfer.Success(source: original, destination: output.appendingPathComponent("portrait.jpg"))
  try check(legacy.canonicalSource == nil, "Existing caller-created success fixtures remain source-compatible")
  try noStaging(output)
}

for operation in [Transfer.Operation.copy, .move] {
  let name = operation == .copy ? "copy" : "move"
  let (input, output) = try fixture("\(name)-collision")
  let original = try file(input, "same.mp4", "source-content")
  let existing = try file(output, "same.mp4", "existing-content")
  let report = try transfer([original], output, operation)
  try check(report.successes.isEmpty && report.failures.count == 1, "\(name) refuses same-name destination")
  try check((report.failures[0].error as NSError).code == CocoaError.fileWriteFileExists.rawValue, "Collision has a recognizable Cocoa error")
  try check(String(contentsOf: existing, encoding: .utf8) == "existing-content", "Collision never overwrites destination bytes")
  try check(String(contentsOf: original, encoding: .utf8) == "source-content", "Collision retains source bytes")
  try noStaging(output)

  let same = try transfer([original], input, operation)
  try failed(same, .sameLocation, "\(name) within the current folder is a safe no-op")

  let tree = try folder(input, "Tree")
  let subfolder = try folder(tree, "Subfolder")
  try failed(transfer([tree], tree, operation), .recursiveDestination, "Folder cannot be transferred to itself")
  try failed(transfer([tree], subfolder, operation), .recursiveDestination, "Folder cannot be transferred to its descendant")
  let alias = input.appendingPathComponent("destination-alias")
  try manager.createSymbolicLink(at: alias, withDestinationURL: subfolder)
  let aliasChild = try folder(subfolder, "Deeper")
  let aliasDestination = alias.appendingPathComponent(aliasChild.lastPathComponent)
  try failed(transfer([tree], aliasDestination, operation), .recursiveDestination,
             "Symlinked ancestor paths cannot hide a recursive destination")
}

do {
  let (input, output) = try fixture("same-volume-moves")
  let original = try file(input, "movie.mp4")
  let source = try Transfer.Source(url: original)
  let report = Transfer.execute(sources: [source], destination: try Transfer.Source(url: output), operation: .move)
  try check(report.successes.count == 1 && report.failures.isEmpty, "Same-volume file move succeeds")
  try check(!manager.fileExists(atPath: original.path), "Successful move removes the old name")
  try check(String(contentsOf: report.successes[0].destination, encoding: .utf8) == "synthetic-media-bytes", "Moved file retains its content")
  let tree = try folder(input, "Tree")
  _ = try file(tree, "image.png")
  let movedTree = try transfer([tree], output, .move)
  try check(movedTree.successes.count == 1 && movedTree.failures.isEmpty, "Same-volume directory move succeeds")
  try check(manager.fileExists(atPath: output.appendingPathComponent("Tree/image.png").path), "Directory move retains children")
  try noStaging(output)
}

for operation in [Transfer.Operation.copy, .move] {
  let name = operation == .copy ? "copy" : "move"
  let (input, output) = try fixture("\(name)-identity")
  let original = try file(input, "item.mp4", "old-content")
  let source = try Transfer.Source(url: original)
  let saved = input.appendingPathComponent("saved.mp4")
  try manager.moveItem(at: original, to: saved)
  _ = try file(input, "item.mp4", "replacement-content")
  let report = Transfer.execute(sources: [source], destination: try Transfer.Source(url: output), operation: operation)
  try failed(report, .changed, "A replaced source is rejected")
  try check(String(contentsOf: original, encoding: .utf8) == "replacement-content", "Replacement source is not changed")
  try check(String(contentsOf: saved, encoding: .utf8) == "old-content", "Original renamed source is not changed")
  try check(manager.contentsOfDirectory(atPath: output.path).isEmpty, "Invalid source creates no destination")

  let validSource = try Transfer.Source(url: original)
  let destination = try Transfer.Source(url: output)
  let oldOutput = output.deletingLastPathComponent().appendingPathComponent("old-output")
  try manager.moveItem(at: output, to: oldOutput)
  try manager.createDirectory(at: output, withIntermediateDirectories: false)
  let destinationReport = Transfer.execute(sources: [validSource], destination: destination, operation: operation)
  try failed(destinationReport, .changed, "A replaced destination directory is rejected")
  try check(manager.contentsOfDirectory(atPath: output.path).isEmpty && manager.contentsOfDirectory(atPath: oldOutput.path).isEmpty,
            "Neither replacement nor displaced destination is written")
}

do {
  let (input, output) = try fixture("ancestor-replacement")
  let nested = try folder(input, "nested")
  let original = try file(nested, "image.png")
  let source = try Transfer.Source(url: original)
  let old = input.appendingPathComponent("old-nested")
  try manager.moveItem(at: nested, to: old)
  let replacement = try folder(input, "nested")
  _ = try file(replacement, "image.png", "replacement")
  try failed(Transfer.execute(sources: [source], destination: Transfer.Source(url: output), operation: .move),
             .changed, "A replaced containing directory is rejected")
  let alias = input.appendingPathComponent("alias")
  try manager.createSymbolicLink(at: alias, withDestinationURL: old)
  let aliasSource = try Transfer.Source(url: alias.appendingPathComponent("image.png"))
  try manager.removeItem(at: alias)
  try manager.createSymbolicLink(at: alias, withDestinationURL: replacement)
  try failed(Transfer.execute(sources: [aliasSource], destination: Transfer.Source(url: output), operation: .copy),
             .changed, "Retargeting a symlinked ancestor invalidates a selection")
}

do {
  let (input, output) = try fixture("partial-failures")
  let missing = try file(input, "missing.png")
  let valid = try file(input, "valid.png")
  let sources = try [missing, valid].map { try Transfer.Source(url: $0) }
  try manager.removeItem(at: missing)
  let report = Transfer.execute(sources: sources, destination: try Transfer.Source(url: output), operation: .copy)
  try check(report.failures.count == 1 && report.failures[0].source == missing, "Missing source is reported separately")
  try check(report.successes.count == 1 && report.successes[0].source == valid, "Unrelated valid items continue after failure")
  try check(Data(contentsOf: valid) == Data(contentsOf: output.appendingPathComponent("valid.png")), "Partial success has complete correct bytes")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("overlapping-selections")
  let tree = try folder(input, "Tree")
  let child = try file(tree, "child.png")
  let unrelated = try file(input, "other.png")
  let report = try transfer([tree, child, unrelated], output, .move)
  try check(report.failures.count == 2 && report.successes.count == 1, "Overlapping parent/child selections reject both conflicting items")
  try check(report.failures.allSatisfy { $0.error as? Transfer.TransferError == .conflictingSelection }, "Overlapping selection failures are explained")
  try check(manager.fileExists(atPath: tree.path) && manager.fileExists(atPath: child.path), "Conflicting sources are preserved")
  let duplicate = try transfer([tree, tree], output)
  try check(duplicate.successes.isEmpty && duplicate.failures.count == 2, "Duplicate sources never transfer twice")
  let secondFolder = try folder(input, "Other")
  let duplicateName = try file(secondFolder, "child.png")
  let sameNames = try transfer([child, duplicateName], output)
  try check(sameNames.successes.isEmpty && sameNames.failures.count == 2, "Same-name batch sources do not depend on arbitrary item order")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("unsupported-items")
  let regular = try file(input, "regular.txt")
  let link = input.appendingPathComponent("root-link")
  try manager.createSymbolicLink(at: link, withDestinationURL: regular)
  try rejectsSource(link, "Top-level symlinks are not silently dereferenced")
  try rejectsSource(URL(string: "https://example.invalid/file.mp4")!, "Remote URL sources are rejected")
  try rejectsSource(URL(string: "file://remote.invalid\(regular.path)")!, "Foreign file URL hosts are rejected")
  try rejectsSource(URL(fileURLWithPath: input.path + "\0/regular.txt"), "NUL bytes in ancestor paths are rejected")
  try rejectsSource(input.appendingPathComponent("absent"), "Missing source cannot be captured")
  let fifo = input.appendingPathComponent("named-pipe")
  try check(mkfifo(fifo.path, 0o600) == 0, "Synthetic named pipe is created")
  try rejectsSource(fifo, "Top-level special files are rejected without blocking")
  let tree = try folder(input, "Tree")
  _ = try file(tree, "regular.mp4")
  try check(mkfifo(tree.appendingPathComponent("named-pipe").path, 0o600) == 0, "Nested synthetic named pipe is created")
  try failed(transfer([tree], output), .unsupportedItem, "A special file inside a folder aborts the complete folder copy")
  try check(!manager.fileExists(atPath: output.appendingPathComponent("Tree").path), "Incomplete directory is never published")
  try noStaging(output)
  try failed(transfer([regular], regular), .destinationNotDirectory, "Regular file cannot be a paste destination")
}

do {
  let (input, output) = try fixture("destination-symlink-collision")
  let original = try file(input, "image.jpg", "copy-source")
  let protected = try file(input, "protected.txt", "protected-bytes")
  let collision = output.appendingPathComponent("image.jpg")
  try manager.createSymbolicLink(at: collision, withDestinationURL: protected)
  let report = try transfer([original], output)
  try check(report.successes.isEmpty && report.failures.count == 1, "Existing destination symlink blocks publication")
  try check(manager.destinationOfSymbolicLink(atPath: collision.path) == protected.path, "Existing destination symlink is not replaced")
  try check(String(contentsOf: protected, encoding: .utf8) == "protected-bytes", "Existing destination symlink target is never written")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("readonly-directory-collision")
  let original = try folder(input, "ReadOnly")
  _ = try file(original, "image.jpg")
  try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: original.path)
  _ = try folder(output, "ReadOnly")
  let report = try transfer([original], output)
  try check(report.successes.isEmpty && report.failures.count == 1, "Read-only copied folder still refuses collision")
  try noStaging(output)
  try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: original.path)
}

do {
  let (input, output) = try fixture("immutable-partial-copy")
  let original = try file(input, "locked.jpg", "immutable-source")
  try check(chflags(original.path, UInt32(UF_IMMUTABLE)) == 0, "Synthetic immutable source is created")
  defer { _ = chflags(original.path, 0) }
  let existing = try file(output, "locked.jpg", "existing-target")
  let report = try transfer([original], output)
  try check(report.successes.isEmpty && report.failures.count == 1, "Immutable copy collision fails safely")
  try check(String(contentsOf: existing, encoding: .utf8) == "existing-target", "Immutable collision does not alter the existing destination")
  try check(String(contentsOf: original, encoding: .utf8) == "immutable-source", "Immutable original is retained")
  var originalStatus = stat()
  try check(lstat(original.path, &originalStatus) == 0 && originalStatus.st_flags & UInt32(UF_IMMUTABLE) != 0,
            "Cleanup never relaxes the original immutable flag")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("acl-partial-copy")
  let original = try folder(input, "Protected")
  let child = try file(original, "image.jpg")
  func chmodACL(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    try check(process.terminationStatus == 0, "Synthetic ACL operation succeeds")
  }
  try chmodACL(["+a", "everyone deny delete", child.path])
  defer { try? chmodACL(["-N", child.path]) }
  _ = try folder(output, "Protected")
  let report = try transfer([original], output)
  try check(report.successes.isEmpty && report.failures.count == 1, "Copied delete-denying ACL never permits an overwrite")
  try check(manager.fileExists(atPath: child.path), "ACL-protected original is retained")
  try noStaging(output)
}

do {
  let (input, output) = try fixture("unicode-and-many-files")
  let tree = try folder(input, "Album")
  for index in 0..<150 { _ = try file(tree, "Frame-\(index).jpg", "frame-\(index)") }
  _ = try file(tree, "\u{4E2D}\u{6587}-\u{1F4F7}.png", "unicode-file")
  let report = try transfer([tree], output)
  try check(report.failures.isEmpty && report.successes.count == 1, "Large directory copy completes")
  let result = output.appendingPathComponent("Album")
  try check(manager.contentsOfDirectory(atPath: result.path).count == 151, "Every directory entry is present")
  for index in 0..<150 {
    try check(String(contentsOf: result.appendingPathComponent("Frame-\(index).jpg"), encoding: .utf8) == "frame-\(index)",
              "Bulk file \(index) has exact bytes")
  }
  try check(String(contentsOf: result.appendingPathComponent("\u{4E2D}\u{6587}-\u{1F4F7}.png"), encoding: .utf8) == "unicode-file",
            "Unicode names are preserved")
  try noStaging(output)
}

for operation in [Transfer.Operation.copy, .move] {
  let operationName = operation == .copy ? "copy" : "move"
  let (input, output) = try fixture("concurrent-\(operationName)")
  var sources: [Transfer.Source] = []
  for index in 0..<24 {
    let directory = try folder(input, "source-\(index)")
    let original = try file(directory, "shared-name.mp4", "source-\(index)")
    sources.append(try Transfer.Source(url: original))
  }
  let destination = try Transfer.Source(url: output)
  let lock = NSLock()
  var reports: [Transfer.Report] = []
  DispatchQueue.concurrentPerform(iterations: sources.count) { index in
    let report = Transfer.execute(sources: [sources[index]], destination: destination, operation: operation)
    lock.lock()
    reports.append(report)
    lock.unlock()
  }
  let successes = reports.flatMap(\.successes), failures = reports.flatMap(\.failures)
  try check(successes.count == 1 && failures.count == 23, "Concurrent \(operationName) has exactly one exclusive publisher")
  let winner = successes[0]
  let winnerIndex = sources.firstIndex { $0.url == winner.source }!
  try check(String(contentsOf: winner.destination, encoding: .utf8) == "source-\(winnerIndex)",
            "Concurrent published bytes belong entirely to the winning source")
  for (index, source) in sources.enumerated() {
    if operation == .move && index == winnerIndex {
      try check(!manager.fileExists(atPath: source.url.path), "The successful concurrent move removes only its original name")
    } else {
      try check(String(contentsOf: source.url, encoding: .utf8) == "source-\(index)",
                "Concurrent \(operationName) preserves losing source \(index)")
    }
  }
  try noStaging(output)
}

do {
  let (input, output) = try fixture("source-name-swap-stress")
  for iteration in 0..<100 {
    let sourceDirectory = try folder(input, "source-\(iteration)")
    let targetDirectory = try folder(output, "target-\(iteration)")
    let a = "object-A-\(iteration)", b = "object-B-\(iteration)"
    let sourceURL = try file(sourceDirectory, "selected.mp4", a)
    let alternateURL = try file(sourceDirectory, "alternate.mp4", b)
    let source = try Transfer.Source(url: sourceURL)
    let target = try Transfer.Source(url: targetDirectory)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      for _ in 0..<200 {
        _ = renameatx_np(AT_FDCWD, sourceURL.path, AT_FDCWD, alternateURL.path, UInt32(RENAME_SWAP))
      }
      group.leave()
    }
    let report = Transfer.execute(sources: [source], destination: target, operation: .move)
    group.wait()
    let candidates = [sourceURL, alternateURL, targetDirectory.appendingPathComponent("selected.mp4")]
    let surviving = try candidates.filter { manager.fileExists(atPath: $0.path) }
      .map { try String(contentsOf: $0, encoding: .utf8) }.sorted()
    try check(surviving == [a, b].sorted(), "Rename race \(iteration) preserves both complete original objects")
    try check(report.successes.count + report.failures.count == 1, "Rename race \(iteration) has one terminal result")
    let correctlySelected = try report.successes.first.map { try String(contentsOf: $0.destination, encoding: .utf8) == a } ?? true
    try check(correctlySelected, "A successful racing move is the selected identity, not its replacement")
  }
}

print("PASS: \(checks) filesystem transfer checks")
