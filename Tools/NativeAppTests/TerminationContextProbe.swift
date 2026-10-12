// Real AppKit run-loop probe; it does not model PlayerCore or prove App resource teardown.
// The runner mechanically inserts the exact driver scheduling method into this type.
import AppKit

enum NativeAppQuitScheduling {
  // INSERT_DRIVER_SCHEDULER
}

final class TerminationProbe: NSObject, NSApplicationDelegate {
  private var completed = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async {
      NativeAppQuitScheduling.performTerminationFromRunLoop { NSApp.terminate(nil) }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    print("TERMINATION_PROBE: should_terminate")
    let watchdog = Timer(timeInterval: 1, repeats: false) { _ in
      print("TERMINATION_PROBE_FAIL: main_queue_completions=\(self.completed)")
      exit(1)
    }
    RunLoop.main.add(watchdog, forMode: .common)
    for _ in 0..<2 {
      DispatchQueue.main.async {
        self.completed += 1
        if self.completed == 2 {
          watchdog.invalidate()
          NSApp.reply(toApplicationShouldTerminate: true)
        }
      }
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    print("TERMINATION_PROBE: will_terminate main_queue_completions=\(completed)")
    exit(completed == 2 ? 0 : 2)
  }
}

let delegate = TerminationProbe()
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.delegate = delegate
DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(124) }
application.run()
