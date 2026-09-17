import CoreGraphics
import Foundation

/// Integer pixel edges measured from the top-left of the oriented image.
struct ImagePixelRect: Equatable {
  var x: Int
  var y: Int
  var width: Int
  var height: Int
}

/// Geometry is applied in order: clockwise rotation, oriented-axis flips, crop, resize.
struct ImageEditPlan: Equatable {
  var quarterTurnsClockwise: Int = 0
  var flipHorizontal: Bool = false
  var flipVertical: Bool = false
  var crop: ImagePixelRect? = nil
  var outputWidth: Int? = nil
  var outputHeight: Int? = nil
  var sourceWidth: Int? = nil
  var sourceHeight: Int? = nil
}

enum ImageEditor {
  private static var memoryBudget: Int {
    Int(min(UInt64(1_073_741_824), ProcessInfo.processInfo.physicalMemory / 4))
  }

  private static func normalizedTurns(_ value: Int) -> Int { (value % 4 + 4) % 4 }

  /// Validate the complete plan without decoding, allocating, or modifying pixels.
  static func outputSize(for image: CGImage, plan: ImageEditPlan) throws -> (width: Int, height: Int) {
    try validateSource(image, plan: plan)
    _ = try storageBytes(image)
    let turns = normalizedTurns(plan.quarterTurnsClockwise)
    var width = turns % 2 == 0 ? image.width : image.height
    var height = turns % 2 == 0 ? image.height : image.width
    if let crop = plan.crop {
      guard crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
            crop.x < width, crop.y < height,
            crop.width <= width - crop.x, crop.height <= height - crop.y else {
        throw ImageProcessingError.invalid("裁剪区域必须完整位于旋转后的原图范围内，宽高至少为 1 像素。")
      }
      width = crop.width
      height = crop.height
    }
    guard (plan.outputWidth == nil) == (plan.outputHeight == nil) else {
      throw ImageProcessingError.invalid("调整尺寸时必须同时提供有效的宽度和高度。")
    }
    if let requestedWidth = plan.outputWidth, let requestedHeight = plan.outputHeight {
      guard requestedWidth > 0, requestedHeight > 0 else {
        throw ImageProcessingError.invalid("输出图片的宽度和高度必须大于 0。")
      }
      width = requestedWidth
      height = requestedHeight
    }
    try ImageDocument.validateDimensions(width, height, depth: max(8, image.bitsPerComponent))
    return (width, height)
  }

  /// Quarter turns and flips copy original pixel bit patterns instead of resampling.
  /// The source ICC profile, alpha representation, precision and byte order survive.
  static func orientedImage(_ image: CGImage, plan: ImageEditPlan,
                            token: ImageCancellationToken? = nil) throws -> CGImage {
    try token?.check()
    try validateSource(image, plan: plan)
    let sourceBytes = try storageBytes(image)
    let turns = normalizedTurns(plan.quarterTurnsClockwise)
    guard turns != 0 || plan.flipHorizontal || plan.flipVertical else { return image }
    let width = turns % 2 == 0 ? image.width : image.height
    let height = turns % 2 == 0 ? image.height : image.width
    let bits = image.bitsPerPixel
    let rowBytes = (width * bits + 7) / 8
    let outputBytes = rowBytes * height
    let readableBytes = (image.height - 1) * image.bytesPerRow + (image.width * bits + 7) / 8
    // A provider may copy its storage; include both retained source and copied bytes.
    try validateWorkingSet([sourceBytes, sourceBytes, outputBytes])
    guard !image.isMask, let space = image.colorSpace, let provider = image.dataProvider, let source = provider.data,
          CFDataGetLength(source) >= readableBytes, let input = CFDataGetBytePtr(source) else {
      throw ImageProcessingError.unsupported
    }
    try token?.check()
    var data = Data(count: outputBytes)
    try data.withUnsafeMutableBytes { raw in
      let output = raw.bindMemory(to: UInt8.self).baseAddress!
      for y in 0..<image.height {
        if y % 8 == 0 { try token?.check() }
        for x in 0..<image.width {
          var destinationX: Int
          var destinationY: Int
          switch turns {
          case 1: destinationX = image.height - 1 - y; destinationY = x
          case 2: destinationX = image.width - 1 - x; destinationY = image.height - 1 - y
          case 3: destinationX = y; destinationY = image.width - 1 - x
          default: destinationX = x; destinationY = y
          }
          if plan.flipHorizontal { destinationX = width - 1 - destinationX }
          if plan.flipVertical { destinationY = height - 1 - destinationY }
          if bits % 8 == 0 {
            let count = bits / 8
            UnsafeMutableRawPointer(output.advanced(by: destinationY * rowBytes + destinationX * count))
              .copyMemory(from: input.advanced(by: y * image.bytesPerRow + x * count), byteCount: count)
          } else {
            // Packed grayscale/indexed images have most-significant pixel bits first.
            let sourceBit = y * image.bytesPerRow * 8 + x * bits
            let destinationBit = destinationY * rowBytes * 8 + destinationX * bits
            for bit in 0..<bits {
              let value = (input[(sourceBit + bit) / 8] >> (7 - (sourceBit + bit) % 8)) & 1
              output[(destinationBit + bit) / 8] |= value << (7 - (destinationBit + bit) % 8)
            }
          }
        }
      }
    }
    try token?.check()
    guard let provider = CGDataProvider(data: data as CFData),
          let result = CGImage(width: width, height: height, bitsPerComponent: image.bitsPerComponent,
                               bitsPerPixel: bits, bytesPerRow: rowBytes, space: space,
                               bitmapInfo: image.bitmapInfo, provider: provider, decode: image.decode,
                               shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
      throw ImageProcessingError.exportFailed
    }
    try token?.check()
    return result
  }

  static func render(_ image: CGImage, plan: ImageEditPlan,
                     token: ImageCancellationToken? = nil) throws -> CGImage {
    try token?.check()
    let size = try outputSize(for: image, plan: plan)
    var result = try orientedImage(image, plan: plan, token: token)
    try token?.check()
    // A cropped CGImage can retain the full oriented backing store, not just its crop.
    let retainedBytes = try storageBytes(image) + (result === image ? 0 : storageBytes(result))
    if let crop = plan.crop,
       crop.x != 0 || crop.y != 0 || crop.width != result.width || crop.height != result.height {
      guard let cropped = result.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)),
            cropped.width == crop.width, cropped.height == crop.height else {
        throw ImageProcessingError.exportFailed
      }
      result = cropped
    }
    try token?.check()
    guard result.width != size.width || result.height != size.height else { return result }
    let resized = try resize(result, width: size.width, height: size.height, retainedSourceBytes: retainedBytes)
    try token?.check()
    return resized
  }

  private static func storageBytes(_ image: CGImage) throws -> Int {
    try ImageDocument.validateDimensions(image.width, image.height, depth: max(8, image.bitsPerComponent))
    guard (1...128).contains(image.bitsPerPixel), (1...32).contains(image.bitsPerComponent),
          image.bytesPerRow >= (image.width * image.bitsPerPixel + 7) / 8 else {
      throw ImageProcessingError.unsupported
    }
    let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !overflow, bytes > 0, bytes <= memoryBudget else { throw ImageProcessingError.tooLarge }
    return bytes
  }

  private static func validateSource(_ image: CGImage, plan: ImageEditPlan) throws {
    guard (plan.sourceWidth == nil) == (plan.sourceHeight == nil) else {
      throw ImageProcessingError.invalid("编辑方案缺少完整的原图尺寸，请重新打开图片后编辑。")
    }
    if let width = plan.sourceWidth, let height = plan.sourceHeight {
      guard width > 0, height > 0, width == image.width, height == image.height else {
        throw ImageProcessingError.invalid("图片帧或页面的尺寸与编辑预览不同，已停止导出。请单独编辑该帧或页面。")
      }
    }
  }

  private static func validateWorkingSet(_ sizes: [Int]) throws {
    var available = memoryBudget
    for size in sizes {
      guard size >= 0, size <= available else { throw ImageProcessingError.tooLarge }
      available -= size
    }
  }

  private static func resize(_ image: CGImage, width: Int, height: Int, retainedSourceBytes: Int) throws -> CGImage {
    guard let originalSpace = image.colorSpace else { throw ImageProcessingError.unsupported }
    let space = originalSpace.model == .indexed ? originalSpace.baseColorSpace : originalSpace
    guard let space, [.rgb, .monochrome, .cmyk].contains(space.model) else {
      throw ImageProcessingError.invalid("当前颜色空间不能安全调整尺寸，请先转换为带颜色配置的 PNG 或 TIFF。")
    }
    let depth = image.bitsPerComponent <= 8 ? 8 : image.bitsPerComponent <= 16 ? 16 : 32
    let hasAlpha = [.premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly].contains(image.alphaInfo)
    guard space.model != .cmyk || !hasAlpha else {
      throw ImageProcessingError.invalid("当前 CMYK 透明图片无法安全调整尺寸，请先转换为带颜色配置的 PNG 或 TIFF。")
    }
    let alpha: CGImageAlphaInfo = space.model == .cmyk ? .none
      : hasAlpha ? .premultipliedLast : space.model == .rgb ? .noneSkipLast : .none
    var bitmap = CGBitmapInfo(rawValue: alpha.rawValue)
    if image.bitmapInfo.contains(.floatComponents) { bitmap.insert(.floatComponents) }
    if depth == 16 { bitmap.insert(.byteOrder16Little) }
    if depth == 32 { bitmap.insert(.byteOrder32Little) }
    if depth == 8 && space.model == .rgb { bitmap.insert(.byteOrder32Big) }
    let components = space.model == .monochrome ? (hasAlpha ? 2 : 1) : 4
    let rowBytes = width * components * (depth / 8)
    let outputBytes = rowBytes * height
    try validateWorkingSet([retainedSourceBytes, try storageBytes(image), outputBytes, outputBytes])
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: depth,
                                  bytesPerRow: rowBytes, space: space, bitmapInfo: bitmap.rawValue) else {
      throw ImageProcessingError.unsupported
    }
    context.setBlendMode(.copy)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw ImageProcessingError.exportFailed }
    return result
  }
}
