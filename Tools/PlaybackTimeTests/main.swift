import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
}

check(VideoTime(59.9996).stringRepresentationWithPrecision(3) == "01:00.000",
      "Fractional rounding carries into minutes")
check(VideoTime(3599.9996).stringRepresentationWithPrecision(3) == "1:00:00.000",
      "Fractional rounding carries into hours")
check(VideoTime(VideoTime(3599.9996).stringRepresentationWithPrecision(3))?.second == 3600,
      "A normalized jump-dialog timestamp parses back to the rounded time")
for (precision, value) in [(UInt(1), 59.96), (UInt(2), 59.996), (UInt(3), 59.9996)] {
  check(VideoTime(value).stringRepresentationWithPrecision(precision) == "01:00." + String(repeating: "0", count: Int(precision)),
        "Each supported fractional precision normalizes seconds")
}
for (value, expected) in [(0.0, "00:00"), (0.5, "00:00"), (0.51, "00:01"),
                          (59.5, "00:59"), (59.51, "01:00"), (3600.0, "1:00:00")] {
  check(VideoTime(value).stringRepresentation == expected, "Whole seconds retain half-down rounding")
}
check(VideoTime(12.345).stringRepresentationWithPrecision(3) == "00:12.345", "Millisecond precision is retained")
check(VideoTime(61.234).stringRepresentationWithPrecision(2) == "01:01.23", "Fractional seconds are zero padded")
check(VideoTime(-61.234).stringRepresentationWithPrecision(2) == "-01:01.23", "Negative times have one leading sign")
check(VideoTime.infinite.stringRepresentation == "End", "The existing end sentinel is retained")
for precision in [UInt(4), UInt.max] {
  check(VideoTime(59.51).stringRepresentationWithPrecision(precision) == "01:00", "Unsupported precision falls back safely")
}
for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), Double(Int.min)] {
  for precision in [UInt(0), 1, 2, 3] {
    check(VideoTime(value).stringRepresentationWithPrecision(precision) == "--:--", "Invalid or unrepresentable time does not crash")
  }
}
for (input, expected) in [("20:35", 1235.0), ("1:02:03.456", 3723.456), ("90", 90.0),
                          (" 00:05.25\n", 5.25), ("90:00", 5400.0), ("-1:30", -90.0),
                          ("-5", -5.0), ("+1:30", 90.0), ("0", 0.0)] {
  check(VideoTime(input)?.second == expected, "Valid time input is parsed completely: \(input)")
}
for input in ["", " ", "bad", "bad:30", "1:bad", "1::2", ":1", "1:", "1:2:3:4",
              "nan", "inf", "-inf", "1:nan", "1:inf", "1:-3", "1:+3", "1:2.5:3", "1e999"] {
  check(VideoTime(input) == nil, "Malformed time is rejected instead of seeking elsewhere: \(input)")
}
check(VideoTime(1.0001) == VideoTime(1.0009), "Equality retains millisecond truncation")
check(VideoTime(1.0009) < VideoTime(1.0011), "Ordering retains millisecond precision")
check(VideoTime(1e20) < VideoTime(2e20), "Large finite comparisons cannot overflow Int")
check(VideoTime(1e305) < VideoTime(1e306), "Ordering is stable across the millisecond overflow boundary")
check(VideoTime(1e307) < VideoTime(2e307), "Distinct extreme finite values remain ordered")
check(VideoTime(1e307) != VideoTime(2e307), "Extreme finite values do not both compare as infinity")
check(!(VideoTime(.nan) == VideoTime(0)), "Invalid times do not compare equal to zero")
check(VideoTime(Int.max, Int.max, 0).second.isFinite, "Hour and minute arithmetic cannot overflow Int")
let position: VideoTime? = VideoTime(5)
check(position / VideoTime(10) == 0.5, "Valid progress is retained")
for duration in [0.0, -1, .nan, .infinity] {
  check(position / VideoTime(duration) == nil, "Invalid durations cannot produce invalid progress")
}
check(VideoTime(.infinity) / VideoTime(10) == nil, "Invalid position cannot produce invalid progress")
check(position / nil == nil, "Missing duration has no progress")
print("Playback time checks passed: \(checks)")
