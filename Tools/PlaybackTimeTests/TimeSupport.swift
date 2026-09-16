import Foundation

enum Constants {
  enum Time {
    static let infinite = VideoTime(999, 0, 0)
  }
}

extension Double {
  func roundedHalfDown() -> Double {
    let lower = floor(self)
    return self <= lower + 0.5 ? lower : ceil(self)
  }
}
