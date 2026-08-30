import Foundation

// Translates engine/model/posterior.py's scenarios_artifact() (:197-235,
// the Python reference implementation) verbatim.
// Row order matches Python's nested loops exactly (source outer, target
// middle, shift_pct inner, 1...24) since the consuming app does integer
// index lookups into the rows array.
public struct ScenarioRow {
    public let source: String
    public let target: String
    public let shiftPct: Int
    public let shiftDollars: Double
    public let deltaLeadsWeekly: IntervalResult
    public let pPositive: Double
    public let blendedCplAfter: Double

    public func toJSON() -> JSONValue {
        .object([
            "source": .string(source),
            "target": .string(target),
            "shift_pct": .int(shiftPct),
            "shift_dollars": .double(shiftDollars),
            "delta_leads_weekly": deltaLeadsWeekly.toJSON(),
            "p_positive": .double(pPositive),
            "blended_cpl_after": .double(blendedCplAfter),
        ])
    }
}

public struct ScenariosArtifact {
    public let referenceTotalWeeklySpend: Double
    public let shiftPctMin: Int
    public let shiftPctMax: Int
    public let rows: [ScenarioRow]
    public let optimalAllocation: OptimalAllocationResult

    public func toJSON() -> JSONValue {
        .object([
            "reference_total_weekly_spend": .double(referenceTotalWeeklySpend),
            "shift_pct_min": .int(shiftPctMin),
            "shift_pct_max": .int(shiftPctMax),
            "rows": .array(rows.map { $0.toJSON() }),
            "optimal_allocation": optimalAllocation.toJSON(),
        ])
    }
}

public enum ScenariosArtifactBuilder {
    public static func build(view: PosteriorView) -> ScenariosArtifact {
        let R = view.refSpend
        let totalWeekly = R.reduce(0, +)
        let baseLeads = view.leadsAt(R)  // (S, C)
        let baseTotal = (0..<view.S).map { s in baseLeads[s].reduce(0, +) }

        var rows: [ScenarioRow] = []
        rows.reserveCapacity(view.C * (view.C - 1) * 24)

        for si in 0..<view.C {
            let leadsSBase = (0..<view.S).map { baseLeads[$0][si] }
            for ti in 0..<view.C where ti != si {
                let leadsTBase = (0..<view.S).map { baseLeads[$0][ti] }
                for pct in 1...24 {
                    let deltaD = R[si] * Double(pct) / 100.0

                    let leadsTPlus = view.leadsChannel(ti, spend: R[ti] + deltaD)
                    let gain = zip(leadsTPlus, leadsTBase).map { $0 - $1 }

                    let leadsSMinus = view.leadsChannel(si, spend: max(R[si] - deltaD, 0.0))
                    let loss = zip(leadsSBase, leadsSMinus).map { $0 - $1 }

                    let delta = zip(gain, loss).map { $0 - $1 }
                    let totalAfter = zip(baseTotal, delta).map { $0 + $1 }

                    let deltaIv = Metrics.iv(delta)
                    let pPositive = Double(delta.filter { $0 > 0 }.count) / Double(delta.count)
                    let medTotalAfter = Percentile.percentile(totalAfter, 50)

                    rows.append(ScenarioRow(
                        source: view.channels[si],
                        target: view.channels[ti],
                        shiftPct: pct,
                        shiftDollars: roundTo(deltaD, 0),
                        deltaLeadsWeekly: deltaIv,
                        pPositive: roundTo(pPositive, 3),
                        blendedCplAfter: roundTo(totalWeekly / max(medTotalAfter, 1e-9), 2)
                    ))
                }
            }
        }

        let optimal = Optimizer.optimalAllocation(view: view, R: R)

        return ScenariosArtifact(
            referenceTotalWeeklySpend: roundTo(totalWeekly, 0),
            shiftPctMin: 1,
            shiftPctMax: 24,
            rows: rows,
            optimalAllocation: optimal
        )
    }
}
