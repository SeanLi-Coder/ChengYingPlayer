import Cocoa
import ImageIO

var checks = 0
func check(_ condition: Bool, _ message: String) {
  guard condition else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
  fflush(stdout)
}
func reject(_ message: String, _ operation: () throws -> Void) {
  do { try operation(); fatalError("FAIL: \(message)") }
  catch { checks += 1 }
}
func requireCancellation(_ message: String, _ operation: () throws -> Void) {
  do { try operation(); fatalError("FAIL: \(message)") }
  catch ImageProcessingError.cancelled { check(true, message) }
  catch { fatalError("FAIL: \(message): unexpected error \(error)") }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func rgbaImage(width: Int = 3, height: Int = 2, labels: [UInt8] = [10, 20, 30, 40, 50, 60],
               alpha: UInt8 = 255, padding: Int = 0) -> CGImage {
  precondition(labels.count == width * height)
  let row = width * 4 + padding
  var data = Data(repeating: 199, count: row * height)
  for y in 0..<height {
    for x in 0..<width {
      let index = y * row + x * 4
      let value = labels[y * width + x]
      data[index] = value; data[index + 1] = 0; data[index + 2] = 0; data[index + 3] = alpha
    }
  }
  return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                 space: p3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                 provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Cancel inside a real provider read, after the editor's initial checks have passed.
/// This avoids timing-dependent sleeps or assumptions about the CI machine's speed.
final class CancelOnReadPixels {
  let bytes: Data
  let token = ImageCancellationToken()
  var armed = false
  var cancelledDuringRead = false

  init(bytes: Data) { self.bytes = bytes }
}

func cancellableProviderImage() -> (CGImage, CancelOnReadPixels) {
  let pixels = CancelOnReadPixels(bytes: Data([10, 0, 0, 255, 20, 0, 0, 255,
                                              30, 0, 0, 255, 40, 0, 0, 255]))
  var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil,
    releaseBytePointer: nil, getBytesAtPosition: { info, buffer, offset, count in
      let pixels = Unmanaged<CancelOnReadPixels>.fromOpaque(info!).takeUnretainedValue()
      guard offset >= 0, offset < pixels.bytes.count else { return 0 }
      let length = min(count, pixels.bytes.count - Int(offset))
      pixels.bytes.withUnsafeBytes { raw in
        buffer.copyMemory(from: raw.baseAddress!.advanced(by: Int(offset)), byteCount: length)
      }
      if pixels.armed {
        pixels.cancelledDuringRead = true
        pixels.token.cancel()
      }
      return length
    }, releaseInfo: { info in
      Unmanaged<CancelOnReadPixels>.fromOpaque(info!).release()
    })
  let provider = CGDataProvider(directInfo: Unmanaged.passRetained(pixels).toOpaque(),
                                size: off_t(pixels.bytes.count), callbacks: &callbacks)!
  let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                      space: p3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent)!
  pixels.armed = true
  return (image, pixels)
}

func canonicalRGBA(_ image: CGImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  bytes.withUnsafeMutableBytes { data in
    let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: image.colorSpace?.model == .rgb ? image.colorSpace! : p3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.setBlendMode(.copy)
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return bytes
}

func labels(_ image: CGImage) -> [UInt8] {
  let bytes = canonicalRGBA(image)
  return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
}

func plan(turns: Int = 0, horizontal: Bool = false, vertical: Bool = false,
          crop: ImagePixelRect? = nil, width: Int? = nil, height: Int? = nil) -> ImageEditPlan {
  ImageEditPlan(quarterTurnsClockwise: turns, flipHorizontal: horizontal, flipVertical: vertical,
                crop: crop, outputWidth: width, outputHeight: height)
}

func write(_ name: String, images: [CGImage], type: String = "public.png", animation: Bool = false) -> URL {
  let url = fixtures.appendingPathComponent(name)
  let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
  let key = type == "com.compuserve.gif" ? "{GIF}" : "{PNG}"
  if animation { CGImageDestinationSetProperties(destination, [key: ["LoopCount": 3]] as CFDictionary) }
  for (index, image) in images.enumerated() {
    var metadata: [String: Any] = [kCGImagePropertyOrientation as String: 1]
    if animation { metadata[key] = ["UnclampedDelayTime": index == 0 ? 0.2 : 0.4, "DelayTime": index == 0 ? 0.2 : 0.4] }
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
  }
  check(CGImageDestinationFinalize(destination), "Fixture encoding succeeds: \(name)")
  return url
}

let original = rgbaImage(padding: 8)
let originalData = original.dataProvider!.data! as Data
check(labels(original) == [10, 20, 30, 40, 50, 60], "Fixture rows use top-left pixel ordering")
check(try ImageEditor.render(original, plan: ImageEditPlan()) === original, "An identity edit does not resample")
let cases: [(ImageEditPlan, Int, Int, [UInt8])] = [
  (plan(turns: 1), 2, 3, [40, 10, 50, 20, 60, 30]),
  (plan(turns: 2), 3, 2, [60, 50, 40, 30, 20, 10]),
  (plan(turns: 3), 2, 3, [30, 60, 20, 50, 10, 40]),
  (plan(turns: -1), 2, 3, [30, 60, 20, 50, 10, 40]),
  (plan(turns: 5), 2, 3, [40, 10, 50, 20, 60, 30]),
  (plan(turns: Int.min), 3, 2, [10, 20, 30, 40, 50, 60]),
  (plan(horizontal: true), 3, 2, [30, 20, 10, 60, 50, 40]),
  (plan(vertical: true), 3, 2, [40, 50, 60, 10, 20, 30]),
  (plan(horizontal: true, vertical: true), 3, 2, [60, 50, 40, 30, 20, 10]),
  (plan(turns: 1, horizontal: true), 2, 3, [10, 40, 20, 50, 30, 60]),
  (plan(turns: 1, vertical: true), 2, 3, [60, 30, 50, 20, 40, 10]),
]
for (index, item) in cases.enumerated() {
  let edited = try ImageEditor.render(original, plan: item.0)
  check(edited.width == item.1 && edited.height == item.2, "Oriented dimensions match: \(index)")
  check(labels(edited) == item.3, "Exact clockwise/flip direction and original pixels: \(index)")
  check(edited.bitsPerComponent == original.bitsPerComponent && edited.alphaInfo == original.alphaInfo,
        "Orientation preserves precision and straight alpha: \(index)")
  check(edited.colorSpace!.copyICCData()! as Data == original.colorSpace!.copyICCData()! as Data,
        "Orientation preserves original ICC bytes: \(index)")
}
for (crop, expected) in [
  (ImagePixelRect(x: 0, y: 0, width: 1, height: 1), [UInt8(10)]),
  (ImagePixelRect(x: 2, y: 0, width: 1, height: 1), [UInt8(30)]),
  (ImagePixelRect(x: 0, y: 1, width: 1, height: 1), [UInt8(40)]),
  (ImagePixelRect(x: 2, y: 1, width: 1, height: 1), [UInt8(60)]),
  (ImagePixelRect(x: 1, y: 0, width: 2, height: 2), [UInt8(20), 30, 50, 60]),
] {
  let edited = try ImageEditor.render(original, plan: plan(crop: crop))
  check(edited.width == crop.width && edited.height == crop.height && labels(edited) == expected,
        "Crop uses exact top-left original-pixel edges")
}
let cropAfterRotation = plan(turns: 1, crop: ImagePixelRect(x: 0, y: 1, width: 2, height: 2))
check(labels(try ImageEditor.render(original, plan: cropAfterRotation)) == [50, 20, 60, 30],
      "Rotation occurs before top-left crop")
let nativeCrop = original.cropping(to: CGRect(x: 1, y: 0, width: 2, height: 2))!
check(labels(try ImageEditor.orientedImage(nativeCrop, plan: plan(horizontal: true))) == [30, 20, 60, 50],
      "Pixel remapping respects a cropped CGImage provider's actual origin")
let resized = try ImageEditor.render(original, plan: plan(width: 9, height: 4))
check(resized.width == 9 && resized.height == 4, "Resize uses requested original-pixel dimensions")
check(resized.colorSpace!.copyICCData()! as Data == p3.copyICCData()! as Data, "Resize retains the source ICC profile")
let pipeline = try ImageEditor.render(original, plan: plan(turns: 1, crop: ImagePixelRect(x: 0, y: 1, width: 2, height: 2), width: 4, height: 6))
check(pipeline.width == 4 && pipeline.height == 6, "Resize follows rotation and crop")
check(original.dataProvider!.data! as Data == originalData, "All geometry leaves original provider bytes unchanged")

let cancelled = ImageCancellationToken()
cancelled.cancel()
for edit in [ImageEditPlan(), plan(turns: 1), plan(horizontal: true)] {
  requireCancellation("A cancelled orientation never returns original or transformed pixels") {
    _ = try ImageEditor.orientedImage(original, plan: edit, token: cancelled)
  }
}
for edit in [ImageEditPlan(), plan(turns: 1), cropAfterRotation, plan(width: 9, height: 4)] {
  requireCancellation("A cancelled render never returns an identity, crop, rotation, or resize") {
    _ = try ImageEditor.render(original, plan: edit, token: cancelled)
  }
}
check(original.dataProvider!.data! as Data == originalData, "Cancelled edits leave original provider bytes unchanged")
do {
  let (image, pixels) = cancellableProviderImage()
  check(!pixels.token.isCancelled, "The provider-backed rotation begins with an active token")
  requireCancellation("Cancellation during provider acquisition stops real pixel orientation") {
    _ = try ImageEditor.orientedImage(image, plan: plan(turns: 1), token: pixels.token)
  }
  check(pixels.cancelledDuringRead, "Rotation cancellation occurred after processing began")
}
do {
  let (image, pixels) = cancellableProviderImage()
  check(!pixels.token.isCancelled, "The provider-backed resize begins with an active token")
  requireCancellation("Cancellation inside opaque CoreGraphics drawing cannot return a resized result") {
    _ = try ImageEditor.render(image, plan: plan(width: 6, height: 4), token: pixels.token)
  }
  check(pixels.cancelledDuringRead, "Resize cancellation occurred during real CoreGraphics source reading")
}

let alphaImage = rgbaImage(width: 1, height: 2, labels: [200, 200], alpha: 128)
let alphaRotated = try ImageEditor.orientedImage(alphaImage, plan: plan(turns: 1))
let alphaRaw = alphaRotated.dataProvider!.data! as Data
check(alphaRotated.alphaInfo == .last && alphaRaw[0] == 200 && alphaRaw[3] == 128,
      "Orientation does not quantize transparent straight-alpha edges")
let alphaResized = canonicalRGBA(try ImageEditor.render(alphaImage, plan: plan(width: 4, height: 4)))
check(stride(from: 3, to: alphaResized.count, by: 4).allSatisfy { abs(Int(alphaResized[$0]) - 128) <= 1 },
      "Resize preserves partial transparency")

let values16: [UInt16] = [10_001, 101, 501, 65_535, 20_003, 103, 503, 65_535,
                          30_007, 107, 507, 65_535, 40_009, 109, 509, 65_535]
let bytes16 = values16.withUnsafeBytes { Data($0) }
let image16 = CGImage(width: 2, height: 2, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 16, space: p3,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                     provider: CGDataProvider(data: bytes16 as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let rotate16 = try ImageEditor.render(image16, plan: plan(turns: 1))
let mapped16 = (rotate16.dataProvider!.data! as Data).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
check(rotate16.bitsPerComponent == 16 && mapped16 == Array(values16[8..<12]) + Array(values16[0..<4]) + Array(values16[12..<16]) + Array(values16[4..<8]),
      "16-bit orientation preserves every component bit")
let resize16 = try ImageEditor.render(image16, plan: plan(width: 4, height: 4))
check(resize16.bitsPerComponent == 16 && resize16.colorSpace!.copyICCData()! as Data == p3.copyICCData()! as Data,
      "16-bit resize keeps precision and ICC")
let samples16 = (resize16.dataProvider!.data! as Data).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
check(samples16.contains { $0 != 0 && $0 != UInt16.max && $0 % 257 != 0 }, "Resize has no hidden 8-bit intermediate")
let crop16 = try ImageEditor.render(image16, plan: plan(crop: ImagePixelRect(x: 1, y: 0, width: 1, height: 2)))
check(crop16.bitsPerComponent == 16 && crop16.width == 1 && crop16.height == 2, "16-bit crop preserves precision")

let gray = CGImage(width: 3, height: 2, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: 1,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: CGDataProvider(data: Data([0b10100000, 0b01000000]) as CFData)!,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let rotateGray = try ImageEditor.orientedImage(gray, plan: plan(turns: 1))
check(rotateGray.bitsPerComponent == 1 && rotateGray.width == 2 && rotateGray.height == 3,
      "Packed grayscale orientation preserves its original bit depth")
check(rotateGray.dataProvider!.data! as Data == Data([0b01000000, 0b10000000, 0b01000000]),
      "Packed grayscale pixels are rotated without touching padding bits")
let grayResized = try ImageEditor.render(gray, plan: plan(width: 6, height: 4))
check(grayResized.width == 6 && grayResized.height == 4 && grayResized.colorSpace?.model == .monochrome,
      "Grayscale resizing retains its grayscale color space")
let croppedGray = gray.cropping(to: CGRect(x: 1, y: 0, width: 2, height: 2))!
let mirroredGray = try ImageEditor.orientedImage(croppedGray, plan: plan(horizontal: true))
check(labels(mirroredGray) == [255, 0, 0, 255], "Packed non-byte-aligned crops preserve their pixel origin")

let floatComponents: [Float] = [1.25, 0.5, 0.25, 1, 0.125, 0.25, 0.5, 1]
let floatData = floatComponents.withUnsafeBytes { Data($0) }
let floatSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let floatImage = CGImage(width: 2, height: 1, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: 32,
                        space: floatSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue | CGBitmapInfo.floatComponents.rawValue),
                        provider: CGDataProvider(data: floatData as CFData)!, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
let floatOriented = try ImageEditor.orientedImage(floatImage, plan: plan(turns: 1))
check(floatOriented.bitsPerComponent == 32 && floatOriented.bitmapInfo.contains(.floatComponents)
      && floatOriented.dataProvider!.data! as Data == floatData, "Floating-point orientation preserves HDR component bits")
let floatResized = try ImageEditor.render(floatImage, plan: plan(width: 4, height: 2))
check(floatResized.bitsPerComponent == 32 && floatResized.bitmapInfo.contains(.floatComponents)
      && floatResized.colorSpace?.name == floatSpace.name, "Floating-point resize retains precision and extended color space")

for crop in [ImagePixelRect(x: -1, y: 0, width: 1, height: 1),
             ImagePixelRect(x: 0, y: -1, width: 1, height: 1),
             ImagePixelRect(x: 0, y: 0, width: 0, height: 1),
             ImagePixelRect(x: 0, y: 0, width: 1, height: -1),
             ImagePixelRect(x: 3, y: 0, width: 1, height: 1),
             ImagePixelRect(x: 0, y: 2, width: 1, height: 1),
             ImagePixelRect(x: 1, y: 1, width: 3, height: 1),
             ImagePixelRect(x: Int.max, y: 0, width: Int.max, height: 1),
             ImagePixelRect(x: 0, y: 0, width: Int.max, height: Int.max)] {
  reject("Invalid, overflowing, or out-of-bounds crop fails before rendering") {
    _ = try ImageEditor.render(original, plan: plan(crop: crop))
  }
}
for dimensions in [(Optional(1), nil), (nil, Optional(1)), (0, 2), (-1, 2), (2, 0), (Int.max, 2), (131_072, 131_072)] {
  reject("Incomplete, invalid, or excessive output dimensions fail") {
    _ = try ImageEditor.render(original, plan: plan(width: dimensions.0, height: dimensions.1))
  }
}
var bound = plan(turns: 1)
bound.sourceWidth = 3; bound.sourceHeight = 2
check(try ImageEditor.outputSize(for: original, plan: bound).width == 2, "Source-bound output validation is available without rendering")
bound.sourceWidth = 2
reject("Orientation rejects another frame's source dimensions") { _ = try ImageEditor.orientedImage(original, plan: bound) }
reject("Render rejects another frame's source dimensions") { _ = try ImageEditor.render(original, plan: bound) }
bound.sourceWidth = nil
reject("Partial source dimensions are rejected") { _ = try ImageEditor.outputSize(for: original, plan: bound) }

let still = write("original.png", images: [original])
let originalFile = try Data(contentsOf: still)
let first = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, editPlan: cropAfterRotation,
                                       token: ImageCancellationToken(), progress: { _ in })
check(first.lastPathComponent == "original_edited.png", "Edits use a separate edited output name")
let firstData = try Data(contentsOf: first)
let firstFrame = try ImageDocument(url: first).frame(at: 0)
check(labels(firstFrame) == [50, 20, 60, 30], "PNG conversion uses the full-resolution edited pixels")
let second = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, editPlan: cropAfterRotation,
                                        token: ImageCancellationToken(), progress: { _ in })
check(second.lastPathComponent == "original_edited_2.png" && first != second, "Colliding edits receive distinct no-replace names")
check(try Data(contentsOf: first) == firstData, "A repeated edit never replaces an existing result")
let legacy = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, token: ImageCancellationToken(), progress: { _ in })
let legacyFrame = try ImageDocument(url: legacy).frame(at: 0)
check(legacy.lastPathComponent == "original_converted.png" && labels(legacyFrame) == labels(original),
      "A legacy conversion without an edit plan keeps original naming and pixels")
check(try Data(contentsOf: still) == originalFile, "Editing and conversion never change the source file")
let highInput = write("high16.tiff", images: [image16], type: "public.tiff")
let highOutput = try ImageConverter.convert(url: highInput, format: .png, frameIndex: nil, editPlan: plan(turns: 1, width: 4, height: 4),
                                           token: ImageCancellationToken(), progress: { _ in })
check(try ImageDocument(url: highOutput).frame(at: 0).bitsPerComponent == 16, "Edited PNG export retains 16-bit precision")

for (ext, type) in [("gif", "com.compuserve.gif"), ("apng", "public.png")] {
  let input = write("animation.\(ext)", images: [original, rgbaImage(labels: [60, 50, 40, 30, 20, 10])], type: type, animation: true)
  let before = try Data(contentsOf: input)
  let document = try ImageDocument(url: input)
  for format in [ImageConversionFormat.gif, .apng, .webp] where ImageConversionFormat.available.contains(format) {
    let output = try ImageConverter.convert(url: input, format: format, frameIndex: nil, editPlan: cropAfterRotation,
                                            token: ImageCancellationToken(), progress: { _ in })
    let result = try ImageDocument(url: output)
    check(result.isAnimated && result.frameCount == 2 && result.loopCount == document.loopCount,
          "Edited animation preserves all frames and finite loop count: \(ext) -> \(format)")
    for index in 0..<2 {
      let image = try result.frame(at: index)
      check(image.width == 2 && image.height == 2, "Every animation frame receives the same source-pixel crop")
      check(abs(result.frameDuration(at: index) - document.frameDuration(at: index)) < 0.011,
            "Edited animation preserves nonuniform frame duration: \(ext) -> \(format)")
    }
    let firstRed = labels(try result.frame(at: 0))[0]
    let secondRed = labels(try result.frame(at: 1))[0]
    check(firstRed > secondRed, "Edited animation retains frame content and order: \(ext) -> \(format)")
  }
  check(try Data(contentsOf: input) == before, "Animation export does not rewrite its source")
}

let pages = write("varied.tiff", images: [original, rgbaImage(width: 1, height: 1, labels: [90])], type: "public.tiff")
let entries = Set(try FileManager.default.contentsOfDirectory(atPath: fixtures.path))
reject("A crop valid only on the first page fails the entire multipage export") {
  _ = try ImageConverter.convert(url: pages, format: .tiff, frameIndex: nil, editPlan: cropAfterRotation,
                                token: ImageCancellationToken(), progress: { _ in })
}
check(Set(try FileManager.default.contentsOfDirectory(atPath: fixtures.path)) == entries,
      "Invalid later-page crop leaves no output or scratch directory")
var sourceBoundPlan = plan(crop: ImagePixelRect(x: 0, y: 0, width: 1, height: 1))
sourceBoundPlan.sourceWidth = 3; sourceBoundPlan.sourceHeight = 2
reject("Source-bound edits reject different-sized pages even when their crop would fit") {
  _ = try ImageConverter.convert(url: pages, format: .tiff, frameIndex: nil, editPlan: sourceBoundPlan,
                                token: ImageCancellationToken(), progress: { _ in })
}
let during = ImageCancellationToken()
reject("Cancelling an edit before encoding prevents publication") {
  _ = try ImageConverter.convert(url: still, format: .png, frameIndex: nil, editPlan: plan(turns: 1), token: during) { _ in during.cancel() }
}
check(Set(try FileManager.default.contentsOfDirectory(atPath: fixtures.path)) == entries,
      "Cancelled and dimension-mismatched edits leave existing files unchanged")
if ImageConversionFormat.available.contains(.webp) {
  let webp = try ImageConverter.convert(url: still, format: .webp, frameIndex: nil, editPlan: cropAfterRotation,
                                       token: ImageCancellationToken(), progress: { _ in })
  check(labels(try ImageDocument(url: webp).frame(at: 0)) == [50, 20, 60, 30], "Real WebP helper receives edited full-resolution pixels")
  check(try ImageDocument(url: webp).frame(at: 0).colorSpace?.name == CGColorSpace.displayP3,
        "Edited WebP preserves the original P3 profile")
} else {
  print("SKIP WebP: bundled executable or system decoding is unavailable")
}
print("SUCCESS: \(checks) image editing checks passed")
