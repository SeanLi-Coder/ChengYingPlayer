import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/VideoTools/VideoToolsRotationIntent.swift"), encoding: .utf8)
let mutations = [
  ("repeated-consumption", "    self.pending = nil\n    return Submission", "    return Submission"),
  ("stale-request", "pending?.ticket == ticket && ticket.mediaEpoch", "ticket.mediaEpoch")
]
for (name, original, replacement) in mutations {
  guard source.components(separatedBy: original).count == 2 else {
    fatalError("The negative control must change exactly one production landmark")
  }
  let altered = source.replacingOccurrences(of: original, with: replacement)
  try altered.write(to: destination.appendingPathComponent("\(name).swift"), atomically: true, encoding: .utf8)
}
