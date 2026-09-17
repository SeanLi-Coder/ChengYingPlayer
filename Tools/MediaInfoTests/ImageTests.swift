import AppKit
import ImageIO
import PDFKit

@main
enum ImageMediaInfoTests {
  static var checks = 0

  static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    checks += 1
    if try !condition() { fatalError("FAIL: " + message) }
  }

  static func rejects(_ message: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); fatalError("FAIL: " + message) } catch { }
  }

  static func value(_ content: MediaInfoContent, _ id: String) -> String? {
    content.sections.flatMap(\.rows).first { $0.id == "image." + id }?.value
  }

  static func raster(width: Int = 32, height: Int = 20, depth: Int = 8) -> CGImage {
    let bitmap: CGBitmapInfo = depth == 16 ? [.byteOrder16Little] : []
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: depth,
                            bytesPerRow: width * 4 * (depth / 8), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: bitmap.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  static func write(_ url: URL, type: String = "public.png", images: [CGImage],
                    properties: [String: Any] = [:], global: [String: Any] = [:]) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
    CGImageDestinationSetProperties(destination, global as CFDictionary)
    for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
    check(CGImageDestinationFinalize(destination), "Image fixture is written: " + url.lastPathComponent)
  }

  static func gif(delays: [Int?], repeats: Int? = nil, padding: Int = 0) -> Data {
    var data = Data("GIF89a".utf8)
    data.append(contentsOf: [1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255])
    if let repeats {
      data.append(contentsOf: [0x21, 0xff, 11])
      data.append(Data("NETSCAPE2.0".utf8))
      data.append(contentsOf: [3, 1, UInt8(repeats & 255), UInt8(repeats >> 8), 0])
    }
    if padding > 0 {
      data.append(contentsOf: [0x21, 0xfe])
      var remaining = padding
      while remaining > 0 {
        let size = min(255, remaining)
        data.append(UInt8(size))
        data.append(Data(repeating: 65, count: size))
        remaining -= size
      }
      data.append(0)
    }
    for delay in delays {
      if let delay { data.append(contentsOf: [0x21, 0xf9, 4, 0, UInt8(delay & 255), UInt8(delay >> 8), 0, 0]) }
      data.append(contentsOf: [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0])
    }
    data.append(0x3b)
    return data
  }

  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let token = MediaInfoCancellation()
    func read(_ url: URL) throws -> MediaInfoContent {
      let identity = try MediaInfoFileIdentity(url: url)
      let bytes = try Data(contentsOf: url)
      let result = try ImageMediaInfoReader.read(url: url, token: token)
      try check(try MediaInfoFileIdentity(url: url) == identity, "Metadata reading does not modify source identity")
      try check(try Data(contentsOf: url) == bytes, "Metadata reading does not modify source bytes")
      let ids = result.sections.flatMap(\.rows).map(\.id)
      check(Set(ids).count == ids.count, "Metadata row IDs are unique")
      return result
    }

    let image = raster()
    let misnamed = directory.appendingPathComponent("actual-png.jpg")
    write(misnamed, images: [image])
    let png = try read(misnamed)
    check(value(png, "format") == "PNG", "Detected format does not trust filename extension")
    check(value(png, "uti") == "public.png", "Actual source UTI is retained")
    check(value(png, "stored_size") == "32 × 20", "Stored pixel dimensions are exact")
    check(value(png, "display_size") == "32 × 20", "Missing orientation leaves display dimensions unchanged")
    check(value(png, "depth") == "8", "Depth is per sample, not 32-bit RGBA")
    check(value(png, "alpha") == "Yes", "PNG alpha is reported from metadata")
    check(value(png, "image_count") == "1", "Single image count is reported")
    check(png.notes.contains { $0.contains("ImageIO") && $0.contains("ICC") }, "ICC metadata provenance is explicit")
    let source = CGImageSourceCreateWithURL(misnamed as CFURL, nil)!
    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
    for (key, id) in [(kCGImagePropertyDPIWidth as String, "dpi_x"), (kCGImagePropertyDPIHeight as String, "dpi_y")] {
      if sourceProperties[key] == nil { check(value(png, id) == MediaInfoValue.unknown, "Missing DPI is not synthesized") }
    }

    let high = directory.appendingPathComponent("high-depth.tiff")
    write(high, type: "public.tiff", images: [raster(depth: 16)])
    try check(value(try read(high), "depth") == "16", "16-bit source is not confused with an 8-bit preview")

    for orientation in 1...8 {
      let url = directory.appendingPathComponent("orientation-\(orientation).tiff")
      write(url, type: "public.tiff", images: [image], properties: [
        kCGImagePropertyOrientation as String: orientation,
        kCGImagePropertyDPIWidth as String: 300,
        kCGImagePropertyDPIHeight as String: 150,
      ])
      let content = try read(url)
      check(value(content, "stored_size") == "32 × 20", "EXIF orientation does not overwrite stored dimensions")
      check(value(content, "display_size") == ((5...8).contains(orientation) ? "20 × 32" : "32 × 20"),
            "EXIF orientation \(orientation) swaps display axes only when required")
      check(value(content, "orientation")?.hasPrefix("\(orientation) ·") == true, "EXIF mirrored orientation is retained")
      check(value(content, "dpi_x") == "300" && value(content, "dpi_y") == "150", "Unequal DPI axes are retained")
    }

    let cameraURL = directory.appendingPathComponent("camera.jpg")
    write(cameraURL, type: "public.jpeg", images: [image], properties: [
      kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Test Maker",
                                                kCGImagePropertyTIFFModel as String: "Test Camera"],
      kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 0.008,
                                                kCGImagePropertyExifFNumber as String: 2.8,
                                                kCGImagePropertyExifFocalLength as String: 50,
                                                kCGImagePropertyExifISOSpeedRatings as String: [400],
                                                kCGImagePropertyExifLensModel as String: "Test Lens",
                                                kCGImagePropertyExifBodySerialNumber as String: "SECRET_BODY_SERIAL",
                                                kCGImagePropertyExifLensSerialNumber as String: "SECRET_LENS_SERIAL"],
      kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 37.3349,
                                               kCGImagePropertyGPSLatitudeRef as String: "N"],
    ])
    let camera = try read(cameraURL)
    check(value(camera, "camera_model") == "Test Camera", "Camera model is exposed")
    check(value(camera, "exposure") == "0.008", "Exposure time is accurate")
    check(value(camera, "aperture") == "2.8", "Aperture is accurate")
    check(value(camera, "iso") == "400", "ISO is accurate")
    let cameraText = MediaInfoSnapshot(url: cameraURL, kind: .image, content: camera).plainText
    check(!cameraText.contains("SECRET_") && !cameraText.contains("37.3349") && !cameraText.contains("GPS"),
          "GPS and device serial numbers are not exposed in copied metadata")

    let multi = directory.appendingPathComponent("multiple.tiff")
    write(multi, type: "public.tiff", images: [image, raster(width: 17, height: 11)])
    let multiple = try read(multi)
    check(value(multiple, "image_count") == "2", "Multi-image TIFF count is retained")
    check(!multiple.sections.contains { $0.id == "image.animation" }, "Multi-image TIFF is not mislabeled as an animation")

    for (name, delays, repeats, duration, plays, padding) in [
      ("once", [1, 25] as [Int?], nil as Int?, "0.26", "1", 0),
      ("repeat", [1, 25], 2, "0.26", "3", 0),
      ("infinite", [1, 25], 0, "0.26", "Infinite", 0),
      ("zero-delay", [0, 20], nil, "0.2", "1", 0),
      ("missing-delay", [nil, 20], nil, MediaInfoValue.unknown, "1", 0),
      ("buffer-boundary", [1, 25], 1, "0.26", "2", 131_077),
    ] {
      let url = directory.appendingPathComponent(name + ".gif")
      try gif(delays: delays, repeats: repeats, padding: padding).write(to: url)
      let result = try read(url)
      check(value(result, "frame_count") == "2", "GIF frame count is correct: " + name)
      check(value(result, "duration") == duration, "GIF uses explicit timing without fallback: " + name)
      check(value(result, "plays") == plays, "GIF repeat extension is interpreted correctly: " + name)
    }

    let apngURL = directory.appendingPathComponent("animation.png")
    let apng = CGImageDestinationCreateWithURL(apngURL as CFURL, "public.png" as CFString, 2, nil)!
    CGImageDestinationSetProperties(apng, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 2]] as CFDictionary)
    for delay in [0.04, 0.23] {
      CGImageDestinationAddImage(apng, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGUnclampedDelayTime: delay]] as CFDictionary)
    }
    check(CGImageDestinationFinalize(apng), "APNG fixture is written")
    let animatedPNG = try read(apngURL)
    check(value(animatedPNG, "duration") == "0.27", "APNG uses unclamped frame times")
    check(value(animatedPNG, "plays") == "2", "APNG total plays are not GIF repetitions")

    let pdfURL = directory.appendingPathComponent("document.data")
    let document = PDFDocument()
    for index in 0..<2 {
      let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 32, height: 20)))!
      page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
      page.setBounds(CGRect(x: 0, y: 0, width: 250, height: 350), for: .cropBox)
      page.rotation = 90
      document.insert(page, at: index)
    }
    check(document.write(to: pdfURL), "PDF fixture is written")
    let pdf = try read(pdfURL)
    check(value(pdf, "format") == "PDF", "PDF format is detected from file contents")
    check(value(pdf, "page_count") == "2", "PDF page count is reported")
    check(value(pdf, "pdf_media_box") == "300 × 400", "PDF page dimensions remain page-space points")
    check(value(pdf, "pdf_crop_box") == "250 × 350", "PDF crop box is distinct from media box")
    check(value(pdf, "pdf_rotation") == "90", "PDF rotation is retained separately from page-space box")
    check(value(pdf, "depth") == nil && value(pdf, "stored_size") == nil && value(pdf, "alpha") == nil,
          "PDF does not invent preview raster properties")
    check(pdf.notes.contains { $0.contains("144 DPI") && $0.contains("not") }, "PDF preview/source distinction is explicit")

    let svgURL = directory.appendingPathComponent("vector.data")
    try Data("<svg xmlns='http://www.w3.org/2000/svg' width='10cm' height='100%' viewBox='0 0 320 240'><rect width='10' height='10'/></svg>".utf8).write(to: svgURL)
    let svg = try read(svgURL)
    check(value(svg, "format") == "SVG", "SVG format is detected from XML, not its extension")
    check(value(svg, "svg_width") == "10cm" && value(svg, "svg_height") == "100%", "SVG declared units are not changed to pixels")
    check(value(svg, "svg_viewbox") == "0 0 320 240", "SVG viewBox is retained in user units")
    check(value(svg, "stored_size") == nil && value(svg, "depth") == nil, "SVG does not expose preview raster parameters")
    check(value(svg, "representation") == "SVG vector document", "SVG vector representation is explicit")
    let referencedURL = directory.appendingPathComponent("referenced.svg")
    try Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1 1'><image href='http://127.0.0.1:1/not-loaded.png'/><script>throw new Error('must not execute');</script></svg>".utf8).write(to: referencedURL)
    let referenced = try read(referencedURL)
    check(value(referenced, "representation") == "SVG vector document with image references", "Image references are distinguished from pure vector declarations")
    check(referenced.notes.contains { $0.contains("no script") && $0.contains("external resource") }, "SVG safety limitations are disclosed")
    check(value(referenced, "svg_width") == MediaInfoValue.unknown, "Missing SVG width remains unknown")
    for (name, xml) in [
      ("entity", "<!DOCTYPE svg [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><svg xmlns='http://www.w3.org/2000/svg'>&secret;</svg>"),
      ("external-dtd", "<!DOCTYPE svg SYSTEM 'http://127.0.0.1:1/never.dtd'><svg/>"),
      ("wrong-root", "<html><svg/></html>"),
      ("wrong-namespace", "<svg xmlns='http://example.invalid/not-svg'/>"),
      ("broken", "<svg><g></svg>"),
      ("too-deep", "<svg>" + String(repeating: "<g>", count: 129) + String(repeating: "</g>", count: 129) + "</svg>"),
    ] {
      let url = directory.appendingPathComponent(name + ".svg")
      try Data(xml.utf8).write(to: url)
      rejects("Unsafe or invalid SVG is rejected: " + name) { _ = try ImageMediaInfoReader.read(url: url, token: token) }
    }
    let excessiveSVG = directory.appendingPathComponent("oversized.svg")
    try Data(repeating: 32, count: 10 * 1024 * 1024 + 1).write(to: excessiveSVG)
    rejects("Oversized SVG metadata is bounded") { _ = try ImageMediaInfoReader.read(url: excessiveSVG, token: token) }

    let cancelled = MediaInfoCancellation()
    cancelled.cancel()
    do {
      _ = try ImageMediaInfoReader.read(url: misnamed, token: cancelled)
      fatalError("FAIL: Cancellation is observed")
    } catch MediaInfoError.cancelled { check(true, "Cancellation is observed") }
    rejects("Remote URLs are never opened") { _ = try ImageMediaInfoReader.read(url: URL(string: "https://example.invalid/image.png")!, token: token) }
    rejects("Directories are not treated as images") { _ = try ImageMediaInfoReader.read(url: directory, token: token) }
    print("PASS: \(checks) image metadata checks")
  }
}
