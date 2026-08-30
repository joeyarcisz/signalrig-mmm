import Foundation

// Translates engine/model/posterior.py's curves_artifact() (:175-194,
// the Python reference implementation) verbatim.
public struct CurvePoint {
    public let spend: Double
    public let leadsMed: Double
    public let leadsLo: Double
    public let leadsHi: Double

    public func toJSON() -> JSONValue {
        .object([
            "spend": .double(spend),
            "leads_med": .double(leadsMed),
            "leads_lo": .double(leadsLo),
            "leads_hi": .double(leadsHi),
        ])
    }
}

public struct ChannelCurve {
    public let key: String
    public let label: String
    public let currentSpend: Double
    public let points: [CurvePoint]

    public func toJSON() -> JSONValue {
        .object([
            "key": .string(key),
            "label": .string(label),
            "current_spend": .double(currentSpend),
            "points": .array(points.map { $0.toJSON() }),
        ])
    }
}

public struct CurvesArtifact {
    public let channels: [ChannelCurve]
    public let intervalLevel: Double

    public func toJSON() -> JSONValue {
        .object([
            "channels": .array(channels.map { $0.toJSON() }),
            "interval_level": .double(intervalLevel),
        ])
    }
}

public enum CurvesArtifactBuilder {
    // np.linspace(lo, hi, n): n evenly spaced points from lo to hi
    // inclusive (endpoint=True, numpy's default).
    static func linspace(_ lo: Double, _ hi: Double, _ n: Int) -> [Double] {
        guard n > 1 else { return [lo] }
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + step * Double($0) }
    }

    public static func build(view: PosteriorView) -> CurvesArtifact {
        var channels: [ChannelCurve] = []
        for (ci, key) in view.channels.enumerated() {
            let rCi = view.refSpend[ci]
            let grid = linspace(0.0, 2.5 * rCi, 41)
            let leads = view.leadsChannelGrid(ci, spends: grid)  // (S, 41)

            var points: [CurvePoint] = []
            points.reserveCapacity(grid.count)
            for g in 0..<grid.count {
                let col = (0..<view.S).map { leads[$0][g] }
                let p = Percentile.percentiles(col, [5, 50, 95])
                points.append(CurvePoint(
                    spend: roundTo(grid[g], 0),
                    leadsMed: roundTo(p[1], 2),
                    leadsLo: roundTo(p[0], 2),
                    leadsHi: roundTo(p[2], 2)
                ))
            }

            channels.append(ChannelCurve(key: key, label: ChannelRegistry.label(forKey: key), currentSpend: roundTo(rCi, 0), points: points))
        }
        return CurvesArtifact(channels: channels, intervalLevel: 0.9)
    }
}
