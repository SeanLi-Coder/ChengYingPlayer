import Foundation
import ImageIO
import PDFKit
import CoreServices
import UniformTypeIdentifiers

/// Reads source metadata only. Never creates a CGImage, thumbnail, or rendered PDF/SVG preview.
enum ImageMediaInfoReader {
  private static let imageOptions = [kCGImageSourceShouldCache: false,
                                     kCGImageSourceShouldCacheImmediately: false] as CFDictionary

  static func read(url: URL, token: MediaInfoCancellation) throws -> MediaInfoContent {
    try token.check()
    guard url.isFileURL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw MediaInfoError.invalidSource
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let prefix = try readBytes(handle, count: 1024)
    if prefix.starts(with: Data("%PDF-".utf8)) {
      return try readPDF(url: url, token: token)
    }
    if let source = CGImageSourceCreateWithURL(url as CFURL, imageOptions),
       CGImageSourceGetCount(source) > 0 {
      return try readRaster(url: url, source: source, token: token)
    }
    return try readSVG(url: url, token: token)
  }

  private static func row(_ key: String, _ fallback: String, _ value: String?) -> MediaInfoRow {
    MediaInfoRow(id: "image." + key, label: mediaInfoText("image." + key, fallback),
                 value: MediaInfoValue.text(value))
  }

  private static func readBytes(_ handle: FileHandle, count: Int) throws -> Data {
    if #available(macOS 10.15.4, *) { return try handle.read(upToCount: count) ?? Data() }
    return handle.readData(ofLength: count)
  }

  private static func number(_ value: Any?, allowZero: Bool = false) -> Double? {
    guard let value = value as? NSNumber else { return nil }
    let result = value.doubleValue
    return result.isFinite && (allowZero ? result >= 0 : result > 0) ? result : nil
  }

  private static func integer(_ value: Any?, allowZero: Bool = false) -> Int? {
    guard let value = number(value, allowZero: allowZero), value < Double(Int.max),
          value.rounded(.towardZero) == value else { return nil }
    return Int(value)
  }

  private static func decimal(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }

  private static func dimensions(_ width: Int?, _ height: Int?) -> String? {
    guard let width, let height else { return nil }
    return "\(width) × \(height)"
  }

  private static func readRaster(url: URL, source: CGImageSource,
                                 token: MediaInfoCancellation) throws -> MediaInfoContent {
    try token.check()
    let count = CGImageSourceGetCount(source)
    let primary = CGImageSourceGetPrimaryImageIndex(source)
    guard primary < count,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, imageOptions) as? [String: Any],
          let uti = CGImageSourceGetType(source) as String? else {
      throw MediaInfoError.readFailed(mediaInfoText("image.error.metadata", "The source image metadata could not be read."))
    }
    let global = CGImageSourceCopyProperties(source, imageOptions) as? [String: Any] ?? [:]
    let width = integer(properties[kCGImagePropertyPixelWidth as String])
    let height = integer(properties[kCGImagePropertyPixelHeight as String])
    let orientation = integer(properties[kCGImagePropertyOrientation as String])
    let displaySize: String?
    if let orientation, !(1...8).contains(orientation) {
      displaySize = nil
    } else if let orientation, (5...8).contains(orientation) {
      displaySize = dimensions(height, width)
    } else {
      displaySize = dimensions(width, height)
    }
    let raw: Bool
    if #available(macOS 11.0, *) {
      raw = UTType(uti)?.conforms(to: .rawImage) == true
    } else {
      raw = UTTypeConformsTo(uti as CFString, "public.camera-raw-image" as CFString)
    }
    let depth = integer(properties[kCGImagePropertyDepth as String]).map(String.init)
    let alpha = (properties[kCGImagePropertyHasAlpha as String] as? NSNumber).map {
      $0.boolValue ? mediaInfoText("image.yes", "Yes") : mediaInfoText("image.no", "No")
    }
    var rows = [
      row("format", "Detected format", formatName(uti)),
      row("uti", "Detected UTI", uti),
      row("representation", "Representation", raw
          ? mediaInfoText("image.raw", "RAW image (ImageIO representation)")
          : mediaInfoText("image.raster", "Raster image")),
      row("stored_size", "Stored dimensions (pixels)", dimensions(width, height)),
      row("display_size", "Oriented dimensions (pixels)", displaySize),
      row("orientation", "EXIF orientation", orientationName(orientation)),
      row("depth", "Bit depth per color sample", depth),
      row("alpha", "Alpha channel (ImageIO)", alpha),
      row("color_model", "Color model (ImageIO)", properties[kCGImagePropertyColorModel as String] as? String),
      row("profile", "ICC profile name (ImageIO)", properties[kCGImagePropertyProfileName as String] as? String),
      row("dpi_x", "Horizontal resolution (DPI)", number(properties[kCGImagePropertyDPIWidth as String]).map(decimal)),
      row("dpi_y", "Vertical resolution (DPI)", number(properties[kCGImagePropertyDPIHeight as String]).map(decimal)),
      row("image_count", "Image count", String(count)),
      row("primary_index", "Primary image (1-based)", String(primary + 1)),
    ]
    if let floating = properties[kCGImagePropertyIsFloat as String] as? NSNumber {
      rows.append(row("float", "Floating-point samples", floating.boolValue
                      ? mediaInfoText("image.yes", "Yes") : mediaInfoText("image.no", "No")))
    }
    var sections = [MediaInfoSection(id: "image", title: mediaInfoText("image.section", "Image"), rows: rows)]
    var notes = [mediaInfoText("image.metadata_note", "Color and pixel fields come from ImageIO primary-image metadata, not a rendered preview. A profile name alone does not verify embedded ICC profile bytes.")]
    if orientation == nil {
      notes.append(mediaInfoText("image.orientation_note", "No EXIF orientation was provided; oriented dimensions assume standard orientation."))
    }
    if raw {
      notes.append(mediaInfoText("image.raw_note", "RAW metadata describes the representation exposed by ImageIO; it does not certify sensor bit depth or the dimensions of every RAW plane."))
    }
    if count > 1, let animation = try animationSection(url: url, source: source, uti: uti,
                                                       count: count, global: global, properties: properties,
                                                       token: token) {
      sections.append(animation)
      notes.append(mediaInfoText("image.animation_note", "Duration is one sequence pass, calculated only from explicit, unclamped frame delays. Player timing policies and repeated loops are not included."))
    }
    let camera = cameraRows(properties)
    if !camera.isEmpty {
      sections.append(MediaInfoSection(id: "image.camera", title: mediaInfoText("image.camera_section", "Camera"), rows: camera))
    }
    try token.check()
    return MediaInfoContent(sections: sections, notes: notes)
  }

  private static func formatName(_ uti: String) -> String {
    let names = ["public.jpeg": "JPEG", "public.png": "PNG", "com.compuserve.gif": "GIF",
                 "public.tiff": "TIFF", "org.webmproject.webp": "WebP", "public.heic": "HEIC",
                 "public.heif": "HEIF", "public.heics": "HEIC sequence", "public.heif-standard": "HEIF",
                 "public.avif": "AVIF", "public.avis": "AVIF sequence", "public.jpeg-xl": "JPEG XL",
                 "com.microsoft.bmp": "BMP", "com.microsoft.ico": "ICO", "com.apple.icns": "ICNS",
                 "com.adobe.photoshop-image": "PSD", "com.ilm.openexr-image": "OpenEXR",
                 "public.jpeg-2000": "JPEG 2000", "com.truevision.tga-image": "TGA"]
    return names[uti] ?? uti
  }

  private static func orientationName(_ orientation: Int?) -> String? {
    guard let orientation else { return nil }
    let names = ["Top-left", "Top-right (mirrored)", "Bottom-right (180°)", "Bottom-left (mirrored)",
                 "Left-top (mirrored)", "Right-top (90° clockwise)", "Right-bottom (mirrored)", "Left-bottom (90° counterclockwise)"]
    guard (1...8).contains(orientation) else { return String(orientation) }
    return "\(orientation) · " + mediaInfoText("image.orientation_\(orientation)", names[orientation - 1])
  }

  private static func animationSection(url: URL, source: CGImageSource, uti: String, count: Int,
                                       global: [String: Any], properties: [String: Any],
                                       token: MediaInfoCancellation) throws -> MediaInfoSection? {
    let keys = ["com.compuserve.gif": "{GIF}", "public.png": "{PNG}", "org.webmproject.webp": "{WebP}",
                "public.heics": "{HEICS}", "public.heif-standard": "{HEICS}", "public.avis": "{AVIS}"]
    guard let key = keys[uti] else { return nil }
    let animation = global[key] as? [String: Any] ?? [:]
    let first = properties[key] as? [String: Any] ?? [:]
    guard uti == "com.compuserve.gif" || uti == "public.png" || animation["LoopCount"] != nil ||
          animation["FrameInfo"] != nil || first["DelayTime"] != nil || first["UnclampedDelayTime"] != nil else { return nil }
    var duration: Double?
    var totalPlays: Int?
    if uti == "com.compuserve.gif" {
      if let metadata = try GIFMetadata.read(url: url, token: token), metadata.delays.count == count {
        totalPlays = metadata.totalPlays
        if metadata.delays.allSatisfy({ $0 != nil }) { duration = metadata.delays.compactMap { $0 }.reduce(0, +) }
      }
    } else {
      totalPlays = integer(animation["LoopCount"], allowZero: true)
      let frames = animation["FrameInfo"] as? [[String: Any]] ?? []
      if count <= 100_000 {
        var sum = 0.0
        var complete = true
        for index in 0..<count {
          try token.check()
          let frame = CGImageSourceCopyPropertiesAtIndex(source, index, imageOptions) as? [String: Any] ?? [:]
          var timing = frames.indices.contains(index) ? frames[index] : [:]
          timing.merge(frame[key] as? [String: Any] ?? [:]) { _, local in local }
          guard let delay = number(timing["UnclampedDelayTime"], allowZero: true) else { complete = false; break }
          sum += delay
        }
        if complete && sum.isFinite { duration = sum }
      }
    }
    let loops = totalPlays.map { $0 == 0 ? mediaInfoText("image.infinite", "Infinite") : String($0) }
    return MediaInfoSection(id: "image.animation", title: mediaInfoText("image.animation_section", "Animation"), rows: [
      row("frame_count", "Frame count", String(count)),
      row("duration", "One-pass duration (seconds)", duration.map(decimal)),
      row("plays", "Total plays (container metadata)", loops),
    ])
  }

  private static func cameraRows(_ properties: [String: Any]) -> [MediaInfoRow] {
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    var rows: [MediaInfoRow] = []
    // Deliberately allowlist useful fields; never expose GPS, serial numbers, or owner names.
    for (id, label, value) in [
      ("camera_make", "Camera maker", tiff[kCGImagePropertyTIFFMake as String]),
      ("camera_model", "Camera model", tiff[kCGImagePropertyTIFFModel as String]),
      ("lens_make", "Lens maker", exif[kCGImagePropertyExifLensMake as String]),
      ("lens_model", "Lens model", exif[kCGImagePropertyExifLensModel as String]),
      ("captured", "Capture date (EXIF, timezone may be absent)", exif[kCGImagePropertyExifDateTimeOriginal as String]),
    ] {
      if let text = value as? String, !text.isEmpty { rows.append(row(id, label, text)) }
    }
    for (id, label, value) in [
      ("exposure", "Exposure time (seconds)", exif[kCGImagePropertyExifExposureTime as String]),
      ("aperture", "Aperture (f-number)", exif[kCGImagePropertyExifFNumber as String]),
      ("focal_length", "Focal length (mm)", exif[kCGImagePropertyExifFocalLength as String]),
    ] {
      if let number = number(value) { rows.append(row(id, label, decimal(number))) }
    }
    if let values = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] {
      let iso = values.compactMap { integer($0) }.map(String.init)
      if !iso.isEmpty { rows.append(row("iso", "ISO sensitivity", iso.joined(separator: ", "))) }
    }
    return rows
  }

  private static func readPDF(url: URL, token: MediaInfoCancellation) throws -> MediaInfoContent {
    try token.check()
    guard let document = PDFDocument(url: url), !document.isLocked,
          document.pageCount > 0, let page = document.page(at: 0) else {
      throw MediaInfoError.readFailed(mediaInfoText("image.error.pdf", "The PDF metadata could not be read, or the PDF requires a password."))
    }
    func box(_ box: PDFDisplayBox) -> String? {
      let bounds = page.bounds(for: box)
      guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
      return "\(decimal(Double(bounds.width))) × \(decimal(Double(bounds.height)))"
    }
    let rows = [row("format", "Detected format", "PDF"), row("uti", "Detected UTI", "com.adobe.pdf"),
                row("representation", "Representation", mediaInfoText("image.pdf_representation", "Document; pages may contain vector and raster content")),
                row("page_count", "Page count", String(document.pageCount)),
                row("pdf_media_box", "First page media box (pt)", box(.mediaBox)),
                row("pdf_crop_box", "First page crop box (pt)", box(.cropBox)),
                row("pdf_rotation", "First page rotation (degrees)", String(page.rotation))]
    try token.check()
    return MediaInfoContent(sections: [MediaInfoSection(id: "image", title: mediaInfoText("image.section", "Image"), rows: rows)], notes: [
      mediaInfoText("image.pdf_note", "PDF boxes are measured in page-space points, not pixels. The 144 DPI viewer preview is a rendering choice, not the source resolution. A PDF has no single intrinsic raster bit depth, alpha channel, or ICC profile."),
    ])
  }

  private static func readSVG(url: URL, token: MediaInfoCancellation) throws -> MediaInfoContent {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024 else {
      throw MediaInfoError.readFailed(mediaInfoText("image.error.svg_size", "SVG metadata inspection is limited to 10 MB files."))
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try readBytes(handle, count: 10 * 1024 * 1024 + 1)
    guard data.count <= 10 * 1024 * 1024 else {
      throw MediaInfoError.readFailed(mediaInfoText("image.error.svg_size", "SVG metadata inspection is limited to 10 MB files."))
    }
    try token.check()
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
          text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
          text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
      throw MediaInfoError.readFailed(mediaInfoText("image.error.svg_safety", "SVG metadata must use UTF-8 without DTD or entity declarations. External resources are never loaded."))
    }
    let delegate = SVGMetadata(token: token)
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    guard parser.parse(), delegate.validRoot else {
      try token.check()
      throw MediaInfoError.readFailed(mediaInfoText("image.error.unsupported", "The file is not a supported image, PDF, or safe SVG document."))
    }
    let representation = delegate.hasImages
      ? mediaInfoText("image.svg_mixed", "SVG vector document with image references")
      : mediaInfoText("image.svg_vector", "SVG vector document")
    let rows = [row("format", "Detected format", "SVG"), row("uti", "Detected UTI", "public.svg-image"),
                row("representation", "Representation", representation),
                row("svg_width", "Declared width (original units)", delegate.attributes["width"]),
                row("svg_height", "Declared height (original units)", delegate.attributes["height"]),
                row("svg_viewbox", "Declared viewBox (user units)", delegate.attributes["viewBox"])]
    try token.check()
    return MediaInfoContent(sections: [MediaInfoSection(id: "image", title: mediaInfoText("image.section", "Image"), rows: rows)], notes: [
      mediaInfoText("image.svg_note", "SVG declarations are not raster pixel dimensions. No SVG was rendered, no script was executed, and no referenced image, font, stylesheet, or external resource was loaded. Raster bit depth, alpha, and ICC profile are not inferred from the viewer preview."),
    ])
  }

  private final class SVGMetadata: NSObject, XMLParserDelegate {
    let token: MediaInfoCancellation
    var validRoot = false
    var hasImages = false
    var attributes: [String: String] = [:]
    private var count = 0
    private var depth = 0

    init(token: MediaInfoCancellation) { self.token = token }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
      count += 1
      depth += 1
      guard count <= 100_000, depth <= 128, !token.isCancelled else { parser.abortParsing(); return }
      if count == 1 {
        validRoot = name == "svg" && (namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://www.w3.org/2000/svg")
        guard validRoot else { parser.abortParsing(); return }
        self.attributes = attributes.filter { ["width", "height", "viewBox"].contains($0.key) }
      }
      if name == "image" || name == "foreignObject" { hasImages = true }
    }

    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }

    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? {
      parser.abortParsing()
      return nil
    }
  }

  private struct GIFMetadata {
    let totalPlays: Int
    let delays: [Double?]

    /// Read block headers, skipping compressed image bytes. ImageIO may synthesize loop/delay defaults.
    static func read(url: URL, token: MediaInfoCancellation) throws -> GIFMetadata? {
      let reader = try GIFBytes(url: url)
      guard let header = try reader.take(13), String(bytes: header.prefix(6), encoding: .ascii)?.hasPrefix("GIF8") == true else { return nil }
      if header[10] & 0x80 != 0, try !reader.skip(3 * (1 << (Int(header[10] & 7) + 1))) { return nil }
      var plays = 1
      var delay: Double?
      var delays: [Double?] = []
      var blocks = 0
      while let marker = try reader.byte() {
        try token.check()
        blocks += 1
        guard blocks <= 2_000_000, delays.count <= 100_000 else { return nil }
        if marker == 0x3b { return GIFMetadata(totalPlays: plays, delays: delays) }
        if marker == 0x2c {
          guard let descriptor = try reader.take(9) else { return nil }
          if descriptor[8] & 0x80 != 0, try !reader.skip(3 * (1 << (Int(descriptor[8] & 7) + 1))) { return nil }
          guard try reader.byte() != nil else { return nil }
          delays.append(delay)
          delay = nil
        } else if marker == 0x21 {
          guard let label = try reader.byte() else { return nil }
          if label == 0xf9 {
            guard try reader.byte() == 4, let control = try reader.take(4), try reader.byte() == 0 else { return nil }
            delay = Double(Int(control[1]) | Int(control[2]) << 8) / 100
            continue
          }
          if label == 0xff {
            guard let size = try reader.byte(), let app = try reader.take(Int(size)) else { return nil }
            if let name = String(bytes: app, encoding: .ascii), ["NETSCAPE2.0", "ANIMEXTS1.0"].contains(name) {
              guard try reader.byte() == 3, let loop = try reader.take(3), loop[0] == 1 else { return nil }
              let repeats = Int(loop[1]) | Int(loop[2]) << 8
              plays = repeats == 0 ? 0 : repeats + 1
            }
          }
          if label == 0x01 { delay = nil }
        } else { return nil }
        while let size = try reader.byte(), size != 0 {
          blocks += 1
          if blocks % 1024 == 0 { try token.check() }
          guard blocks <= 2_000_000, try reader.skip(Int(size)) else { return nil }
        }
      }
      return nil
    }
  }

  /// Bounded buffering prevents large animated files from being copied into memory.
  private final class GIFBytes {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    func byte() throws -> UInt8? {
      if offset == buffer.count {
        buffer = try ImageMediaInfoReader.readBytes(handle, count: 65_536)
        offset = 0
      }
      guard offset < buffer.count else { return nil }
      defer { offset += 1 }
      return buffer[offset]
    }

    func take(_ count: Int) throws -> [UInt8]? {
      var result: [UInt8] = []
      for _ in 0..<count {
        guard let value = try byte() else { return nil }
        result.append(value)
      }
      return result
    }

    func skip(_ count: Int) throws -> Bool {
      var remaining = count
      while remaining > 0 {
        if offset == buffer.count {
          guard try byte() != nil else { return false }
          remaining -= 1
          continue
        }
        let available = min(remaining, buffer.count - offset)
        offset += available
        remaining -= available
      }
      return true
    }
  }
}
