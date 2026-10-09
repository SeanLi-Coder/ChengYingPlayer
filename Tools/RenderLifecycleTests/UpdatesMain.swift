import Foundation

@main
enum RenderUpdateTests {
  static var checks = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
  }

  static func fixture(_ body: (VideoView, ViewLayer, RenderContext) -> Void) {
    let view = VideoView()
    let layer = ViewLayer(view)
    body(view, layer, view.player.mpv.context)
    // Drain callbacks from each controlled injection before destroying the fixture.
    layer.mpvGLQueue.sync {}
    layer.mpvGLQueue.sync {}
    check(view.player.mpv.locks == view.player.mpv.unlocks, "Fallback GL locks remain balanced")
  }

  static func ready(_ layer: ViewLayer) -> Bool {
    layer.canDraw(inCGLContext: 0, pixelFormat: 0, forLayerTime: 0, displayTime: nil)
  }

  static func drain(_ layer: ViewLayer) {
    layer.mpvGLQueue.sync {}
    layer.mpvGLQueue.sync {}
  }

  static func main() {
    fixture { _, layer, context in
      // mpv has already moved a late next_frame into cur_frame: no FRAME bit.
      layer.update()
      drain(layer)
      check(context.renders == 1, "A callback redraws the current frame after its FRAME bit expires")
      check(context.updates == 2, "Both readiness and draw service advanced-control dispatch")
      check(!layer.pendingRenderUpdate, "A completed draw consumes the original callback")
      let displays = layer.displays
      check(!ready(layer), "Idle readiness does not repeat a consumed redraw")
      check(layer.displays == displays && context.renders == 1, "No background display loop is manufactured")
    }

    fixture { _, layer, context in
      layer.forceDraw = true
      check(ready(layer), "Explicit forced drawing remains supported")
      check(context.updates == 1, "Forced drawing must not short-circuit advanced-control dispatch")
      layer.display()
      check(context.renders == 1 && !layer.forceDraw, "Forced drawing clears after its actual render")
      check(!ready(layer), "A completed forced draw is not sticky")
    }

    fixture { _, layer, context in
      context.frameAvailable = true
      layer.display()
      check(context.renders == 1, "A genuine FRAME bit draws without an extra callback")
      check(!ready(layer), "A consumed genuine frame does not continuously redraw")
    }

    fixture { _, layer, context in
      context.onRender = {
        if context.renders == 1 { layer.update() }
      }
      layer.update()
      drain(layer)
      check(context.renders == 2, "A callback arriving inside rendering survives for the next display")
      check(context.skips == 0, "A new callback is not mistaken for a skipped AppKit draw")
      check(!layer.pendingRenderUpdate && !ready(layer), "The follow-up render consumes only its own request")
      context.onRender = nil
    }

    fixture { _, layer, context in
      context.onUpdate = {
        // First update is canDraw; second is dispatch just before rendering.
        if context.updates == 2 { layer.update() }
      }
      layer.update()
      drain(layer)
      check(context.renders == 2, "A callback arriving during draw dispatch survives its first render")
      check(context.skips == 0 && !ready(layer), "Dispatch callbacks drain without skip or redraw loops")
      context.onUpdate = nil
    }

    fixture { _, layer, context in
      let enteredRender = DispatchSemaphore(value: 0)
      let releaseRender = DispatchSemaphore(value: 0)
      var renderWaitSucceeded = false
      context.onRender = {
        if context.renders == 1 {
          enteredRender.signal()
          renderWaitSucceeded = releaseRender.wait(timeout: .now() + 3) == .success
        }
      }
      layer.update()
      check(enteredRender.wait(timeout: .now() + 3) == .success, "The render thread reaches the controlled callback boundary")
      layer.update()
      releaseRender.signal()
      drain(layer)
      check(renderWaitSucceeded, "An update from another thread does not wait for the rendering lock")
      check(context.renders == 2 && context.skips == 0, "A concurrent callback survives until a second real draw")
      check(!layer.pendingRenderUpdate && !ready(layer), "Concurrent requests drain completely without polling")
      context.onRender = nil
    }

    fixture { _, layer, context in
      layer.onBeforeDraw = {
        layer.onBeforeDraw = nil
        layer.update()
      }
      layer.update()
      drain(layer)
      check(context.renders == 1, "A callback before draw is covered by the draw's fresh dispatch update")
      check(context.updates >= 3, "A queued callback still services dispatch after an earlier draw covers it")
      check(!layer.pendingRenderUpdate && !ready(layer), "Covered callbacks do not leave pending work")
    }

    fixture { _, layer, context in
      layer.appKitDraws = false
      layer.update()
      drain(layer)
      check(context.skips == 1 && context.renders == 0, "Hidden AppKit surfaces acknowledge one pending redraw")
      check(context.updates == 1, "Hidden surfaces still process advanced-control dispatch")
      check(!layer.pendingRenderUpdate, "Hidden-surface acknowledgement consumes the original request")
      layer.display()
      check(context.skips == 1, "A hidden surface does not continuously acknowledge the same request")
    }

    fixture { _, layer, context in
      layer.appKitDraws = false
      context.onRender = {
        if context.skips == 1 { layer.update() }
      }
      layer.update()
      drain(layer)
      check(context.skips == 2, "A callback during skipped rendering is preserved for a follow-up display")
      check(!layer.pendingRenderUpdate && context.renders == 0, "Hidden callbacks drain without real drawing")
      context.onRender = nil
    }

    fixture { _, layer, context in
      layer.appKitDraws = false
      context.onUpdate = {
        if context.updates == 1 { layer.update() }
      }
      layer.update()
      drain(layer)
      check(context.skips == 2, "A callback during hidden-surface dispatch is not cleared after the API call")
      check(!layer.pendingRenderUpdate, "The hidden dispatch follow-up consumes its own notification")
      context.onUpdate = nil
    }

    fixture { view, layer, context in
      view.isUninited = true
      layer.update(force: true)
      drain(layer)
      check(context.updates == 0 && context.renders == 0 && context.skips == 0,
            "Late callbacks must not access a freed renderer")
    }

    fixture { _, layer, context in
      layer.inLiveResize = true
      drain(layer)
      check(context.renders == 1, "Live resize still forces a background draw")
      check(!ready(layer), "The main thread does not draw while live resize is active")
      layer.inLiveResize = false
      drain(layer)
      check(context.renders == 2 && !layer.isAsynchronous, "Ending resize draws once and leaves asynchronous mode")
      check(!ready(layer), "Ending resize does not create an idle render loop")
    }

    print("PASS: Render update regressions (\(checks) checks; no GUI or media)")
  }
}
