import Cocoa

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
  guard (try? condition()) == true else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
  checks += 1
  print("PASS: \(message)")
}

func bytes<T>(_ value: T) -> Data {
  var value = value
  return withUnsafeBytes(of: &value) { Data($0) }
}

func imageData(width: Int = 24, height: Int = 12, format: NSBitmapImageRep.FileType = .jpeg) -> Data {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: width * 3, bitsPerPixel: 24)!
  memset(bitmap.bitmapData, 80, bitmap.bytesPerRow * height)
  return bitmap.representation(using: format, properties: [.compressionFactor: 0.75])!
}

let root = Utility.thumbnailCacheURL
let video = root.deletingLastPathComponent().appendingPathComponent("source-video.mp4")
try Data(repeating: 42, count: 24).write(to: video)
let attributes = try FileManager.default.attributesOfItem(atPath: video.path)
let timestamp = Int64((attributes[.modificationDate] as! Date).timeIntervalSince1970)
let header = bytes(UInt8(2)) + bytes(UInt64(24)) + bytes(timestamp)
let jpeg = imageData()

func block(_ image: Data = jpeg, timestamp: Double = 0.25) -> Data {
  bytes(Int64(image.count + 8)) + bytes(timestamp) + image
}

func store(_ name: String, _ data: Data) throws {
  try data.write(to: root.appendingPathComponent(name))
}

func reject(_ name: String, _ data: Data) throws {
  try store(name, data)
  check(ThumbnailCache.read(forName: name) == nil, "rejects \(name)")
}

try store("valid", header + block() + block(timestamp: 0.75))
check(ThumbnailCache.fileIsCached(forName: "valid", forVideo: video), "existing version-2 cache metadata remains compatible")
let valid = ThumbnailCache.read(forName: "valid")!
check(valid.count == 2, "reads both bounded JPEG thumbnails")
check(valid[0].realTime == 0.25 && valid[1].realTime == 0.75, "preserves fractional thumbnail timestamps")
check(valid[0].image?.size == NSSize(width: 24, height: 12), "preserves thumbnail dimensions")
check(!ThumbnailCache.fileIsCached(forName: "valid", forVideo: nil), "missing source URL is safe")
check(!ThumbnailCache.fileIsCached(forName: "valid", forVideo: root.appendingPathComponent("missing")), "missing source file is safe")
try store("wrong-source", bytes(UInt8(2)) + bytes(UInt64(25)) + bytes(timestamp) + block())
check(!ThumbnailCache.fileIsCached(forName: "wrong-source", forVideo: video), "metadata rejects a changed source size")
try store("wrong-time", bytes(UInt8(2)) + bytes(UInt64(24)) + bytes(timestamp - 1) + block())
check(!ThumbnailCache.fileIsCached(forName: "wrong-time", forVideo: video), "metadata rejects a changed source date")

for length in [Int64.min, -1, 0, 1, 7, 8, 16 * 1_024 * 1_024 + 9, Int64.max] {
  try reject("invalid-length-\(length)", header + bytes(length) + bytes(0.0) + jpeg)
}
try reject("truncated-header", Data([2, 1]))
try reject("empty-cache", header)
try reject("wrong-version", Data([99]) + header.dropFirst() + block())
try reject("truncated-block", header + bytes(Int64(32)) + bytes(0.0) + Data([1, 2]))
try reject("trailing-byte", header + block() + Data([1]))
try reject("invalid-image", header + block(Data([1, 2, 3, 4])))
try reject("nonfinite-timestamp", header + block(timestamp: .infinity))
try reject("nan-timestamp", header + block(timestamp: .nan))
try reject("non-jpeg-image", header + block(imageData(format: .png)))
try reject("oversized-image-dimension", header + block(imageData(width: 4097, height: 1)))
var tooMany = header
for _ in 0..<1002 { tooMany.append(block()) }
try reject("too-many-images", tooMany)
var decodedBudget = header
let largeJPEG = imageData(width: 4096, height: 1024)
for _ in 0..<9 { decodedBudget.append(block(largeJPEG)) }
try reject("decoded-memory-budget", decodedBudget)

let sparse = root.appendingPathComponent("oversized-file")
let sparseDescriptor = open(sparse.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
check(sparseDescriptor >= 0, "creates sparse oversized fixture")
check(ftruncate(sparseDescriptor, 256 * 1_024 * 1_024 + 1) == 0, "oversized fixture does not allocate a large payload")
close(sparseDescriptor)
check(ThumbnailCache.read(forName: "oversized-file") == nil, "rejects oversized cache before allocating data")
let link = root.appendingPathComponent("symlink")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("valid"))
check(ThumbnailCache.read(forName: "symlink") == nil, "does not follow cache symlinks")
check(ThumbnailCache.read(forName: "valid")?.count == 2, "symlink rejection preserves its target")
let fifo = root.appendingPathComponent("fifo")
check(mkfifo(fifo.path, 0o600) == 0, "creates FIFO fixture")
let fifoStart = Date()
check(ThumbnailCache.read(forName: "fifo") == nil, "rejects a FIFO without opening a blocking read")
check(Date().timeIntervalSince(fifoStart) < 1, "FIFO rejection is immediate")

func descriptors() -> Int {
  (0..<2048).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
}
let descriptorsBefore = descriptors()
for _ in 0..<200 {
  _ = ThumbnailCache.fileIsCached(forName: "valid", forVideo: video)
  _ = ThumbnailCache.fileIsCached(forName: "wrong-source", forVideo: video)
  _ = ThumbnailCache.read(forName: "valid")
}
check(descriptors() <= descriptorsBefore + 1, "repeated metadata and image reads close every descriptor")

let thumbnail = FFThumbnail()
thumbnail.realTime = 1.25
thumbnail.image = NSImage(data: jpeg)
ThumbnailCache.write([thumbnail], forName: "written", forVideo: video)
check(ThumbnailCache.fileIsCached(forName: "written", forVideo: video), "atomic writer publishes valid metadata")
check(ThumbnailCache.read(forName: "written")?.first?.realTime == 1.25, "atomic writer round-trips the image and timestamp")
let savedBytes = try Data(contentsOf: root.appendingPathComponent("written"))
let invalid = FFThumbnail()
invalid.realTime = .nan
invalid.image = thumbnail.image
ThumbnailCache.write([invalid], forName: "written", forVideo: video)
check(try Data(contentsOf: root.appendingPathComponent("written")) == savedBytes, "failed cache write preserves the previous complete file")
Preference.cacheMegabytes = 1
var oldAccess = [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)]
check(oldAccess.withUnsafeBufferPointer { utimes(root.appendingPathComponent("written").path, $0.baseAddress) } == 0,
  "marks the previous valid cache as the oldest eviction candidate")
CacheManager.shared.needsRefresh = true
check(CacheManager.shared.getCacheSize() > 1_024 * 1_024, "failed-write eviction fixture exceeds its cache quota")
ThumbnailCache.write([invalid], forName: "written", forVideo: video)
check(try Data(contentsOf: root.appendingPathComponent("written")) == savedBytes,
  "failed replacement preserves the oldest valid cache even when the folder is over quota")
ThumbnailCache.write([thumbnail], forName: "written", forVideo: video)
check(ThumbnailCache.read(forName: "written")?.count == 1, "successful over-quota replacement is excluded from immediate eviction")
Preference.cacheMegabytes = 500
check(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }.isEmpty, "failed writes remove only their temporary file")
ThumbnailCache.write([thumbnail], forName: "nil-source-write", forVideo: nil)
check(!ThumbnailCache.fileExists(forName: "nil-source-write"), "writer rejects a missing source without creating a partial cache")
Preference.cacheMegabytes = Int.max
ThumbnailCache.write([thumbnail], forName: "overflow-setting", forVideo: video)
check(!ThumbnailCache.fileExists(forName: "overflow-setting"), "cache-size preference overflow is safe")
Preference.cacheMegabytes = 500

let group = DispatchGroup()
let failureLock = NSLock()
var failures = 0
for index in 0..<20 {
  group.enter()
  DispatchQueue.global().async {
    if index % 2 == 0 { ThumbnailCache.write([thumbnail], forName: "concurrent", forVideo: video) }
    if ThumbnailCache.fileIsCached(forName: "concurrent", forVideo: video),
       ThumbnailCache.read(forName: "concurrent")?.count != 1 {
      failureLock.lock()
      failures += 1
      failureLock.unlock()
    }
    group.leave()
  }
}
check(group.wait(timeout: .now() + 10) == .success, "parallel cache reads and writes complete")
check(failures == 0, "parallel readers never observe a partially published cache")

let cleanupRoot = root.appendingPathComponent("cleanup", isDirectory: true)
try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: false)
Utility.thumbnailCacheURL = cleanupRoot
CacheManager.shared = CacheManager()
Preference.cacheMegabytes = 1
for name in ["first", "second"] { try Data(repeating: 0, count: 600 * 1_024).write(to: cleanupRoot.appendingPathComponent(name)) }
check(CacheManager.shared.getCacheSize() == 1200 * 1_024, "cache-size measurement reads the current folder")
CacheManager.shared.clearOldCache()
check(CacheManager.shared.getCacheSize() == 600 * 1_024, "first cleanup releases its target amount")
CacheManager.shared.clearOldCache()
check(CacheManager.shared.getCacheSize() == 0, "cleanup can run again after the first job finishes")
try FileManager.default.createDirectory(at: cleanupRoot.appendingPathComponent("directory"), withIntermediateDirectories: false)
try Data([7]).write(to: cleanupRoot.appendingPathComponent("directory/keep"))
try FileManager.default.createSymbolicLink(at: cleanupRoot.appendingPathComponent("link"), withDestinationURL: video)
CacheManager.shared.needsRefresh = true
CacheManager.shared.clearOldCache()
check(FileManager.default.fileExists(atPath: cleanupRoot.appendingPathComponent("directory/keep").path), "cleanup never recursively removes a directory")
check(FileManager.default.fileExists(atPath: video.path), "cleanup never follows a symlink to source media")
let missingRoot = cleanupRoot.appendingPathComponent("temporarily-missing", isDirectory: true)
Utility.thumbnailCacheURL = missingRoot
CacheManager.shared = CacheManager()
CacheManager.shared.clearOldCache()
try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: false)
try Data(repeating: 0, count: 600 * 1_024).write(to: missingRoot.appendingPathComponent("retry"))
CacheManager.shared.clearOldCache()
check(CacheManager.shared.getCacheSize() == 0, "failed directory enumeration does not permanently disable cleanup")
try Data(repeating: 0, count: 128).write(to: missingRoot.appendingPathComponent("manual-clear"))
CacheManager.shared.needsRefresh = true
check(CacheManager.shared.getCacheSize() == 128, "manual-clear fixture primes cached folder metadata")
try FileManager.default.removeItem(at: missingRoot)
try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: false)
CacheManager.shared.needsRefresh = true
check(CacheManager.shared.getCacheSize() == 0, "manual folder clearing invalidates previously cached file sizes")
let settingsSource = try String(contentsOfFile: CommandLine.arguments[2] + "/iina/PrefUtilsViewController.swift", encoding: .utf8)
let clearAction = settingsSource.components(separatedBy: "@IBAction func clearCacheBtnAction").last!
let invalidationRange = clearAction.range(of: "CacheManager.shared.needsRefresh = true")
let refreshRange = clearAction.range(of: "self.updateThumbnailCacheStat()")
check(invalidationRange != nil && refreshRange != nil && invalidationRange!.lowerBound < refreshRange!.lowerBound,
  "the real clear-cache action invalidates folder metadata before refreshing its size label")
print("Thumbnail cache: \(checks) checks passed.")
