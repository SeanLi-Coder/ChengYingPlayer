import AppKit

var passed = 0, failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  if condition() { passed += 1; print("PASS: \(name)") }
  else { failed += 1; print("FAIL: \(name)") }
}
func pump(_ duration: Double = 0.3) {
  let until = Date().addingTimeInterval(duration)
  while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

func fixture(native: Bool = false) -> (PlayerCore, PreferenceObserverHarness) {
  let core = PlayerCore()
  if native { core.nativeTransport = 1; core.info.state = .playing; core.playbackEventRoute.acceptsMPV = false }
  return (core, PreferenceObserverHarness(core))
}
do {
  let (native, first) = fixture(native: true)
  let (idle, second) = fixture()
  native.onDelivery = { native.hasPendingGenericPlaybackHandoff = true }
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  check(first.writes.isEmpty && second.writes.isEmpty, "Preference observer never writes MPV directly")
  check(native.deliveries == ["coreaudio/a"] && idle.deliveries == ["coreaudio/a"], "Global preference reaches every live Core through its device API")
  check(!native.deliveredOffMain && !idle.deliveredOffMain, "All Core preference deliveries occur on main")
  native.info.state = .shutDown; idle.info.state = .shutDown
  native.onDelivery = nil
}
do {
  let (core, observer) = fixture(native: true)
  core.hasPendingGenericPlaybackHandoff = true
  Preference.set("coreaudio/b", for: .audioDevice)
  pump(0.04)
  check(observer.writes.isEmpty && core.deliveries.isEmpty, "Busy owner receives no preference write")
  Preference.set("auto", for: .audioDevice)
  core.nativeTransport = nil; core.playbackEventRoute.acceptsMPV = true
  core.hasPendingGenericPlaybackHandoff = false
  pump()
  check(core.deliveries == ["auto"], "Busy preference changes coalesce to the latest persisted value")
  check(Preference.effectiveAudioDeviceName == "auto", "Deferred application preserves the persistent choice")
}
do {
  let (core, observer) = fixture()
  core.playbackEventRoute.acceptsMPV = false
  check(!core.canSelectAudioDevice, "Inventory window rejects device mutation")
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  check(core.deliveries.isEmpty && observer.writes.isEmpty, "Inventory does not receive an idle MPV device write")
  core.playbackEventRoute.acceptsMPV = true
  pump()
  check(core.deliveries == ["coreaudio/a"], "Preference remains pending until inventory is settled")
}
do {
  let (core, observer) = fixture()
  core.hasPendingGenericPlaybackHandoff = true
  Preference.set("coreaudio/b", for: .audioDevice)
  core.info.state = .shuttingDown
  pump()
  check(core.deliveries.isEmpty && observer.writes.isEmpty, "Terminal Core never receives a queued device preference")
}
do {
  let (core, observer) = fixture()
  let completed = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    Preference.set("auto", for: .audioDevice)
    completed.signal()
  }
  check(completed.wait(timeout: .now() + 1) == .success, "Off-main KVO callback does not block on main")
  pump()
  check(core.deliveries == ["auto"] && !core.deliveredOffMain && observer.writes.isEmpty, "Off-main preference is delivered only through main Core API")
}
do {
  let core = PlayerCore(); core.hasPendingGenericPlaybackHandoff = true
  var observer: PreferenceObserverHarness? = PreferenceObserverHarness(core)
  weak var weakObserver = observer
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  observer = nil
  check(weakObserver == nil, "Pending preference task does not retain its Controller")
  core.hasPendingGenericPlaybackHandoff = false
  pump()
  check(core.deliveries.isEmpty, "Destroyed Controller cannot deliver a delayed preference")
}
do {
  let first = PlayerCore(), busy = PlayerCore()
  busy.hasPendingGenericPlaybackHandoff = true
  PlayerCore.playerCores = [first, busy]
  let pane = PreferencePaneHarness(); pane.updateAudioDevicePopUp()
  pane.audioDevicePopUp.selectItem(at: 2)
  let before = Preference.effectiveAudioDeviceName
  pane.audioDeviceAction(pane.audioDevicePopUp)
  check(Preference.effectiveAudioDeviceName == before, "Busy preferences UI does not overwrite the saved choice")
  check((pane.audioDevicePopUp.selectedItem?.representedObject as? MPVAudioDevice)?.name == before, "Rejected UI choice is restored visibly")
  check(Utility.alerts == ["audio_device.busy"], "Rejected UI choice explains the busy transition")
  busy.hasPendingGenericPlaybackHandoff = false
  pane.audioDevicePopUp.selectItem(at: 2)
  pane.audioDeviceAction(pane.audioDevicePopUp)
  check(Preference.effectiveAudioDeviceName == "coreaudio/b", "Settled preferences UI still saves the requested device")
}
do {
  let (core, observer) = fixture(native: true)
  core.onDelivery = { core.hasPendingGenericPlaybackHandoff = true }
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  check(core.deliveries == ["coreaudio/a"], "Native preference begins one Core-owned request")
  Preference.set("coreaudio/b", for: .audioDevice)
  Preference.set("auto", for: .audioDevice)
  pump()
  check(core.deliveries == ["coreaudio/a"] && observer.writes.isEmpty, "Rapid choices remain deferred while the native request owns restoration")
  core.nativeTransport = nil; core.playbackEventRoute.acceptsMPV = true
  core.hasPendingGenericPlaybackHandoff = false; core.onDelivery = nil
  pump()
  check(core.deliveries == ["coreaudio/a", "auto"], "Native request continuation applies only the latest global preference")
  pump()
  check(core.deliveries == ["coreaudio/a", "auto"], "Settled continuation stops polling after exactly one final delivery")
}
do {
  let (core, observer) = fixture()
  core.hasPendingGenericPlaybackHandoff = true
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  let delivered = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    observer.hasReceivedShutdown = true
    delivered.signal()
  }
  check(delivered.wait(timeout: .now() + 1) == .success, "Actual atomic shutdown flag is recorded before UI state delivery")
  core.hasPendingGenericPlaybackHandoff = false
  pump()
  check(core.info.state == .idle && core.deliveries.isEmpty && observer.writes.isEmpty, "Reader shutdown prevents preference delivery before the UI terminal callback")
}
do {
  let (core, observer) = fixture()
  core.hasPendingGenericPlaybackHandoff = true
  Preference.set("coreaudio/b", for: .audioDevice)
  pump(0.04)
  observer.mpv = nil; core.hasPendingGenericPlaybackHandoff = false
  pump()
  check(core.deliveries.isEmpty && observer.writes.isEmpty, "Destroyed MPV handle cancels pending preference delivery")
}
do {
  let (core, observer) = fixture(native: true)
  core.onDelivery = { core.hasPendingGenericPlaybackHandoff = true }
  Preference.set("coreaudio/a", for: .audioDevice)
  pump(0.04)
  check(core.deliveries == ["coreaudio/a"], "Rejected handoff fixture begins one real KVO delivery")
  // The service boundary reports an unsuccessful/cancelled compatibility
  // attempt by releasing busy ownership while remaining on native output.
  core.hasPendingGenericPlaybackHandoff = false
  pump(0.35)
  check(core.deliveries == ["coreaudio/a"] && observer.writes.isEmpty, "Failed native handoff is not automatically retried")
  check(Preference.effectiveAudioDeviceName == "coreaudio/a", "Failed native handoff retains the desired saved preference")
  check(observer.diagnostics.count == 1, "Failed native handoff records one non-retrying diagnostic")
  let count = core.deliveries.count
  core.hasPendingGenericPlaybackHandoff = false
  Preference.set("coreaudio/b", for: .audioDevice)
  pump(0.04)
  check(core.deliveries.count == count + 1 && core.deliveries.last == "coreaudio/b", "Different-value KVO request can retry after cancelled native handoff")
  core.info.state = .shutDown; core.onDelivery = nil
}
do {
  let (core, observer) = fixture()
  Preference.set(Preference.effectiveAudioDeviceName, for: .audioDevice)
  pump(0.04)
  check(core.deliveries.isEmpty && observer.writes.isEmpty, "Equal-value UserDefaults assignment does not emit another KVO request")
}
PlayerCore.playerCores = []
Preference.store.removePersistentDomain(forName: Preference.domain)
print("Audio preference checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
