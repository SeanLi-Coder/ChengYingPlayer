import Cocoa
import ImageIO
import PDFKit

var checks = 0
func check(_ condition: Bool, _ message: String) {
  guard condition else { fatalError("FAIL: \(message)") }
  checks += 1
}
func rejects(_ message: String, _ operation: () throws -> Void) {
  do { try operation(); fatalError("FAIL: \(message)") } catch { checks += 1 }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
func makeImage(blue: Bool = false, depth: Int = 8) -> CGImage {
  let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: depth,
    bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(colorSpace: space, components: blue ? [0, 0, 1, 1] : [1, 0, 0, 1])!)
  context.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
  return context.makeImage()!
}
func write(_ name: String, type: String = "public.png", images: [CGImage] = [makeImage()],
           orientation: Int = 1, animation: Bool = false, loops: Int? = 3) -> URL {
  let url = fixtures.appendingPathComponent(name)
  let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
  let dictionary = type == "com.compuserve.gif" ? "{GIF}" : "{PNG}"
  if animation, let loops {
    CGImageDestinationSetProperties(destination, [dictionary: ["LoopCount": loops]] as CFDictionary)
  }
  for (index, image) in images.enumerated() {
    var properties: [String: Any] = [kCGImagePropertyOrientation as String: orientation,
                                   kCGImageDestinationLossyCompressionQuality as String: 0.99]
    if animation { properties[dictionary] = ["UnclampedDelayTime": index == 0 ? 0.2 : 0.4] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  }
  check(CGImageDestinationFinalize(destination), "Fixture encoding succeeds: \(name)")
  return url
}
func pixels(_ image: CGImage) -> [UInt8] {
  var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
  data.withUnsafeMutableBytes { bytes in
    let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return data
}
let still = write("original.png")
let originalBytes = try Data(contentsOf: still)
let document = try ImageDocument(url: still)
check(document.width == 32 && document.height == 24 && document.hasAlpha, "Original size and alpha are available")
check(!document.isAnimated && document.frameCount == 1, "A still is not animated")
check(try document.frame(at: 0).colorSpace?.name == CGColorSpace.displayP3, "Original ICC profile is retained")
rejects("Out-of-range frame is rejected") { _ = try document.frame(at: -1) }
for dimensions in [(0, 1), (-1, 24), (Int.max, Int.max), (131_072, 131_072)] {
  rejects("Untrusted dimensions are bounded") { try ImageDocument.validateDimensions(dimensions.0, dimensions.1) }
}
check(ImageFileSupport.isImageURL(still), "Local PNG routes to the viewer")
check(!ImageFileSupport.isImageURL(URL(string: "https://example.invalid/a.png")!), "Remote URLs are not image file routes")
for ext in ["GIF", "apng", "WebP", "AVIF", "JXL", "heic", "dng", "cr3", "psd", "svg", "pdf"] {
  check(ImageFileSupport.isImageURL(fixtures.appendingPathComponent("a.\(ext)")), "Mainstream extension routes safely: \(ext)")
}

for format in ImageConversionFormat.available {
  var progress: [Double] = []
  let output = try ImageConverter.convert(url: still, format: format, frameIndex: nil,
    token: ImageCancellationToken()) { progress.append($0) }
  let result = try ImageDocument(url: output)
  check(result.width == 32 && result.height == 24, "Export keeps source pixels: \(format)")
  check(output != still && output.deletingLastPathComponent() == fixtures, "Export is a separate sibling: \(format)")
  check(progress.last == 1 && progress == progress.sorted(), "Export progress is monotonic: \(format)")
  let frame = try result.frame(at: 0)
  if [.png, .apng, .tiff, .webp].contains(format) {
    check(frame.colorSpace?.name == CGColorSpace.displayP3, "Lossless export retains P3: \(format)")
    check(pixels(frame) == pixels(try document.frame(at: 0)), "Lossless export retains RGBA pixels: \(format)")
  }
  if !format.supportsAlpha {
    let values = pixels(frame)
    check(values[80] > 240 && values[81] > 240 && values[82] > 240 && values[83] == 255,
          "Transparent JPEG/BMP pixels become white, not black")
  }
}
check(try Data(contentsOf: still) == originalBytes, "Conversions never modify original bytes")
let one = try ImageConverter.convert(url: still, format: .png, frameIndex: nil,
                                    token: ImageCancellationToken(), progress: { _ in })
let firstBytes = try Data(contentsOf: one)
let two = try ImageConverter.convert(url: still, format: .png, frameIndex: nil,
                                    token: ImageCancellationToken(), progress: { _ in })
let preservedBytes = try Data(contentsOf: one)
check(one != two && preservedBytes == firstBytes, "Repeated exports never replace existing files")
let cancelled = ImageCancellationToken()
cancelled.cancel()
rejects("Pre-cancelled export stops before creating files") {
  _ = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, token: cancelled, progress: { _ in })
}
let during = ImageCancellationToken()
rejects("Cancellation during export prevents publication") {
  _ = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, token: during) { _ in during.cancel() }
}

for orientation in 1...8 {
  let input = write("orientation-\(orientation).tiff", type: "public.tiff", orientation: orientation)
  let oriented = try ImageDocument(url: input)
  let frame = try oriented.frame(at: 0)
  let expectedWidth = orientation >= 5 ? 24 : 32
  let expectedHeight = orientation >= 5 ? 32 : 24
  check(frame.width == expectedWidth && frame.height == expectedHeight, "EXIF orientation keeps full resolution: \(orientation)")
  check(oriented.width == frame.width && oriented.height == frame.height, "Oriented metadata agrees with pixels")
  let output = try ImageConverter.convert(url: input, format: .png, frameIndex: nil,
                                        token: ImageCancellationToken(), progress: { _ in })
  check(pixels(try ImageDocument(url: output).frame(at: 0)) == pixels(frame), "Export never rotates twice")
}
let highDepth = write("sixteen-bit.tiff", type: "public.tiff", images: [makeImage(depth: 16)], orientation: 6)
let highFrame = try ImageDocument(url: highDepth).frame(at: 0)
check(highFrame.bitsPerComponent == 16, "Orientation normalization does not downconvert 16-bit input")
let highOutput = try ImageConverter.convert(url: highDepth, format: .png, frameIndex: nil,
                                          token: ImageCancellationToken(), progress: { _ in })
check(try ImageDocument(url: highOutput).frame(at: 0).bitsPerComponent == 16, "PNG export keeps 16-bit depth")

for (ext, type) in [("gif", "com.compuserve.gif"), ("apng", "public.png")] {
  let animation = write("motion.\(ext)", type: type, images: [makeImage(), makeImage(blue: true)], animation: true)
  let source = try ImageDocument(url: animation)
  check(source.isAnimated && source.frameCount == 2, "Animation is recognized: \(ext)")
  check(source.loopCount == 3, "ImageIO loop metadata uses total plays")
  check(abs(source.frameDuration(at: 0) - 0.2) < 0.001 && abs(source.frameDuration(at: 1) - 0.4) < 0.001,
        "Nonuniform frame timings are preserved")
  for format in ImageConversionFormat.available.filter({ $0.supportsAnimation }) {
    let output = try ImageConverter.convert(url: animation, format: format, frameIndex: nil,
                                          token: ImageCancellationToken(), progress: { _ in })
    let result = try ImageDocument(url: output)
    check(result.isAnimated && result.frameCount == 2, "Animation remains animated: \(ext) to \(format)")
    check(result.loopCount == source.loopCount, "Cross-format loop semantics are retained")
    check(abs(result.frameDuration(at: 0) - 0.2) < 0.011 && abs(result.frameDuration(at: 1) - 0.4) < 0.011,
          "Cross-format timings are retained")
  }
  rejects("Animation flattening requires explicit frame selection") {
    _ = try ImageConverter.convert(url: animation, format: .png, frameIndex: nil,
                                  token: ImageCancellationToken(), progress: { _ in })
  }
  let frameOutput = try ImageConverter.convert(url: animation, format: .png, frameIndex: 1,
                                              token: ImageCancellationToken(), progress: { _ in })
  check(try ImageDocument(url: frameOutput).frameCount == 1, "Explicit current-frame export succeeds")
}
let pages = write("pages.tiff", type: "public.tiff", images: [makeImage(), makeImage(blue: true)])
let pageDocument = try ImageDocument(url: pages)
check(pageDocument.frameCount == 2 && !pageDocument.isAnimated, "Multipage TIFF is not mistaken for animation")
let pagesOutput = try ImageConverter.convert(url: pages, format: .tiff, frameIndex: nil,
                                           token: ImageCancellationToken(), progress: { _ in })
check(try ImageDocument(url: pagesOutput).frameCount == 2, "TIFF-to-TIFF retains all pages")

// GIF container repetitions and ImageIO total-play metadata are distinct.
let onceGIF = write("once-no-loop-extension.gif", type: "com.compuserve.gif",
                    images: [makeImage(), makeImage(blue: true)], animation: true, loops: nil)
check(try Data(contentsOf: onceGIF).range(of: Data("NETSCAPE2.0".utf8)) == nil,
      "Single-play GIF fixture has no loop application extension")
check(try ImageDocument(url: onceGIF).loopCount == 1, "GIF without loop extension plays once")
for plays in [0, 1, 2] {
  let input = plays == 1 ? onceGIF : write("gif-plays-\(plays).gif", type: "com.compuserve.gif",
    images: [makeImage(), makeImage(blue: true)], animation: true, loops: plays)
  for format in [ImageConversionFormat.apng, .webp] where ImageConversionFormat.available.contains(format) {
    let output = try ImageConverter.convert(url: input, format: format, frameIndex: nil,
      token: ImageCancellationToken(), progress: { _ in })
    let converted = try ImageDocument(url: output)
    check(converted.isAnimated && converted.loopCount == plays && converted.frameCount == 2 &&
          abs(converted.frameDuration(at: 0) - 0.2) < 0.001 && abs(converted.frameDuration(at: 1) - 0.4) < 0.001,
          "GIF total plays and nonuniform timing survive \(plays)-play conversion to \(format)")
  }
}

// Hand-built local rectangles require ImageIO to apply disposal before random access.
func disposalGIF() -> Data {
  var data = Data("GIF89a".utf8)
  data.append(contentsOf: [4, 0, 4, 0, 0x81, 3, 0])
  data.append(contentsOf: [255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 0])
  func frame(_ color: UInt8, x: UInt8, y: UInt8, width: UInt8, height: UInt8, disposal: UInt8) {
    data.append(contentsOf: [0x21, 0xf9, 4, disposal << 2, 20, 0, 0, 0])
    data.append(contentsOf: [0x2c, x, 0, y, 0, width, 0, height, 0, 0, 2])
    var codes: [UInt8] = []
    for _ in 0..<(Int(width) * Int(height)) { codes.append(contentsOf: [4, color]) }
    codes.append(5)
    var bytes: [UInt8] = []
    var accumulator = 0, bitCount = 0
    for code in codes {
      accumulator |= Int(code) << bitCount
      bitCount += 3
      while bitCount >= 8 { bytes.append(UInt8(accumulator & 255)); accumulator >>= 8; bitCount -= 8 }
    }
    if bitCount > 0 { bytes.append(UInt8(accumulator)) }
    data.append(UInt8(bytes.count)); data.append(contentsOf: bytes); data.append(0)
  }
  frame(0, x: 0, y: 0, width: 4, height: 4, disposal: 1)
  frame(1, x: 1, y: 1, width: 1, height: 1, disposal: 2)
  frame(2, x: 2, y: 2, width: 1, height: 1, disposal: 1)
  data.append(0x3b)
  return data
}
func colorCounts(_ image: CGImage) -> [String: Int] {
  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let bytes = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
  var colors: [String: Int] = [:]
  for pixel in 0..<(image.width * image.height) {
    let at = pixel * 4
    colors["\(bytes[at]),\(bytes[at + 1]),\(bytes[at + 2]),\(bytes[at + 3])", default: 0] += 1
  }
  return colors
}
let disposalURL = fixtures.appendingPathComponent("local-disposal.gif")
try disposalGIF().write(to: disposalURL)
let disposalDocument = try ImageDocument(url: disposalURL)
let expectedColors = [
  ["255,0,0,255": 16],
  ["255,0,0,255": 15, "0,0,255,255": 1],
  ["255,0,0,255": 14, "0,0,0,255": 1, "0,255,0,255": 1],
]
for index in [2, 1, 0] {
  let frame = try disposalDocument.frame(at: index)
  check(frame.width == 4 && frame.height == 4 && colorCounts(frame) == expectedColors[index],
        "Random-access GIF frame \(index) is a full disposal-composited canvas")
}

func sizedImage(width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage {
  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.2, 0.6, 0.8, 1])!)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()!
}
if ImageConversionFormat.available.contains(.webp) {
  let smaller = sizedImage(width: 17, height: 11, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  let variedTIFF = write("varying-pages.tiff", type: "public.tiff", images: [makeImage(), smaller])
  let variedDocument = try ImageDocument(url: variedTIFF)
  check(try variedDocument.frame(at: 0).colorSpace?.name == CGColorSpace.displayP3 &&
        variedDocument.frame(at: 1).colorSpace?.name == CGColorSpace.sRGB,
        "Multipage TIFF fixture retains distinct per-page profiles")
  rejects("Multipage TIFF cannot silently become a WebP animation") {
    _ = try ImageConverter.convert(url: variedTIFF, format: .webp, frameIndex: nil,
      token: ImageCancellationToken(), progress: { _ in })
  }
  let variedOutput = try ImageConverter.convert(url: variedTIFF, format: .webp, frameIndex: 1,
    token: ImageCancellationToken(), progress: { _ in })
  let variedResult = try ImageDocument(url: variedOutput)
  check(variedResult.width == 17 && variedResult.height == 11 && variedResult.frameCount == 1,
        "Selected non-first TIFF page controls WebP dimensions")
  check(try variedResult.frame(at: 0).colorSpace?.name == CGColorSpace.sRGB &&
        pixels(variedResult.frame(at: 0)) == pixels(variedDocument.frame(at: 1)),
        "Selected TIFF page retains its own profile and visible colors")

  let variedPDF = fixtures.appendingPathComponent("varying-pages.pdf")
  let pdfPages = PDFDocument()
  for (index, image) in [makeImage(), smaller].enumerated() {
    let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))!
    page.setBounds(CGRect(x: 0, y: 0, width: image.width, height: image.height), for: .mediaBox)
    pdfPages.insert(page, at: index)
  }
  check(pdfPages.write(to: variedPDF), "Variable-size PDF fixture is written")
  let variedPDFDocument = try ImageDocument(url: variedPDF)
  let selectedPDF = try variedPDFDocument.frame(at: 1)
  let pdfOutput = try ImageConverter.convert(url: variedPDF, format: .webp, frameIndex: 1,
    token: ImageCancellationToken(), progress: { _ in })
  let pdfResult = try ImageDocument(url: pdfOutput)
  check(variedPDFDocument.width == 64 && pdfResult.width == 34 && pdfResult.height == 22,
        "Selected non-first PDF page uses its own 144 dpi raster dimensions")
  check(try pixels(pdfResult.frame(at: 0)) == pixels(selectedPDF), "Selected PDF page preserves rasterized colors")

  // A straight-alpha fixture catches the 1-LSB loss caused by an 8-bit premultiply round trip.
  let straightBytes: [UInt8] = [200, 100, 50, 128, 53, 210, 7, 17]
  let provider = CGDataProvider(data: Data(straightBytes) as CFData)!
  let straight = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
    space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let straightPNG = write("straight-alpha.png", images: [straight])
  let straightOutput = try ImageConverter.convert(url: straightPNG, format: .webp, frameIndex: nil,
    token: ImageCancellationToken(), progress: { _ in })
  let straightDecoded = try ImageDocument(url: straightOutput).frame(at: 0)
  check(straightDecoded.alphaInfo == .last && straightDecoded.bitsPerComponent == 8 && straightDecoded.bitsPerPixel == 32,
        "WebP decoding exposes straight RGBA8 for precision inspection")
  let decodedBytes = straightDecoded.dataProvider!.data! as Data
  check(Array(decodedBytes.prefix(8)) == straightBytes, "PNG to WebP preserves exact semitransparent RGB and alpha")
}
let longLoops = write("large-loop-count.apng", images: [makeImage(), makeImage(blue: true)], animation: true, loops: 32_768)
check(try ImageDocument(url: longLoops).loopCount == 32_768, "Large APNG loop count is retained on input")
rejects("Unsupported large GIF loop count is rejected instead of becoming one or infinite plays") {
  _ = try ImageConverter.convert(url: longLoops, format: .gif, frameIndex: nil,
    token: ImageCancellationToken(), progress: { _ in })
}

let safeSVG = fixtures.appendingPathComponent("vector.svg")
try #"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="24"><rect width="32" height="24" fill="red"/></svg>"#
  .write(to: safeSVG, atomically: false, encoding: .utf8)
check(try ImageDocument(url: safeSVG).frame(at: 0).width == 32, "Safe local SVG renders")
for content in [
  #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
  #"<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///etc/passwd"/></svg>"#,
  #"<!DOCTYPE svg [<!ENTITY a SYSTEM "file:///etc/passwd">]><svg>&a;</svg>"#,
  #"<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(https://example.invalid/a)"/></svg>"#,
  #"<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>"#,
  #"<?xml-stylesheet type="text/css" href="https://example.invalid/remote.css"?><svg xmlns="http://www.w3.org/2000/svg" width="32" height="24"><rect width="32" height="24"/></svg>"#,
  #"<?xml-stylesheet type="text/css" href="file:///etc/passwd"?><svg xmlns="http://www.w3.org/2000/svg" width="32" height="24"><rect width="32" height="24"/></svg>"#,
] {
  let unsafe = fixtures.appendingPathComponent("unsafe.svg")
  try content.write(to: unsafe, atomically: false, encoding: .utf8)
  rejects("Active or external SVG content is rejected") { _ = try ImageDocument(url: unsafe) }
}
let pdf = write("document.pdf", type: "com.adobe.pdf")
let pdfDocument = try ImageDocument(url: pdf)
check(pdfDocument.width == 64 && pdfDocument.height == 48 && !pdfDocument.isAnimated, "PDF uses explicit 144 dpi rasterization")
check(try pdfDocument.frame(at: 0).width == 64, "PDF page renders full selected raster size")
let junk = fixtures.appendingPathComponent("broken.png")
try Data([1, 2, 3]).write(to: junk)
rejects("Corrupt image produces an error") { _ = try ImageDocument(url: junk) }
check(try FileManager.default.contentsOfDirectory(atPath: fixtures.path).allSatisfy { !$0.hasPrefix(".chengying-image-") },
      "All temporary conversion directories are cleaned")
print("Image viewer backend checks passed: \(checks)")
