import Foundation

// Translates engine/model/posterior.py's diagnostics_artifact() (:360-415,
// read-only reference at the historical Python research engine).
// rhat_max/ess_bulk_min/divergences summarize BOTH full and holdout fits:
// worst R-hat, lowest ESS, and total divergences. The ppc/holdout bands
// and mape/r2/coverage come
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
            "quality_policy_version": .int(ArtifactConstants.qualityPolicyVersion),
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

public enum ArtifactDiagnosticsError: Error, CustomStringConvertible {
    case incompatiblePanels
    case unverifiedPreprocessing

    public var description: String {
        switch self {
        case .incompatiblePanels:
            return "full and holdout fits must describe the same panel with a valid held-out window"
        case .unverifiedPreprocessing:
            return "full and holdout views must carry preprocessing receipts for their own observed windows"
        }
    }
}

public enum ArtifactDiagnosticsBuilder {
    // Stan's diagnostic guidance recommends at least four chains, folded
    // rank R-hat below 1.01, and bulk ESS of at least 100 per chain.
    // Any divergent transition blocks a budget recommendation.
    // https://mc-stan.org/docs/2_39/cmdstan-guide/diagnose_utility.html
    static let minimumChains = 4
    static let minimumBulkESSPerChain = 100
    static let maximumRhat = 1.01

    static func makeGates(
        full: DiagnosticsResult, fullChains: Int,
        holdout: DiagnosticsResult, holdoutChains: Int,
        mapeHoldoutPct: Double, r2Holdout: Double, coverage90Pct: Double
    ) -> Gates {
        func trustworthy(_ diagnostics: DiagnosticsResult, chains: Int) -> Bool {
            chains >= minimumChains && diagnostics.rhatMax.isFinite && diagnostics.rhatMax > 0
                && diagnostics.rhatMax < maximumRhat
                && diagnostics.essBulkMin / max(chains, 1) >= minimumBulkESSPerChain
                && diagnostics.divergences == 0
        }
        let converged = trustworthy(full, chains: fullChains) && trustworthy(holdout, chains: holdoutChains)
        // Product withholding policy, not a claim of general calibration:
        // small percentage error alone can hide a worse-than-mean fit and
        // severe undercoverage. At 12 weeks, the coverage floor needs at
        // least 10 observed outcomes inside their nominal 90% intervals.
        let fitOk = mapeHoldoutPct.isFinite && mapeHoldoutPct >= 0 && mapeHoldoutPct < 15
            && r2Holdout.isFinite && r2Holdout > 0 && r2Holdout <= 1
            && coverage90Pct.isFinite && coverage90Pct >= 80 && coverage90Pct <= 100
        return Gates(converged: converged, fitOk: fitOk, optimizerUnlocked: converged && fitOk)
    }

    // viewHoldout is required, not optional (frozen design decision 1: the
    // no-holdout "diagnostics skipped" artifact variant is removed
    // entirely -- every real fit that reaches this builder always ran the
    // 12-week holdout refit, so mape/r2/coverage below are always
    // computed from real numbers, never left as NaN placeholders that
    // later get silently zeroed or printed as the literal text "nan").
    public static func build(fitFull: StanFit, fitHoldout: StanFit, viewFull: PosteriorView, viewHoldout: PosteriorView, holdoutWeeks: Int) throws -> DiagnosticsArtifact {
        guard fitFull.C == fitHoldout.C, fitFull.K == fitHoldout.K, fitFull.T == fitHoldout.T,
              viewFull.T == fitFull.T, viewHoldout.T == fitHoldout.T,
              viewFull.C == fitFull.C, viewHoldout.C == fitHoldout.C,
              viewFull.S == fitFull.totalDraws, viewHoldout.S == fitHoldout.totalDraws,
              viewFull.dates == viewHoldout.dates, viewFull.channels == viewHoldout.channels,
              holdoutWeeks > 0, holdoutWeeks < viewFull.T else {
            throw ArtifactDiagnosticsError.incompatiblePanels
        }
        func hasPreprocessing(_ view: PosteriorView, observedWeeks: Int, controls: Int) -> Bool {
            guard let preprocessing = view.preprocessing else { return false }
            return preprocessing.observedWeeks == observedWeeks
                && preprocessing.xScale == view.M && preprocessing.yScale == view.yMax
                && preprocessing.refSpend == view.refSpend
                && preprocessing.controlNames.count == controls
                && preprocessing.controlMean.count == controls && preprocessing.controlStd.count == controls
        }
        guard hasPreprocessing(viewFull, observedWeeks: fitFull.T, controls: fitFull.K),
              hasPreprocessing(viewHoldout, observedWeeks: fitHoldout.T - holdoutWeeks, controls: fitHoldout.K) else {
            throw ArtifactDiagnosticsError.unverifiedPreprocessing
        }
        try Grader.validateIndependentFits(full: fitFull, holdout: fitHoldout)
        let diag = try DiagnosticsCalc.compute(fit: fitFull)
        let holdoutDiag = try DiagnosticsCalc.compute(fit: fitHoldout)
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

        let gates = makeGates(
            full: diag, fullChains: fitFull.nChains,
            holdout: holdoutDiag, holdoutChains: fitHoldout.nChains,
            mapeHoldoutPct: mape, r2Holdout: r2, coverage90Pct: coverage
        )

        let chains = fitFull.nChains
        let drawsPerChain = fitFull.chains.first?.nDraws ?? 0

        return DiagnosticsArtifact(
            rhatMax: max(diag.rhatMax, holdoutDiag.rhatMax),
            essBulkMin: Double(min(diag.essBulkMin, holdoutDiag.essBulkMin)),
            divergences: diag.divergences + holdoutDiag.divergences,
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
