import Foundation

// Translates engine/model/posterior.py's PosteriorView class (:28-100,
// read-only reference at the Python reference implementation) verbatim:
// same steady-state response equations, operating on this package's own
// StanFit draws + PanelMeta instead of an arviz InferenceData + Panel.
//
// Subsampling is always disabled here (maxDraws: Int.max passed to
// Metrics.subsampleDraws), per the task packet's instruction that
// downstream artifact numbers be deterministic over the full draw set --
// unlike Python's PosteriorView, which subsamples to max_draws=800 by
// default. Every artifact this package emits is therefore graded against
// all 4000 posterior draws, matching how the goldens were generated
// (see goldens-artifacts/generate_goldens.py).
public struct PosteriorView {
    public let alpha: [[Double]]     // (S, C)
    public let kappa: [[Double]]     // (S, C)
    public let slope: [[Double]]     // (S, C)
    public let beta: [[Double]]      // (S, C)
    public let sigma: [Double]       // (S,)
    public let muScaled: [[Double]]  // (S, T)
    public let A: [[Double]]         // (S, C) asymptote weekly leads

    public let S: Int
    public let C: Int
    public let T: Int
    public let yMax: Double          // panel.y_scale
    public let M: [Double]           // panel.x_scale
    public let channels: [String]
    public let dates: [String]
    public let X: [[Double]]         // (T, C) raw weekly spend
    public let y: [Double]           // (T,) raw KPI
    public let refSpend: [Double]
    public let lMax: Int

    // Predictive noise gets its own deterministic stream derived from the
    // run seed, matching `self.noise_rng_seed = seed + 1` in
    // posterior.py :59. Two PosteriorViews built with the same seed
    // (e.g. the full-model and holdout-model views in run_all.py, both
    // seed=cfg.seed) therefore replay the identical eps stream when
    // .predictive() is called on each -- a property of the Python code
    // this port intentionally preserves, not a bug.
    public let noiseRNGSeed: UInt64

    public init(fit: StanFit, meta: PanelMeta, seed: UInt64 = 42) {
        let subset = Metrics.subsampleDraws(fit: fit, yScale: meta.yScale, maxDraws: Int.max, seed: seed)
        alpha = subset.alpha
        kappa = subset.kappa
        slope = subset.slope
        beta = subset.beta
        sigma = subset.sigma
        muScaled = subset.muScaled
        A = subset.A

        S = subset.alpha.count
        C = meta.channels.count
        T = meta.dates.count
        yMax = meta.yScale
        M = meta.xScale
        channels = meta.channels
        dates = meta.dates
        X = meta.xRaw
        y = meta.yRaw
        refSpend = meta.refSpend
        lMax = meta.lMax
        noiseRNGSeed = seed + 1
    }

    var drawsSubset: DrawsSubset {
        DrawsSubset(alpha: alpha, kappa: kappa, slope: slope, beta: beta, sigma: sigma, muScaled: muScaled, A: A)
    }

    // leads_at (posterior.py :68-71): steady-state weekly leads per draw
    // for every channel at a given spend vector, shape (S, C).
    public func leadsAt(_ spend: [Double]) -> [[Double]] {
        var out = Array(repeating: [Double](repeating: 0, count: C), count: S)
        for s in 0..<S {
            for c in 0..<C {
                let x = spend[c] / M[c]
                let xs = pow(max(x, 0.0), slope[s][c])
                let kapS = pow(kappa[s][c], slope[s][c])
                out[s][c] = A[s][c] * (xs / (kapS + xs))
            }
        }
        return out
    }

    // leads_channel (posterior.py :73-80), single-spend case: (S,) leads
    // for one channel at one spend value.
    public func leadsChannel(_ ci: Int, spend: Double) -> [Double] {
        let Mc = M[ci]
        var out = [Double](repeating: 0, count: S)
        for s in 0..<S {
            let x = spend / Mc
            let xs = pow(max(x, 0.0), slope[s][ci])
            let kapS = pow(kappa[s][ci], slope[s][ci])
            out[s] = A[s][ci] * (xs / (kapS + xs))
        }
        return out
    }

    // leads_channel (posterior.py :73-80), grid case: (S, G) leads for one
    // channel across a spend grid (used by curves_artifact's 41-point
    // linspace).
    public func leadsChannelGrid(_ ci: Int, spends: [Double]) -> [[Double]] {
        let Mc = M[ci]
        let G = spends.count
        var out = Array(repeating: [Double](repeating: 0, count: G), count: S)
        for s in 0..<S {
            for g in 0..<G {
                let x = spends[g] / Mc
                let xs = pow(max(x, 0.0), slope[s][ci])
                let kapS = pow(kappa[s][ci], slope[s][ci])
                out[s][g] = A[s][ci] * (xs / (kapS + xs))
            }
        }
        return out
    }

    // weekly_contributions (posterior.py :82-94): (S, T, C) weekly lead
    // contributions in natural units, adstock included. Delegates to the
    // existing Metrics.weeklyContributions kernel (identical math, already
    // parity-tested via the `grade` command's recovery computation).
    public func weeklyContributions() -> [[[Double]]] {
        Metrics.weeklyContributions(draws: drawsSubset, X: X, xScale: M, L: lMax)
    }

    // predictive (posterior.py :96-100): (S, T) posterior-predictive KPI
    // in natural units, from this view's own seeded noise stream. Returns
    // per-week 5/50/95 percentiles (every artifact caller only needs the
    // bands) via Metrics.predictiveSeries.
    public func predictiveSeries() -> (lo: [Double], med: [Double], hi: [Double]) {
        Metrics.predictiveSeries(draws: drawsSubset, yScale: yMax, seed: noiseRNGSeed)
    }
}
