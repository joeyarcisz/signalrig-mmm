import Foundation

// Translates engine/model/posterior.py's recovery_artifact() (:270-329)
// and unavailable_recovery_artifact() (:332-357), read-only reference at
// the Python reference implementation, verbatim. These are distinct
// types from Metrics.RecoveryResult/RecoveryParam (used by the existing
// `grade` CLI command, which mirrors grade.py's leaner shape): the
// artifact shape additionally carries "label" per param and the separate
// "cpl_comparison" table the app's recovery.json contract expects.
public struct RecoveryParamArtifact {
    public let key: String
    public let label: String
    public let metric: String
    public let unit: String
    public let trueValue: Double
    public let recovered: IntervalResult
    public let insideInterval: Bool

    public func toJSON() -> JSONValue {
        .object([
            "key": .string(key),
            "label": .string(label),
            "metric": .string(metric),
            "unit": .string(unit),
            "true_value": .double(trueValue),
            "recovered": recovered.toJSON(),
            "inside_interval": .bool(insideInterval),
        ])
    }
}

public struct CplComparisonRow {
    public let key: String
    public let label: String
    public let vendorClaimedCpl: Double?  // nil -> JSON null (vendor declined to benchmark)
    public let trueCpl: Double
    public let recoveredCpl: IntervalResult
    public let insideInterval: Bool

    public func toJSON() -> JSONValue {
        .object([
            "key": .string(key),
            "label": .string(label),
            "vendor_claimed_cpl": vendorClaimedCpl.map { JSONValue.double($0) } ?? .null,
            "true_cpl": .double(trueCpl),
            "recovered_cpl": recoveredCpl.toJSON(),
            "inside_interval": .bool(insideInterval),
        ])
    }
}

public struct RecoveryAvailableArtifact {
    public let isSynthetic: Bool
    public let dataDisclosure: String
    public let params: [RecoveryParamArtifact]
    public let cplComparison: [CplComparisonRow]
    public let coverageRate: Double
    public let nParams: Int
    public let nInside: Int
    public let note: String

    public func toJSON() -> JSONValue {
        .object([
            "available": .bool(true),
            "is_synthetic": .bool(isSynthetic),
            "data_disclosure": .string(dataDisclosure),
            "params": .array(params.map { $0.toJSON() }),
            "cpl_comparison": .array(cplComparison.map { $0.toJSON() }),
            "coverage_rate": .double(coverageRate),
            "n_params": .int(nParams),
            "n_inside": .int(nInside),
            "note": .string(note),
        ])
    }
}

public struct RecoveryUnavailableArtifact {
    public let reason: String
    public let dataDisclosure: String
    public let note: String

    public func toJSON() -> JSONValue {
        .object([
            "available": .bool(false),
            "is_synthetic": .bool(false),
            "reason": .string(reason),
            "data_disclosure": .string(dataDisclosure),
            "params": .array([]),
            "cpl_comparison": .array([]),
            // JSON null, not NaN: NaN survives Python's json.dumps/loads
            // round-trip but is not valid JSON and breaks strict parsers
            // such as the consuming app's JS JSON.parse (posterior.py's
            // own docstring for unavailable_recovery_artifact makes this
            // exact point at :342-344).
            "coverage_rate": .null,
            "n_params": .int(0),
            "n_inside": .int(0),
            "note": .string(note),
        ])
    }
}

public enum RecoveryArtifactBuilder {
    public static func build(view: PosteriorView, truth: [TruthChannel]) -> RecoveryAvailableArtifact {
        var truthByKey: [String: TruthChannel] = [:]
        for t in truth { truthByKey[t.key] = t }

        // recovery_artifact averages contributions over the FULL window
        // (posterior.py :274: "over full window"), unlike channel_summaries'
        // last-52-weeks tail -- a deliberate difference documented in the
        // Python source, ported as-is.
        let contrib = view.weeklyContributions()  // (S, T, C)
        var weekly = Array(repeating: [Double](repeating: 0, count: view.C), count: view.S)
        for s in 0..<view.S {
            for c in 0..<view.C {
                var sum = 0.0
                for t in 0..<view.T { sum += contrib[s][t][c] }
                weekly[s][c] = sum / Double(view.T)
            }
        }
        var shares = Array(repeating: [Double](repeating: 0, count: view.C), count: view.S)
        for s in 0..<view.S {
            var total = 0.0
            for c in 0..<view.C { total += weekly[s][c] }
            let denom = max(total, 1e-9)
            for c in 0..<view.C { shares[s][c] = weekly[s][c] / denom }
        }

        var params: [RecoveryParamArtifact] = []
        var cplRows: [CplComparisonRow] = []
        var nInside = 0

        for (ci, key) in view.channels.enumerated() {
            guard let t = truthByKey[key] else { continue }

            let sRef = t.refWeeklySpend
            let leadsRef = view.leadsChannel(ci, spend: sRef)
            let cplDraws = leadsRef.map { sRef / max($0, 1e-9) }
            let cplIv = Metrics.iv(cplDraws)
            let insideCpl = cplIv.lo <= t.trueCplAtRef && t.trueCplAtRef <= cplIv.hi

            let halfLife = view.alpha.map { row -> Double in
                let a = min(max(row[ci], 1e-6), 1 - 1e-6)
                return log(0.5) / log(a)
            }
            let hlIv = Metrics.iv(halfLife)
            let insideHl = hlIv.lo <= t.adstockHalfLifeWeeks && t.adstockHalfLifeWeeks <= hlIv.hi

            let shareCol = (0..<view.S).map { shares[$0][ci] }
            let shareIv = Metrics.iv(shareCol)
            let insideShare = shareIv.lo <= t.contributionShare && t.contributionShare <= shareIv.hi

            let entries: [(String, String, Double, IntervalResult, Bool)] = [
                ("cpl", "$/lead", t.trueCplAtRef, cplIv, insideCpl),
                ("adstock_half_life", "weeks", t.adstockHalfLifeWeeks, hlIv, insideHl),
                ("contribution_share", "share", t.contributionShare, shareIv, insideShare),
            ]
            for (metric, unit, trueV, rec, inside) in entries {
                params.append(RecoveryParamArtifact(
                    key: key, label: t.label, metric: metric, unit: unit,
                    trueValue: roundTo(trueV, 4), recovered: rec, insideInterval: inside
                ))
                if inside { nInside += 1 }
            }

            cplRows.append(CplComparisonRow(
                key: key, label: t.label, vendorClaimedCpl: t.vendorClaimedCpl,
                trueCpl: roundTo(t.trueCplAtRef, 2), recoveredCpl: cplIv, insideInterval: insideCpl
            ))
        }

        let nParams = params.count
        let coverageRate = nParams > 0 ? roundTo(Double(nInside) / Double(nParams), 3) : 0.0

        return RecoveryAvailableArtifact(
            isSynthetic: true,
            dataDisclosure: ArtifactConstants.disclosure,
            params: params,
            cplComparison: cplRows,
            coverageRate: coverageRate,
            nParams: nParams,
            nInside: nInside,
            note: "Generated and fitted under the same model family \u{2014} a fair parameter-recovery exam, said plainly. Real-data receipts are the holdout error, interval coverage, and posterior predictive checks."
        )
    }

    public static func buildUnavailable(reason: String = "no ground truth for real data") -> RecoveryUnavailableArtifact {
        RecoveryUnavailableArtifact(
            reason: reason,
            dataDisclosure: "Fitted on the client data package \u{2014} no hidden ground truth exists for real data.",
            note: "Receipts for real data are the holdout error, interval coverage, and posterior predictive checks."
        )
    }
}
