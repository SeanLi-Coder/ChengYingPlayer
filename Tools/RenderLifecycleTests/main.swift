import Cocoa
import OpenGL

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
  checks += 1
}

func testCopies() {
  let view = VideoView()
  let layer = ViewLayer(view)
  CGLSetCurrentContext(nil)
  let context = layer.cglContext
  let pixelFormat = layer.cglPixelFormat
  let contextBaseline = CGLGetContextRetainCount(context)
  let formatBaseline = CGLGetPixelFormatRetainCount(pixelFormat)
  for _ in 0..<512 {
    let copiedContext = layer.copyCGLContext(forPixelFormat: pixelFormat)
    check(copiedContext == context, "Copies must keep the mpv OpenGL context identity")
    check(CGLGetContextRetainCount(context) == contextBaseline + 1,
          "Each context copy must transfer one independently retained reference")
    layer.releaseCGLContext(copiedContext)
    check(CGLGetContextRetainCount(context) == contextBaseline,
          "Core Animation context release must not consume the layer's reference")

    let copiedFormat = layer.copyCGLPixelFormat(forDisplayMask: 0)
    check(copiedFormat == pixelFormat, "Copies must keep the original pixel format")
    check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline + 1,
          "Each pixel-format copy must transfer one independently retained reference")
    layer.releaseCGLPixelFormat(copiedFormat)
    check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline,
          "Core Animation format release must not consume the layer's reference")
  }
}

func testShadowLifetime() {
  let view = VideoView()
  var model: ViewLayer? = ViewLayer(view)
  CGLSetCurrentContext(nil)
  let context = CGLRetainContext(model!.cglContext)
  let pixelFormat = CGLRetainPixelFormat(model!.cglPixelFormat)
  defer {
    CGLReleaseContext(context)
    CGLReleasePixelFormat(pixelFormat)
  }
  let contextBaseline = CGLGetContextRetainCount(context)
  let formatBaseline = CGLGetPixelFormatRetainCount(pixelFormat)
  for _ in 0..<128 {
    autoreleasepool {
      var shadow: ViewLayer? = ViewLayer(layer: model!)
      check(shadow!.cglContext == context, "Shadow context must retain the shared identity")
      check(CGLGetContextRetainCount(context) == contextBaseline + 1,
            "Each shadow must independently retain the context")
      check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline + 1,
            "Each shadow must independently retain the pixel format")
      shadow = nil
    }
    CATransaction.flush()
    check(CGLGetContextRetainCount(context) == contextBaseline,
          "Shadow destruction must balance its context retain")
    check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline,
          "Shadow destruction must balance its pixel-format retain")
  }
  var survivingShadow: ViewLayer? = ViewLayer(layer: model!)
  model = nil
  CATransaction.flush()
  check(CGLGetContextRetainCount(context) == contextBaseline,
        "The surviving shadow must own the context after model destruction")
  check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline,
        "The surviving shadow must own the pixel format after model destruction")
  let copied = survivingShadow!.copyCGLContext(forPixelFormat: pixelFormat)
  survivingShadow!.releaseCGLContext(copied)
  survivingShadow = nil
  CATransaction.flush()
  check(CGLGetContextRetainCount(context) == contextBaseline - 1,
        "Final layer destruction must release the owned context")
  check(CGLGetPixelFormatRetainCount(pixelFormat) == formatBaseline - 1,
        "Final layer destruction must release the owned pixel format")
}

func testShutdown() {
  let view = VideoView()
  let idleTimer = Timer(timeInterval: 600, repeats: false) { _ in }
  view.displayIdleTimer = idleTimer
  view.uninit()
  check(!view.stopWaitTimedOut, "Shutdown must not hold the callback's read/write lock while joining it")
  check(!view.stopWhileGLLocked, "The display link must stop before locking the OpenGL context")
  check(view.player.mpv.swaps == 1, "The last active callback must finish before renderer teardown")
  check(view.player.mpv.swapsAfterFree == 0, "Callbacks must not access a freed renderer")
  check(view.player.mpv.freeCount == 1 && view.isUninited, "Shutdown must free the renderer exactly once")
  check(view.player.mpv.lockCount == view.player.mpv.unlockCount, "OpenGL locks must be balanced")
  check(view.displayIdleTimer == nil && !idleTimer.isValid, "Shutdown must invalidate the idle timer")
  let lockCount = view.player.mpv.lockCount
  let stopCount = view.stopCount
  view.uninit()
  check(view.player.mpv.freeCount == 1, "Repeated shutdown must not free the renderer again")
  check(view.player.mpv.lockCount == lockCount && view.stopCount == stopCount,
        "Repeated teardown must not touch the weak player or its old OpenGL context")
  check(view.player.mpv.swaps == 1, "Repeated shutdown callbacks must skip the freed renderer")
  view.startDisplayLink()
  check(view.createLinkCount == 0, "A late activity notification must not restart a freed renderer's link")
}

let group = CommandLine.arguments.dropFirst().first ?? "all"
if group == "all" || group == "copies" { testCopies() }
if group == "all" || group == "shadows" { testShadowLifetime() }
if group == "all" || group == "shutdown" { testShutdown() }
print("PASS: Render lifecycle regressions (\(checks) checks)")
