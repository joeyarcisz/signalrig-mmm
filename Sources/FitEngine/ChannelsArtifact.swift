import Foundation

// Translates engine/model/posterior.py's channel_summaries() (:105-172,
// read-only reference the Python reference implementation) verbatim,
// including its exact grading thresholds and decision-hint text.
public struct ConfidenceInfo {
    public let grade: String
    public let basis: String

    public func toJSON() -> JSONValue {
        .object(["grade": .string(grade), "basis": .string(basis)])
    }
}

public struct ChannelSummary {
    public let key: String
    public let label: String
    public let platform: String
    public let spendWeeklyAvg: Double
    public let spendTotal: Double
    public let contributionShare: IntervalResult
    public let contributionLeadsWeekly: IntervalResult
    public let cpl: IntervalResult
    public let marginalCpl: IntervalResult
    public let saturationPct: Double
    public let adstockHalfLifeWeeks: Double
    public let confidence: ConfidenceInfo
    public let decisionHint: String

    public func toJSON() -> JSONValue {
        .object([
            "key": .string(key),
            "label": .string(label),
            "platform": .string(platform),
            "spend_weekly_avg": .double(spendWeeklyAvg),
            "spend_total": .double(spendTotal),
            "contribution_share": contributionShare.toJSON(),
            "contribution_leads_weekly": contributionLeadsWeekly.toJSON(),
            "cpl": cpl.toJSON(),
            "marginal_cpl": marginalCpl.toJSON(),
            "saturation_pct": .double(saturationPct),
            "adstock_half_life_weeks": .double(adstockHalfLifeWeeks),
            "confidence": confidence.toJSON(),
            "decision_hint": .string(decisionHint),
        ])
    }
}

public struct ChannelsArtifact {
    public let channels: [ChannelSummary]
    public let baselineShare: IntervalResult
    public let totalWeeklyLeadsMean: Double

    public func toJSON() -> JSONValue {
        .object([
            "channels": .array(channels.map { $0.toJSON() }),
            "baseline_share": baselineShare.toJSON(),
            "total_weekly_leads_mean": .double(totalWeeklyLeadsMean),
        ])
    }
}

public enum ChannelsArtifactBuilder {
    static func column(_ matrix: [[Double]], _ c: Int) -> [Double] {
        matrix.map { $0[c] }
    }

    // Confidence grading thresholds and basis text, copied verbatim from
    // posterior.py :134-140.
    static func grade(cplIv: IntervalResult) -> ConfidenceInfo {
        let ratio = cplIv.hi / max(cplIv.lo, 1e-9)
        let grade = ratio < 1.6 ? "high" : (ratio < 2.6 ? "medium" : "low")
        let basis: String
        switch grade {
        case "high": basis = "Strong spend variation in history; narrow posterior interval"
        case "medium": basis = "Moderate spend variation; interval is usable but not tight"
        default: basis = "Low historical spend or flighting gaps; the model says so instead of guessing"
        }
        return ConfidenceInfo(grade: grade, basis: basis)
    }

    // Decision-hint text and saturation thresholds, copied verbatim from
    // posterior.py :141-147.
    static func decisionHint(satPct: Double) -> String {
        if satPct > 55 {
            return "Approaching saturation \u{2014} next dollar buys less here."
        } else if satPct > 35 {
            return "Headroom remains; scale in measured steps."
        } else {
            return "Clear headroom \u{2014} strongest candidate for added spend."
        }
    }

    public static func build(view: PosteriorView) -> ChannelsArtifact {
        let R = view.refSpend
        let contrib = view.weeklyContributions()  // (S, T, C)
        let tailLen = min(52, view.T)
        let tailStart = view.T - tailLen

        // weekly[s][c] = mean over the last tailLen weeks (posterior.py
        // :112-113: "channel summaries report the RECENT picture").
        var weekly = Array(repeating: [Double](repeating: 0, count: view.C), count: view.S)
        for s in 0..<view.S {
            for c in 0..<view.C {
                var sum = 0.0
                for t in tailStart..<view.T { sum += contrib[s][t][c] }
                weekly[s][c] = sum / Double(tailLen)
            }
        }
        var shares = Array(repeating: [Double](repeating: 0, count: view.C), count: view.S)
        for s in 0..<view.S {
            var total = 0.0
            for c in 0..<view.C { total += weekly[s][c] }
            let denom = max(total, 1e-9)
            for c in 0..<view.C { shares[s][c] = weekly[s][c] / denom }
        }

        var channels: [ChannelSummary] = []
        for (ci, key) in view.channels.enumerated() {
            let leadsR = view.leadsChannel(ci, spend: R[ci])
            let cpl = leadsR.map { R[ci] / max($0, 1e-9) }

            let delta = max(R[ci] * 0.01, 1.0)
            let leadsRPlusDelta = view.leadsChannel(ci, spend: R[ci] + delta)
            let marginalLeads = zip(leadsRPlusDelta, leadsR).map { $0 - $1 }
            let marginalCpl = marginalLeads.map { delta / max($0, 1e-9) }

            let xRef = R[ci] / view.M[ci]
            var satArr = [Double](repeating: 0, count: view.S)
            for s in 0..<view.S {
                let xs = pow(xRef, view.slope[s][ci])
                let kapS = pow(view.kappa[s][ci], view.slope[s][ci])
                satArr[s] = xs / (kapS + xs)
            }
            let satPct = 100.0 * Percentile.percentile(satArr, 50)

            let halfLife = view.alpha.map { row -> Double in
                let a = min(max(row[ci], 1e-6), 1 - 1e-6)
                return log(0.5) / log(a)
            }

            let cplIv = Metrics.iv(cpl)
            let confidence = grade(cplIv: cplIv)
            let hint = decisionHint(satPct: satPct)

            channels.append(ChannelSummary(
                key: key,
                label: ChannelRegistry.label(forKey: key),
                platform: ChannelRegistry.platform(forKey: key),
                spendWeeklyAvg: roundTo(R[ci], 0),
                spendTotal: roundTo(column(view.X, ci).reduce(0, +), 0),
                contributionShare: Metrics.iv(column(shares, ci)),
                contributionLeadsWeekly: Metrics.iv(column(weekly, ci)),
                cpl: cplIv,
                marginalCpl: Metrics.iv(marginalCpl),
                saturationPct: roundTo(satPct, 1),
                adstockHalfLifeWeeks: roundTo(Percentile.percentile(halfLife, 50), 2),
                confidence: confidence,
                decisionHint: hint
            ))
        }

        let mediaWeekly = (0..<view.S).map { s in weekly[s].reduce(0, +) }
        let tailY = Array(view.y[tailStart..<view.T])
        let yWeekly = tailY.reduce(0, +) / Double(tailLen)
        let baselineShare = mediaWeekly.map { min(max(1.0 - $0 / max(yWeekly, 1e-9), 0.0), 1.0) }

        return ChannelsArtifact(
            channels: channels,
            baselineShare: Metrics.iv(baselineShare),
            totalWeeklyLeadsMean: roundTo(yWeekly, 1)
        )
    }
}
