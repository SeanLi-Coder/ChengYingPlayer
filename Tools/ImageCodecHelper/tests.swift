// SPDX-License-Identifier: GPL-3.0-only
import Cocoa
import ImageIO

let helper = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let manager = FileManager.default
var checks = 0
func check(_ condition: Bool, _ message: String) {
  checks += 1
  guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func run(_ arguments: [String]) throws -> (Int32, String) {
  let process = Process()
  let output = Pipe()
  process.executableURL = helper
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
func fixture(_ name: String, frames: [Data], durations: [Int], loop: Int = 0,
             profile: Data = Data(), width: Int = 8, height: Int = 6) throws -> URL {
  let directory = root.appendingPathComponent(name, isDirectory: true)
  try manager.createDirectory(at: directory, withIntermediateDirectories: false)
  let text = "CHENGYING_WEBP_1\n\(width) \(height) \(frames.count) \(loop) \(profile.count)\n" +
    durations.map { "\($0)\n" }.joined()
  try Data(text.utf8).write(to: directory.appendingPathComponent("manifest.txt"))
  for (index, frame) in frames.enumerated() {
    try frame.write(to: directory.appendingPathComponent(String(format: "frame-%06d.rgba", index)))
  }
  if !profile.isEmpty { try profile.write(to: directory.appendingPathComponent("profile.icc")) }
  return directory
}
func encode(_ directory: URL, output: URL? = nil) throws -> (Int32, String) {
  try run(["encode", directory.appendingPathComponent("manifest.txt").path,
           (output ?? directory.appendingPathComponent("output.webp")).path])
}
func pixels(_ color: [UInt8]) -> Data {
  var output = Data()
  for y in 0..<6 {
    for x in 0..<8 {
      output.append(contentsOf: (x == 0 || y == 0) ? [0, 0, 0, 0] : color)
    }
  }
  return output
}
func rgba(_ image: CGImage) -> Data {
  let context = CGContext(data: nil, width: image.width, height: image.height,
    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Data(bytes: context.data!, count: image.width * image.height * 4)
}
func source(_ directory: URL) -> CGImageSource {
  CGImageSourceCreateWithURL(directory.appendingPathComponent("output.webp") as CFURL, nil)!
}
func riffChunk(_ data: Data, _ name: String) -> Data? {
  var offset = 12
  while offset + 8 <= data.count {
    let size = (0..<4).reduce(0) { $0 | (Int(data[offset + 4 + $1]) << ($1 * 8)) }
    guard size <= data.count - offset - 8 else { return nil }
    if String(decoding: data[offset..<(offset + 4)], as: UTF8.self) == name {
      return data.subdata(in: (offset + 8)..<(offset + 8 + size))
    }
    offset += 8 + size + (size & 1)
  }
  return nil
}

do {
  let version = try run(["--version"])
  check(version.0 == 0 && version.1.contains("libwebp 1.6.0"), "Pinned codec version")
  check(try run([]).0 == 2, "Invalid invocation")
  let profile = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
  let red = pixels([255, 0, 0, 255])
  let blue = pixels([0, 0, 255, 255])
  let green = pixels([0, 255, 0, 255])
  let still = try fixture("still with spaces", frames: [red], durations: [0], profile: profile)
  let encoded = try encode(still)
  check(encoded.0 == 0 && encoded.1.contains("FRAME 1 1") && encoded.1.contains("DONE "), "Static encoding")
  let imageSource = source(still)
  check(CGImageSourceGetCount(imageSource) == 1, "Static image count")
  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
  check(image.width == 8 && image.height == 6, "Static original dimensions")
  check(rgba(image) == red, "Static lossless RGBA including transparent border")
  check(image.colorSpace?.name == CGColorSpace.displayP3, "Static Display P3 profile")
  let stillData = try Data(contentsOf: still.appendingPathComponent("output.webp"))
  check(riffChunk(stillData, "ICCP") == profile, "ICC bytes retained exactly")
  check(try encode(still).0 != 0, "Existing output is not overwritten")
  check(try Data(contentsOf: still.appendingPathComponent("output.webp")) == stillData, "Existing output remains unchanged")

  let animated = try fixture("animated", frames: [red, blue, green], durations: [23, 147, 301], loop: 3, profile: profile)
  check(try encode(animated).0 == 0, "Animated encoding")
  let animationSource = source(animated)
  check(CGImageSourceGetCount(animationSource) == 3, "Animated frame count")
  let global = CGImageSourceCopyProperties(animationSource, nil)! as NSDictionary
  let webp = global["{WebP}"] as! NSDictionary
  check((webp["LoopCount"] as? NSNumber)?.intValue == 3, "Animated loop count")
  for (index, expected) in [red, blue, green].enumerated() {
    let frame = CGImageSourceCreateImageAtIndex(animationSource, index, nil)!
    check(frame.width == 8 && frame.height == 6, "Animated frame dimensions")
    check(rgba(frame) == expected, "Animated frame lossless pixels")
    let properties = CGImageSourceCopyPropertiesAtIndex(animationSource, index, nil)! as NSDictionary
    let timing = properties["{WebP}"] as! NSDictionary
    let delay = (timing["UnclampedDelayTime"] as! NSNumber).doubleValue
    check(abs(delay - [0.023, 0.147, 0.301][index]) < 0.00001, "Unclamped animation timing")
  }
  let animatedData = try Data(contentsOf: animated.appendingPathComponent("output.webp"))
  check(riffChunk(animatedData, "ICCP") == profile, "Animation ICC bytes retained exactly")

  // ImageIO exposes canonical total plays, not the GIF container's repeat field.
  // Keep both checks so native and external-codec loop semantics cannot drift.
  for plays in [0, 1, 2, 3] {
    let buffer = NSMutableData()
    let destination = CGImageDestinationCreateWithData(buffer, "com.compuserve.gif" as CFString, 2, nil)!
    CGImageDestinationSetProperties(destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: plays]] as CFDictionary)
    for index in 0..<2 {
      let frame = CGImageSourceCreateImageAtIndex(animationSource, index, nil)!
      CGImageDestinationAddImage(destination, frame,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
    }
    check(CGImageDestinationFinalize(destination), "Native GIF fixture encoding")
    let data = buffer as Data
    let application = data.range(of: Data("NETSCAPE2.0".utf8))
    let rawRepeat = application.map { Int(data[$0.upperBound + 2]) | Int(data[$0.upperBound + 3]) << 8 }
    check(rawRepeat == (plays == 1 ? nil : (plays == 0 ? 0 : plays - 1)), "GIF raw repeat convention")
    let source = CGImageSourceCreateWithData(buffer, nil)!
    let properties = CGImageSourceCopyProperties(source, nil)! as NSDictionary
    check(((properties["{GIF}"] as? NSDictionary)?["LoopCount"] as? NSNumber)?.intValue == plays,
          "ImageIO GIF loop property reports total plays")
  }

  let duplicate = try fixture("duplicate-frames", frames: [red, red, blue], durations: [10, 20, 30])
  check(try encode(duplicate).0 == 0, "Identical adjacent frame encoding")
  let duplicateSource = source(duplicate)
  check(CGImageSourceGetCount(duplicateSource) == 3, "Identical adjacent frames are not merged")
  let duplicateProperties = CGImageSourceCopyProperties(duplicateSource, nil)! as NSDictionary
  check(((duplicateProperties["{WebP}"] as? NSDictionary)?["LoopCount"] as? NSNumber)?.intValue == 0,
        "Infinite animation loop preserved")
  for index in 0..<3 {
    let properties = CGImageSourceCopyPropertiesAtIndex(duplicateSource, index, nil)! as NSDictionary
    let timing = properties["{WebP}"] as! NSDictionary
    check(abs((timing["UnclampedDelayTime"] as! NSNumber).doubleValue - [0.01, 0.02, 0.03][index]) < 0.00001,
          "Identical frame durations retained individually")
  }
  let translucent = try fixture("translucent", frames: [pixels([200, 100, 50, 128])], durations: [0])
  check(try encode(translucent).0 == 0, "Half-transparent pixel encoding")
  let translucentImage = CGImageSourceCreateImageAtIndex(source(translucent), 0, nil)!
  check(rgba(translucentImage) == pixels([100, 50, 25, 128]), "Straight alpha round-trips to premultiplied display pixels")

  let invalidHeaders = [
    "0 6 1 0 0\n0\n", "16384 6 1 0 0\n0\n", "8 0 1 0 0\n0\n",
    "8 6 0 0 0\n", "8 6 10001 0 0\n", "8 6 1 65536 0\n0\n",
    "8 6 1 0 4194305\n0\n", "8 6 1 0 0\n1\n", "8 6 2 0 0\n0\n100\n",
    "8 6 2 0 0\n100\n16777216\n", "-8 6 1 0 0\n0\n",
    "18446744073709551616 6 1 0 0\n0\n", "8 6 1 0 0\n0\nextra\n",
    "8 6 2 0 0\n10\n", "16383 16383 1 0 0\n0\n",
    "8192 8192 33 0 0\n" + String(repeating: "100\n", count: 33),
    "1 1 129 0 0\n" + String(repeating: "16777215\n", count: 129),
    "8x 6 1 0 0\n0\n", "8 6 1 0 0 8\n0\n", "8 6 1 0 0\0ignored\n0\n"
  ]
  for (index, header) in invalidHeaders.enumerated() {
    let directory = try fixture("invalid-\(index)", frames: [red], durations: [0])
    try Data(("CHENGYING_WEBP_1\n" + header).utf8).write(to: directory.appendingPathComponent("manifest.txt"))
    check(try encode(directory).0 != 0, "Invalid manifest rejected: \(index)")
    check(!manager.fileExists(atPath: directory.appendingPathComponent("output.webp").path), "No partial invalid output")
  }
  for length in [0, 191, 193] {
    let directory = try fixture("bad-length-\(length)", frames: [Data(repeating: 0, count: length)], durations: [0])
    check(try encode(directory).0 != 0, "Incorrect RGBA length rejected")
  }
  let missingICC = try fixture("missing-icc", frames: [red], durations: [0], profile: profile)
  try manager.removeItem(at: missingICC.appendingPathComponent("profile.icc"))
  check(try encode(missingICC).0 != 0, "Missing ICC rejected")
  let linked = try fixture("symlink-frame", frames: [red], durations: [0])
  let frameURL = linked.appendingPathComponent("frame-000000.rgba")
  try manager.removeItem(at: frameURL)
  try manager.createSymbolicLink(at: frameURL, withDestinationURL: still.appendingPathComponent("frame-000000.rgba"))
  check(try encode(linked).0 != 0, "Input frame symlink rejected")
  let linkedOutput = still.appendingPathComponent("linked.webp")
  try manager.createSymbolicLink(at: linkedOutput, withDestinationURL: still.appendingPathComponent("output.webp"))
  check(try encode(still, output: linkedOutput).0 != 0, "Output symlink rejected")
  check(try Data(contentsOf: still.appendingPathComponent("output.webp")) == stillData, "Symlink target unchanged")
  let leftovers = try manager.contentsOfDirectory(atPath: still.path).filter { $0.hasPrefix(".chengying-webp-") }
  check(leftovers.isEmpty, "Temporary output cleanup")

  var seed: UInt64 = 0x123456789abcdef
  var noise = Data(count: 2048 * 2048 * 4)
  noise.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
    for index in 0..<bytes.count {
      seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
      bytes[index] = UInt8(truncatingIfNeeded: seed)
    }
  }
  let cancellation = try fixture("cancel", frames: [noise], durations: [0], width: 2048, height: 2048)
  let process = Process()
  let pipe = Pipe()
  process.executableURL = helper
  process.arguments = ["encode", cancellation.appendingPathComponent("manifest.txt").path,
                       cancellation.appendingPathComponent("output.webp").path]
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  Thread.sleep(forTimeInterval: 0.15)
  check(process.isRunning, "Cancellation fixture is still encoding")
  process.terminate()
  let deadline = Date().addingTimeInterval(5)
  while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
  if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  process.waitUntilExit()
  check(process.terminationStatus == 130, "SIGTERM cancels the codec cooperatively")
  check(!manager.fileExists(atPath: cancellation.appendingPathComponent("output.webp").path), "Cancellation leaves no published output")
  print("Image codec checks passed: \(checks)")
} catch {
  fputs("Image codec test failed: \(error)\n", stderr)
  exit(1)
}
