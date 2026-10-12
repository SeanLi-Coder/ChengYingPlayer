import Cocoa

private final class EventApplication: NSApplication {
  var dispatchedProbes = 0

  override func sendEvent(_ event: NSEvent) {
    if event.type == .applicationDefined && event.subtype.rawValue == 23491 {
      dispatchedProbes += 1
      return
    }
    super.sendEvent(event)
  }
}

@main
enum WindowLifecycleTests {
  static func main() {
    guard let application = EventApplication.shared as? EventApplication else {
      fatalError("The event probe must use its isolated application subclass")
    }
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    func enqueueProbe() {
      let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: 0, context: nil, subtype: 23491, data1: 0, data2: 0)!
      application.postEvent(event, atStart: false)
      // Native posting can arrive asynchronously. Establish queue membership
      // without dequeuing or delivering the probe before comparing dispatchers.
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      var queued = false
      while !queued && ProcessInfo.processInfo.systemUptime < deadline {
        if let pending = application.nextEvent(matching: .applicationDefined,
                                              until: Date().addingTimeInterval(0.005),
                                              inMode: .default, dequeue: false) {
          queued = pending.subtype.rawValue == 23491
        }
      }
      precondition(queued, "The native probe must be in the queue before exercising dispatch")
    }
    enqueueProbe()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    precondition(application.dispatchedProbes == 0,
                 "Negative control: a RunLoop turn must leave the application event undispatched")
    PlayerCloseWindowLifecycle.dispatchEvents(until: ProcessInfo.processInfo.systemUptime + 1)
    precondition(application.dispatchedProbes == 1,
                 "The actual fixture dispatcher must deliver the queued native application event")
    PlayerCloseWindowLifecycle.dispatchEvents(until: ProcessInfo.processInfo.systemUptime + 1)
    precondition(application.dispatchedProbes == 1, "A drained event must not be delivered twice")

    enqueueProbe()
    PlayerCloseWindowLifecycle.dispatchEvents(until: ProcessInfo.processInfo.systemUptime - 1)
    precondition(application.dispatchedProbes == 1, "An exhausted budget must not dispatch another event")
    PlayerCloseWindowLifecycle.dispatchEvents(until: ProcessInfo.processInfo.systemUptime + 1)
    precondition(application.dispatchedProbes == 2, "An undelivered event must remain available")

    for ordered in [false, true] {
      for active in [false, true] {
        for visible in [false, true] {
          precondition(PlayerCloseWindowLifecycle.isVisible(orderedOnScreen: ordered, onActiveSpace: active,
                                                           unoccluded: visible) == (ordered && active && visible),
                       "The display barrier must reject every partially invisible state")
        }
      }
    }
    precondition(!PlayerCloseWindowLifecycle.isVisible(orderedOnScreen: true, onActiveSpace: false,
                                                      unoccluded: false),
                 "Negative control: the old isVisible-only predicate accepts a non-presentable window")
    print("PASS: 16 window lifecycle and native event-dispatch checks")
  }
}
