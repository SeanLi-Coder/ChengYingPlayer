import Foundation

let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let destination = CommandLine.arguments[2]
let mode = CommandLine.arguments[3]
let changes: [String: (String, String)] = [
  "deadline": ("private func beforeDeadline(_ value: Operation) -> Bool { clock() < value.deadline }",
               "private func beforeDeadline(_ value: Operation) -> Bool { true }"),
  "activation-status": ("var activationAcknowledged = false", "var activationAcknowledged = true"),
  "readback-cancel": ("guard owns(value), value.phase == .awaitingLoaded else { return }",
                      "guard owns(value) else { return }"),
  "owner": ("guard isCurrent(value.token) else { finish(value, .superseded); return false }",
            "guard isCurrent(value.token) || operation === value else { finish(value, .superseded); return false }"),
  "old-end-event": ("case .endFile(let entryID):\n      guard value.entryIDs.contains(entryID) else { return }",
                    "case .endFile:\n      // Negative control: accept an old entry's END_FILE.")
]
var result = source
if mode == "prefix" {
  let start = source.range(of: "  private func matchesPrefix(")!.lowerBound
  let end = source.range(of: "\n  }", range: start..<source.endIndex)!.upperBound
  let header = source.range(of: " -> Bool {", range: start..<end)!.upperBound
  result.replaceSubrange(header..<end, with: "\n    return true\n  }")
} else if mode != "positive" {
  guard let change = changes[mode], source.components(separatedBy: change.0).count == 2 else {
    fatalError("Installer negative-control landmark changed")
  }
  result = source.replacingOccurrences(of: change.0, with: change.1)
}
try result.write(toFile: destination, atomically: true, encoding: .utf8)
