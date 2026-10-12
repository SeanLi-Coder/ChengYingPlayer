import Foundation

enum Preference { enum SeekOption { case relative, exact, auto } }
enum Logger { enum Level { case debug, verbose } }
final class TimingInfo {
  struct State { var loaded = true }
  var state = State()
}
final class TimingPlayer {
  let info = TimingInfo()
  var videoToolsMediaGeneration: UInt64 = 1
  var useExactSeekForCurrentFile = true
}
final class SeekCommandBoundary {
  var commands: [[String?]] = []
  var generations: [UInt64?] = []
  // The previous production method uses these fields in the negative control.
  var needRecordSeekTime = false
  var recordedSeekTimeListener: ((Double) -> Void)?
  func command(_ command: MPVCommand, args: [String?], checkError: Bool,
               level: Logger.Level = .debug, seekTimingGeneration: UInt64? = nil) {
    commands.append(args)
    generations.append(seekTimingGeneration)
  }
}
