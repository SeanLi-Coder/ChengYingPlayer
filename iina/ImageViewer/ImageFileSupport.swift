import Foundation

/// File routing is deliberately separate from actual runtime codec availability.
enum ImageFileSupport {
  static let extensions: Set<String> = [
    "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp", "heic", "heif", "heics", "heifs",
    "avif", "avifs", "jxl", "tif", "tiff", "bmp", "dib", "ico", "icns", "psd", "tga", "exr",
    "hdr", "pic", "pbm", "pgm", "ppm", "pnm", "jp2", "j2k", "jpf", "jpx", "svg", "pdf",
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "raw",
    "raf", "pef", "ptx", "srw", "rwl", "3fr", "fff", "iiq", "kdc", "dcr", "mos", "mrw", "x3f",
  ]

  static func isImageURL(_ url: URL) -> Bool {
    url.isFileURL && !url.path.contains("\0") && extensions.contains(url.pathExtension.lowercased())
  }
}

final class ImageCancellationToken {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    if let process, process.isRunning { process.terminate() }
    lock.unlock()
  }

  func check() throws {
    if isCancelled { throw ImageProcessingError.cancelled }
  }

  /// Starting and cancelling are serialized so a cancelled task cannot launch later.
  func run(_ child: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw ImageProcessingError.cancelled }
    process = child
    try child.run()
  }

  func detachProcess() {
    lock.lock()
    process = nil
    lock.unlock()
  }
}

enum ImageProcessingError: LocalizedError {
  case invalid(String)
  case unsupported
  case tooLarge
  case cancelled
  case exportFailed

  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .unsupported: return "当前 macOS 无法解码这张图片。请更新系统，或先转换为 PNG / TIFF。RAW 支持取决于相机型号。"
    case .tooLarge: return "图片的像素、帧数或内存需求超出安全上限，已停止处理，原文件未改动。"
    case .cancelled: return "操作已取消，原文件未改动。"
    case .exportFailed: return "图片编码失败，没有生成完整输出，原文件未改动。请尝试 PNG 或 TIFF。"
    }
  }
}
