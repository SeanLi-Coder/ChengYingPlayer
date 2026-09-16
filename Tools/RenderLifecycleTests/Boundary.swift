import Cocoa
import OpenGL

enum CocoaCbSwRenderer { case yes, no, auto }
enum MPVOption {
  enum GPURendererOptions {
    static let cocoaCbSwRenderer = "cocoa-cb-sw-renderer"
    static let cocoaCb10bitContext = "cocoa-cb-10bit-context"
  }
}
enum Logger {
  enum Level { case debug, verbose, warning }
  static func makeSubsystem(_ value: String) -> String { value }
  static func log(_ message: String, level: Level = .debug, subsystem: String = "") {}
  static func fatal(_ message: String) -> Never { fatalError(message) }
}

final class MPVBoundary {
  let glLock = NSRecursiveLock()
  let traceLock = NSLock()
  var lockCount = 0
  var unlockCount = 0
  var freeCount = 0
  var swaps = 0
  var swapsAfterFree = 0
  var freed = false

  func getEnum(_ name: String) -> CocoaCbSwRenderer { .auto }
  func getFlag(_ name: String) -> Bool { false }
  func lockAndSetOpenGLContext() { glLock.lock(); lockCount += 1 }
  func unlockOpenGLContext() { unlockCount += 1; glLock.unlock() }
  func mpvUninitRendering() {
    traceLock.lock()
    freeCount += 1
    freed = true
    traceLock.unlock()
  }
  func mpvReportSwap() {
    traceLock.lock()
    swaps += 1
    if freed { swapsAfterFree += 1 }
    traceLock.unlock()
  }
}
final class PlayerCore {
  let mpv = MPVBoundary()
  let playerNumber = 0
}

class VideoViewBoundary {
  let player = PlayerCore()
  @ReadWriteAtomic var isUninited = false
  var displayIdleTimer: Timer?
  var stopWaitTimedOut = false
  var stopWhileGLLocked = false
  var stopCount = 0
  let callbackDone = DispatchSemaphore(value: 0)
  var createLinkCount = 0
  var link: CVDisplayLink?

  // Model CVDisplayLinkStop's synchronous callback join using the production
  // read/write lock, with a bounded wait so old code fails without hanging CI.
  func stopDisplayLink() {
    stopCount += 1
    DispatchQueue.global().async { [self] in
      if player.mpv.glLock.try() {
        player.mpv.glLock.unlock()
      } else {
        stopWhileGLLocked = true
      }
      $isUninited.withReadLock { isUninited in
        if !isUninited { player.mpv.mpvReportSwap() }
      }
      callbackDone.signal()
    }
    stopWaitTimedOut = callbackDone.wait(timeout: .now() + 2) != .success
  }
  func obtainDisplayLink() -> CVDisplayLink {
    createLinkCount += 1
    if let link { return link }
    guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
      fatalError("Failed to create fixture display link")
    }
    return link
  }
  func updateDisplayLink() {}
  func checkResult(_ result: CVReturn, _ operation: String) {}
  func log(_ message: String, level: Logger.Level) {}
}

func mutableRawPointerOf<T: AnyObject>(obj: T) -> UnsafeMutableRawPointer {
  Unmanaged.passUnretained(obj).toOpaque()
}
func displayLinkCallback(
  _ displayLink: CVDisplayLink, _ now: UnsafePointer<CVTimeStamp>,
  _ outputTime: UnsafePointer<CVTimeStamp>, _ flagsIn: CVOptionFlags,
  _ flagsOut: UnsafeMutablePointer<CVOptionFlags>, _ context: UnsafeMutableRawPointer?
) -> CVReturn { kCVReturnSuccess }
