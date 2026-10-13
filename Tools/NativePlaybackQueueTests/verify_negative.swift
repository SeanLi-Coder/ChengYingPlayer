import Foundation

let mode = CommandLine.arguments[1]
let actual = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
  .split(separator: "\n").map(String.init)
let expected: [String: [String]] = [
  "stale-checkpoint": [
    "Pause ABA rejects the stale checkpoint revision",
    "Repeat ABA rejects the stale checkpoint revision",
    "Autoplay ABA rejects the stale checkpoint revision",
    "Ready transition invalidates an earlier checkpoint revision"
  ],
  "same-generation": [
    "Same-item reselection has a new generation in the same queue epoch",
    "Old same-URL load callback cannot accept the new generation",
    "Only the latest rapid selection becomes ready",
    "A one-item playlist repeat creates a fresh playback generation",
    "Resume after delayed EOF off starts a new rewind generation",
    "Resume after delayed EOF file starts a new rewind generation",
    "Resume after delayed EOF playlist starts a new rewind generation"
  ],
  "stale-eof": ["Stale EOF cannot skip the newly selected item"]
]
guard let labels = expected[mode], actual.count == labels.count,
      Set(actual) == Set(labels.map { "FAIL: " + $0 }) else {
  fatalError("Unexpected queue negative-control failures: \(actual)")
}
print("PASS: Single-variable \(mode) control reproduces exactly \(actual.count) named failures")
