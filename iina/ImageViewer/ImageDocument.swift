import Cocoa
import CoreImage
import ImageIO
import PDFKit

/// Confined to the caller's serial decoding queue; decoded frames are not retained here.
final class ImageDocument {
  let url: URL
  let width: Int
  let height: Int
  let frameCount: Int
  let isAnimated: Bool
  let loopCount: Int
  let formatName: String
  let bitDepth: Int
  let hasAlpha: Bool
  private let source: CGImageSource?
  private let pdf: PDFDocument?
  private let vector: CGImage?
  private let orientation: Int
  private let animationDictionary: String?
  private let imageOptions = [kCGImageSourceShouldCache: false] as CFDictionary

  init(url: URL) throws {
    guard url.isFileURL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw ImageProcessingError.invalid("请选择本地图片文件。")
    }
    self.url = url
    let ext = url.pathExtension.lowercased()
    if ext == "svg" {
      let image = try Self.readSVG(url)
      source = nil; pdf = nil; vector = image; orientation = 1; animationDictionary = nil
      width = image.width; height = image.height; frameCount = 1
      isAnimated = false; loopCount = 0; formatName = "SVG · 栅格化预览"
      bitDepth = image.bitsPerComponent; hasAlpha = true
      return
    }
    if ext == "pdf" {
      guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
            document.pageCount <= 100_000, let page = document.page(at: 0) else {
        throw ImageProcessingError.invalid("PDF 无法读取，或需要密码。")
      }
      let size = try Self.pdfSize(page)
      source = nil; pdf = document; vector = nil; orientation = 1; animationDictionary = nil
      width = size.0; height = size.1; frameCount = document.pageCount
      isAnimated = false; loopCount = 0; formatName = "PDF · 144 dpi 栅格化预览"
      bitDepth = 8; hasAlpha = true
      return
    }
    guard let input = CGImageSourceCreateWithURL(url as CFURL, imageOptions),
          CGImageSourceGetCount(input) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any],
          let rawWidth = Self.integer(properties[kCGImagePropertyPixelWidth as String]),
          let rawHeight = Self.integer(properties[kCGImagePropertyPixelHeight as String]) else {
      throw ImageProcessingError.unsupported
    }
    bitDepth = Self.integer(properties[kCGImagePropertyDepth as String]) ?? 8
    try Self.validateDimensions(rawWidth, rawHeight, depth: bitDepth)
    let count = CGImageSourceGetCount(input)
    guard count <= 100_000 else { throw ImageProcessingError.tooLarge }
    orientation = Self.integer(properties[kCGImagePropertyOrientation as String]) ?? 1
    width = (5...8).contains(orientation) ? rawHeight : rawWidth
    height = (5...8).contains(orientation) ? rawWidth : rawHeight
    source = input; pdf = nil; vector = nil; frameCount = count
    hasAlpha = (properties[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false
    let type = CGImageSourceGetType(input) as String? ?? ext
    switch type {
    case "com.compuserve.gif": animationDictionary = "{GIF}"
    case "public.png": animationDictionary = "{PNG}"
    case "org.webmproject.webp": animationDictionary = "{WebP}"
    case "public.heics", "public.heif-standard": animationDictionary = "{HEICS}"
    case "public.avis": animationDictionary = "{AVIS}"
    default: animationDictionary = nil
    }
    let global = CGImageSourceCopyProperties(input, nil) as? [String: Any] ?? [:]
    let frameAnimation = animationDictionary.flatMap { properties[$0] as? [String: Any] } ?? [:]
    let globalAnimation = animationDictionary.flatMap { global[$0] as? [String: Any] } ?? [:]
    isAnimated = count > 1 && animationDictionary != nil &&
      (frameAnimation["DelayTime"] != nil || frameAnimation["UnclampedDelayTime"] != nil ||
       globalAnimation["LoopCount"] != nil || globalAnimation["FrameInfo"] != nil)
    let storedLoops = Self.integer(globalAnimation["LoopCount"])
    // GIF stores repetitions after the first play; APNG/WebP store total plays.
    if type == "com.compuserve.gif" {
      // ImageIO synthesizes LoopCount=1 even when NETSCAPE metadata is absent.
      // Inspect the container extension instead of turning a play-once GIF into two plays.
      loopCount = Self.gifTotalPlays(url) ?? 1
    } else {
      loopCount = storedLoops ?? 0
    }
    formatName = ext.uppercased() + (ext == "psd" ? " · 合成图" : "")
  }

  func frameDuration(at index: Int) -> TimeInterval {
    guard isAnimated, let source, let key = animationDictionary, (0..<frameCount).contains(index) else { return 0.1 }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
    let global = CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
    let frames = (global[key] as? [String: Any])?["FrameInfo"] as? [[String: Any]] ?? []
    var animation = frames.indices.contains(index) ? frames[index] : [:]
    animation.merge(properties[key] as? [String: Any] ?? [:]) { _, frameValue in frameValue }
    let delay = (animation["UnclampedDelayTime"] as? NSNumber)?.doubleValue ??
      (animation["DelayTime"] as? NSNumber)?.doubleValue ?? 0.1
    return delay.isFinite && delay > 0 ? max(0.001, delay) : 0.1
  }

  func frame(at index: Int) throws -> CGImage {
    guard (0..<frameCount).contains(index) else { throw ImageProcessingError.invalid("图片帧号无效。") }
    if let vector { return vector }
    if let pdf, let page = pdf.page(at: index) { return try Self.renderPDF(page) }
    guard let source else { throw ImageProcessingError.unsupported }
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
       let w = Self.integer(properties[kCGImagePropertyPixelWidth as String]),
       let h = Self.integer(properties[kCGImagePropertyPixelHeight as String]) {
      try Self.validateDimensions(w, h, depth: bitDepth)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, index, imageOptions) else {
      throw ImageProcessingError.unsupported
    }
    try Self.validateDimensions(image.width, image.height, depth: image.bitsPerComponent)
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
    let direction = Self.integer(properties[kCGImagePropertyOrientation as String]) ?? orientation
    guard (2...8).contains(direction) else { return image }
    // ImageIO does not apply EXIF orientation to full-size image decoding. Core Image
    // reorients at source resolution without the 8-bit thumbnail conversion path.
    let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(direction))
    let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.cacheIntermediates: false])
    let format: CIFormat = image.bitsPerComponent > 16 || image.bitmapInfo.contains(.floatComponents)
      ? .RGBAf : (image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8)
    guard let result = context.createCGImage(oriented, from: oriented.extent, format: format, colorSpace: space) else {
      throw ImageProcessingError.unsupported
    }
    return result
  }

  static func validateDimensions(_ width: Int, _ height: Int, depth: Int = 8) throws {
    guard width > 0, height > 0, width <= 131_072, height <= 131_072 else {
      throw ImageProcessingError.tooLarge
    }
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    let bytesPerPixel = depth > 16 ? 16 : (depth > 8 ? 8 : 4)
    let budget = min(UInt64(1_073_741_824), ProcessInfo.processInfo.physicalMemory / 8)
    guard !overflow, pixels <= 256_000_000, UInt64(pixels) <= budget / UInt64(bytesPerPixel) else {
      throw ImageProcessingError.tooLarge
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, number.doubleValue.isFinite,
          number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
    return number.intValue
  }

  private static func gifTotalPlays(_ url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 13 else { return nil }
    var offset = 13
    if data[10] & 0x80 != 0 { offset += 3 * (1 << (Int(data[10] & 7) + 1)) }
    while offset < data.count {
      let marker = data[offset]; offset += 1
      if marker == 0x3b { return 1 }
      if marker == 0x2c {
        guard offset <= data.count - 9 else { return nil }
        let packed = data[offset + 8]; offset += 9
        if packed & 0x80 != 0 { offset += 3 * (1 << (Int(packed & 7) + 1)) }
        offset += 1 // LZW minimum code size.
      } else if marker == 0x21 {
        guard offset < data.count else { return nil }
        let label = data[offset]; offset += 1
        if label == 0xff, offset <= data.count - 12, data[offset] == 11 {
          let application = String(data: data[(offset + 1)..<(offset + 12)], encoding: .ascii)
          if application == "NETSCAPE2.0" || application == "ANIMEXTS1.0" {
            let block = offset + 12
            guard block <= data.count - 4, data[block] >= 3, data[block + 1] == 1 else { return nil }
            let repetitions = Int(data[block + 2]) | Int(data[block + 3]) << 8
            return repetitions == 0 ? 0 : repetitions + 1
          }
        }
      } else { return nil }
      // Skip extension or compressed image subblocks without decoding/copying them.
      while offset < data.count {
        let count = Int(data[offset]); offset += 1
        guard count <= data.count - offset else { return nil }
        offset += count
        if count == 0 { break }
      }
    }
    return nil
  }

  private static func pdfSize(_ page: PDFPage) throws -> (Int, Int) {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
          bounds.width <= 65_536, bounds.height <= 65_536 else { throw ImageProcessingError.tooLarge }
    let size = (Int(ceil(bounds.width * 2)), Int(ceil(bounds.height * 2)))
    try validateDimensions(size.0, size.1)
    return size
  }

  private static func renderPDF(_ page: PDFPage) throws -> CGImage {
    let size = try pdfSize(page)
    let bounds = page.bounds(for: .mediaBox)
    guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw ImageProcessingError.tooLarge
    }
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else { throw ImageProcessingError.unsupported }
    return image
  }

  private static func readSVG(_ url: URL) throws -> CGImage {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10_000_000 else {
      throw ImageProcessingError.tooLarge
    }
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
          !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
          !text.localizedCaseInsensitiveContains("<!ENTITY") else {
      throw ImageProcessingError.invalid("为保护本地文件，SVG 不允许 DTD、实体或外部资源。请使用纯矢量 SVG。")
    }
    let validator = LocalSVGValidator()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = validator
    guard parser.parse(), validator.isSafe, validator.hasRoot else {
      throw ImageProcessingError.invalid("SVG 包含脚本、外部资源或不支持的交互内容，已拒绝载入。")
    }
    guard let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
          image.size.width > 0, image.size.height > 0, image.size.width <= 131_072, image.size.height <= 131_072 else {
      throw ImageProcessingError.unsupported
    }
    try validateDimensions(Int(ceil(image.size.width)), Int(ceil(image.size.height)))
    let width = Int(ceil(image.size.width)), height = Int(ceil(image.size.height))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageProcessingError.tooLarge }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
               operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard let result = context.makeImage() else {
      throw ImageProcessingError.unsupported
    }
    return result
  }
}

/// SVG is rendered by AppKit, never an HTML/WebKit surface. Restrict it to local vectors.
private final class LocalSVGValidator: NSObject, XMLParserDelegate {
  var isSafe = true
  var hasRoot = false
  private var elements = 0
  private var depth = 0
  private let allowed: Set<String> = ["svg", "g", "defs", "path", "rect", "circle", "ellipse", "line",
    "polyline", "polygon", "text", "tspan", "textpath", "title", "desc", "metadata", "clippath",
    "mask", "lineargradient", "radialgradient", "stop", "pattern", "use", "symbol", "marker"]

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?, attributes attributeDict: [String: String]) {
    let name = elementName.lowercased()
    elements += 1
    depth += 1
    guard elements <= 100_000, depth <= 128 else { isSafe = false; parser.abortParsing(); return }
    if !hasRoot { hasRoot = name == "svg" }
    guard allowed.contains(name) else { isSafe = false; parser.abortParsing(); return }
    for (key, value) in attributeDict {
      let key = key.lowercased()
      let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if key.hasPrefix("on") || key == "xml:base" || value.contains("@") || value.contains("\\") ||
          ((key == "href" || key.hasSuffix(":href")) && !value.hasPrefix("#")) {
        isSafe = false
      }
      if value.contains("url(") {
        let pattern = #"url\(\s*['\"]?#[a-z0-9_.:-]+['\"]?\s*\)"#
        let stripped = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        if stripped.contains("url(") { isSafe = false }
      }
    }
    if !isSafe { parser.abortParsing() }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    depth -= 1
  }

  func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
    isSafe = false
    parser.abortParsing()
  }
}
