import Cocoa
import OpenGL.GL3

let failureDiagnosticDirectory: URL? = CommandLine.arguments.count > 2
  ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
let playerCloseGLPassDiagnosticsEnabled = ProcessInfo.processInfo.environment["CLOSE_TEST_GL_PASS_DIAGNOSTICS"] == "1"
var playerCloseGLInitUnpackSnapshots: [[String: Any]] = []

private func captureInitialUnpackState(_ phase: String) {
  guard playerCloseGLPassDiagnosticsEnabled else { return }
  let parameters: [(String, GLenum)] = [
    ("clientStorageApple", GLenum(0x85B2)),
    ("alignment", GLenum(GL_UNPACK_ALIGNMENT)), ("swapBytes", GLenum(GL_UNPACK_SWAP_BYTES)),
    ("rowLength", GLenum(GL_UNPACK_ROW_LENGTH)), ("skipRows", GLenum(GL_UNPACK_SKIP_ROWS)),
    ("skipPixels", GLenum(GL_UNPACK_SKIP_PIXELS)), ("imageHeight", GLenum(GL_UNPACK_IMAGE_HEIGHT)),
    ("skipImages", GLenum(GL_UNPACK_SKIP_IMAGES)),
    ("pixelUnpackBuffer", GLenum(GL_PIXEL_UNPACK_BUFFER_BINDING)),
  ]
  var snapshot: [String: Any] = ["phase": phase, "entryError": glGetError()]
  for (name, parameter) in parameters {
    var value: GLint = -1
    glGetIntegerv(parameter, &value)
    snapshot[name] = value
  }
  snapshot["queryError"] = glGetError()
  playerCloseGLInitUnpackSnapshots.append(snapshot)
}

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
    if failureDiagnosticDirectory != nil {
      precondition(mpv_request_log_messages(mpv, "debug") >= 0)
      precondition(mpv_set_option_string(mpv, "screenshot-format", "png") >= 0)
    }
    for (name, value) in [
      ("config", "no"), ("terminal", "no"), ("input-default-bindings", "no"),
      ("input-terminal", "no"), ("idle", "yes"), ("keep-open", "yes"),
      ("vo", "libmpv"), ("ao", "null"), ("hwdec", ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"] ?? "no"),
      ("cache", "no"), ("save-position-on-quit", "no"), ("resume-playback", "no"),
      ("osd-level", "0"), ("loop-file", "no"), ("loop-playlist", "no")
    ] { precondition(mpv_set_option_string(mpv, name, value) >= 0) }
    precondition(mpv_initialize(mpv) >= 0)
    precondition(mpv_observe_property(mpv, 1, "time-pos", MPV_FORMAT_DOUBLE) >= 0)
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
  func diagnosticCommand(_ args: [String], identifier: UInt64) -> Int32 {
    var pointers: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
    defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    return mpv_command_async(mpv, identifier, &pointers)
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
    captureInitialUnpackState("before-context-create")
    if let mode = ProcessInfo.processInfo.environment["CLOSE_TEST_MPE_CONTROL"] {
      precondition(mode == "default" || mode == "disabled", "Unknown MPE diagnostic control")
      var before: GLint = -1
      let beforeResult = CGLIsEnabled(openGLContext, kCGLCEMPEngine, &before)
      guard beforeResult == kCGLNoError && before == 1 else {
        print("MPE_CONTROL_INVALID: mode=\(mode), before_result=\(beforeResult.rawValue), before=\(before)")
        fflush(stdout)
        exit(78)
      }
      let disableResult = mode == "disabled" ? CGLDisable(openGLContext, kCGLCEMPEngine) : kCGLNoError
      var after: GLint = -1
      let afterResult = CGLIsEnabled(openGLContext, kCGLCEMPEngine, &after)
      let expected: GLint = mode == "disabled" ? 0 : 1
      print("MPE_CONTROL: mode=\(mode), before_result=\(beforeResult.rawValue), before=\(before), disable_result=\(disableResult.rawValue), after_result=\(afterResult.rawValue), after=\(after)")
      fflush(stdout)
      guard disableResult == kCGLNoError && afterResult == kCGLNoError && after == expected else {
        print("MPE_CONTROL_INVALID: requested state was not observed")
        fflush(stdout)
        exit(78)
      }
    }
    let lookup: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
      guard let name else { return nil }
      if playerCloseGLPassDiagnosticsEnabled, let pointer = playerCloseGLDiagnosticFunction(name) { return pointer }
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
    captureInitialUnpackState("after-context-create")
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
  @Atomic static var pictureFrames = 0
  @Atomic static var readinessChecks = 0
  @Atomic static var acceptedReadinessChecks = 0
  override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
    Self.$readinessChecks.withLock { $0 += 1 }
    let accepted = super.canDraw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    if accepted { Self.$acceptedReadinessChecks.withLock { $0 += 1 } }
    return accepted
  }
  override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                     forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
    var target: GLint = 0
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &target)
    super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    Self.$frames.withLock { $0 += 1 }
    // A zero target makes production use its private cached FBO. Do not count an
    // unrelated default back buffer as verified output when that target is unknown.
    guard target > 0 else { return }
    // Sample the actual framebuffer after production drawing. The generated
    // color pattern must not be confused with a clear-only/empty layer callback.
    var viewport: [GLint] = [0, 0, 0, 0]
    glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
    guard viewport[2] > 0, viewport[3] > 0 else { return }
    // mpv restores most GL state, including framebuffer bindings. Read from the
    // framebuffer Core Animation supplied to production draw, not its default.
    var savedReadFramebuffer: GLint = 0
    var savedReadBuffer: GLint = 0
    glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &savedReadFramebuffer)
    glGetIntegerv(GLenum(GL_READ_BUFFER), &savedReadBuffer)
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(target))
    glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
    defer {
      glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(savedReadFramebuffer))
      glReadBuffer(GLenum(savedReadBuffer))
    }
    var colors = Set<UInt32>()
    for row in 1...3 {
      for column in 1...3 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        glReadPixels(viewport[0] + viewport[2] * GLint(column) / 4,
                     viewport[1] + viewport[3] * GLint(row) / 4,
                     1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
        guard glGetError() == GLenum(GL_NO_ERROR) else { return }
        let color = UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
        if color != 0 { colors.insert(color) }
      }
    }
    if colors.count >= 2 { Self.$pictureFrames.withLock { $0 += 1 } }
  }
}
