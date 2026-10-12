import Cocoa

/// A RunLoop turn alone does not dispatch the application's queued window events.
enum PlayerCloseWindowLifecycle {
  static func dispatchEvents(until deadline: TimeInterval) {
    while ProcessInfo.processInfo.systemUptime < deadline {
      let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
      // A WindowServer wakeup may return nil before a posted event is delivered.
      // Keep servicing AppKit for the existing pump slice, never beyond it.
      if let event = NSApp.nextEvent(matching: .any,
                                    until: Date().addingTimeInterval(min(0.005, remaining)),
                                    inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
    }
  }

  static func isVisible(_ window: NSWindow) -> Bool {
    isVisible(orderedOnScreen: window.isVisible, onActiveSpace: window.isOnActiveSpace,
              unoccluded: window.occlusionState.contains(.visible))
  }

  static func isVisible(orderedOnScreen: Bool, onActiveSpace: Bool, unoccluded: Bool) -> Bool {
    orderedOnScreen && onActiveSpace && unoccluded
  }
}
