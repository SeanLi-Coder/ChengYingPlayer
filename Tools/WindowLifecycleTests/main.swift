import Cocoa

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL: \(message)")
  }
}

// CGEvent creates real NSEvent scroll packets; validate their phase decoding too.
func event(x: Int32 = 0, y: Int32 = 0, phase: NSEvent.Phase = [], momentum: Int64 = 0,
           precise: Bool = true) -> NSEvent {
  let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                   wheel1: y, wheel2: x, wheel3: 0)!
  let cgPhase: Int64
  switch phase {
  case .began: cgPhase = 1
  case .changed: cgPhase = 2
  case .ended: cgPhase = 4
  case .cancelled: cgPhase = 8
  default: cgPhase = 0
  }
  cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: cgPhase)
  cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  let result = NSEvent(cgEvent: cg)!
  check(result.phase == phase, "Synthetic event preserves the real AppKit phase")
  check(result.hasPreciseScrollingDeltas == precise, "Synthetic event preserves device precision")
  return result
}

let selected = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
func run(_ name: String, _ block: () -> Void) {
  if selected == "all" || selected == name { block() }
}

run("cancel") {
  let controller = ScrollControllerUnderTest()
  controller.scrollWheel(with: event(x: 4, phase: .began))
  check(controller.player.pauses == 1, "Seeking pauses a playing video")
  controller.scrollWheel(with: event(x: 7, phase: .cancelled))
  check(controller.player.resumes == 1, "Cancelled seeking restores playback")
  check(controller.player.seeks.count == 1, "Cancelled packets cannot move the playhead")
  controller.scrollWheel(with: event(phase: .ended))
  check(controller.player.resumes == 1, "An extra end packet cannot resume twice")

  let paused = ScrollControllerUnderTest()
  paused.player.info.state = .paused
  paused.scrollWheel(with: event(x: 4, phase: .began))
  paused.scrollWheel(with: event(phase: .cancelled))
  check(paused.player.resumes == 0, "Originally paused video remains paused")

  let pending = ScrollControllerUnderTest()
  pending.player.deferPauseNotification = true
  pending.scrollWheel(with: event(x: 4, phase: .began))
  pending.scrollWheel(with: event(phase: .ended))
  check(pending.player.resumes == 1, "Short gestures undo a pause whose notification is still queued")

  let stopped = ScrollControllerUnderTest()
  stopped.scrollWheel(with: event(x: 4, phase: .began))
  stopped.player.info.state = .stopping
  stopped.scrollWheel(with: event(phase: .cancelled))
  check(stopped.player.resumes == 0, "Gesture cancellation never restarts a stopping player")

  let miniVolume = MiniPlayerWindowController()
  miniVolume.scrollWheel(with: event(y: 4, phase: .began))
  miniVolume.scrollWheel(with: event(phase: .cancelled))
  check(miniVolume.popoverEvents.last?.1 == true, "Cancelled volume gestures close their temporary popover")
}

run("momentum") {
  let controller = ScrollControllerUnderTest()
  controller.scrollWheel(with: event(x: 4, phase: .began))
  let normal = controller.player.seeks.last!
  controller.scrollWheel(with: event(x: 4, y: 1, phase: .ended))
  check(controller.player.seeks.count == 2, "The final horizontal delta remains a seek")
  check(controller.player.volumes.isEmpty, "Ending a horizontal gesture never changes volume")
  let momentum = event(x: 4, momentum: 1)
  check(momentum.momentumPhase.contains(.began), "Momentum event decodes as a new momentum phase")
  controller.scrollWheel(with: momentum)
  check(controller.player.seeks.last == normal, "Momentum retains trackpad sensitivity instead of mouse amplification")
  controller.scrollWheel(with: event(momentum: 3))
  check(controller.scrollDirection == nil, "The end of momentum releases its locked axis")

  let mouse = ScrollControllerUnderTest()
  mouse.scrollWheel(with: event(x: 4))
  check(mouse.player.seeks.last == normal * 8, "Ordinary mouse scrolling keeps its configured sensitivity")

  let wheel = ScrollControllerUnderTest()
  wheel.scrollWheel(with: event(x: 4, precise: false))
  check(wheel.player.seeks.count == 1, "Physical mouse wheel packets perform a seek")
  wheel.scrollWheel(with: event(precise: false))
  check(wheel.player.seeks.count == 1, "Empty mouse packets never add a phantom seek")
  let stationary = ScrollControllerUnderTest()
  stationary.scrollWheel(with: event(precise: false))
  check(stationary.player.volumes.isEmpty, "Empty mouse packets never change volume")
}

run("filtered_end") {
  let main = MainWindowUnderTest()
  main.hitView = main.fragSliderView
  main.scrollWheel(with: event(x: 4, phase: .began))
  main.hitView = main.sideBarView
  main.scrollWheel(with: event(phase: .ended))
  check(main.player.resumes == 1, "Ending over the sidebar releases the seek pause")

  let title = MainWindowUnderTest()
  title.scrollWheel(with: event(x: 4, phase: .began))
  title.hitView = title.titleBarView
  title.scrollWheel(with: event(phase: .cancelled))
  check(title.player.resumes == 1, "Cancellation over the title bar releases the seek pause")

  let interactive = MainWindowUnderTest()
  interactive.scrollWheel(with: event(x: 4, phase: .began))
  interactive.isInInteractiveMode = true
  interactive.scrollWheel(with: event(phase: .cancelled))
  check(interactive.player.resumes == 0, "Interactive cropping keeps its intentional pause")
  interactive.isInInteractiveMode = false
  interactive.scrollWheel(with: event(phase: .ended))
  check(interactive.player.resumes == 0, "A cancelled seek cannot leak playback restoration past interaction mode")

  let mini = MiniPlayerWindowController()
  mini.hitView = mini.playSlider
  mini.scrollWheel(with: event(x: 4, phase: .began))
  mini.hitView = mini.backgroundView
  mini.scrollWheel(with: event(phase: .ended))
  check(mini.player.resumes == 1, "Mini player filtered end events release the seek pause")
}

run("sensitivity") {
  for value in [Int.min, -1, 0, 1, 4, 5, Int.max] {
    let seek = ScrollControllerUnderTest()
    seek.relativeSeekAmount = value
    seek.scrollWheel(with: event(x: 4, phase: .began))
    check(seek.player.seeks.last?.isFinite == true, "Seek sensitivity is safe for persisted value \(value)")

    let volume = ScrollControllerUnderTest()
    volume.volumeScrollAmount = value
    volume.scrollWheel(with: event(y: 4, phase: .began))
    check(volume.player.volumes.last?.isFinite == true, "Volume sensitivity is safe for persisted value \(value)")

    let speed = ScrollControllerUnderTest()
    speed.playbackSpeedScrollAmount = value
    speed.verticalScrollAction = .playbackSpeed
    speed.scrollWheel(with: event(y: 4, phase: .began))
    check(speed.player.speeds.last?.isFinite == true, "Speed sensitivity is safe for persisted value \(value)")
  }
}

run("resize") {
  let notice = Notification(name: NSWindow.didEndLiveResizeNotification)
  for state in [PlayerState.idle, .stopping, .shuttingDown, .shutDown] {
    let main = MainWindowUnderTest()
    main.player.info.state = state
    main.windowDidEndLiveResize(notice)
    check(!main.videoView.videoLayer.inLiveResize, "Inactive main windows exit live resize")
    check(main.parameterUpdates == 0, "Inactive main windows do not access mpv")
    let mini = MiniPlayerWindowController()
    mini.player.info.state = state
    mini.windowDidEndLiveResize(notice)
    check(!mini.videoView.videoLayer.inLiveResize, "Inactive mini windows exit live resize")
  }
  let active = MainWindowUnderTest()
  active.windowDidEndLiveResize(notice)
  check(!active.videoView.videoLayer.inLiveResize, "Playing windows exit live resize")
  check(active.parameterUpdates == 1, "Playing windows refresh mpv dimensions")
}

print("Window lifecycle checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
