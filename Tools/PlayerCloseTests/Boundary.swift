import Cocoa
import OpenGL.GL3

enum Logger {
  enum Level { case debug, verbose, warning }
  static func makeSubsystem(_ value: String) -> String { value }
  static func log(_ message: String, level: Level = .debug, subsystem: String = "") {}
  static func fatal(_ message: String) -> Never { fatalError(message) }
}

final class MPVController {
  let mpv: OpaquePointer
  var mpvRenderContext: OpaquePointer?
  var openGLContext: CGLContextObj!
  init() {
    mpv = mpv_create()!
    for (name, value) in [
      ("config", "no"), ("terminal", "no"), ("input-default-bindings", "no"),
      ("input-terminal", "no"), ("idle", "yes"), ("keep-open", "yes"),
      ("vo", "libmpv"), ("ao", "null"), ("hwdec", ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"] ?? "no"),
      ("cache", "no"), ("save-position-on-quit", "no"), ("resume-playback", "no"),
      ("osd-level", "0"), ("loop-file", "no"), ("loop-playlist", "no")
    ] { precondition(mpv_set_option_string(mpv, name, value) >= 0) }
    precondition(mpv_initialize(mpv) >= 0)
  }
  func getEnum(_ name: String) -> CocoaCbSwRenderer {
    ProcessInfo.processInfo.environment["CHENGYING_TEST_SOFTWARE_GL"] == "1" ? .yes : .auto
  }
  func getFlag(_ name: String) -> Bool {
    var flag: Int32 = 0
    _ = mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    return flag != 0
  }
  func getString(_ name: String) -> String? {
    guard let value = mpv_get_property_string(mpv, name) else { return nil }
    defer { mpv_free(value) }
    return String(cString: value)
  }
  func setString(_ name: String, _ value: String) {
    precondition(mpv_set_property_string(mpv, name, value) >= 0)
  }
  func command(_ args: [String]) {
    var pointers: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
    defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    precondition(mpv_command(mpv, &pointers) >= 0)
  }
  func lockAndSetOpenGLContext() {
    CGLLockContext(openGLContext)
    CGLSetCurrentContext(openGLContext)
  }
  func unlockOpenGLContext() { CGLUnlockContext(openGLContext) }
  func shouldRenderUpdateFrame() -> Bool {
    guard let mpvRenderContext else { return false }
    return mpv_render_context_update(mpvRenderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
  }
  func startRendering(layer: ViewLayer) {
    openGLContext = CGLGetCurrentContext()
    let lookup: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
      guard let name else { return nil }
      return CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString), String(cString: name) as CFString)
    }
    var gl = mpv_opengl_init_params(get_proc_address: lookup, get_proc_address_ctx: nil)
    var advanced: Int32 = 1
    let api = strdup(MPV_RENDER_API_TYPE_OPENGL)
    defer { free(api) }
    withUnsafeMutablePointer(to: &gl) { gl in
      withUnsafeMutablePointer(to: &advanced) { advanced in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: gl),
          mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
          mpv_render_param()
        ]
        precondition(mpv_render_context_create(&mpvRenderContext, mpv, &params) >= 0)
      }
    }
    mpv_render_context_set_update_callback(mpvRenderContext, { pointer in
      guard let pointer else { return }
      Unmanaged<ViewLayer>.fromOpaque(pointer).takeUnretainedValue().update()
    }, Unmanaged.passUnretained(layer).toOpaque())
  }
  func finish(view: VideoView) {
    lockAndSetOpenGLContext()
    view.$isUninited.withWriteLock { value in
      value = true
      mpv_render_context_set_update_callback(mpvRenderContext, nil, nil)
      mpv_render_context_free(mpvRenderContext)
      mpvRenderContext = nil
    }
    unlockOpenGLContext()
    mpv_terminate_destroy(mpv)
  }
}

final class PlayerCore {
  let mpv: MPVController! = MPVController()
  let playerNumber = 0
}
final class VideoView: NSView {
  weak var player: PlayerCore!
  @ReadWriteAtomic var isUninited = false
  lazy var videoLayer = ObservedLayer(self)
  init(player: PlayerCore) {
    self.player = player
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    layer = videoLayer
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError("Unused fixture initializer") }
}

final class ObservedLayer: ViewLayer {
  @Atomic static var frames = 0
  override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                     forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    Self.$frames.withLock { $0 += 1 }
  }
}
