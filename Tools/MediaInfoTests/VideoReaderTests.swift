import Foundation
import Darwin

@main
enum VideoReaderTests {
  static var checks = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    checks += 1
  }

  static func rejects(_ message: String, containing text: String? = nil, _ body: () throws -> Void) {
    do {
      try body()
      fatalError("FAIL: \(message)")
    } catch {
      if let text { check(error.localizedDescription.contains(text), "\(message): expected error detail in \(error.localizedDescription)") }
      checks += 1
    }
  }

  static func field(_ content: MediaInfoContent, _ identifier: String) -> String? {
    content.sections.flatMap(\.rows).first { $0.id == identifier }?.value
  }

  static func parse(_ streams: [[String: Any]], format: [String: Any] = [:], catalog: [String: [Int]] = [:]) throws -> MediaInfoContent {
    try VideoMediaInfoReader.parseMetadata(["streams": streams, "format": format], componentDepths: catalog)
  }

  static func process(_ executable: URL, _ arguments: [String]) throws {
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.standardError
    try child.run()
    child.waitUntilExit()
    check(child.terminationStatus == 0, "Fixture command succeeds: \(arguments)")
  }

  static func fixture(_ root: URL, _ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data("metadata fixture".utf8).write(to: url, options: .withoutOverwriting)
    return url
  }

  static func requireReaped(_ source: URL) throws {
    let pidURL = URL(fileURLWithPath: source.path + ".pid")
    let text = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(text) else { fatalError("FAIL: probe fixture did not report a PID") }
    check(kill(pid, 0) == -1 && errno == ESRCH, "The interrupted probe process was reaped")
  }

  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let tools = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
    let fakeProbe = root.appendingPathComponent("probe-fixture")
    let ffmpeg = tools.appendingPathComponent("ffmpeg")
    let ffprobe = tools.appendingPathComponent("ffprobe")

    let allTracks: [[String: Any]] = [
      ["index": 0, "codec_type": "video", "codec_name": "hevc", "profile": "Main 10", "width": 3840,
       "height": 2160, "coded_width": 3840, "coded_height": 2176, "sample_aspect_ratio": "4:3",
       "display_aspect_ratio": "64:27", "avg_frame_rate": "30000/1001", "r_frame_rate": "30/1",
       "pix_fmt": "yuv420p10le", "color_transfer": "smpte2084", "color_primaries": "bt2020",
       "color_range": "tv", "color_space": "bt2020nc", "bits_per_raw_sample": "10",
       "side_data_list": [["rotation": -17.25, "displaymatrix": "mirrored matrix retained"]]],
      ["index": 1, "codec_type": "audio", "codec_name": "aac", "sample_fmt": "fltp", "sample_rate": "48000",
       "channels": 6, "channel_layout": "5.1(side)", "bit_rate": "384000", "bits_per_sample": 0,
       "tags": ["language": "jpn", "title": "Japanese surround"]],
      ["index": 2, "codec_type": "audio", "codec_name": "pcm_s24le", "sample_rate": "96000", "channels": 2,
       "channel_layout": "stereo", "bits_per_sample": 24, "tags": ["LANGUAGE": "eng"]],
      ["index": 3, "codec_type": "subtitle", "codec_name": "ass", "tags": ["language": "zho"], "disposition": ["forced": 1]],
      ["index": 4, "codec_type": "video", "codec_name": "mjpeg", "pix_fmt": "rgb565le", "color_primaries": "bt2020",
       "disposition": ["attached_pic": 1]],
      ["index": 5, "codec_type": "attachment", "codec_name": "ttf", "tags": ["filename": "font.ttf", "mimetype": "font/ttf"]],
      ["index": 6, "codec_type": "data", "codec_name": "bin_data"],
    ]
    let parsed = try parse(allTracks, format: ["format_name": "matroska,webm", "format_long_name": "Matroska / WebM", "duration": "3.125", "bit_rate": "12345678"], catalog: ["rgb565le": [5, 6, 5]])
    check(parsed.sections.count == 8, "All video, audio, subtitle, attachment, and data tracks are retained")
    check(field(parsed, "video.stream.0.dimensions") == "3840 × 2160 px", "Original dimensions do not apply display rotation")
    check(field(parsed, "video.stream.0.coded_dimensions") == "3840 × 2176 px", "Coded padding is distinct from frame dimensions")
    check(field(parsed, "video.stream.0.sar") == "4:3", "SAR retains its rational value")
    check(field(parsed, "video.stream.0.dar") == "64:27", "DAR retains its rational value")
    check(field(parsed, "video.stream.0.rotation") == "-17.25°", "Arbitrary rotation is reported without normalization")
    check(field(parsed, "video.stream.0.display_matrix") == "mirrored matrix retained", "Mirrored matrices remain visible")
    check(field(parsed, "video.stream.0.fps_average")?.contains("30000/1001") == true, "Average FPS retains the exact fraction")
    check(field(parsed, "video.stream.0.fps_nominal") == "30/1 (30 fps)", "Nominal FPS is separate from average FPS")
    check(field(parsed, "video.stream.0.bit_depth")?.contains("10 bit") == true, "Explicit component depth is honored")
    check(field(parsed, "video.stream.0.hdr") == "PQ (smpte2084)", "PQ is reported only from transfer signaling")
    check(field(parsed, "video.stream.1.audio_depth") == MediaInfoValue.unknown, "AAC decoded float samples are not mislabeled as 32-bit source audio")
    check(field(parsed, "video.stream.1.channels") == "6", "All original audio channels are retained")
    check(field(parsed, "video.stream.1.channel_layout") == "5.1(side)", "The declared audio layout remains exact")
    check(field(parsed, "video.stream.2.audio_depth") == "24 bit", "Explicit PCM depth is displayed")
    check(field(parsed, "video.stream.2.language") == "eng", "Case-insensitive track tags are supported")
    check(field(parsed, "video.stream.3.disposition") == "forced", "Forced subtitle flags are visible")
    check(field(parsed, "video.stream.4.bit_depth")?.contains("5/6/5") == true, "Mixed RGB component depths are not reduced to an invented single depth")
    check(field(parsed, "video.stream.4.hdr") == MediaInfoValue.unknown, "BT.2020 alone does not imply HDR")
    check(parsed.notes.count == 2, "Metadata limitations are disclosed")

    for invalid in ["0/0", "0/1", "1/0", "-3/1", "nan/1", "1/inf", "N/A", "30000//1001"] {
      let data = try parse([["codec_type": "video", "avg_frame_rate": invalid, "bits_per_raw_sample": "0"]])
      check(field(data, "video.stream.0.fps_average") == MediaInfoValue.unknown, "Invalid FPS is unknown: \(invalid)")
      check(field(data, "video.stream.0.bit_depth") == MediaInfoValue.unknown, "Missing depth is never defaulted to 8 bits")
    }
    for value: Any in ["NaN", "Infinity", -1, true, "0", ""] {
      let data = try parse([["codec_type": "video", "width": value, "height": 50, "bits_per_raw_sample": value]], format: ["duration": value, "bit_rate": value])
      check(field(data, "video.stream.0.dimensions") == MediaInfoValue.unknown, "Invalid or zero dimensions remain unknown")
      check(field(data, "duration") == MediaInfoValue.unknown, "Invalid or zero duration remains unknown")
      check(field(data, "bit_rate") == MediaInfoValue.unknown, "Invalid or zero bitrate remains unknown")
    }
    let catalogDepth = try parse([["codec_type": "video", "pix_fmt": "yuv420p", "bits_per_pixel": 12]], catalog: ["yuv420p": [8, 8, 8]])
    check(field(catalogDepth, "video.stream.0.bit_depth")?.contains("8 bit") == true, "12 bits per pixel is not confused with 8 bits per component")
    let falseHDR = try parse([["codec_type": "video", "pix_fmt": "yuv420p10le", "bits_per_raw_sample": 10, "color_primaries": "bt2020"]])
    check(field(falseHDR, "video.stream.0.hdr") == MediaInfoValue.unknown, "10-bit BT.2020 is not automatically called HDR")
    let hdr = try parse([["codec_type": "video", "color_transfer": "arib-std-b67", "side_data_list": [["side_data_type": "DOVI configuration record", "dv_profile": 8], ["side_data_type": "Content light level metadata", "max_content": 1000, "max_average": 400]]]])
    check(field(hdr, "video.stream.0.hdr")?.contains("HLG") == true, "HLG transfer has explicit evidence")
    check(field(hdr, "video.stream.0.hdr")?.contains("Dolby Vision") == true, "Dolby Vision is based on stream side data")
    check(field(hdr, "video.stream.0.content_light")?.contains("max_content=1000") == true, "HDR content-light values remain explicit")
    let detailedHDR = try parse([["codec_type": "video", "side_data_list": [
      ["side_data_type": "Mastering display metadata", "red_x": "34000/50000", "max_luminance": "10000000/10000"],
      ["side_data_type": "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"],
    ]]])
    check(field(detailedHDR, "video.stream.0.mastering_display")?.contains("red_x=34000/50000") == true, "Static HDR mastering fractions are retained exactly")
    check(field(detailedHDR, "video.stream.0.hdr")?.contains("HDR10+") == true, "Dynamic HDR labels require explicit reported side data")
    let tiny = try parse([["codec_type": "audio", "bits_per_raw_sample": 999]], format: ["duration": "0.0001"])
    check(field(tiny, "duration") == "0.0001 s", "Sub-millisecond duration is not displayed as zero")
    check(field(tiny, "video.stream.0.audio_depth") == MediaInfoValue.unknown, "Impossible audio sample depth is not reported as a valid value")
    rejects("A missing stream list is an error") { _ = try VideoMediaInfoReader.parseMetadata([:], componentDepths: [:]) }
    rejects("An excessive track list is bounded") { _ = try parse(Array(repeating: ["codec_type": "video"], count: 513)) }

    let local = try fixture(root, "arguments.media")
    setenv("FFREPORT", "file=should-not-write.log", 1)
    setenv("https_proxy", "http://127.0.0.1:1", 1)
    let fakeContent = try VideoMediaInfoReader.read(url: local, ffprobeURL: fakeProbe, token: MediaInfoCancellation())
    unsetenv("FFREPORT")
    unsetenv("https_proxy")
    check(field(fakeContent, "video.stream.0.bit_depth") == "8 bit (pixel format)", "A real bounded probe process can provide the pixel format catalog")
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-write.log").path), "FFREPORT was not inherited")
    for invalid in [URL(string: "https://example.invalid/video.mp4")!, root, root.appendingPathComponent("missing") ] {
      rejects("Only existing local regular files can be inspected") {
        _ = try VideoMediaInfoReader.read(url: invalid, ffprobeURL: fakeProbe, token: MediaInfoCancellation())
      }
    }
    let cancelled = MediaInfoCancellation()
    cancelled.cancel()
    rejects("Pre-cancelled reads do not launch a probe", containing: "cancelled") {
      _ = try VideoMediaInfoReader.read(url: local, ffprobeURL: fakeProbe, token: cancelled)
    }
    rejects("Malformed JSON is rejected", containing: "invalid metadata") {
      _ = try VideoMediaInfoReader.read(url: fixture(root, "malformed.media"), ffprobeURL: fakeProbe, token: MediaInfoCancellation())
    }
    rejects("FFprobe errors retain a bounded diagnostic", containing: "fixture diagnostic") {
      _ = try VideoMediaInfoReader.read(url: fixture(root, "error.media"), ffprobeURL: fakeProbe, token: MediaInfoCancellation())
    }
    for mode in ["flood-stdout", "flood-stderr"] {
      let url = try fixture(root, mode + ".media")
      rejects("Output flooding is bounded", containing: "output limit") {
        _ = try VideoMediaInfoReader.capture(executableURL: fakeProbe, arguments: [url.path], token: MediaInfoCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 3, maximumOutputBytes: 1024)
      }
      try requireReaped(url)
    }
    let slow = try fixture(root, "slow-timeout.media")
    let start = ProcessInfo.processInfo.systemUptime
    rejects("A probe ignoring SIGTERM is force-stopped on timeout", containing: "time limit") {
      _ = try VideoMediaInfoReader.capture(executableURL: fakeProbe, arguments: [slow.path], token: MediaInfoCancellation(), deadline: ProcessInfo.processInfo.systemUptime + 0.2, maximumOutputBytes: 1024)
    }
    check(ProcessInfo.processInfo.systemUptime - start < 2, "Timeout cleanup is bounded")
    try requireReaped(slow)
    let cancelSource = try fixture(root, "slow-cancel.media")
    let token = MediaInfoCancellation()
    let cancelGroup = DispatchGroup()
    cancelGroup.enter()
    DispatchQueue.global().async {
      let deadline = ProcessInfo.processInfo.systemUptime + 2
      while !FileManager.default.fileExists(atPath: cancelSource.path + ".pid") && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
      token.cancel()
      cancelGroup.leave()
    }
    rejects("Cancellation terminates and reaps a running probe", containing: "cancelled") {
      _ = try VideoMediaInfoReader.capture(executableURL: fakeProbe, arguments: [cancelSource.path], token: token, deadline: ProcessInfo.processInfo.systemUptime + 3, maximumOutputBytes: 1024)
    }
    cancelGroup.wait()
    try requireReaped(cancelSource)

    check(FileManager.default.isExecutableFile(atPath: ffmpeg.path), "The real bundled FFmpeg is available")
    check(FileManager.default.isExecutableFile(atPath: ffprobe.path), "The real bundled FFprobe is available")
    let video = root.appendingPathComponent("相机 资料.mp4")
    try process(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30000/1001:duration=0.3", "-f", "lavfi", "-i", "sine=sample_rate=48000:duration=0.3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "setsar=4/3", "-c:a", "aac", "-metadata:s:a:0", "language=eng", video.path])
    let sourceBytes = try Data(contentsOf: video)
    let real = try VideoMediaInfoReader.read(url: video, ffprobeURL: ffprobe, token: MediaInfoCancellation())
    check(field(real, "video.stream.0.dimensions") == "160 × 90 px", "Real H.264 frame dimensions are read")
    check(field(real, "video.stream.0.sar") == "4:3", "Real non-square pixel SAR is read")
    check(field(real, "video.stream.0.fps_average")?.contains("30000/1001") == true, "Real NTSC frame rate is not rounded away")
    check(field(real, "video.stream.1.sample_rate") == "48000 Hz", "Real audio sample rate is read")
    check(field(real, "video.stream.1.language") == "eng", "Real audio language is read")
    let rotated = root.appendingPathComponent("rotated.mov")
    try process(ffmpeg, ["-v", "error", "-display_rotation", "90", "-i", video.path, "-c", "copy", rotated.path])
    let rotatedInfo = try VideoMediaInfoReader.read(url: rotated, ffprobeURL: ffprobe, token: MediaInfoCancellation())
    check(field(rotatedInfo, "video.stream.0.rotation") == "90°", "Real display matrix rotation is read")
    check(field(rotatedInfo, "video.stream.0.dimensions") == "160 × 90 px", "Rotation does not exchange the original dimensions")

    let subtitles = root.appendingPathComponent("captions.srt")
    try "1\n00:00:00,000 --> 00:00:00,200\nHello\n".write(to: subtitles, atomically: false, encoding: .utf8)
    let multi = root.appendingPathComponent("multitrack.mkv")
    try process(ffmpeg, ["-v", "error", "-i", video.path, "-i", subtitles.path, "-map", "0:v", "-map", "0:a", "-map", "0:a", "-map", "1:s", "-c", "copy", "-metadata:s:a:1", "language=jpn", multi.path])
    let multiInfo = try VideoMediaInfoReader.read(url: multi, ffprobeURL: ffprobe, token: MediaInfoCancellation())
    check(multiInfo.sections.count == 5, "Real multiple audio and subtitle tracks are all shown")
    check(field(multiInfo, "video.stream.2.language") == "jpn", "The second real audio track is not discarded")
    check(field(multiInfo, "video.stream.3.codec") == "subrip", "The real subtitle codec is shown")

    let hdrVideo = root.appendingPathComponent("hdr10.mp4")
    try process(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=128x72:rate=5:duration=0.4", "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast", "-x265-params", "pools=1:frame-threads=1:log-level=error:colorprim=9:transfer=16:colormatrix=9", hdrVideo.path])
    let hdrInfo = try VideoMediaInfoReader.read(url: hdrVideo, ffprobeURL: ffprobe, token: MediaInfoCancellation())
    check(field(hdrInfo, "video.stream.0.bit_depth")?.contains("10 bit") == true, "Real HEVC component depth comes from FFprobe's pixel catalog")
    check(field(hdrInfo, "video.stream.0.color_transfer") == "smpte2084", "Real PQ tagging is preserved")
    check(field(hdrInfo, "video.stream.0.hdr") == "PQ (smpte2084)", "Real HDR labeling is evidence-based")

    let listener = socket(AF_INET, SOCK_STREAM, 0)
    check(listener >= 0, "A loopback listener can detect attempted network access")
    defer { Darwin.close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    check(bindResult == 0 && listen(listener, 1) == 0, "A local test listener is available")
    check(fcntl(listener, F_SETFL, O_NONBLOCK) == 0, "The network check does not block")
    var addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
    let socketNameResult = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &addressSize)
      }
    }
    check(socketNameResult == 0, "The allocated loopback port can be read")
    let port = UInt16(bigEndian: address.sin_port)
    let remotePlaylist = root.appendingPathComponent("remote.m3u8")
    try "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:\(port)/forbidden.ts\n#EXT-X-ENDLIST\n".write(to: remotePlaylist, atomically: false, encoding: .utf8)
    rejects("Local playlists cannot open HTTP resources") {
      _ = try VideoMediaInfoReader.read(url: remotePlaylist, ffprobeURL: ffprobe, token: MediaInfoCancellation())
    }
    let unexpectedConnection = accept(listener, nil, nil)
    let connectionError = errno
    if unexpectedConnection >= 0 { Darwin.close(unexpectedConnection) }
    check(unexpectedConnection == -1 && (connectionError == EAGAIN || connectionError == EWOULDBLOCK), "FFprobe never connected to the playlist's HTTP resource")
    let finalSourceBytes = try Data(contentsOf: video)
    check(finalSourceBytes == sourceBytes, "Metadata reads never modify the source")
    print("PASS: \(checks) video metadata parser, real FFprobe, protocol isolation, output-limit, timeout, and cancellation checks")
  }
}
