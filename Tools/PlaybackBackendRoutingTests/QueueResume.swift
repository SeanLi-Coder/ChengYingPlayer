import Cocoa

/// Retain actual MPV events on the production reader while application main is
/// deliberately not drained. No event or readiness result is manufactured.
private func collectThroughActualRestart(_ controller: MPVController) -> Bool {
  var restarted = false
  controller.queue.sync {
    let deadline = Date().addingTimeInterval(5)
    while !restarted && Date() < deadline {
      guard let value = mpv_wait_event(controller.mpv, 0.01) else { continue }
      controller.handleEvent(value)
      restarted = value.pointee.event_id == MPV_EVENT_PLAYBACK_RESTART
    }
  }
  return restarted
}

private func drainResumeMain() -> Bool {
  var drained = false
  DispatchQueue.main.async { drained = true }
  let deadline = Date().addingTimeInterval(2)
  while !drained && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
  }
  return drained
}

func runQueueResumeBridge() {
  print("CASE: queue-resume")
  let url = URL(fileURLWithPath: CommandLine.arguments[2])
  for deferLoaded in [false, true] {
    let label = deferLoaded ? "restart-before-loaded-delivery" : "reader-before-main"
    let player = PlayerCore()
    let controller = MPVController(player)
    controller.realPropertyReadback = true
    route(player, enabled: false)
    var state = try! NativeQueueState(plan: NativeQueuePlan(urls: [url, url, url]), selectedIndex: 2)
    let checkpoint = state.handoffCheckpoint()!
    let token = state.beginHandoff(checkpoint)!
    var outcomes = [MPVQueueInstaller.Outcome]()
    var events = [String]()
    var heldLoaded: MPVQueueInstaller.Event?
    let installer = MPVQueueInstaller(backend: controller, isCurrent: { $0 == token })
    check(controller.beginNativeQueueInstallation(owner: token.id, receive: { value in
      events.append(String(describing: value))
      if deferLoaded, case .fileLoaded = value { heldLoaded = value }
      else { installer.receive(value) }
    }), "\(label): reserve exact production queue owner")
    check(installer.begin(checkpoint, installation: token, waitForPlaybackRestart: true, completion: {
      outcomes.append($0)
      controller.endNativeQueueInstallation(owner: token.id)
      route(player, enabled: true)
    }) == .accepted, "\(label): begin restart-aware actual installation")
    controller.queue.sync {
      let deadline = Date().addingTimeInterval(2)
      while !controller.queueHasReachedInitialIdle && Date() < deadline {
        if let value = mpv_wait_event(controller.mpv, 0.01) { controller.handleEvent(value) }
      }
    }
    check(controller.queueHasReachedInitialIdle, "\(label): production reader observes actual initial idle")
    installer.advance()
    check(collectThroughActualRestart(controller), "\(label): actual worker restart reaches reader before main")
    check(outcomes.isEmpty, "\(label): queued events cannot deliver an early installation receipt")
    check(drainResumeMain(), "\(label): queued actual events drain without blocking")
    if deferLoaded {
      check(heldLoaded != nil && outcomes.isEmpty, "\(label): restart alone cannot replace matching FILE_LOADED")
      if let heldLoaded { installer.receive(heldLoaded) }
    }
    let receipts = outcomes.compactMap { value -> MPVQueueInstaller.Receipt? in
      if case .installed(let receipt) = value { return receipt }; return nil
    }
    check(receipts.count == 1 && receipts[0].playbackRestarted,
          "\(label): exact owned initial restart completes one verified receipt")
    check(receipts.first?.selectedEntryID == controller.queueSnapshot()?.entries.last?.id,
          "\(label): restart receipt identifies selected duplicate entry")
    check(events.filter { $0.hasPrefix("playbackRestart") }.count == 1,
          "\(label): production reader forwards initial restart exactly once")
    check(player.actions.isEmpty && player.events.calls == 0,
          "\(label): buffered startup events cannot run ordinary presentation")
    if let receipt = receipts.first { installer.receive(.playbackRestart(entryID: receipt.selectedEntryID)) }
    check(outcomes.count == 1, "\(label): duplicate restart cannot deliver a second receipt")
    print("RESTART_DIAGNOSTIC: case=\(label) events=\(events) outcomes=\(outcomes)")
  }

  let player = PlayerCore()
  let controller = MPVController(player)
  controller.realPropertyReadback = true
  route(player, enabled: false)
  let oldOwner = UUID(), newOwner = UUID()
  var oldEvents = [String](), newEvents = [String]()
  check(controller.beginNativeQueueInstallation(owner: oldOwner, receive: { oldEvents.append(String(describing: $0)) }),
        "superseded: reserve old event owner")
  controller.command(.loadfile, args: [url.path])
  check(collectThroughActualRestart(controller), "superseded: retain actual restart before main")
  controller.endNativeQueueInstallation(owner: oldOwner)
  check(controller.beginNativeQueueInstallation(owner: newOwner, receive: { newEvents.append(String(describing: $0)) }),
        "superseded: reserve replacement event owner")
  check(drainResumeMain(), "superseded: old event envelopes drain")
  check(oldEvents.isEmpty && newEvents.isEmpty, "superseded: actual delayed restart cannot borrow replacement ownership")
  controller.endNativeQueueInstallation(owner: newOwner)
}
