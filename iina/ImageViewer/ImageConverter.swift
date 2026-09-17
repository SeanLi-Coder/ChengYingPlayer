import Cocoa
import ImageIO
import Darwin

enum ImageConversionFormat: String, CaseIterable {
  case jpeg, png, gif, apng, tiff, bmp, heic, avif, webp

  var title: String {
    switch self {
    case .jpeg: return "JPEG · 高质量 · 白底"
    case .png: return "PNG · 无损 · 透明"
    case .gif: return "GIF · 动图 · 256 色"
    case .apng: return "APNG · 无损动图"
    case .tiff: return "TIFF · 无损 · 多页"
    case .bmp: return "BMP · 白底"
    case .heic: return "HEIC · 高质量"
    case .avif: return "AVIF · 高质量"
    case .webp: return "WebP · 无损 · 动图"
    }
  }

  var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
  var supportsAnimation: Bool { [.gif, .apng, .webp].contains(self) }
  var supportsAlpha: Bool { self != .jpeg && self != .bmp }
  var typeIdentifier: String {
    switch self {
    case .jpeg: return "public.jpeg"
    case .png, .apng: return "public.png"
    case .gif: return "com.compuserve.gif"
    case .tiff: return "public.tiff"
    case .bmp: return "com.microsoft.bmp"
    case .heic: return "public.heic"
    case .avif: return "public.avif"
    case .webp: return "org.webmproject.webp"
    }
  }

  /// A listed UTI is not sufficient: some OS releases advertise unusable encoders.
  private static let nativeAvailable: Set<ImageConversionFormat> = {
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as! [String]
    guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage() else { return [] }
    return Set(allCases.filter { format in
      guard format != .webp, identifiers.contains(format.typeIdentifier) else { return false }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
        return false
      }
      CGImageDestinationAddImage(destination, image,
                                [kCGImageDestinationLossyCompressionQuality: 0.99] as CFDictionary)
      return CGImageDestinationFinalize(destination)
    })
  }()

  static var available: [Self] {
    let readable = CGImageSourceCopyTypeIdentifiers() as! [String]
    return allCases.filter {
      nativeAvailable.contains($0) ||
        ($0 == .webp && readable.contains($0.typeIdentifier) && ImageConverter.webPHelperURL != nil)
    }
  }
}

enum ImageConverter {
  static var webPHelperURL: URL? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let helper = executable.deletingLastPathComponent().appendingPathComponent("chengying-image-codec")
    return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
  }

  /// Exports from full-resolution decoding, never the displayed image. GPS/EXIF user
  /// metadata is deliberately not copied; the decoded color profile remains attached.
  static func convert(url: URL, format: ImageConversionFormat, frameIndex: Int?,
                      editPlan: ImageEditPlan? = nil, token: ImageCancellationToken,
                      progress: @escaping (Double) -> Void) throws -> URL {
    try token.check()
    let document = try ImageDocument(url: url)
    let indices: [Int]
    if let frameIndex {
      guard (0..<document.frameCount).contains(frameIndex) else {
        throw ImageProcessingError.invalid("要导出的图片帧号无效。")
      }
      indices = [frameIndex]
    } else if document.isAnimated && format.supportsAnimation || format == .tiff {
      indices = Array(0..<document.frameCount)
    } else {
      guard document.frameCount == 1 else {
        throw ImageProcessingError.invalid("目标格式不能保留整段动画或全部页面，请明确选择仅导出当前帧。")
      }
      indices = [0]
    }
    if format == .gif && indices.count > 1 && document.loopCount > 32_767 {
      throw ImageProcessingError.invalid("当前 GIF 编码器无法保留超过 32767 次的有限循环，请选择 APNG / WebP。")
    }
    let directory = url.deletingLastPathComponent()
    let scratch = directory.appendingPathComponent(".chengying-image-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let temporary = scratch.appendingPathComponent("converted.\(format.fileExtension)")
    progress(0)
    if format == .webp {
      try encodeWebP(document, indices: indices, scratch: scratch, output: temporary,
                     token: token, editPlan: editPlan, progress: progress)
    } else {
      guard ImageConversionFormat.available.contains(format),
            let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
              format.typeIdentifier as CFString, indices.count, nil) else {
        throw ImageProcessingError.exportFailed
      }
      let animationKey: CFString = format == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
      let loopKey: CFString = format == .gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
      let delayKey: CFString = format == .gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
      let unclampedKey: CFString = format == .gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
      if format.supportsAnimation && indices.count > 1 {
        // ImageIO's GIF writer translates total plays to NETSCAPE repetitions.
        CGImageDestinationSetProperties(destination, [animationKey: [loopKey: document.loopCount]] as CFDictionary)
      }
      for (offset, index) in indices.enumerated() {
        try token.check()
        try autoreleasepool {
          let original = try document.frame(at: index)
          let edited = try editPlan.map { try ImageEditor.render(original, plan: $0, token: token) } ?? original
          try token.check()
          let image = format.supportsAlpha ? edited : try flatten(edited)
          var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            // AVIF 1.0 requests an unsupported lossless mode on current ImageIO.
            kCGImageDestinationLossyCompressionQuality: format == .jpeg ? 1.0 : 0.99,
          ]
          if format.supportsAnimation && indices.count > 1 {
            let delay = document.frameDuration(at: index)
            properties[animationKey] = [delayKey: delay, unclampedKey: delay]
          }
          CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        progress(Double(offset + 1) / Double(indices.count) * 0.85)
      }
      try token.check()
      guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.exportFailed }
    }
    try token.check()
    // Verify encoded structure before publishing. Never leave a partial destination.
    guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
          CGImageSourceGetCount(check) == indices.count else {
      throw ImageProcessingError.exportFailed
    }
    progress(0.95)
    let result = try publish(temporary, beside: url, fileExtension: format.fileExtension,
                             edited: editPlan != nil, token: token)
    progress(1)
    return result
  }

  private static func flatten(_ image: CGImage) throws -> CGImage {
    let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw ImageProcessingError.tooLarge
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    guard let result = context.makeImage() else { throw ImageProcessingError.exportFailed }
    return result
  }

  private static func encodeWebP(_ document: ImageDocument, indices: [Int], scratch: URL, output: URL,
                                token: ImageCancellationToken, editPlan: ImageEditPlan?,
                                progress: @escaping (Double) -> Void) throws {
    guard let helper = webPHelperURL else {
      throw ImageProcessingError.invalid("应用缺少 WebP 编码器，请使用完整构建，或选择 PNG / TIFF。")
    }
    let firstFrame: CGImage = try autoreleasepool {
      let original = try document.frame(at: indices[0])
      return try editPlan.map { try ImageEditor.render(original, plan: $0, token: token) } ?? original
    }
    let width = firstFrame.width, height = firstFrame.height
    let frameBytes = UInt64(width) * UInt64(height) * 4
    guard width <= 16_383, height <= 16_383, indices.count <= 10_000,
          frameBytes <= 256 * 1_048_576, frameBytes * UInt64(indices.count) <= 8 * 1_073_741_824,
          document.loopCount <= 65_535 else {
      throw ImageProcessingError.invalid("WebP 上限：单边 16383 像素、单帧 RGBA 256 MiB、10000 帧、临时数据 8 GiB、有限循环 65535 次。请使用 PNG / TIFF。")
    }
    var profile = Data()
    var outputSpace: CGColorSpace?
    var durations: [Int] = []
    var timestamp = 0
    for (offset, index) in indices.enumerated() {
      try token.check()
      try autoreleasepool {
        let image: CGImage
        if offset == 0 { image = firstFrame }
        else {
          let original = try document.frame(at: index)
          image = try editPlan.map { try ImageEditor.render(original, plan: $0, token: token) } ?? original
        }
        try token.check()
        guard image.width == width, image.height == height else {
          throw ImageProcessingError.invalid("WebP 动画的所有帧必须尺寸一致。")
        }
        if outputSpace == nil {
          outputSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let space = outputSpace!
        if offset == 0, let icc = space.copyICCData() { profile = icc as Data }
        var components = [UInt16](repeating: 0, count: image.width * image.height * 4)
        try components.withUnsafeMutableBytes { bytes in
          guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 16, bytesPerRow: image.width * 8, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageProcessingError.tooLarge
          }
          context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var pixels = [UInt8](repeating: 0, count: components.count)
        // Premultiply at 16 bits, then unpremultiply before quantizing to WebP's
        // 8-bit straight alpha. An 8-bit intermediate loses visible edge precision.
        for pixel in stride(from: 0, to: components.count, by: 4) {
          let alpha = Int(components[pixel + 3])
          pixels[pixel + 3] = UInt8((alpha + 128) / 257)
          for channel in 0..<3 {
            let straight = alpha > 0 ? min(65_535, (Int(components[pixel + channel]) * 65_535 + alpha / 2) / alpha) : 0
            pixels[pixel + channel] = UInt8((straight + 128) / 257)
          }
        }
        let frameURL = scratch.appendingPathComponent(String(format: "frame-%06d.rgba", offset))
        try Data(pixels).write(to: frameURL, options: .withoutOverwriting)
      }
      let seconds = document.frameDuration(at: index)
      guard seconds <= 16_777.215 else { throw ImageProcessingError.invalid("WebP 无法保留超过 16777 秒的单帧时长。") }
      let milliseconds = indices.count == 1 ? 0 : max(1, Int((seconds * 1000).rounded()))
      guard timestamp <= Int(Int32.max) - milliseconds else { throw ImageProcessingError.tooLarge }
      timestamp += milliseconds
      durations.append(milliseconds)
      progress(Double(offset + 1) / Double(indices.count) * 0.5)
    }
    if !profile.isEmpty { try profile.write(to: scratch.appendingPathComponent("profile.icc"), options: .withoutOverwriting) }
    let header = "CHENGYING_WEBP_1\n\(width) \(height) \(indices.count) \(document.loopCount) \(profile.count)\n"
    let manifest = scratch.appendingPathComponent("manifest.txt")
    try (header + durations.map(String.init).joined(separator: "\n") + "\n").write(to: manifest, atomically: false, encoding: .ascii)
    let process = Process()
    process.executableURL = helper
    process.arguments = ["encode", manifest.path, output.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errorURL = scratch.appendingPathComponent("encoder.log")
    guard FileManager.default.createFile(atPath: errorURL.path, contents: nil),
          let errorFile = FileHandle(forWritingAtPath: errorURL.path) else { throw ImageProcessingError.exportFailed }
    defer { errorFile.closeFile() }
    process.standardError = errorFile
    try token.run(process)
    defer { token.detachProcess() }
    process.waitUntilExit()
    try token.check()
    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
      throw ImageProcessingError.exportFailed
    }
    progress(0.9)
  }

  private static func publish(_ temporary: URL, beside source: URL, fileExtension: String,
                              edited: Bool, token: ImageCancellationToken) throws -> URL {
    var stem = source.deletingPathExtension().lastPathComponent
    while stem.utf8.count > 150 { stem.removeLast() }
    let directory = source.deletingLastPathComponent()
    for index in 1...10_000 {
      try token.check()
      let suffix = index == 1 ? "" : "_\(index)"
      let operation = edited ? "edited" : "converted"
      let output = directory.appendingPathComponent("\(stem)_\(operation)\(suffix).\(fileExtension)")
      // link(2) is an atomic no-replace operation on the same volume, including
      // removable APFS/exFAT media where Foundation move may replace a target.
      if link(temporary.path, output.path) == 0 { return output }
      if errno == EEXIST { continue }
      if errno == ENOTSUP || errno == EPERM || errno == EOPNOTSUPP {
        // Darwin renamex_np provides exclusive atomic publication on exFAT, which
        // does not implement hard links. RENAME_EXCL never replaces another file.
        if renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
        if errno == EEXIST { continue }
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    throw ImageProcessingError.invalid("同目录下已有过多重名输出，请整理后重试。")
  }
}
