import AppKit
import CoreGraphics
import IOKit.hidsystem

// Post only to the test process. Never request or change Accessibility permission.
guard CGPreflightPostEventAccess() else {
  fputs("Keyboard event posting is not authorized for this test runner.\n", stderr)
  exit(77)
}
if CommandLine.arguments.dropFirst() == ["--preflight"] {
  print("PASS: Keyboard event posting is already authorized")
  exit(0)
}
guard CommandLine.arguments.count == 4,
      let pid = Int32(CommandLine.arguments[1]), pid > 0,
      let interval = Double(CommandLine.arguments[3]), interval.isFinite,
      interval >= 0, interval <= 0.25,
      let application = NSRunningApplication(processIdentifier: pid) else {
  fputs("Usage: RotationKeyDriver PID LR_SEQUENCE INTERVAL_SECONDS\n", stderr)
  exit(2)
}
let sequence = CommandLine.arguments[2]
guard !sequence.isEmpty, sequence.count <= 1000,
      sequence.allSatisfy({ $0 == "L" || $0 == "R" }) else {
  fputs("The key sequence must contain only L and R.\n", stderr)
  exit(2)
}
guard application.activate(options: []) else {
  fputs("Could not activate the test application.\n", stderr)
  exit(1)
}
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let source = CGEventSource(stateID: .privateState)
let flags = CGEventFlags(rawValue:
  CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
    | UInt64(NX_DEVICELCMDKEYMASK) | UInt64(NX_DEVICELSHIFTKEYMASK))
for direction in sequence {
  guard !application.isTerminated else {
    fputs("The test application terminated during the key sequence.\n", stderr)
    exit(1)
  }
  let key: CGKeyCode = direction == "L" ? 37 : 15
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
      fputs("Could not construct a keyboard event.\n", stderr)
      exit(1)
    }
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    event.postToPid(pid)
  }
  Thread.sleep(forTimeInterval: interval)
}
print("PASS: Posted \(sequence.count) rotation shortcuts to PID \(pid)")
