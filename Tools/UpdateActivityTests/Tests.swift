import Foundation

@main
struct Tests {
  @MainActor static var checks = 0
  @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
  }

  @MainActor static func main() throws {
    for reason in ["busy.playback", "busy.videoTask", "busy.subtitles", "busy.images", "busy.unknown"] {
      let f = GateFixture(); f.local = [reason]
      var result: UpdateReadiness?
      f.gate.readiness { result = $0 }
      check(result == .busy([reason]), "Local work must veto readiness")
      f.gate.acquireInstallationBarrier { result = $0 }
      check(result == .busy([reason]) && !f.admission.isBlocked, "Busy acquisition must be side-effect free")
      check(f.acquire == nil && f.drainCount == 0, "Busy tasks must not be stopped")
    }
    for value: Bool? in [true, false, nil] {
      let f = GateFixture(); var result: UpdateReadiness?
      f.gate.readiness { result = $0 }
      check(result == nil && !f.admission.isBlocked, "Readiness is asynchronous and read-only")
      f.activity?(value)
      check(result == (value == false ? .ready : .busy([value == true ? "busy.downloads" : "busy.unknown"])), "Backend unknown fails closed")
    }
    do {
      let f = GateFixture(); var result: UpdateReadiness?
      f.gate.readiness { result = $0 }
      f.local = ["busy.videoTask"]; f.activity?(false)
      check(result == .busy(["busy.videoTask"]), "Recheck local work after network latency")
    }
    do {
      let f = GateFixture(); var result: UpdateReadiness?
      f.gate.acquireInstallationBarrier { result = $0 }
      check(f.admission.isBlocked && !f.gate.installationBarrierIsSafe, "Freeze admission before asynchronous lease")
      check(f.admission.beginActivity(reason: "busy.images") == nil, "Native work cannot start under barrier")
      f.acquire?(true)
      check(result == nil && f.drainCount == 1, "Wait for actual helper exits")
      f.drain?(true)
      check(result == .ready && f.gate.installationBarrierIsSafe, "Only drained barrier is safe")
      f.local = ["busy.playback"]
      check(!f.gate.installationBarrierIsSafe, "Final synchronous guard detects missed entry guards")
      f.gate.releaseInstallationBarrier(); f.gate.releaseInstallationBarrier()
      check(!f.admission.isBlocked && f.released == f.leases, "Release is idempotent and targets exact lease")
    }
    for phase in ["lease", "drain"] {
      let f = GateFixture(); var result: UpdateReadiness?
      f.gate.acquireInstallationBarrier { result = $0 }
      f.acquire?(phase != "lease")
      if phase == "drain" { f.drain?(false) }
      check(result != nil && result != .ready && !f.admission.isBlocked, "Failure releases admission")
      check(f.released == f.leases && !f.gate.installationBarrierIsSafe, "Failure releases backend lease")
    }
    for phase in ["lease", "drain"] {
      let f = GateFixture(); var result: UpdateReadiness?
      f.gate.acquireInstallationBarrier { result = $0 }
      let oldAcquire = f.acquire
      if phase == "drain" { oldAcquire?(true) }
      let oldDrain = f.drain
      f.gate.releaseInstallationBarrier()
      f.gate.acquireInstallationBarrier { _ in }
      if phase == "lease" { oldAcquire?(true) } else { oldDrain?(true) }
      check(result == .busy(["busy.unknown"]) && !f.gate.installationBarrierIsSafe, "Cancelled callbacks cannot install a newer generation")
      check(f.released.count == 1 && f.admission.isBlocked, "Old callbacks cannot release the new barrier")
      f.gate.releaseInstallationBarrier()
    }
    do {
      let f = GateFixture()
      let token = f.admission.beginActivity(reason: "busy.images")!
      var result: UpdateReadiness?
      f.gate.readiness { result = $0 }
      check(result == .busy(["busy.images"]), "Background conversion survives window teardown")
      f.admission.endActivity(token)
      f.gate.acquireInstallationBarrier { result = $0 }
      check(f.admission.isBlocked, "Completed background work releases its lease")
      f.gate.releaseInstallationBarrier()
    }
    let native = UpdateActivityGate()
    for state in [PlayerState.loading, .starting, .loaded, .playing, .paused, .stopping] {
      let player = PlayerCore(); player.info.state = state; PlayerCore.playerCores = [player]
      var result: UpdateReadiness?
      native.readiness { result = $0 }
      check(result == .busy(["busy.playback"]), "Production mapping protects viewing sessions")
    }
    PlayerCore.playerCores = []
    VideoToolsRotationCoordinator.hasPendingUpdateWork = true
    var result: UpdateReadiness?
    native.readiness { result = $0 }
    check(result == .busy(["busy.videoTask"]), "Debounced rotation is active before a task exists")
    VideoToolsRotationCoordinator.hasPendingUpdateWork = false
    ImageViewerCoordinator.shared.isActiveForUpdate = true
    native.readiness { result = $0 }
    check(result == .busy(["busy.images"]), "Slideshow delays installation")
    ImageViewerCoordinator.shared.isActiveForUpdate = false
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["0.4"]
    try child.run()
    var drainResult: Bool?
    UpdateProcessDrain.wait(for: child, timeout: 0.05) { drainResult = $0 }
    while drainResult == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    check(drainResult == false && child.isRunning, "Drain timeout must not terminate the child")
    check(UpdateWorkAdmission.shared.hasDrainingProcesses, "Timed-out live child still prevents installation")
    while UpdateWorkAdmission.shared.hasDrainingProcesses { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    check(!child.isRunning && child.terminationStatus == 0, "Helper must exit naturally")
    print("Update activity tests passed: \(checks) checks")
  }
}
