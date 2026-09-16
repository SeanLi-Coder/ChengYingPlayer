//
//  VideoToolsShortcuts.swift
//  ChengYing
//

import Cocoa
import IOKit.hidsystem

enum VideoToolsShortcuts {
  enum Action: Equatable {
    case rotateLeft
    case rotateRight
    case speedUp
    case speedDown
    case setA
    case setB
    case consume
  }

  enum SpeedDirection {
    case increase
    case decrease
  }

  static func resolve(
    _ event: NSEvent,
    hasMedia: Bool,
    isTextInput: Bool,
    isModal: Bool = false
  ) -> Action? {
    guard event.type == .keyDown else { return nil }
    return resolve(
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags,
      deviceFlags: event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue),
      hasMedia: hasMedia,
      isTextInput: isTextInput,
      isModal: isModal,
      isRepeat: event.isARepeat
    )
  }

  static func resolve(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    deviceFlags: UInt64,
    hasMedia: Bool,
    isTextInput: Bool,
    isModal: Bool = false,
    isRepeat: Bool = false
  ) -> Action? {
    guard hasMedia, !isTextInput, !isModal else { return nil }

    // Physical key codes keep shortcuts stable while using a Chinese input method.
    // Caps Lock is a typing mode, not an additional shortcut modifier.
    let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    if keyCode == 37 || keyCode == 15 {
      guard modifiers == [.command, .shift],
            deviceFlags & UInt64(NX_DEVICELCMDKEYMASK) != 0,
            deviceFlags & UInt64(NX_DEVICERCMDKEYMASK) == 0 else { return nil }
      if isRepeat { return .consume }
      return keyCode == 37 ? .rotateLeft : .rotateRight
    }

    guard modifiers.isEmpty else { return nil }
    switch keyCode {
    case 8:
      return .speedUp
    case 7:
      return .speedDown
    case 33:
      return isRepeat ? .consume : .setA
    case 30:
      return isRepeat ? .consume : .setB
    default:
      return nil
    }
  }

  static func adjustedSpeed(from currentSpeed: Double, direction: SpeedDirection) -> Double {
    guard currentSpeed.isFinite,
          let current = Decimal(string: String(currentSpeed), locale: Locale(identifier: "en_US_POSIX")) else {
      return 1
    }
    let step = Decimal(1) / Decimal(10)
    var adjusted = current + (direction == .increase ? step : -step)
    var rounded = Decimal()
    // Remove insignificant binary conversion noise without snapping arbitrary speeds to tenths.
    NSDecimalRound(&rounded, &adjusted, 12, .plain)
    return NSDecimalNumber(decimal: min(Decimal(16), max(step, rounded))).doubleValue
  }
}

/// Recognize standard mpv navigation commands without changing unrelated custom bindings.
enum VideoToolsPlaybackCommand: Equatable {
  enum SeekMode: Equatable { case relative, absolute, relativePercent, absolutePercent }
  enum SpeedMode: Equatable { case set, add, multiply }
  case seek(Double, SeekMode)
  case frame(backwards: Bool)
  case speed(Double, SpeedMode)

  static func parse(_ originalTokens: [String]) -> VideoToolsPlaybackCommand? {
    let prefixes: Set<String> = ["no-osd", "osd-auto", "osd-msg", "osd-bar", "osd-msg-bar", "raw", "repeatable", "async", "sync"]
    let tokens = Array(originalTokens.drop(while: { prefixes.contains($0) }))
    guard let name = tokens.first, !tokens.contains(where: { $0.contains(";") }) else { return nil }
    if tokens.count == 1 {
      if name == "frame-step" { return .frame(backwards: false) }
      if name == "frame-back-step" { return .frame(backwards: true) }
    }
    if name == "seek", (2...4).contains(tokens.count), let amount = Double(tokens[1]), amount.isFinite {
      // The optional fourth token is legacy precision, never another seek mode.
      if tokens.count == 4, !["exact", "keyframes"].contains(tokens[3]) { return nil }
      let flags = tokens.count >= 3 ? tokens[2].split(separator: "+").map(String.init) : []
      let allowed: Set<String> = ["relative", "absolute", "relative-percent", "absolute-percent", "exact", "keyframes", "0", "1", "2"]
      guard flags.allSatisfy(allowed.contains) else { return nil }
      if flags.contains("absolute-percent") || flags.contains("1") { return .seek(amount, .absolutePercent) }
      if flags.contains("absolute") || flags.contains("2") { return .seek(amount, .absolute) }
      if flags.contains("relative-percent") { return .seek(amount, .relativePercent) }
      return .seek(amount, .relative)
    }
    if tokens.count == 3, tokens[1] == "speed", let amount = number(tokens[2]) {
      switch name {
      case "set": return .speed(amount, .set)
      case "add": return .speed(amount, .add)
      case "multiply": return .speed(amount, .multiply)
      default: break
      }
    }
    return nil
  }

  /// mpv interprets negative absolute seek targets relative to the end of the file.
  /// Returning nil lets callers defer to mpv when the duration is unavailable.
  static func absoluteSeekTarget(_ amount: Double, duration: Double?) -> Double? {
    guard amount.isFinite else { return nil }
    guard amount < 0 else { return amount }
    guard let duration, duration.isFinite, duration >= 0 else { return nil }
    return max(0, duration + amount)
  }

  private static func number(_ string: String) -> Double? {
    if let value = Double(string), value.isFinite { return value }
    let parts = string.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
          numerator.isFinite, denominator.isFinite, denominator != 0 else { return nil }
    let value = numerator / denominator
    return value.isFinite ? value : nil
  }
}
