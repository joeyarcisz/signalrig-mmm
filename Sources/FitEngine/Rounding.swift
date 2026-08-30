import Foundation

// Python's round() uses round-half-to-even with correctly-rounded decimal
// string conversion; this uses round-half-away-from-zero on the scaled
// value instead. The two differ only on an exact tie at the target decimal
// digit, which does not occur for values derived from continuous posterior
// draws, so this is safe under the packet's tolerance-based parity checks.
public func roundTo(_ x: Double, _ digits: Int) -> Double {
    if x.isNaN || x.isInfinite { return x }
    let factor = pow(10.0, Double(digits))
    return (x * factor).rounded(.toNearestOrAwayFromZero) / factor
}

public func roundToInt(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    return Int(x.rounded(.toNearestOrAwayFromZero))
}
