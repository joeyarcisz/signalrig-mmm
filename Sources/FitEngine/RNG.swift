import Foundation

// Deterministic RNG for the metrics stage. SplitMix64 chosen over
// xoshiro256++ for a smaller, easier-to-audit implementation; numpy stream
// parity with grade.py's np.random.default_rng is NOT required (the
// task packet's tolerances account for a different RNG stream), only
// determinism for a given seed within this package.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return z
    }
}

public enum RNGUtil {
    // Partial Fisher-Yates: selects `k` distinct indices from 0..<n uniformly
    // at random without replacement, returned in ascending order. Matches
    // the packet's "choose min(800, S) distinct draw indices uniformly
    // without replacement, sorted ascending" requirement.
    public static func choiceWithoutReplacement(n: Int, k: Int, rng: inout SplitMix64) -> [Int] {
        var indices = Array(0..<n)
        let count = min(k, n)
        for i in 0..<count {
            guard n - i - 1 > 0 else { break }
            let j = i + Int.random(in: 0...(n - i - 1), using: &rng)
            indices.swapAt(i, j)
        }
        return Array(indices[0..<count]).sorted()
    }

    // 53-bit uniform double in [0, 1).
    public static func nextUniform(_ rng: inout SplitMix64) -> Double {
        Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    // Box-Muller (cosine branch), one standard normal per call from two
    // uniform draws; documented choice, not a numpy-parity requirement.
    public static func nextGaussian(_ rng: inout SplitMix64) -> Double {
        var u1 = 0.0
        repeat {
            u1 = nextUniform(&rng)
        } while u1 <= 0
        let u2 = nextUniform(&rng)
        let r = (-2.0 * log(u1)).squareRoot()
        let theta = 2.0 * Double.pi * u2
        return r * cos(theta)
    }
}
