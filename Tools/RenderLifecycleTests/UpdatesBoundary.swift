import Foundation

// These boundaries deliberately do not create AppKit, OpenGL, or media objects.
typealias CGLContextObj = Int
typealias CGLPixelFormatObj = Int
typealias CFTimeInterval = Double
typealias GLint = Int32
typealias GLenum = UInt32
typealias GLbitfield = UInt32
struct CVTimeStamp {}

let GL_COLOR_BUFFER_BIT: GLenum = 1
let GL_DRAW_FRAMEBUFFER_BINDING: GLenum = 2
let GL_VIEWPORT: GLenum = 3
func glClear(_ mask: GLbitfield) {}
func glClearColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {}
func glFlush() {}
func glGetIntegerv(_ property: GLenum, _ value: UnsafeMutablePointer<GLint>) {
  if property == GL_VIEWPORT {
    value[0] = 0; value[1] = 0; value[2] = 640; value[3] = 360
  } else {
    value.pointee = 1
  }
}

struct mpv_opengl_fbo { var fbo: Int32; var w: Int32; var h: Int32; var internal_format: Int32 }
struct mpv_render_param {
  var type = 0
  var data: UnsafeMutableRawPointer? = nil
}
let MPV_RENDER_PARAM_OPENGL_FBO = 1
let MPV_RENDER_PARAM_FLIP_Y = 2
let MPV_RENDER_PARAM_DEPTH = 3
let MPV_RENDER_PARAM_SKIP_RENDERING = 4
struct FrameFlag { let rawValue: UInt64 }
let MPV_RENDER_UPDATE_FRAME = FrameFlag(rawValue: 1)

final class RenderContext {
  var frameAvailable = false
  var updates = 0
  var renders = 0
  var skips = 0
  var onUpdate: (() -> Void)?
  var onRender: (() -> Void)?
}

func mpv_render_context_update(_ context: RenderContext) -> UInt64 {
  context.updates += 1
  context.onUpdate?()
  return context.frameAvailable ? MPV_RENDER_UPDATE_FRAME.rawValue : 0
}

@discardableResult
func mpv_render_context_render(_ context: RenderContext, _ parameters: UnsafePointer<mpv_render_param>) -> Int32 {
  context.frameAvailable = false
  if parameters.pointee.type == MPV_RENDER_PARAM_SKIP_RENDERING {
    context.skips += 1
  } else {
    context.renders += 1
  }
  context.onRender?()
  return 0
}

final class MPVBoundary {
  let context = RenderContext()
  var mpvRenderContext: RenderContext? { context }
  let glLock = NSRecursiveLock()
  var locks = 0
  var unlocks = 0
  func lockAndSetOpenGLContext() { glLock.lock(); locks += 1 }
  func unlockOpenGLContext() { unlocks += 1; glLock.unlock() }
}
final class PlayerCore { let mpv: MPVBoundary! = MPVBoundary() }
final class VideoView {
  let player = PlayerCore()
  @ReadWriteAtomic var isUninited = false
}

class LayerBoundary {
  var isAsynchronous = false
  var appKitDraws = true
  var onBeforeDraw: (() -> Void)?
  var displays = 0
  func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
               forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool { false }
  func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
            forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {}
  func display() {
    displays += 1
    guard appKitDraws, canDraw(inCGLContext: 0, pixelFormat: 0, forLayerTime: 0, displayTime: nil) else { return }
    onBeforeDraw?()
    draw(inCGLContext: 0, pixelFormat: 0, forLayerTime: 0, displayTime: nil)
  }
}
enum CATransaction {
  static func begin() {}
  static func commit() {}
  static func flush() {}
}
