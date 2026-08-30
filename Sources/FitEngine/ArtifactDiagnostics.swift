import Foundation

// Translates engine/model/posterior.py's diagnostics_artifact() (:360-415,
// the Python reference implementation) verbatim.
// rhat_max/ess_bulk_min/divergences come from this package's existing
// DiagnosticsCalc.compute (already ported and parity-tested against
// grade.py); the ppc/holdout SeriesPoint bands and mape/r2/coverage come
// from Metrics.predictiveSeries/errorStats (this file's own additions,
// added alongside this port). The predictive-noise stream is this
// package's own RNG (SplitMix64), not numpy's -- per the task packet,
// diagnostics parity tolerance on these seeded-noise-dependent fields
// covers that difference (mape +/-0.3, r2 +/-0.03, coverage +/-5.0, bands
// +/-5% med / +/-10% lo-hi relative per point).
public struct SeriesPoint {
    public let date: String
    public let actual: Double
    public let predMed: Double
    public let predLo: Double
    public let predHi: Double

    public func toJSON() -> JSONValue {
        .object([
            "date": .string(date),
            "actual": .double(actual),
            "pred_med": .double(predMed),
            "pred_lo": .double(predLo),
            "pred_hi": .double(predHi),
        ])
    }
}

public struct Gates {
    public let converged: Bool
    public let fitOk: Bool
    public let optimizerUnlocked: Bool

    public func toJSON() -> JSONValue {
        .object([
            "converged": .bool(converged),
            "fit_ok": .bool(fitOk),
            "optimizer_unlocked": .bool(optimizerUnlocked),
        ])
    }
}

public struct DiagnosticsArtifact {
    public let rhatMax: Double
    public let essBulkMin: Double  // float in Python's emitted JSON (round(ess_min)), not the grade command's plain Int
    public let divergences: Int
    public let mapeHoldoutPct: Double
    public let r2Holdout: Double
    public let coverage90Pct: Double
    public let holdoutWeeks: Int
    public let ppc: [SeriesPoint]
    public let holdout: [SeriesPoint]
    public let gates: Gates
    public let sampler: String
    public let draws: Int
    public let chains: Int

    public func toJSON() -> JSONValue {
        .object([
            "rhat_max": .double(rhatMax),
            "ess_bulk_min": .double(essBulkMin),
            "divergences": .int(divergences),
            "mape_holdout_pct": .double(mapeHoldoutPct),
            "r2_holdout": .double(r2Holdout),
            "coverage_90_pct": .double(coverage90Pct),
            "holdout_weeks": .int(holdoutWeeks),
            "ppc": .array(ppc.map { $0.toJSON() }),
            "holdout": .array(holdout.map { $0.toJSON() }),
            "gates": gates.toJSON(),
            "sampler": .string(sampler),
            "draws": .int(draws),
            "chains": .int(chains),
        ])
    }
}

public enum ArtifactDiagnosticsBuilder {
    // viewHoldout is required, not optional (frozen design decision 1: the
    // no-holdout "diagnostics skipped" artifact variant is removed
    // entirely -- every real fit that reaches this builder always ran the
    // 12-week holdout refit, so mape/r2/coverage below are always
    // computed from real numbers, never left as NaN placeholders that
    // later get silently zeroed or printed as the literal text "nan").
    public static func build(fitFull: StanFit, viewFull: PosteriorView, viewHoldout: PosteriorView, holdoutWeeks: Int) -> DiagnosticsArtifact {
        let diag = DiagnosticsCalc.compute(fit: fitFull)
        let T = viewFull.T

        let (loFull, medFull, hiFull) = viewFull.predictiveSeries()

        // ppc window: posterior.py :373-377 -- the 18 weeks immediately
        // before the holdout window, from the FULL model's own predictive.
        let ppcStart = max(0, T - holdoutWeeks - 18)
        let ppcEnd = T - holdoutWeeks
        var ppc: [SeriesPoint] = []
        if ppcStart < ppcEnd {
            for t in ppcStart..<ppcEnd {
                ppc.append(SeriesPoint(
                    date: viewFull.dates[t], actual: viewFull.y[t],
                    predMed: roundTo(medFull[t], 0), predLo: roundTo(loFull[t], 0), predHi: roundTo(hiFull[t], 0)
                ))
            }
        }

        let (loH, medH, hiH) = viewHoldout.predictiveSeries()
        let start = T - holdoutWeeks
        let idxRange = start..<T
        let actual = idxRange.map { viewFull.y[$0] }
        let medSub = idxRange.map { medH[$0] }
        let loSub = idxRange.map { loH[$0] }
        let hiSub = idxRange.map { hiH[$0] }

        let stats = Metrics.errorStats(actual: actual, predMed: medSub, predLo: loSub, predHi: hiSub)
        let mape = stats.mapePct
        let r2 = stats.r2
        let coverage = stats.coverage90Pct

        var holdoutSeries: [SeriesPoint] = []
        for t in idxRange {
            holdoutSeries.append(SeriesPoint(
                date: viewFull.dates[t], actual: viewFull.y[t],
                predMed: roundTo(medH[t], 0), predLo: roundTo(loH[t], 0), predHi: roundTo(hiH[t], 0)
            ))
        }

        // Gate thresholds copied verbatim from posterior.py :398-399.
        let converged = diag.rhatMax < 1.01 && diag.divergences <= 5
        let fitOk = !mape.isNaN && mape < 15.0
        let gates = Gates(converged: converged, fitOk: fitOk, optimizerUnlocked: converged && fitOk)

        let chains = fitFull.nChains
        let drawsPerChain = fitFull.chains.first?.nDraws ?? 0

        return DiagnosticsArtifact(
            rhatMax: diag.rhatMax,
            essBulkMin: Double(diag.essBulkMin),
            divergences: diag.divergences,
            mapeHoldoutPct: mape,
            r2Holdout: r2,
            coverage90Pct: coverage,
            holdoutWeeks: holdoutWeeks,
            ppc: ppc,
            holdout: holdoutSeries,
            gates: gates,
            sampler: "NUTS (\(chains) chains)",
            draws: drawsPerChain,
            chains: chains
        )
    }
}
