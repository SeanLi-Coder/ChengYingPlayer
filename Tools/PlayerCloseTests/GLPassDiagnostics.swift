import Foundation
import OpenGL.GL3

// Diagnostic-only interception. The caller must explicitly install this lookup.
// Readback synchronizes rendering and can change timing; these samples must never
// contribute to the fixture's original picture count or release assertions.
private let passDiagnosticLimit = 18
private let unpackClientStorageApple = GLenum(0x85B2)

private struct PassPixel: Encodable {
  let x: GLint
  let y: GLint
  let rgbaFloat: [GLfloat]
  let floatError: GLenum
  let rgbaByte: [UInt8]
  let byteError: GLenum
}

private struct PassTextureUnit: Encodable {
  let unit: Int
  let texture1D: GLint
  let texture2D: GLint
  let description1D: PassTextureDescription?
  let description2D: PassTextureDescription?
}

private struct PassTextureDescription: Encodable {
  let target: GLenum
  let texture: GLint
  let width: GLint
  let height: GLint
  let internalFormat: GLint
  let minFilter: GLint
  let magFilter: GLint
  let error: GLenum
}

private struct PassUniform: Encodable {
  let name: String
  let type: GLenum
  let location: GLint
  let integers: [GLint]
  let floats: [GLfloat]
  let error: GLenum
}

private struct PassChannelStatistics: Encodable {
  let channel: Int
  let finiteCount: Int
  let nanCount: Int
  let positiveInfinityCount: Int
  let negativeInfinityCount: Int
  let finiteMinimum: GLfloat?
  let finiteMaximum: GLfloat?
}

private struct PassLUT: Encodable {
  let uniform: String
  let unit: GLint
  let texture: PassTextureDescription
  var values: [GLfloat] = []
  var channels: [PassChannelStatistics] = []
  var readError: GLenum = 0
  var restoreError: GLenum = 0
  var skipped: String?
}

private struct PassNeighbor: Encodable {
  let anchorX: GLint
  let anchorY: GLint
  let x: GLint
  let y: GLint
  let rgbaFloat: [GLfloat]
  let error: GLenum
}

private struct PassRecord: Encodable {
  let index: Int
  let mode: GLenum
  let first: GLint
  let count: GLsizei
  var entryError: GLenum = 0
  var unpackBefore: [String: GLint] = [:]
  var unpackQueryError: GLenum = 0
  var drawError: GLenum = 0
  var program: GLint = 0
  var drawFramebuffer: GLint = 0
  var drawBuffer: GLint = 0
  var viewport: [GLint] = []
  var activeTexture: GLint = 0
  var textureUnits: [PassTextureUnit] = []
  var uniforms: [PassUniform] = []
  var uniformQueryError: GLenum = 0
  var lut: PassLUT?
  var stateQueryError: GLenum = 0
  var readFramebufferStatus: GLenum = 0
  var readSetupError: GLenum = 0
  var pixels: [PassPixel] = []
  var horizontalNeighbors: [PassNeighbor] = []
  var readSkipped: String?
  var restoreError: GLenum = 0
}

private struct PassReport: Encodable {
  let schemaVersion = 1
  let diagnosticOnly = true
  let passLimit = passDiagnosticLimit
  let drawCallsSeen: Int
  let completedRecords: [PassRecord]
}

private final class PassStore {
  static let shared = PassStore()
  private let lock = NSLock()
  private var seen = 0
  private var records: [PassRecord] = []

  func reserve() -> Int? {
    lock.lock()
    defer { lock.unlock() }
    // Saturation also bounds bookkeeping in an unexpectedly long-running test.
    if seen < Int.max { seen += 1 }
    return seen <= passDiagnosticLimit ? seen : nil
  }

  func append(_ record: PassRecord) {
    lock.lock()
    defer { lock.unlock() }
    if records.count < passDiagnosticLimit { records.append(record) }
  }

  func report() -> PassReport {
    lock.lock()
    defer { lock.unlock() }
    return PassReport(drawCallsSeen: seen, completedRecords: records.sorted { $0.index < $1.index })
  }
}

private func passInteger(_ name: GLenum) -> GLint {
  var value: GLint = -1
  glGetIntegerv(name, &value)
  return value
}

private func passUnpackState() -> [String: GLint] {
  let parameters: [(String, GLenum)] = [
    ("clientStorageApple", unpackClientStorageApple),
    ("alignment", GLenum(GL_UNPACK_ALIGNMENT)),
    ("swapBytes", GLenum(GL_UNPACK_SWAP_BYTES)),
    ("rowLength", GLenum(GL_UNPACK_ROW_LENGTH)),
    ("skipRows", GLenum(GL_UNPACK_SKIP_ROWS)),
    ("skipPixels", GLenum(GL_UNPACK_SKIP_PIXELS)),
    ("imageHeight", GLenum(GL_UNPACK_IMAGE_HEIGHT)),
    ("skipImages", GLenum(GL_UNPACK_SKIP_IMAGES)),
    ("pixelUnpackBuffer", GLenum(GL_PIXEL_UNPACK_BUFFER_BINDING)),
  ]
  return Dictionary(uniqueKeysWithValues: parameters.map { ($0.0, passInteger($0.1)) })
}

private func passTextures() -> [PassTextureUnit] {
  let previousActive = passInteger(GLenum(GL_ACTIVE_TEXTURE))
  guard previousActive >= GLint(GL_TEXTURE0) else { return [] }
  defer { glActiveTexture(GLenum(previousActive)) }
  // These are bindings, not a claim about sampler uniform values. mpv's shader
  // source log provides the sampler declarations; restrict queries to four units.
  return (0..<4).map { unit in
    glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
    let one = passInteger(GLenum(GL_TEXTURE_BINDING_1D))
    let two = passInteger(GLenum(GL_TEXTURE_BINDING_2D))
    return PassTextureUnit(unit: unit, texture1D: one, texture2D: two,
                           description1D: passTextureDescription(GLenum(GL_TEXTURE_1D), texture: one),
                           description2D: passTextureDescription(GLenum(GL_TEXTURE_2D), texture: two))
  }
}

private func passTextureDescription(_ target: GLenum, texture: GLint) -> PassTextureDescription? {
  guard texture > 0 else { return nil }
  func level(_ parameter: GLenum) -> GLint {
    var result: GLint = -1
    glGetTexLevelParameteriv(target, 0, parameter, &result)
    return result
  }
  func parameter(_ name: GLenum) -> GLint {
    var result: GLint = -1
    glGetTexParameteriv(target, name, &result)
    return result
  }
  return PassTextureDescription(target: target, texture: texture,
    width: level(GLenum(GL_TEXTURE_WIDTH)),
    height: target == GLenum(GL_TEXTURE_1D) ? 1 : level(GLenum(GL_TEXTURE_HEIGHT)),
    internalFormat: level(GLenum(GL_TEXTURE_INTERNAL_FORMAT)),
    minFilter: parameter(GLenum(GL_TEXTURE_MIN_FILTER)),
    magFilter: parameter(GLenum(GL_TEXTURE_MAG_FILTER)), error: glGetError())
}

private func passUniforms(_ program: GLint) -> [PassUniform] {
  guard program > 0 else { return [] }
  var activeCount: GLint = 0
  glGetProgramiv(GLuint(program), GLenum(GL_ACTIVE_UNIFORMS), &activeCount)
  var result: [PassUniform] = []
  let selected: Set<String> = Set(["lut", "dither", "colormatrix", "colormatrix_c"] +
    (0..<4).flatMap { index in
      ["texture\(index)", "texture_size\(index)", "pixel_size\(index)",
       "texture_rot\(index)", "texture_off\(index)"]
    })
  // Enumerating active uniforms obtains the actual GLSL type before choosing an
  // output buffer size. Do not assume the size from a possibly reused name.
  for index in 0..<max(0, min(Int(activeCount), 64)) {
    var name = [GLchar](repeating: 0, count: 128)
    var length: GLsizei = 0
    var size: GLint = 0
    var type: GLenum = 0
    name.withUnsafeMutableBufferPointer {
      glGetActiveUniform(GLuint(program), GLuint(index), GLsizei($0.count), &length, &size, &type,
                         $0.baseAddress)
    }
    guard length > 0, length < name.count - 1, size == 1 else { continue }
    let text = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    guard selected.contains(text) else { continue }
    let location = text.withCString { glGetUniformLocation(GLuint(program), $0) }
    guard location >= 0 else { continue }
    var integerCount = 0
    var floatCount = 0
    switch Int32(type) {
    case GL_SAMPLER_1D, GL_SAMPLER_2D, GL_SAMPLER_3D, GL_SAMPLER_2D_RECT,
         GL_INT, GL_BOOL:
      integerCount = 1
    case GL_FLOAT: floatCount = 1
    case GL_FLOAT_VEC2: floatCount = 2
    case GL_FLOAT_VEC3: floatCount = 3
    case GL_FLOAT_VEC4, GL_FLOAT_MAT2: floatCount = 4
    case GL_FLOAT_MAT3: floatCount = 9
    case GL_FLOAT_MAT4: floatCount = 16
    default: continue
    }
    var integers = [GLint](repeating: -1, count: integerCount)
    var floats = [GLfloat](repeating: .nan, count: floatCount)
    if integerCount > 0 {
      integers.withUnsafeMutableBufferPointer { glGetUniformiv(GLuint(program), location, $0.baseAddress) }
    } else {
      floats.withUnsafeMutableBufferPointer { glGetUniformfv(GLuint(program), location, $0.baseAddress) }
    }
    result.append(PassUniform(name: text, type: type, location: location,
                              integers: integers, floats: floats, error: glGetError()))
  }
  return result
}

private func passLUT(_ uniforms: [PassUniform]) -> PassLUT? {
  guard let lut = uniforms.first(where: { $0.name == "lut" }),
        lut.type == GLenum(GL_SAMPLER_2D), lut.error == GLenum(GL_NO_ERROR),
        let unit = lut.integers.first, unit >= 0, unit < 16 else { return nil }
  let previousActive = passInteger(GLenum(GL_ACTIVE_TEXTURE))
  guard previousActive >= GLint(GL_TEXTURE0) else { return nil }
  glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
  defer { glActiveTexture(GLenum(previousActive)) }
  let texture = passInteger(GLenum(GL_TEXTURE_BINDING_2D))
  guard let description = passTextureDescription(GLenum(GL_TEXTURE_2D), texture: texture) else {
    return nil
  }
  var record = PassLUT(uniform: lut.name, unit: unit, texture: description)
  let width = Int(description.width), height = Int(description.height)
  guard description.error == GLenum(GL_NO_ERROR), width > 0, height > 0,
        width <= 1024, height <= 1024, width * height * 4 <= 4096 else {
    record.skipped = "LUT dimensions invalid or RGBA readback exceeds 4096 floats"
    return record
  }
  let packParameters = [GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_PACK_SKIP_ROWS,
                        GL_PACK_SKIP_PIXELS, GL_PACK_SWAP_BYTES, GL_PACK_LSB_FIRST,
                        GL_PACK_IMAGE_HEIGHT, GL_PACK_SKIP_IMAGES]
  let previousPack = packParameters.map { passInteger(GLenum($0)) }
  let previousPackBuffer = passInteger(GLenum(GL_PIXEL_PACK_BUFFER_BINDING))
  guard previousPackBuffer >= 0, previousPack.allSatisfy({ $0 >= 0 }) else {
    record.skipped = "Could not capture LUT readback packing state"
    record.readError = glGetError()
    return record
  }
  glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
  for parameter in packParameters {
    glPixelStorei(GLenum(parameter), parameter == GL_PACK_ALIGNMENT ? 1 : 0)
  }
  var values = [GLfloat](repeating: .nan, count: width * height * 4)
  values.withUnsafeMutableBytes {
    glGetTexImage(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_RGBA), GLenum(GL_FLOAT), $0.baseAddress)
  }
  record.readError = glGetError()
  glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), GLuint(previousPackBuffer))
  for (parameter, value) in zip(packParameters, previousPack) {
    glPixelStorei(GLenum(parameter), value)
  }
  record.restoreError = glGetError()
  if record.readError == GLenum(GL_NO_ERROR) {
    // Texel-major RGBA, full level zero only. No arbitrary large source textures
    // are read. Nonfinite values remain explicit strings in JSON.
    record.values = values
    record.channels = (0..<4).map { channel in
      let values = stride(from: channel, to: values.count, by: 4).map { values[$0] }
      let finite = values.filter { $0.isFinite }
      return PassChannelStatistics(channel: channel, finiteCount: finite.count,
        nanCount: values.filter { $0.isNaN }.count,
        positiveInfinityCount: values.filter { $0 == .infinity }.count,
        negativeInfinityCount: values.filter { $0 == -.infinity }.count,
        finiteMinimum: finite.min(), finiteMaximum: finite.max())
    }
  }
  return record
}

private func passReadPixels(_ record: inout PassRecord) {
  guard record.viewport.count == 4,
        record.viewport[2] > 0, record.viewport[3] > 0,
        record.drawFramebuffer >= 0, record.drawBuffer > GLint(GL_NONE) else {
    record.readSkipped = "No readable color output or positive viewport"
    return
  }

  let previousReadFramebuffer = passInteger(GLenum(GL_READ_FRAMEBUFFER_BINDING))
  let previousReadBuffer = passInteger(GLenum(GL_READ_BUFFER))
  let previousPackBuffer = passInteger(GLenum(GL_PIXEL_PACK_BUFFER_BINDING))
  let packParameters = [GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_PACK_SKIP_ROWS,
                        GL_PACK_SKIP_PIXELS, GL_PACK_SWAP_BYTES, GL_PACK_LSB_FIRST]
  let previousPack = packParameters.map { passInteger(GLenum($0)) }
  guard previousReadFramebuffer >= 0, previousReadBuffer >= 0,
        previousPackBuffer >= 0, previousPack.allSatisfy({ $0 >= 0 }) else {
    record.readSkipped = "Could not capture readback state for restoration"
    record.readSetupError = glGetError()
    return
  }

  glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(record.drawFramebuffer))
  // Read-buffer selection belongs to an FBO. Restore the target FBO's selection
  // as well as the previously bound read FBO, which may be a different object.
  let targetPreviousReadBuffer = passInteger(GLenum(GL_READ_BUFFER))
  defer {
    if targetPreviousReadBuffer >= 0 { glReadBuffer(GLenum(targetPreviousReadBuffer)) }
    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(previousReadFramebuffer))
    glReadBuffer(GLenum(previousReadBuffer))
    glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), GLuint(previousPackBuffer))
    for (parameter, value) in zip(packParameters, previousPack) {
      glPixelStorei(GLenum(parameter), value)
    }
    record.restoreError = glGetError()
  }
  guard targetPreviousReadBuffer >= 0 else {
    record.readSkipped = "Could not capture target read-buffer selection"
    record.readSetupError = glGetError()
    return
  }

  glReadBuffer(GLenum(record.drawBuffer))
  record.readFramebufferStatus = glCheckFramebufferStatus(GLenum(GL_READ_FRAMEBUFFER))
  // CPU arrays below are exactly one RGBA pixel. Isolate PACK state for readback
  // only, then restore it; never modify UNPACK state or shader/texture contents.
  glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
  for parameter in packParameters {
    glPixelStorei(GLenum(parameter), parameter == GL_PACK_ALIGNMENT ? 1 : 0)
  }
  record.readSetupError = glGetError()
  guard record.readFramebufferStatus == GLenum(GL_FRAMEBUFFER_COMPLETE),
        record.readSetupError == GLenum(GL_NO_ERROR) else {
    record.readSkipped = "Read framebuffer incomplete or readback setup failed"
    return
  }

  for row in 1...3 {
    for column in 1...3 {
      let xValue = Int(record.viewport[0]) + Int(record.viewport[2]) * column / 4
      let yValue = Int(record.viewport[1]) + Int(record.viewport[3]) * row / 4
      guard let x = GLint(exactly: xValue), let y = GLint(exactly: yValue) else {
        record.readSkipped = "Sample coordinate outside GLint range"
        return
      }
      var floats = [GLfloat](repeating: .nan, count: 4)
      floats.withUnsafeMutableBytes { bytes in
        glReadPixels(x, y, 1, 1, GLenum(GL_RGBA), GLenum(GL_FLOAT), bytes.baseAddress)
      }
      let floatError = glGetError()
      var bytes = [UInt8](repeating: 0, count: 4)
      bytes.withUnsafeMutableBytes { buffer in
        glReadPixels(x, y, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), buffer.baseAddress)
      }
      record.pixels.append(PassPixel(x: x, y: y, rgbaFloat: floats,
                                     floatError: floatError, rgbaByte: bytes,
                                     byteError: glGetError()))
      if record.index <= 3 {
        for offset in -4...4 {
          guard let neighborX = GLint(exactly: xValue + offset) else { continue }
          var neighbor = [GLfloat](repeating: .nan, count: 4)
          neighbor.withUnsafeMutableBytes {
            glReadPixels(neighborX, y, 1, 1, GLenum(GL_RGBA), GLenum(GL_FLOAT), $0.baseAddress)
          }
          record.horizontalNeighbors.append(PassNeighbor(anchorX: x, anchorY: y,
            x: neighborX, y: y, rgbaFloat: neighbor, error: glGetError()))
        }
      }
    }
  }
}

private let passDrawArrays: @convention(c) (GLenum, GLint, GLsizei) -> Void = { mode, first, count in
  guard let index = PassStore.shared.reserve() else {
    glDrawArrays(mode, first, count)
    return
  }
  var record = PassRecord(index: index, mode: mode, first: first, count: count)
  // glGetError consumes error state and cannot restore it. Keep separate entry,
  // query, draw, read and restoration values instead of attributing old errors
  // to the intercepted draw. This interception is never enabled in production.
  record.entryError = glGetError()
  record.unpackBefore = passUnpackState()
  record.unpackQueryError = glGetError()
  // This imported framework symbol does not use mpv's get_proc_address callback.
  glDrawArrays(mode, first, count)
  record.drawError = glGetError()
  record.program = passInteger(GLenum(GL_CURRENT_PROGRAM))
  record.drawFramebuffer = passInteger(GLenum(GL_DRAW_FRAMEBUFFER_BINDING))
  record.drawBuffer = passInteger(GLenum(GL_DRAW_BUFFER))
  var viewport = [GLint](repeating: -1, count: 4)
  viewport.withUnsafeMutableBufferPointer { glGetIntegerv(GLenum(GL_VIEWPORT), $0.baseAddress) }
  record.viewport = viewport
  record.activeTexture = passInteger(GLenum(GL_ACTIVE_TEXTURE))
  record.uniforms = passUniforms(record.program)
  record.uniformQueryError = glGetError()
  record.textureUnits = passTextures()
  record.stateQueryError = glGetError()
  passReadPixels(&record)
  record.lut = passLUT(record.uniforms)
  PassStore.shared.append(record)
}

/// Return nil for unhandled names so the existing OpenGL lookup stays in charge.
/// Call this only in an explicitly enabled diagnostic get_proc_address callback.
func playerCloseGLDiagnosticFunction(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
  guard let name, String(cString: name) == "glDrawArrays" else { return nil }
  return unsafeBitCast(passDrawArrays, to: UnsafeMutableRawPointer.self)
}

/// Return a bounded, thread-safe snapshot without printing or changing GL state.
/// In-flight records may be absent; index values identify their reserved order.
func playerCloseGLPassDiagnosticsJSON() -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  encoder.nonConformingFloatEncodingStrategy = .convertToString(
    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
  guard let data = try? encoder.encode(PassStore.shared.report()),
        let result = String(data: data, encoding: .utf8) else {
    return "{\"schemaVersion\":1,\"diagnosticOnly\":true,\"error\":\"Diagnostic JSON encoding failed\"}"
  }
  return result
}
