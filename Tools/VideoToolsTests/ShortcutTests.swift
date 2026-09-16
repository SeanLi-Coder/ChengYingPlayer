import Cocoa
import IOKit.hidsystem

func runVideoToolsShortcutTests() {
  typealias Action = VideoToolsShortcuts.Action
  let leftCommand = UInt64(NX_DEVICELCMDKEYMASK)
  let rightCommand = UInt64(NX_DEVICERCMDKEYMASK)

  func resolve(
    _ keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    deviceFlags: UInt64 = 0,
    hasMedia: Bool = true,
    isTextInput: Bool = false,
    isModal: Bool = false,
    isRepeat: Bool = false
  ) -> Action? {
    VideoToolsShortcuts.resolve(
      keyCode: keyCode,
      modifierFlags: modifiers,
      deviceFlags: deviceFlags,
      hasMedia: hasMedia,
      isTextInput: isTextInput,
      isModal: isModal,
      isRepeat: isRepeat
    )
  }

  check(resolve(37, modifiers: [.command, .shift], deviceFlags: leftCommand) == .rotateLeft,
        "Left Command Shift L rotates left")
  check(resolve(15, modifiers: [.command, .shift], deviceFlags: leftCommand) == .rotateRight,
        "Left Command Shift R rotates right")
  for keyCode: UInt16 in [37, 15] {
    check(resolve(keyCode, modifiers: [.command, .shift], deviceFlags: rightCommand) == nil,
          "Right Command cannot trigger rotation for key \(keyCode)")
    check(resolve(keyCode, modifiers: [.command, .shift], deviceFlags: leftCommand | rightCommand) == nil,
          "Both Command keys cannot trigger rotation for key \(keyCode)")
    check(resolve(keyCode, modifiers: [.command, .shift]) == nil,
          "Unknown Command side cannot trigger rotation for key \(keyCode)")
    check(resolve(keyCode, modifiers: [.command], deviceFlags: leftCommand) == nil,
          "Rotation requires Shift for key \(keyCode)")
    check(resolve(keyCode, modifiers: [.shift], deviceFlags: leftCommand) == nil,
          "Rotation requires Command for key \(keyCode)")
    check(resolve(keyCode, modifiers: [.command, .shift], deviceFlags: leftCommand, isRepeat: true) == .consume,
          "Repeated rotation is consumed without another operation for key \(keyCode)")
    for extraModifier: NSEvent.ModifierFlags in [.control, .option, .function, .numericPad] {
      check(resolve(keyCode, modifiers: [.command, .shift, extraModifier], deviceFlags: leftCommand) == nil,
            "Additional modifier prevents rotation for key \(keyCode)")
    }
  }

  let bareShortcuts: [(UInt16, Action)] = [(8, .speedUp), (7, .speedDown), (33, .setA), (30, .setB)]
  for (keyCode, action) in bareShortcuts {
    check(resolve(keyCode) == action, "Bare shortcut maps key \(keyCode)")
    check(resolve(keyCode, modifiers: [.capsLock]) == action, "Caps Lock preserves physical shortcut \(keyCode)")
    for modifier: NSEvent.ModifierFlags in [.command, .shift, .control, .option, .function, .numericPad] {
      check(resolve(keyCode, modifiers: modifier) == nil, "Modified key \(keyCode) does not trigger a bare shortcut")
    }
    check(resolve(keyCode, isTextInput: true) == nil, "Text entry keeps key \(keyCode)")
    check(resolve(keyCode, isModal: true) == nil, "Modal UI keeps key \(keyCode)")
    check(resolve(keyCode, hasMedia: false) == nil, "Empty player does not consume key \(keyCode)")
  }
  check(resolve(37, modifiers: [.command, .shift], deviceFlags: leftCommand, isTextInput: true) == nil,
        "Text entry prevents rotation")
  check(resolve(37, modifiers: [.command, .shift], deviceFlags: leftCommand, isModal: true) == nil,
        "Modal UI prevents rotation")
  check(resolve(37, modifiers: [.command, .shift], deviceFlags: leftCommand, hasMedia: false) == nil,
        "Empty player prevents rotation")
  check(resolve(8, isRepeat: true) == .speedUp && resolve(7, isRepeat: true) == .speedDown,
        "Speed shortcuts support key repeat")
  check(resolve(33, isRepeat: true) == .consume && resolve(30, isRepeat: true) == .consume,
        "Marker repeats do not move the selected boundary")
  check(resolve(0) == nil, "Unrelated keys are not consumed")

  let zoomShortcuts: [(UInt16, NSEvent.ModifierFlags, Action)] = [
    (24, [], .zoomIn), (24, [.shift], .zoomIn), (27, [], .zoomOut),
    (69, [], .zoomIn), (69, [.numericPad], .zoomIn),
    (78, [], .zoomOut), (78, [.numericPad], .zoomOut)
  ]
  for (keyCode, modifiers, action) in zoomShortcuts {
    check(resolve(keyCode, modifiers: modifiers) == action,
          "Zoom shortcut maps physical key \(keyCode) with flags \(modifiers.rawValue)")
    check(resolve(keyCode, modifiers: modifiers.union(.capsLock)) == action,
          "Caps Lock preserves zoom key \(keyCode)")
    check(resolve(keyCode, modifiers: modifiers, isRepeat: true) == action,
          "Zoom key \(keyCode) supports continuous key repeat")
    for extraModifier: NSEvent.ModifierFlags in [.command, .control, .option, .function] {
      check(resolve(keyCode, modifiers: modifiers.union(extraModifier)) == nil,
            "Additional modifier prevents zoom key \(keyCode)")
    }
    check(resolve(keyCode, modifiers: modifiers, isTextInput: true) == nil,
          "Text entry keeps zoom key \(keyCode)")
    check(resolve(keyCode, modifiers: modifiers, isModal: true) == nil,
          "Modal UI keeps zoom key \(keyCode)")
    check(resolve(keyCode, modifiers: modifiers, hasMedia: false) == nil,
          "Empty player does not consume zoom key \(keyCode)")
  }
  check(resolve(27, modifiers: [.shift]) == nil, "Underscore does not trigger zoom out")
  for keyCode: UInt16 in [24, 27] {
    check(resolve(keyCode, modifiers: [.numericPad]) == nil,
          "Main keyboard zoom key \(keyCode) does not ignore numeric-pad modifiers")
  }
  for keyCode: UInt16 in [69, 78] {
    check(resolve(keyCode, modifiers: [.numericPad, .shift]) == nil,
          "Numeric-pad zoom key \(keyCode) does not ignore Shift")
  }

  let panShortcuts: [(UInt16, Action)] = [(123, .panLeft), (124, .panRight), (125, .panDown), (126, .panUp)]
  let panBaseModifiers: NSEvent.ModifierFlags = [.command, .shift]
  for (keyCode, action) in panShortcuts {
    for intrinsicFlags: NSEvent.ModifierFlags in [[], .numericPad, .function, [.numericPad, .function]] {
      let modifiers = panBaseModifiers.union(intrinsicFlags)
      for commandSide in [UInt64(0), leftCommand, rightCommand, leftCommand | rightCommand] {
        check(resolve(keyCode, modifiers: modifiers, deviceFlags: commandSide) == action,
              "Pan key \(keyCode) accepts either Command key and intrinsic arrow flags \(intrinsicFlags.rawValue)")
      }
      check(resolve(keyCode, modifiers: modifiers, isRepeat: true) == action,
            "Pan key \(keyCode) supports continuous key repeat")
      check(resolve(keyCode, modifiers: modifiers.union(.capsLock)) == action,
            "Caps Lock preserves pan key \(keyCode)")
      for extraModifier: NSEvent.ModifierFlags in [.control, .option] {
        check(resolve(keyCode, modifiers: modifiers.union(extraModifier)) == nil,
              "Additional modifier prevents pan key \(keyCode)")
      }
      for missingModifier: NSEvent.ModifierFlags in [.command, .shift] {
        check(resolve(keyCode, modifiers: modifiers.subtracting(missingModifier)) == nil,
              "Pan key \(keyCode) requires both Command and Shift")
      }
      check(resolve(keyCode, modifiers: modifiers, isTextInput: true) == nil,
            "Text entry keeps pan key \(keyCode)")
      check(resolve(keyCode, modifiers: modifiers, isModal: true) == nil,
            "Modal UI keeps pan key \(keyCode)")
      check(resolve(keyCode, modifiers: modifiers, hasMedia: false) == nil,
            "Empty player does not consume pan key \(keyCode)")
    }
    check(resolve(keyCode) == nil, "Bare arrow key \(keyCode) keeps its original playback binding")
  }

  for commandSide in [UInt64(0), leftCommand, rightCommand, leftCommand | rightCommand] {
    check(resolve(29, modifiers: [.command, .shift], deviceFlags: commandSide) == .resetViewport,
          "Viewport reset accepts either Command key")
  }
  check(resolve(29, modifiers: [.command, .shift, .capsLock]) == .resetViewport,
        "Caps Lock preserves viewport reset")
  check(resolve(29, modifiers: [.command, .shift], isRepeat: true) == .consume,
        "Repeated viewport reset is consumed without resetting again")
  for modifiers: NSEvent.ModifierFlags in [[], .command, .shift, [.command, .shift, .option],
                                         [.command, .shift, .control], [.command, .shift, .numericPad],
                                         [.command, .shift, .function]] {
    check(resolve(29, modifiers: modifiers) == nil, "Viewport reset requires exactly Command and Shift")
  }
  check(resolve(29, modifiers: [.command, .shift], isTextInput: true) == nil,
        "Text entry prevents viewport reset")
  check(resolve(29, modifiers: [.command, .shift], isModal: true) == nil,
        "Modal UI prevents viewport reset")
  check(resolve(29, modifiers: [.command, .shift], hasMedia: false) == nil,
        "Empty player prevents viewport reset")

  let event = NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue | UInt(leftCommand)),
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "L",
    charactersIgnoringModifiers: "L",
    isARepeat: false,
    keyCode: 37
  )!
  check(VideoToolsShortcuts.resolve(event, hasMedia: true, isTextInput: false) == .rotateLeft,
        "NSEvent adapter preserves device-specific left Command flags")
  for (keyCode, action) in panShortcuts {
    let arrowEvent = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command, .shift, .numericPad, .function],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
      charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
      isARepeat: true,
      keyCode: keyCode
    )!
    check(VideoToolsShortcuts.resolve(arrowEvent, hasMedia: true, isTextInput: false) == action,
          "NSEvent adapter resolves repeated physical arrow key \(keyCode) with intrinsic AppKit flags")
  }
  let keyUp = NSEvent.keyEvent(
    with: .keyUp,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "c",
    charactersIgnoringModifiers: "c",
    isARepeat: false,
    keyCode: 8
  )!
  check(VideoToolsShortcuts.resolve(keyUp, hasMedia: true, isTextInput: false) == nil,
        "Key-up events do not run shortcuts")

  check(VideoToolsShortcuts.adjustedSpeed(from: 1, direction: .increase) == 1.1,
        "Speed increases from 1.0 to 1.1")
  check(VideoToolsShortcuts.adjustedSpeed(from: 1.1, direction: .increase) == 1.2,
        "Speed increases from 1.1 to 1.2 without drift")
  check(VideoToolsShortcuts.adjustedSpeed(from: 1, direction: .decrease) == 0.9,
        "Speed decreases from 1.0 to 0.9")
  check(VideoToolsShortcuts.adjustedSpeed(from: 0.9, direction: .decrease) == 0.8,
        "Speed decreases from 0.9 to 0.8 without drift")
  check(VideoToolsShortcuts.adjustedSpeed(from: 1.25, direction: .increase) == 1.35,
        "Arbitrary current speed keeps its fractional offset when increasing")
  check(VideoToolsShortcuts.adjustedSpeed(from: 1.25, direction: .decrease) == 1.15,
        "Arbitrary current speed keeps its fractional offset when decreasing")
  check(VideoToolsShortcuts.adjustedSpeed(from: 1.2000000000000002, direction: .increase) == 1.3,
        "Speed steps normalize insignificant binary conversion noise")
  check(VideoToolsShortcuts.adjustedSpeed(from: 16, direction: .increase) == 16,
        "Speed does not exceed 16")
  check(VideoToolsShortcuts.adjustedSpeed(from: 15.95, direction: .increase) == 16,
        "Near-maximum speed clamps to 16")
  check(VideoToolsShortcuts.adjustedSpeed(from: 0.1, direction: .decrease) == 0.1,
        "Speed does not drop below 0.1")
  check(VideoToolsShortcuts.adjustedSpeed(from: 0.15, direction: .decrease) == 0.1,
        "Near-minimum speed clamps to 0.1")
  for invalid in [Double.nan, Double.infinity, -Double.infinity] {
    check(VideoToolsShortcuts.adjustedSpeed(from: invalid, direction: .increase) == 1,
          "Invalid speed returns to normal playback")
  }
  var speed = 1.0
  for _ in 0..<10 { speed = VideoToolsShortcuts.adjustedSpeed(from: speed, direction: .increase) }
  check(speed == 2, "Ten speed increases reach exactly 2.0")
  for _ in 0..<10 { speed = VideoToolsShortcuts.adjustedSpeed(from: speed, direction: .decrease) }
  check(speed == 1, "Ten speed decreases return exactly to 1.0")

  check(VideoToolsPlaybackCommand.parse(["seek", "-5", "absolute", "exact"]) == .seek(-5, .absolute),
        "Legacy exact precision preserves negative absolute seek mode")
  check(VideoToolsPlaybackCommand.parse(["seek", "5", "relative", "keyframes"]) == .seek(5, .relative),
        "Legacy keyframe precision preserves relative seek mode")
  check(VideoToolsPlaybackCommand.parse(["seek", "5", "relative", "1"]) == nil,
        "Legacy precision cannot be mistaken for absolute percent mode")
  check(VideoToolsPlaybackCommand.parse(["seek", "5", "relative", "2"]) == nil,
        "Legacy precision cannot be mistaken for absolute timestamp mode")
  check(VideoToolsPlaybackCommand.parse(["seek", "5", "relative", "absolute"]) == nil,
        "A second seek mode is not accepted as legacy precision")
  check(VideoToolsPlaybackCommand.absoluteSeekTarget(-5, duration: 100) == 95,
        "Negative absolute seek is measured from the end of the file")
  check(VideoToolsPlaybackCommand.absoluteSeekTarget(-150, duration: 100) == 0,
        "Absolute seek before the beginning clamps to zero")
  check(VideoToolsPlaybackCommand.absoluteSeekTarget(95, duration: nil) == 95,
        "Positive absolute seek does not require a duration")
  check(VideoToolsPlaybackCommand.absoluteSeekTarget(-5, duration: nil) == nil,
        "Negative absolute seek defers to mpv if duration is unknown")
  check(VideoToolsPlaybackCommand.absoluteSeekTarget(-5, duration: -1) == nil,
        "Negative absolute seek rejects an invalid duration")
  for invalid in [Double.nan, Double.infinity, -Double.infinity] {
    check(VideoToolsPlaybackCommand.absoluteSeekTarget(invalid, duration: 100) == nil,
          "Absolute seek rejects a non-finite target")
    check(VideoToolsPlaybackCommand.absoluteSeekTarget(-5, duration: invalid) == nil,
          "Absolute seek rejects a non-finite duration")
  }
}
