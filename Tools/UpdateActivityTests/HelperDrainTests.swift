import Foundation

@main
struct HelperDrainTests {
  static func main() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    func wait(_ message: String, until predicate: () -> Bool) {
      let deadline = Date(timeIntervalSinceNow: 5)
      while !predicate() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
      check(predicate(), message)
    }
    let client = VideoToolsHelperClient.shared
    var replies = 0
    var failures = 0
    client.eventHandler = { if $0.type == .pong { replies += 1 } }
    client.failureHandler = { _ in failures += 1 }
    for iteration in 1...3 {
      try client.send(.cancel(id: UUID().uuidString, targetID: "no-active-task"))
      wait("The real transport launches or relaunches its helper") { replies == iteration }
      let barrier = UUID()
      check(UpdateWorkAdmission.shared.acquire(barrier), "Idle helper can enter install barrier")
      var completed: Bool?
      client.shutdownForUpdate { completed = $0 }
      check(UpdateWorkAdmission.shared.hasDrainingProcesses, "Drain reservation exists before dispatching to helper queue")
      UpdateWorkAdmission.shared.release(barrier)
      check(!UpdateWorkAdmission.shared.isBlocked, "Cancelling update restores playback admission immediately")
      check(UpdateWorkAdmission.shared.isHelperRestartBlocked, "A closing helper cannot accept newly submitted work")
      wait("The owned helper exits gracefully after update cancellation") { completed != nil }
      check(completed == true && !UpdateWorkAdmission.shared.isHelperRestartBlocked, "Actual exit permits helper restart")
      // AppDelegate's normal termination shutdown is safe after a drained barrier.
      client.shutdown()
      check(failures == 0, "Graceful shutdown never reports a task failure")
    }
    print("Native helper drain tests passed: \(checks) checks")
  }
}
