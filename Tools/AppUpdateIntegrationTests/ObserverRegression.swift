import AppKit
import Sparkle

/// Exercise real production transitions within one actor turn, before any timer can sample them.
@MainActor
func runPhaseObserverRegression() {
  let activity = FixtureActivity()
  let driver = AppUpdateUserDriver(activity: activity, location: { .supported }, usesTimer: false)
  let observed = FixtureObservedUserDriver(driver: driver)
  var phases = [String]()
  var downloadWasVisible = false
  observed.didObserve = { realDriver in
    precondition(realDriver === driver, "The observer must inspect the actual production driver")
    let phase = String(describing: realDriver.phase)
    if phases.last != phase { phases.append(phase) }
    if realDriver.phase == .downloading {
      downloadWasVisible = realDriver.windowController.window?.isVisible == true
    }
  }
  var sampled = [String]()
  let sampler = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    MainActor.assumeIsolated { sampled.append(String(describing: driver.phase)) }
  }
  defer {
    sampler.invalidate()
    driver.dismissUpdateInstallation()
    driver.windowController.window?.orderOut(nil)
  }
  observed.showDownloadInitiated(cancellation: {})
  observed.showDownloadDidReceiveExpectedContentLength(6)
  observed.showDownloadDidReceiveData(ofLength: 6)
  precondition(driver.presentation?.progress == 0.99, "The real download presentation must retain its pre-extraction 99 percent cap")
  observed.showDownloadDidStartExtractingUpdate()
  precondition(phases == ["downloading", "extracting"], "The callback observer lost a same-turn transition")
  precondition(downloadWasVisible, "A recorded download must have an actual visible production window")
  precondition(sampled.isEmpty, "The regression must not let a polling timer observe the short phase")
  sampler.fire()
  precondition(sampled == ["extracting"], "The former polling approach should demonstrably miss downloading")

  let failure = NSError(domain: "org.chengying.tests.phase-observer", code: 1)
  var acknowledgements = 0
  observed.showUpdaterError(failure) {
    precondition(phases.last == "failed", "The observer must run before a reentrant Sparkle acknowledgement")
    acknowledgements += 1
    observed.dismissUpdateInstallation()
  }
  precondition(acknowledgements == 1, "The forwarding observer must acknowledge exactly once")
  observed.showUpdateInstalledAndRelaunched(false) {
    precondition(phases.last == "finished", "Completion must be observed before acknowledgement")
    acknowledgements += 1
    observed.dismissUpdateInstallation()
  }
  precondition(acknowledgements == 2, "The completion acknowledgement must be forwarded exactly once")
  precondition(!activity.installationBarrierIsSafe, "Observation must never acquire an installation barrier")
  print("PASS: Same-turn real downloading/extracting transitions, visible progress, polling reproducer, and reentrant acknowledgements.")
}
