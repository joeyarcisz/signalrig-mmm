import Foundation

// numpy's default percentile method ("linear" interpolation).
public enum Percentile {
    public static func percentile(_ values: [Double], _ q: Double) -> Double {
        percentileSorted(values.sorted(), q)
    }

    public static func percentileSorted(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        precondition(n > 0, "percentile of empty array")
        if n == 1 { return sorted[0] }
        let p = (q / 100.0) * Double(n - 1)
        let lo = Int(p.rounded(.down))
        if lo >= n - 1 { return sorted[n - 1] }
        let frac = p - Double(lo)
        return sorted[lo] + frac * (sorted[lo + 1] - sorted[lo])
    }

    public static func percentiles(_ values: [Double], _ qs: [Double]) -> [Double] {
        let sorted = values.sorted()
        return qs.map { percentileSorted(sorted, $0) }
    }
}
