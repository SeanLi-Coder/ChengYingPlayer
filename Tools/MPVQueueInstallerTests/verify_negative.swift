import Foundation

let mode = CommandLine.arguments[1]
let failures = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
  .split(separator: "\n").map(String.init)
let expected: [String: [String]] = [
  "initial-idle": ["startup-selected-last: no append or activation precedes the real initial IDLE acknowledgement"],
  "deadline": [
    "Installation reaches a bounded terminal outcome",
    "Withheld loaded event times out and cleans its own queue",
    "Late start event cannot win against the installation deadline",
    "Late loaded event cannot win against the installation deadline",
    "Expired cleanup cannot issue a new clear command or report timely success",
    "An expired append batch cannot spend its remaining command budget",
    "Loaded readback crossing the deadline cannot publish success",
    "Cleanup snapshot crossing its deadline cannot report verified success",
    "Cleanup snapshot timeout prevents a later stop command",
    "Cleanup pause crossing its deadline cannot report verified success",
    "Cleanup pause timeout prevents a later stop command",
    "Cleanup stop crossing its deadline cannot report verified success",
    "Cleanup stop timeout prevents a later clear command",
    "Cleanup clear crossing its deadline cannot report verified success"
  ],
  "activation-status": [
    "Reentrant actual loaded event cannot finish before activation status is returned",
    "Missing activation status rejects reentrant real loaded success"
  ],
  "readback-cancel": ["Cancellation during loaded readback cannot publish stale installation success"],
  "owner": [
    "Cleanup readback ownership loss cannot pause a new owner's playback",
    "Cleanup readback ownership loss issues no stop or clear"
  ],
  "old-end-event": [
    "Old event backlog cannot cancel or acknowledge the new installation",
    "Old cleanup events preserve the newly loaded selected file"
  ],
  "prefix": ["Foreign appended entry invalidates the installation prefix"],
  "cleanup-unload": [
    "on_before_start_file: cleanup cannot clear or acknowledge while the real hook is held",
    "on_before_start_file: cleanup verifies empty only after the actual hook retires",
    "on_after_end_file: cleanup cannot clear or acknowledge while the real hook is held",
    "on_after_end_file: cleanup verifies empty only after the actual hook retires"
  ]
]
guard let names = expected[mode], failures.count == names.count,
      failures.sorted() == names.map({ "FAIL: " + $0 }).sorted() else {
  fatalError("Unexpected installer negative-control failures for \(mode): \(failures)")
}
let output = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
  .split(separator: "\n").map(String.init)
let count = mode == "initial-idle" ? 6 : mode == "cleanup-unload" ? 16 : 207
guard output.filter({ $0.hasPrefix("Queue installer:") }) == ["Queue installer: \(count) checks, \(names.count) failures"],
      output.filter({ $0.hasPrefix("PASS:") || $0.hasPrefix("FAIL:") }).count == count else {
  fatalError("Incomplete installer negative-control run for \(mode)")
}
print("PASS: \(mode) negative control reproduces exactly \(names.count) named failures")
