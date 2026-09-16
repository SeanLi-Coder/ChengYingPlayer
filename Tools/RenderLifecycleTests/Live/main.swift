import Cocoa

final class CallbackProbe {
  let lock = NSLock()
  var entered = false
  let callbackStarted = DispatchSemaphore(value: 0)
  let callbackMayFinish = DispatchSemaphore(value: 0)
}

let probe = CallbackProbe()
var link: CVDisplayLink?
guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let displayLink = link else {
  fputs("FAIL: A live display is required for the Core Video callback probe\n", stderr)
  exit(1)
}
let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, pointer in
  let state = Unmanaged<CallbackProbe>.fromOpaque(pointer!).takeUnretainedValue()
  state.lock.lock()
  let first = !state.entered
  state.entered = true
  state.lock.unlock()
  if first {
    state.callbackStarted.signal()
    _ = state.callbackMayFinish.wait(timeout: .now() + 5)
  }
  return kCVReturnSuccess
}
guard CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(probe).toOpaque()) == kCVReturnSuccess,
      CVDisplayLinkStart(displayLink) == kCVReturnSuccess,
      probe.callbackStarted.wait(timeout: .now() + 2) == .success else {
  fputs("FAIL: The live Core Video callback did not start\n", stderr)
  exit(1)
}
let stopStarted = DispatchSemaphore(value: 0)
let stopFinished = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
  stopStarted.signal()
  CVDisplayLinkStop(displayLink)
  stopFinished.signal()
}
_ = stopStarted.wait(timeout: .now() + 2)
guard stopFinished.wait(timeout: .now() + 0.2) == .timedOut else {
  fputs("FAIL: Core Video stop unexpectedly returned before the callback completed\n", stderr)
  exit(1)
}
probe.callbackMayFinish.signal()
guard stopFinished.wait(timeout: .now() + 2) == .success,
      !CVDisplayLinkIsRunning(displayLink) else {
  fputs("FAIL: Core Video stop did not finish after callback completion\n", stderr)
  exit(1)
}
print("PASS: Real Core Video stop waits for an active callback and finishes after it returns")
