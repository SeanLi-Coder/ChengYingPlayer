//
//  SimpleTime.swift
//  iina
//
//  Created by lhc on 25/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Foundation

class VideoTime {
  static let infinite = VideoTime(999, 0, 0)
  static let zero = VideoTime(0)

  var second: Double

  var stringRepresentation: String {
    stringRepresentationWithPrecision(0)
  }

  /// Return this time as a string with the given precision.
  ///
  /// The value of the `precision` parameter controls the number of fractional digits in the seconds portion of the returned time
  /// string and is interpreted as follows:
  /// | Value | Precision |
  /// | --- | --- |
  /// | 0 | 1 second  |
  /// | 1 | 100 milliseconds |
  /// | 2 | 10 milliseconds |
  /// | 3 | 1 millisecond |
  /// - Important: The time is also displayed in the macOS
  ///     [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac)
  ///     Now Playing module. Now Playing uses 1 second precision. When the IINA OSC is also configured to use 1 second precision
  ///     it is important that the times displayed match. This means IINA **must** use the same rounding method that Now Playing
  ///     uses, [rounding half down](https://en.wikipedia.org/wiki/Rounding#Rounding_half_down).  IINA must
  ///     round 0.5 to 0 and 0.51 to 1.
  /// - Parameter precision: Precision to use for the seconds portion of the returned string.
  /// - Returns: A string containing the time in the format "hh:mm:ss.sss", with the number of digits in the fraction controlled by the
  ///     precision parameter.
  func stringRepresentationWithPrecision(_ precision: UInt) -> String {
    if self == Constants.Time.infinite {
      return "End"
    }

    // Whether to include fractional seconds.
    let precise = precision >= 1 && precision <= 3

    // Round the complete time before splitting it. Rounding only the seconds field can
    // otherwise display 00:60.000 and hand an incorrect value back to the jump dialog.
    let scale = precise ? Int(pow(10, Double(precision))) : 1
    let rounded = precise ? (second * Double(scale)).rounded(.toNearestOrEven) : second.roundedHalfDown()
    guard let signedTicks = Int(exactly: rounded), signedTicks != Int.min else { return "--:--" }
    let ticks = abs(signedTicks)
    let wholeSeconds = ticks / scale
    let h = wholeSeconds / 3600
    let remaining = wholeSeconds % 3600
    let m = remaining / 60

    let h_ = h > 0 ? "\(h):" : ""
    let m_ = m < 10 ? "0\(m)" : "\(m)"
    let s = remaining % 60
    var s_ = s < 10 ? "0\(s)" : "\(s)"
    if precise {
      let fraction = String(ticks % scale)
      s_ += "." + String(repeating: "0", count: Int(precision) - fraction.count) + fraction
    }

    return (signedTicks < 0 ? "-" : "") + h_ + m_ + ":" + s_
  }

  convenience init?(_ format: String) {
    var input = format.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = input.first == "-"
    if negative || input.first == "+" { input.removeFirst() }
    let fields = input.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty }),
          let secondsField = fields.last,
          secondsField.first != "-", secondsField.first != "+",
          let seconds = Double(secondsField), seconds.isFinite, seconds >= 0 else { return nil }

    var total = 0.0
    for field in fields.dropLast() {
      guard field.allSatisfy({ $0.isASCII && $0.isNumber }),
            let value = Double(field), value.isFinite else { return nil }
      total = total * 60 + value
    }
    total = total * 60 + seconds
    guard total.isFinite else { return nil }
    self.init(negative ? -total : total)
  }

  init(_ second: Double) {
    self.second = second

  }

  init(_ hour: Int, _ minute: Int, _ second: Double) {
    self.second = Double(hour) * 3600 + Double(minute) * 60 + second
  }

  /** whether self in [min, max) */
  func between(_ min: VideoTime, _ max: VideoTime) -> Bool {
    return self >= min && self < max
  }

}

extension VideoTime: Comparable { }

private func comparableSeconds(_ value: Double) -> Double {
  let milliseconds = value * 1000
  return milliseconds.isFinite ? milliseconds.rounded(.towardZero) / 1000 : value
}

func <(lhs: VideoTime, rhs: VideoTime) -> Bool {
  // ignore additional digits and compare the time in milliseconds
  return comparableSeconds(lhs.second) < comparableSeconds(rhs.second)
}

func ==(lhs: VideoTime, rhs: VideoTime) -> Bool {
  // ignore additional digits and compare the time in milliseconds
  return comparableSeconds(lhs.second) == comparableSeconds(rhs.second)
}

func *(lhs: VideoTime, rhs: Double) -> VideoTime {
  return VideoTime(lhs.second * rhs)
}

func /(lhs: VideoTime?, rhs: VideoTime?) -> Double? {
  if let lhs = lhs, let rhs = rhs, lhs.second.isFinite, rhs.second.isFinite, rhs.second > 0 {
    let result = lhs.second / rhs.second
    return result.isFinite ? result : nil
  } else {
    return nil
  }
}

func -(lhs: VideoTime, rhs: VideoTime) -> VideoTime {
  return VideoTime(lhs.second - rhs.second)
}
