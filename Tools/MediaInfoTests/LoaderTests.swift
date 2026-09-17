import Foundation
import ImageIO

@main
enum MediaInfoLoaderTests {
  static var checks = 0

  static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
    guard try condition() else { fatalError("FAIL: " + message) }
    checks += 1
  }

  static func read(_ url: URL, kind: MediaInfoKind) throws -> MediaInfoSnapshot {
    try MediaInfoLoader.read(url: url, kind: kind, token: MediaInfoCancellation())
  }

  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let mode = CommandLine.arguments[2]
    let executable = Bundle.main.executableURL!
    check(executable.path.contains("Contents/MacOS/"), "Loader test runs inside an app-style executable directory")
    let probe = executable.deletingLastPathComponent().appendingPathComponent("ffprobe")
    check(FileManager.default.isExecutableFile(atPath: probe.path), "Bundled FFprobe exists next to the executable")

    if mode == "real" {
      let video = directory.appendingPathComponent("video sample.mp4")
      let before = try MediaInfoFileIdentity(url: video)
      let info = try read(video, kind: .video)
      check(info.url == video && info.kind == .video, "The loader preserves the selected video URL and kind")
      check(info.content.sections.first?.id == "file", "Common file details precede video metadata")
      let rows = info.content.sections.flatMap(\.rows)
      check(rows.first { $0.id == "video.stream.0.dimensions" }?.value == "160 × 90 px", "The actual bundled FFprobe reads video dimensions")
      check(rows.contains { $0.id.hasSuffix(".codec") && $0.value == "aac" }, "The actual bundled FFprobe reads audio tracks")
      try check(try MediaInfoFileIdentity(url: video) == before, "Reading metadata never modifies the source video")

      let imageURL = directory.appendingPathComponent("image sample.png")
      let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!, nil)
      check(CGImageDestinationFinalize(destination), "Loader image fixture is written")
      let image = try read(imageURL, kind: .image)
      check(image.content.sections.first?.id == "file", "Common file details precede image metadata")
      check(image.content.sections.flatMap(\.rows).first { $0.id == "image.stored_size" }?.value == "8 × 6",
            "The loader invokes the real image metadata reader")
      let oldSize = try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
      let handle = try FileHandle(forWritingTo: imageURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(repeating: 0, count: 31))
      try handle.close()
      let changedDate = Date(timeIntervalSince1970: 1_600_000_000)
      try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: imageURL.path)
      let refreshed = try read(imageURL, kind: .image)
      let size = refreshed.content.sections.flatMap(\.rows).first { $0.id == "file.size" }!.value
      check(size.contains("(\(oldSize + 31) bytes)"), "Refresh reads current size for the same source URL; expected \(oldSize + 31), got \(size)")
      let dateFormatter = DateFormatter()
      dateFormatter.dateStyle = .medium
      dateFormatter.timeStyle = .medium
      let modified = refreshed.content.sections.flatMap(\.rows).first { $0.id == "file.modified" }!.value
      check(modified == dateFormatter.string(from: changedDate), "Refresh reads the current modification date for the same source URL")

      let hiddenProbe = probe.appendingPathExtension("temporarily-hidden")
      try FileManager.default.moveItem(at: probe, to: hiddenProbe)
      defer { try? FileManager.default.moveItem(at: hiddenProbe, to: probe) }
      do {
        _ = try read(video, kind: .video)
        fatalError("FAIL: Missing bundled FFprobe must not use a system fallback")
      } catch MediaInfoError.unavailable { checks += 1 }
      let withoutProbe = try read(imageURL, kind: .image)
      check(withoutProbe.kind == .image, "Image metadata remains usable when bundled FFprobe is unavailable")
    } else {
      for name in ["modified-source", "replaced-source", "appended-source"] {
        let source = directory.appendingPathComponent(name + ".mp4")
        try Data("Original fixture content".utf8).write(to: source)
        do {
          _ = try read(source, kind: .video)
          fatalError("FAIL: Source mutation must invalidate the metadata snapshot: " + name)
        } catch MediaInfoError.changedSource { checks += 1 }
      }
    }
    let cancelled = MediaInfoCancellation()
    cancelled.cancel()
    do {
      _ = try MediaInfoLoader.read(url: directory.appendingPathComponent("missing"), kind: .video, token: cancelled)
      fatalError("FAIL: Pre-cancelled loader must not access the file or launch FFprobe")
    } catch MediaInfoError.cancelled { checks += 1 }
    print("PASS: \(checks) production loader checks (\(mode))")
  }
}
