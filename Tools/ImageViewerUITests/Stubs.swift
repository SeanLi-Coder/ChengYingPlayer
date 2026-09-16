import Cocoa

enum ImageFileSupport {
  static let extensions = ["png", "gif", "tiff", "webp"]
  static func isImageURL(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

final class ImageDocument {
  static let lock = NSLock()
  static var mainThreadDecodeCount = 0
  private static var startedURLs: [URL] = []
  static var starts: [URL] { lock.lock(); defer { lock.unlock() }; return startedURLs }
  let url: URL
  let width = 240
  let height = 120
  let frameCount: Int
  let isAnimated: Bool
  let loopCount: Int
  let formatName: String
  let bitDepth = 8
  let hasAlpha = true

  init(url: URL) throws {
    Self.lock.lock()
    Self.startedURLs.append(url)
    Self.lock.unlock()
    self.url = url
    isAnimated = url.pathExtension == "gif"
    frameCount = isAnimated || url.pathExtension == "tiff" ? 3 : 1
    loopCount = url.lastPathComponent.contains("triple") ? 3 : (url.lastPathComponent.contains("finite") ? 1 : 0)
    formatName = url.pathExtension.uppercased()
    if url.lastPathComponent.contains("slow") { Thread.sleep(forTimeInterval: 0.2) }
  }
  func frame(at index: Int) throws -> CGImage {
    Self.lock.lock()
    if Thread.isMainThread { Self.mainThreadDecodeCount += 1 }
    Self.lock.unlock()
    guard index >= 0 && index < frameCount else { throw NSError(domain: "ImageFixture", code: 1) }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(index + 1) / 3, green: 0.2, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }
  func frameDuration(at index: Int) -> TimeInterval { [0.025, 0.04, 0.06][index % 3] }
}

enum ImageConversionFormat: CaseIterable {
  case jpeg, png, gif, apng, tiff, bmp, heic, avif, webp
  var title: String { String(describing: self).uppercased() }
  var fileExtension: String { String(describing: self) }
  var supportsAnimation: Bool { [.gif, .apng, .webp].contains(self) }
  var supportsAlpha: Bool { self != .jpeg && self != .bmp }
  static var available: [Self] { allCases }
}

final class ImageCancellationToken {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
enum ImageConverter {
  static func convert(url: URL, format: ImageConversionFormat, frameIndex: Int?,
                      token: ImageCancellationToken, progress: @escaping (Double) -> Void) throws -> URL {
    for index in 0...10 {
      if token.isCancelled { throw NSError(domain: "ImageFixture", code: 2) }
      Thread.sleep(forTimeInterval: 0.01)
      progress(Double(index) / 10)
    }
    return url.deletingPathExtension().appendingPathExtension("converted.\(format.fileExtension)")
  }
}
