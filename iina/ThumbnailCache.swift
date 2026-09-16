//
//  ThumbnailCache.swift
//  iina
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import ImageIO

fileprivate let subsystem = Logger.makeSubsystem("thumbcache")

class ThumbnailCache {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  private static let version: CacheVersion = 2
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size
  private static let maxFileBytes: UInt64 = 256 * 1_024 * 1_024
  private static let maxImageBytes = 16 * 1_024 * 1_024
  private static let maxDecodedBytes: UInt64 = 128 * 1_024 * 1_024
  private static let maxImageDimension = 4096
  private static let maxThumbnails = 1001
  private static let lock = NSRecursiveLock()
  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.75]

  private enum CacheError: Error { case invalid }

  /// Keep throwing I/O available on macOS 10.15 without Foundation's exception-based legacy API.
  private final class CacheFile {
    private var descriptor: Int32

    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { try? close() }

    func close() throws {
      guard descriptor >= 0 else { return }
      let current = descriptor
      descriptor = -1
      guard Darwin.close(current) == 0 else { throw CacheError.invalid }
    }

    func synchronize() throws {
      guard fsync(descriptor) == 0 else { throw CacheError.invalid }
    }

    func read(upToCount count: Int) throws -> Data? {
      guard descriptor >= 0, count >= 0, count <= maxImageBytes else { throw CacheError.invalid }
      var data = Data(count: count)
      var total = 0
      try data.withUnsafeMutableBytes { bytes in
        while total < count {
          let amount = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: total), count - total)
          if amount < 0 && errno == EINTR { continue }
          guard amount >= 0 else { throw CacheError.invalid }
          if amount == 0 { break }
          total += amount
        }
      }
      data.count = total
      return data
    }

    func write(contentsOf data: Data) throws {
      guard descriptor >= 0 else { throw CacheError.invalid }
      try data.withUnsafeBytes { bytes in
        var total = 0
        while total < bytes.count {
          let amount = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: total), bytes.count - total)
          if amount < 0 && errno == EINTR { continue }
          guard amount > 0 else { throw CacheError.invalid }
          total += amount
        }
      }
    }
  }

  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  static func fileExists(forName name: String) -> Bool {
    FileManager.default.fileExists(atPath: urlFor(name).path)
  }

  private static func videoMetadata(_ url: URL?) -> (FileSize, FileTimestamp)? {
    guard let url = url,
          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? FileSize,
          let date = attributes[.modificationDate] as? Date,
          date.timeIntervalSince1970.isFinite,
          let timestamp = FileTimestamp(exactly: date.timeIntervalSince1970.rounded(.towardZero)) else { return nil }
    return (size, timestamp)
  }

  /// Use a nonblocking, no-follow descriptor so damaged cache entries cannot redirect reads or hang.
  private static func openCache(_ url: URL) throws -> (CacheFile, UInt64) {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw CacheError.invalid }
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0,
          attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          attributes.st_size >= sizeofMetadata,
          UInt64(attributes.st_size) <= maxFileBytes else {
      Darwin.close(descriptor)
      throw CacheError.invalid
    }
    return (CacheFile(descriptor), UInt64(attributes.st_size))
  }

  private static func readInteger<T: FixedWidthInteger>(_ type: T.Type, from file: CacheFile) throws -> T {
    let length = MemoryLayout<T>.size
    guard let data = try file.read(upToCount: length), data.count == length else { throw CacheError.invalid }
    var value: T = 0
    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
    return value
  }

  private static func data<T>(of value: T) -> Data {
    var value = value
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  static func fileIsCached(forName name: String, forVideo videoPath: URL?) -> Bool {
    // Atomic publication and a private descriptor make this safe without waiting for a background
    // JPEG encode while the playback thread checks metadata.
    guard let expected = videoMetadata(videoPath),
          let (file, _) = try? openCache(urlFor(name)) else { return false }
    defer { try? file.close() }
    do {
      return try readInteger(CacheVersion.self, from: file) == version &&
        readInteger(FileSize.self, from: file) == expected.0 &&
        readInteger(FileTimestamp.self, from: file) == expected.1
    } catch { return false }
  }

  /// Write to a separate file and publish only a complete cache. A failed write preserves any old cache.
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo videoPath: URL?) {
    lock.lock()
    defer { lock.unlock() }
    let configured = Preference.integer(for: .maxThumbnailPreviewCacheSize)
    let (maxCacheSize, overflow) = configured.multipliedReportingOverflow(by: 1_024 * 1_024)
    guard configured > 0, !overflow, !thumbnails.isEmpty, thumbnails.count <= maxThumbnails,
          let metadata = videoMetadata(videoPath) else { return }
    let target = urlFor(name)
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      log("Cannot create thumbnail cache.", level: .error)
      return
    }
    let file = CacheFile(descriptor)
    defer {
      try? file.close()
      try? FileManager.default.removeItem(at: temporary)
    }
    do {
      try file.write(contentsOf: data(of: version))
      try file.write(contentsOf: data(of: metadata.0))
      try file.write(contentsOf: data(of: metadata.1))
      var bytesWritten = UInt64(sizeofMetadata)
      var decodedBytes: UInt64 = 0
      for thumbnail in thumbnails {
        try autoreleasepool {
          guard thumbnail.realTime.isFinite,
                let image = thumbnail.image,
                image.size.width > 0, image.size.height > 0,
                image.size.width <= CGFloat(maxImageDimension),
                image.size.height <= CGFloat(maxImageDimension),
                let tiffData = image.tiffRepresentation,
                let representation = NSBitmapImageRep(data: tiffData),
                let jpegData = representation.representation(using: .jpeg, properties: imageProperties),
                !jpegData.isEmpty, jpegData.count <= maxImageBytes else { throw CacheError.invalid }
          decodedBytes += try decodedSize(jpegData)
          guard decodedBytes <= maxDecodedBytes else { throw CacheError.invalid }
          let blockLength = Int64(MemoryLayout<Double>.size + jpegData.count)
          bytesWritten += UInt64(MemoryLayout<Int64>.size) + UInt64(blockLength)
          guard bytesWritten <= maxFileBytes else { throw CacheError.invalid }
          try file.write(contentsOf: data(of: blockLength))
          try file.write(contentsOf: data(of: thumbnail.realTime))
          try file.write(contentsOf: jpegData)
        }
      }
      guard let currentMetadata = videoMetadata(videoPath),
            metadata.0 == currentMetadata.0, metadata.1 == currentMetadata.1 else { throw CacheError.invalid }
      try file.synchronize()
      try file.close()
      guard rename(temporary.path, target.path) == 0 else { throw CacheError.invalid }
      CacheManager.shared.needsRefresh = true
      // Eviction must not remove the previous good cache before its replacement is safely published.
      if CacheManager.shared.getCacheSize() > maxCacheSize {
        CacheManager.shared.clearOldCache(excluding: target)
      }
      log("Finished writing thumbnail cache.")
    } catch {
      log("Cannot write thumbnail cache.", level: .warning)
    }
  }

  /// Validate compressed and decoded sizes before constructing images from an untrusted disk cache.
  private static func decodedSize(_ data: Data) throws -> UInt64 {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          (CGImageSourceGetType(source) as String?) == "public.jpeg",
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let depth = properties[kCGImagePropertyDepth] as? Int, depth > 0, depth <= 8,
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= maxImageDimension, height <= maxImageDimension else {
      throw CacheError.invalid
    }
    return UInt64(width) * UInt64(height) * 4
  }

  static func read(forName name: String) -> [FFThumbnail]? {
    lock.lock()
    defer { lock.unlock() }
    let pathURL = urlFor(name)
    guard let (file, eof) = try? openCache(pathURL) else {
      log("Cannot open thumbnail cache.", level: .warning)
      return nil
    }
    defer { try? file.close() }
    do {
      guard try readInteger(CacheVersion.self, from: file) == version else { throw CacheError.invalid }
      _ = try readInteger(FileSize.self, from: file)
      _ = try readInteger(FileTimestamp.self, from: file)
      var offset = UInt64(sizeofMetadata)
      var decodedBytes: UInt64 = 0
      var result: [FFThumbnail] = []
      while offset < eof {
        try autoreleasepool {
          guard result.count < maxThumbnails,
                eof - offset >= UInt64(MemoryLayout<Int64>.size + MemoryLayout<Double>.size) else {
            throw CacheError.invalid
          }
          let blockLength = try readInteger(Int64.self, from: file)
          offset += UInt64(MemoryLayout<Int64>.size)
          guard blockLength > MemoryLayout<Double>.size,
                blockLength <= maxImageBytes + MemoryLayout<Double>.size,
                UInt64(blockLength) <= eof - offset else { throw CacheError.invalid }
          let timestamp = Double(bitPattern: try readInteger(UInt64.self, from: file))
          guard timestamp.isFinite else { throw CacheError.invalid }
          let imageLength = Int(blockLength) - MemoryLayout<Double>.size
          guard let jpegData = try file.read(upToCount: imageLength), jpegData.count == imageLength else {
            throw CacheError.invalid
          }
          decodedBytes += try decodedSize(jpegData)
          guard decodedBytes <= maxDecodedBytes, let image = NSImage(data: jpegData) else { throw CacheError.invalid }
          let thumbnail = FFThumbnail()
          thumbnail.realTime = timestamp
          thumbnail.image = image
          result.append(thumbnail)
          offset += UInt64(blockLength)
        }
      }
      guard !result.isEmpty, try file.read(upToCount: 1)?.isEmpty != false else { throw CacheError.invalid }
      log("Finished reading thumbnail cache, \(result.count) in total")
      return result
    } catch {
      try? file.close()
      log("Invalid thumbnail cache will be deleted.", level: .warning)
      deleteCacheFile(at: pathURL)
      return nil
    }
  }

  private static func deleteCacheFile(at pathURL: URL) {
    do {
      try FileManager.default.removeItem(at: pathURL)
      CacheManager.shared.needsRefresh = true
    } catch {
      log("Cannot delete corrupted cache.", level: .error)
    }
  }

  private static func urlFor(_ name: String) -> URL {
    Utility.thumbnailCacheURL.appendingPathComponent(name)
  }
}
