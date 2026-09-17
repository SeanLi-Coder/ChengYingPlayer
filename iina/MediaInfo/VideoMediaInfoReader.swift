import Foundation
import CoreFoundation
import Darwin

/// Invoke on a background queue. Every process and buffer belongs to one cancellable read.
enum VideoMediaInfoReader {
  private static let timeout: TimeInterval = 20
  private static let maximumOutputBytes = 4 * 1024 * 1024

  static func read(url: URL, ffprobeURL: URL, token: MediaInfoCancellation) throws -> MediaInfoContent {
    try token.check()
    guard url.isFileURL, !url.path.contains("\0"),
          url.host == nil || url.host == "" || url.host == "localhost",
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw MediaInfoError.invalidSource
    }
    guard ffprobeURL.isFileURL, !ffprobeURL.path.contains("\0"),
          FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else {
      throw MediaInfoError.unavailable(mediaInfoText("video.error.ffprobe", "The bundled FFprobe executable is unavailable."))
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    let arguments = [
      "-v", "error", "-max_alloc", "67108864", "-protocol_whitelist", "file",
      "-probesize", "8388608", "-analyzeduration", "5000000",
      "-show_format", "-show_streams", "-of", "json", "-i", url.standardizedFileURL.path,
    ]
    let payload = try capture(executableURL: ffprobeURL, arguments: arguments, token: token,
                              deadline: deadline, maximumOutputBytes: maximumOutputBytes)
    let object = try metadataObject(payload)
    var componentDepths: [String: [Int]] = [:]
    let streams = object["streams"] as? [[String: Any]] ?? []
    if streams.contains(where: {
      text($0["codec_type"]) == "video" && positiveInteger($0["bits_per_raw_sample"]) == nil
        && text($0["pix_fmt"]) != nil
    }) {
      // The catalog describes actual pixel components, not aggregate bits per pixel.
      // It is intentionally per-read: cancellation never poisons a shared cache.
      let catalog = try capture(executableURL: ffprobeURL,
        arguments: ["-v", "error", "-max_alloc", "67108864", "-show_pixel_formats", "-of", "json"],
        token: token, deadline: deadline, maximumOutputBytes: maximumOutputBytes)
      if let formats = try metadataObject(catalog)["pixel_formats"] as? [[String: Any]] {
        for format in formats {
          guard let name = text(format["name"]),
                let components = format["components"] as? [[String: Any]], !components.isEmpty else { continue }
          let depths = components.compactMap { positiveInteger($0["bit_depth"]) }
          if depths.count == components.count && depths.allSatisfy({ $0 <= 64 }) {
            componentDepths[name] = depths
          }
        }
      }
    }
    try token.check()
    return try parseMetadata(object, componentDepths: componentDepths)
  }

  /// Keep both pipes drained while enforcing cancellation, a shared deadline, and hard output bounds.
  static func capture(executableURL: URL, arguments: [String], token: MediaInfoCancellation,
                      deadline: TimeInterval, maximumOutputBytes: Int) throws -> Data {
    try token.check()
    guard maximumOutputBytes > 0 else { throw outputLimitError() }
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    // Do not inherit FFREPORT, proxy settings, or dynamic-loader injection variables.
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
    let handles = [output.fileHandleForReading, errors.fileHandleForReading]
    let writeHandles = [output.fileHandleForWriting, errors.fileHandleForWriting]
    var buffers = [Data(), Data()]
    var ended = [false, false]
    var started = false
    defer {
      if started && process.isRunning { stop(process) }
      for handle in handles + writeHandles { try? handle.close() }
    }
    do {
      for handle in handles {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
          throw MediaInfoError.readFailed(mediaInfoText("video.error.pipe", "Could not configure metadata output pipes."))
        }
      }
      try token.check()
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw timeoutError() }
      try process.run()
      started = true
    } catch let error as MediaInfoError {
      throw error
    } catch {
      throw MediaInfoError.readFailed(mediaInfoText("video.error.launch", "Could not start the bundled FFprobe."))
    }
    for handle in writeHandles { try? handle.close() }
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      try token.check()
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw timeoutError() }
      for index in 0..<handles.count where !ended[index] {
        // Limit work per iteration so an endlessly writable pipe cannot starve cancellation.
        for _ in 0..<16 {
          let count = Darwin.read(handles[index].fileDescriptor, &chunk, chunk.count)
          if count == 0 { ended[index] = true; break }
          if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw MediaInfoError.readFailed(mediaInfoText("video.error.pipe", "Could not configure metadata output pipes."))
          }
          let limit = index == 0 ? maximumOutputBytes : min(maximumOutputBytes, 64 * 1024)
          guard count <= limit - buffers[index].count else { throw outputLimitError() }
          buffers[index].append(contentsOf: chunk.prefix(count))
          try token.check()
          guard ProcessInfo.processInfo.systemUptime < deadline else { throw timeoutError() }
        }
      }
      if !process.isRunning && ended.allSatisfy({ $0 }) { break }
      var descriptors = handles.enumerated().map { index, handle in
        pollfd(fd: ended[index] ? -1 : handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      }
      let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), 30)
      if result < 0 && errno != EINTR {
        throw MediaInfoError.readFailed(mediaInfoText("video.error.pipe", "Could not configure metadata output pipes."))
      }
    }
    process.waitUntilExit()
    try token.check()
    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
      let detail = String(data: buffers[1], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let summary = mediaInfoText("video.error.probe", "FFprobe could not read this local media file.")
      throw MediaInfoError.readFailed(detail?.isEmpty == false ? summary + "\n" + String(detail!.prefix(2048)) : summary)
    }
    return buffers[0]
  }

  private static func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 0.2
    while process.isRunning && ProcessInfo.processInfo.systemUptime < gracefulDeadline { usleep(10_000) }
    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
    while process.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline { usleep(10_000) }
    if process.isRunning {
      // Do not keep the metadata worker blocked on uninterruptible filesystem I/O.
      DispatchQueue.global(qos: .utility).async { process.waitUntilExit() }
    } else {
      process.waitUntilExit()
    }
  }

  private static func timeoutError() -> MediaInfoError {
    .readFailed(mediaInfoText("video.error.timeout", "Reading video metadata exceeded its time limit."))
  }

  private static func outputLimitError() -> MediaInfoError {
    .readFailed(mediaInfoText("video.error.output_limit", "The video metadata exceeded its safe output limit."))
  }

  private static func metadataObject(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
      throw MediaInfoError.readFailed(mediaInfoText("video.error.json", "FFprobe returned invalid metadata."))
    }
    return object
  }

  static func parseMetadata(_ object: [String: Any], componentDepths: [String: [Int]]) throws -> MediaInfoContent {
    guard let streams = object["streams"] as? [[String: Any]], !streams.isEmpty else {
      throw MediaInfoError.readFailed(mediaInfoText("video.error.no_streams", "No readable media tracks were reported."))
    }
    guard streams.count <= 512 else { throw outputLimitError() }
    let format = object["format"] as? [String: Any] ?? [:]
    let formatTags = format["tags"] as? [String: Any] ?? [:]
    var sections = [MediaInfoSection(id: "video.container", title: mediaInfoText("video.container", "Container"), rows: [
      row("format", "video.format", "Format", text(format["format_long_name"])),
      row("format_identifier", "video.format_identifier", "Format identifier", text(format["format_name"])),
      row("duration", "video.duration", "Duration", duration(format["duration"])),
      row("start_time", "video.start_time", "Timeline start", seconds(format["start_time"])),
      row("bit_rate", "video.overall_bit_rate", "Overall bit rate", bitRate(format["bit_rate"])),
      row("track_count", "video.track_count", "Reported tracks", String(streams.count)),
      row("title", "video.title", "Title", tag("title", in: formatTags)),
      row("encoder", "video.encoder", "Encoder tag", tag("encoder", in: formatTags)),
    ])]
    for (position, stream) in streams.enumerated() {
      let index = nonnegativeInteger(stream["index"])
      let identifier = "video.stream.\(position)"
      let kind = text(stream["codec_type"])
      let tags = stream["tags"] as? [String: Any] ?? [:]
      let title: String
      switch kind {
      case "video": title = mediaInfoText("video.video_track", "Video track")
      case "audio": title = mediaInfoText("video.audio_track", "Audio track")
      case "subtitle": title = mediaInfoText("video.subtitle_track", "Subtitle track")
      case "attachment": title = mediaInfoText("video.attachment_track", "Attachment track")
      default: title = mediaInfoText("video.other_track", "Other track")
      }
      var rows = [
        row("index", "video.stream_index", "Stream index", index.map(String.init)),
        row("type", "video.track_type", "Track type", kind),
        row("codec", "video.codec", "Codec", text(stream["codec_name"])),
        row("codec_long_name", "video.codec_description", "Codec description", text(stream["codec_long_name"])),
        row("profile", "video.profile", "Profile", text(stream["profile"])),
        row("codec_tag", "video.codec_tag", "Codec tag", text(stream["codec_tag_string"])),
        row("duration", "video.track_duration", "Track duration", duration(stream["duration"])),
        row("start_time", "video.start_time", "Timeline start", seconds(stream["start_time"])),
        row("time_base", "video.time_base", "Time base", ratio(stream["time_base"])),
        row("bit_rate", "video.track_bit_rate", "Track bit rate", bitRate(stream["bit_rate"])),
        row("language", "video.language", "Language", tag("language", in: tags)),
        row("title", "video.title", "Title", tag("title", in: tags)),
        row("disposition", "video.disposition", "Track flags", disposition(stream["disposition"])),
      ]
      if kind == "video" {
        let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
        let rotation = sideData.compactMap { finiteNumber($0["rotation"]) }.first ?? finiteNumber(tag("rotate", in: tags))
        let matrix = sideData.compactMap { text($0["displaymatrix"]) }.first
        let pixelFormat = text(stream["pix_fmt"])
        rows += [
          row("dimensions", "video.dimensions", "Original frame dimensions", dimensions(stream["width"], stream["height"])),
          row("coded_dimensions", "video.coded_dimensions", "Coded dimensions", dimensions(stream["coded_width"], stream["coded_height"])),
          row("sar", "video.sample_aspect_ratio", "Sample aspect ratio (SAR)", ratio(stream["sample_aspect_ratio"])),
          row("dar", "video.display_aspect_ratio", "Display aspect ratio (DAR)", ratio(stream["display_aspect_ratio"])),
          row("rotation", "video.rotation", "Rotation metadata", rotation.map { decimal($0) + "°" }),
          row("display_matrix", "video.display_matrix", "Display matrix", matrix),
          row("fps_average", "video.fps_average", "Average frame rate", frameRate(stream["avg_frame_rate"])),
          row("fps_nominal", "video.fps_nominal", "Nominal frame rate", frameRate(stream["r_frame_rate"])),
          row("frame_count", "video.frame_count", "Reported frame count", positiveInteger(stream["nb_frames"]).map(String.init)),
          row("pixel_format", "video.pixel_format", "Pixel format", pixelFormat),
          row("bit_depth", "video.bit_depth", "Pixel component depth", depth(stream, catalog: componentDepths)),
          row("field_order", "video.field_order", "Field order", text(stream["field_order"])),
          row("color_range", "video.color_range", "Color range", colorRange(stream["color_range"])),
          row("color_primaries", "video.color_primaries", "Color primaries", text(stream["color_primaries"])),
          row("color_transfer", "video.color_transfer", "Transfer characteristic", text(stream["color_transfer"])),
          row("color_space", "video.color_space", "Matrix coefficients", text(stream["color_space"])),
          row("chroma_location", "video.chroma_location", "Chroma location", text(stream["chroma_location"])),
          row("hdr", "video.hdr_signaling", "Reported HDR signaling", hdr(stream, sideData: sideData)),
        ]
        if let mastering = sideData.first(where: { text($0["side_data_type"]) == "Mastering display metadata" }) {
          rows.append(row("mastering_display", "video.mastering_display", "Mastering display metadata", dictionaryText(mastering)))
        }
        if let light = sideData.first(where: { text($0["side_data_type"]) == "Content light level metadata" }) {
          rows.append(row("content_light", "video.content_light", "Content light metadata", dictionaryText(light)))
        }
        if let dovi = sideData.first(where: { (text($0["side_data_type"]) ?? "").uppercased().contains("DOVI") }) {
          rows.append(row("dolby_vision", "video.dolby_vision", "Dolby Vision metadata", dictionaryText(dovi)))
        }
      } else if kind == "audio" {
        rows += [
          row("sample_rate", "video.sample_rate", "Sample rate", positiveInteger(stream["sample_rate"]).map { "\($0) Hz" }),
          row("channels", "video.channels", "Channels", positiveInteger(stream["channels"]).map(String.init)),
          row("channel_layout", "video.channel_layout", "Channel layout", text(stream["channel_layout"])),
          row("sample_format", "video.sample_format", "Decoded sample format", text(stream["sample_fmt"])),
          row("audio_depth", "video.audio_bit_depth", "Reported audio sample depth", audioDepth(stream)),
        ]
      } else if kind == "subtitle" {
        rows += [row("dimensions", "video.subtitle_dimensions", "Subtitle canvas", dimensions(stream["width"], stream["height"]))]
      } else if kind == "attachment" {
        rows += [
          row("filename", "video.attachment_filename", "Attachment filename", tag("filename", in: tags)),
          row("mimetype", "video.attachment_mimetype", "Attachment MIME type", tag("mimetype", in: tags)),
        ]
      }
      rows = rows.map { MediaInfoRow(id: identifier + "." + $0.id, label: $0.label, value: $0.value) }
      sections.append(MediaInfoSection(id: identifier, title: title + " #" + (index.map(String.init) ?? "?"), rows: rows))
    }
    return MediaInfoContent(sections: sections, notes: [
      mediaInfoText("video.note.original", "These values describe the local file, not playback speed, zoom, or preview rotation."),
      mediaInfoText("video.note.rates_hdr", "Frame rates and HDR signaling are reported metadata, not a full-frame scan. Missing HDR metadata does not prove SDR; reported rates do not prove a constant frame rate."),
    ])
  }

  private static func row(_ id: String, _ key: String, _ fallback: String, _ value: String?) -> MediaInfoRow {
    MediaInfoRow(id: id, label: mediaInfoText(key, fallback), value: MediaInfoValue.text(value))
  }

  private static func text(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !["unknown", "unspecified", "n/a", "und", "none"].contains(trimmed.lowercased()) else { return nil }
    return String(trimmed.prefix(4096))
  }

  private static func tag(_ key: String, in tags: [String: Any]) -> String? {
    if let value = text(tags[key]) { return value }
    return tags.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.flatMap { text($0.value) }
  }

  private static func finiteNumber(_ value: Any?) -> Double? {
    let number: Double?
    if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
    else if let value = value as? String { number = Double(value) }
    else { number = nil }
    guard let number, number.isFinite else { return nil }
    return number
  }

  private static func nonnegativeInteger(_ value: Any?) -> Int? {
    guard let number = finiteNumber(value), number >= 0, number < Double(Int.max), number.rounded(.towardZero) == number else { return nil }
    return Int(number)
  }

  private static func positiveInteger(_ value: Any?) -> Int? {
    guard let value = nonnegativeInteger(value), value > 0 else { return nil }
    return value
  }

  private static func decimal(_ value: Double) -> String {
    // Preserve sub-millisecond timestamps instead of presenting a positive value as zero.
    if value != 0 && abs(value) < 0.000001 {
      return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
      .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
  }

  private static func seconds(_ value: Any?) -> String? {
    finiteNumber(value).map { decimal($0) + " s" }
  }

  private static func duration(_ value: Any?) -> String? {
    guard let seconds = finiteNumber(value), seconds > 0 else { return nil }
    return decimal(seconds) + " s"
  }

  private static func bitRate(_ value: Any?) -> String? {
    guard let value = positiveInteger(value) else { return nil }
    let exact = "\(value) bit/s"
    if value >= 1_000_000 { return exact + " (" + decimal(Double(value) / 1_000_000) + " Mbit/s)" }
    if value >= 1_000 { return exact + " (" + decimal(Double(value) / 1_000) + " kbit/s)" }
    return exact
  }

  private static func dimensions(_ width: Any?, _ height: Any?) -> String? {
    guard let width = positiveInteger(width), let height = positiveInteger(height) else { return nil }
    return "\(width) × \(height) px"
  }

  private static func ratio(_ value: Any?) -> String? {
    guard let value = text(value),
          value.range(of: #"^[0-9]+[:/][0-9]+$"#, options: .regularExpression) != nil else { return nil }
    let components = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "/" })
    guard components.count == 2, positiveInteger(String(components[0])) != nil,
          positiveInteger(String(components[1])) != nil else { return nil }
    return value
  }

  private static func frameRate(_ value: Any?) -> String? {
    guard let value = ratio(value), let separator = value.firstIndex(of: "/"),
          let numerator = Double(value[..<separator]), let denominator = Double(value[value.index(after: separator)...]) else { return nil }
    return value + " (" + decimal(numerator / denominator) + " fps)"
  }

  private static func depth(_ stream: [String: Any], catalog: [String: [Int]]) -> String? {
    if let depth = positiveInteger(stream["bits_per_raw_sample"]), depth <= 64 {
      return String(format: mediaInfoText("video.depth_reported", "%@ bit (reported)"), String(depth))
    }
    guard let format = text(stream["pix_fmt"]), let components = catalog[format], !components.isEmpty else { return nil }
    if Set(components).count == 1 {
      return String(format: mediaInfoText("video.depth_pixel_format", "%@ bit (pixel format)"), String(components[0]))
    }
    return String(format: mediaInfoText("video.depth_components", "%@ bit (individual components)"), components.map(String.init).joined(separator: "/"))
  }

  private static func audioDepth(_ stream: [String: Any]) -> String? {
    for key in ["bits_per_raw_sample", "bits_per_sample"] {
      if let depth = positiveInteger(stream[key]), depth <= 64 { return "\(depth) bit" }
    }
    return nil
  }

  private static func colorRange(_ value: Any?) -> String? {
    switch text(value) {
    case "tv": return mediaInfoText("video.range_limited", "Limited (tv)")
    case "pc": return mediaInfoText("video.range_full", "Full (pc)")
    default: return text(value)
    }
  }

  private static func disposition(_ value: Any?) -> String? {
    guard let flags = value as? [String: Any] else { return nil }
    let enabled = flags.keys.sorted().filter { positiveInteger(flags[$0]) != nil }
    return enabled.isEmpty ? mediaInfoText("video.flags_none", "No flags reported") : enabled.joined(separator: ", ")
  }

  private static func hdr(_ stream: [String: Any], sideData: [[String: Any]]) -> String? {
    var evidence: [String] = []
    switch text(stream["color_transfer"]) {
    case "smpte2084": evidence.append("PQ (smpte2084)")
    case "arib-std-b67": evidence.append("HLG (arib-std-b67)")
    default: break
    }
    for item in sideData {
      guard let type = text(item["side_data_type"]) else { continue }
      let upper = type.uppercased()
      if upper.contains("DOVI") || upper.contains("DOLBY VISION") { evidence.append("Dolby Vision") }
      else if upper.contains("HDR10+") || upper.contains("2094-40") { evidence.append("HDR10+") }
      else if type == "Mastering display metadata" || type == "Content light level metadata" {
        let staticEvidence = mediaInfoText("video.hdr_static_metadata", "Static mastering/light metadata present")
        if !evidence.contains(staticEvidence) { evidence.append(staticEvidence) }
      }
    }
    return evidence.isEmpty ? nil : evidence.joined(separator: "; ")
  }

  private static func dictionaryText(_ dictionary: [String: Any]) -> String? {
    let values = dictionary.keys.sorted().filter { $0 != "side_data_type" }.compactMap { key -> String? in
      if let value = text(dictionary[key]) { return key + "=" + value }
      if let value = finiteNumber(dictionary[key]) { return key + "=" + decimal(value) }
      return nil
    }
    return values.isEmpty ? nil : values.joined(separator: ", ")
  }
}
