import Foundation

// Translates the local spike workspace/scripts/grade.py
// (read-only reference) verbatim: same formulas, operating on StanFit
// draws instead of cmdstanpy/arviz objects.

public struct IntervalResult {
    public let lo: Double
    public let med: Double
    public let hi: Double

    public func toJSON() -> JSONValue {
        .object(["lo": .double(lo), "med": .double(med), "hi": .double(hi)])
    }
}

public struct DrawsSubset {
    public let alpha: [[Double]]     // (S, C)
    public let kappa: [[Double]]     // (S, C)
    public let slope: [[Double]]     // (S, C)
    public let beta: [[Double]]      // (S, C)
    public let sigma: [Double]       // (S,)
    public let muScaled: [[Double]]  // (S, T)
    public let A: [[Double]]         // (S, C) = beta * y_scale
}

public struct TruthChannel {
    public let key: String
    public let trueCplAtRef: Double
    public let adstockHalfLifeWeeks: Double
    public let contributionShare: Double
    public let refWeeklySpend: Double
    // label/vendorClaimedCpl: only read by the artifacts port's
    // recovery_artifact (posterior.py :270-329), not by grade.py's
    // recovery grading (which only needs the four fields above). Default
    // label to the raw key and vendorClaimedCpl to nil when a truth file
    // omits them, so the existing `grade` CLI command (and its parity
    // test) is unaffected by this additive change.
    public let label: String
    public let vendorClaimedCpl: Double?

    public static func parse(_ json: JSONValue) -> TruthChannel? {
        guard let key = json["key"]?.asString,
              let cpl = json["true_cpl_at_ref"]?.asDouble,
              let hl = json["adstock_half_life_weeks"]?.asDouble,
              let share = json["contribution_share"]?.asDouble,
              let refSpend = json["ref_weekly_spend"]?.asDouble else { return nil }
        let label = json["label"]?.asString ?? key
        let vendorClaimedCpl = json["vendor_claimed_cpl"]?.asDouble
        return TruthChannel(key: key, trueCplAtRef: cpl, adstockHalfLifeWeeks: hl,
                             contributionShare: share, refWeeklySpend: refSpend,
                             label: label, vendorClaimedCpl: vendorClaimedCpl)
    }
}

public struct RecoveryParam {
    public let key: String
    public let metric: String
    public let unit: String
    public let trueValue: Double
    public let recovered: IntervalResult
    public let insideInterval: Bool

    public func toJSON() -> JSONValue {
        .object([
            "key": .string(key),
            "metric": .string(metric),
            "unit": .string(unit),
            "true_value": .double(trueValue),
            "recovered": recovered.toJSON(),
            "inside_interval": .bool(insideInterval),
        ])
    }
}

public struct RecoveryResult {
    public let params: [RecoveryParam]
    public let coverageRate: Double
    public let nParams: Int
    public let nInside: Int

    public func toJSON() -> JSONValue {
        .object([
            "params": .array(params.map { $0.toJSON() }),
            "coverage_rate": .double(coverageRate),
            "n_params": .int(nParams),
            "n_inside": .int(nInside),
        ])
    }
}

public struct HoldoutDiagnostics {
    public let mapePct: Double
    public let r2: Double
    public let coverage90Pct: Double
}

public enum Metrics {
    public static func iv(_ samples: [Double]) -> IntervalResult {
        let p = Percentile.percentiles(samples, [5, 50, 95])
        return IntervalResult(lo: p[0], med: p[1], hi: p[2])
    }

    // Subsample: min(maxDraws, S) distinct draw indices, uniform without
    // replacement, sorted ascending, seed 42 by convention (see RNG.swift
    // for the numpy-parity caveat: this package's RNG stream does not
    // reproduce numpy's, so a fixed seed value does not fix which subsample
    // results from it).
    //
    // maxDraws defaults to Int.max, which is always >= S, so by default this
    // is the identity: every draw is used, in its natural stacked order, and
    // the RNG is never invoked. This matches grade.py's own behavior when
    // max_draws >= S_total: `np.sort(rng.choice(S_total, size=S_total,
    // replace=False))` selects the full population, and sorting the full
    // population is just 0..S_total-1 regardless of draw order, so the
    // "subsample" is the identity there too. The bounded-subsample path
    // (maxDraws < S) is kept for callers that want a smaller, faster sample;
    // it is not used by the default grading path because comparing against
    // a golden produced from an independent RNG stream at less than the
    // full draw count only measures subsampling noise, not porting
    // correctness.
    public static func subsampleDraws(fit: StanFit, yScale: Double, maxDraws: Int = Int.max, seed: UInt64 = 42) -> DrawsSubset {
        let C = fit.C
        let T = fit.T

        let alphaFull = fit.stackedIndexed("adstock_alpha", count: C)
        let kappaFull = fit.stackedIndexed("hill_kappa", count: C)
        let slopeFull = fit.stackedIndexed("hill_slope", count: C)
        let betaFull = fit.stackedIndexed("channel_beta", count: C)
        let sigmaFull = fit.stackedColumn("sigma")
        let muFull = fit.stackedIndexed("mu_scaled", count: T)

        let sTotal = alphaFull.count
        let idx: [Int]
        if maxDraws >= sTotal {
            idx = Array(0..<sTotal) // identity: no RNG involved
        } else {
            var rng = SplitMix64(seed: seed)
            idx = RNGUtil.choiceWithoutReplacement(n: sTotal, k: maxDraws, rng: &rng)
        }

        let alpha = idx.map { alphaFull[$0] }
        let kappa = idx.map { kappaFull[$0] }
        let slope = idx.map { slopeFull[$0] }
        let beta = idx.map { betaFull[$0] }
        let sigma = idx.map { sigmaFull[$0] }
        let mu = idx.map { muFull[$0] }
        let A = beta.map { row in row.map { $0 * yScale } }

        return DrawsSubset(alpha: alpha, kappa: kappa, slope: slope, beta: beta, sigma: sigma, muScaled: mu, A: A)
    }

    // (S, T, C) weekly per-channel contribution to the KPI, in natural units.
    public static func weeklyContributions(draws: DrawsSubset, X: [[Double]], xScale: [Double], L: Int) -> [[[Double]]] {
        let T = X.count
        let C = xScale.count
        let S = draws.alpha.count

        var xNorm = Array(repeating: [Double](repeating: 0, count: C), count: T)
        for t in 0..<T {
            for c in 0..<C { xNorm[t][c] = X[t][c] / xScale[c] }
        }

        var contrib = Array(repeating: Array(repeating: [Double](repeating: 0, count: C), count: T), count: S)

        for s in 0..<S {
            var weights = Array(repeating: [Double](repeating: 0, count: C), count: L)
            for c in 0..<C {
                var wsum = 0.0
                for lag in 0..<L {
                    let w = pow(draws.alpha[s][c], Double(lag))
                    weights[lag][c] = w
                    wsum += w
                }
                for lag in 0..<L { weights[lag][c] /= wsum }
            }
            for t in 0..<T {
                for c in 0..<C {
                    var adstocked = 0.0
                    for lag in 0..<L where t - lag >= 0 {
                        adstocked += weights[lag][c] * xNorm[t - lag][c]
                    }
                    let xs = pow(max(adstocked, 0.0), draws.slope[s][c])
                    let kapS = pow(draws.kappa[s][c], draws.slope[s][c])
                    let sat = xs / (kapS + xs)
                    contrib[s][t][c] = sat * draws.A[s][c]
                }
            }
        }
        return contrib
    }

    static func computeShares(contrib: [[[Double]]]) -> (weekly: [[Double]], shares: [[Double]]) {
        let S = contrib.count
        let T = contrib.first?.count ?? 0
        let C = contrib.first?.first?.count ?? 0

        var weekly = Array(repeating: [Double](repeating: 0, count: C), count: S)
        for s in 0..<S {
            for c in 0..<C {
                var sum = 0.0
                for t in 0..<T { sum += contrib[s][t][c] }
                weekly[s][c] = sum / Double(T)
            }
        }
        var shares = Array(repeating: [Double](repeating: 0, count: C), count: S)
        for s in 0..<S {
            var total = 0.0
            for c in 0..<C { total += weekly[s][c] }
            let denom = max(total, 1e-9)
            for c in 0..<C { shares[s][c] = weekly[s][c] / denom }
        }
        return (weekly, shares)
    }

    static func leadsChannel(draws: DrawsSubset, xScale: [Double], channelIndex ci: Int, spend: Double) -> [Double] {
        let M = xScale[ci]
        let x = spend / M
        let S = draws.alpha.count
        var out = [Double](repeating: 0, count: S)
        for s in 0..<S {
            let xs = pow(max(x, 0.0), draws.slope[s][ci])
            let kapS = pow(draws.kappa[s][ci], draws.slope[s][ci])
            let sat = xs / (kapS + xs)
            out[s] = draws.A[s][ci] * sat
        }
        return out
    }

    public static func recovery(draws: DrawsSubset, meta: PanelMeta, truth: [TruthChannel], L: Int) -> RecoveryResult {
        var truthByKey: [String: TruthChannel] = [:]
        for t in truth { truthByKey[t.key] = t }

        let contrib = weeklyContributions(draws: draws, X: meta.xRaw, xScale: meta.xScale, L: L)
        let (_, shares) = computeShares(contrib: contrib)

        var params: [RecoveryParam] = []
        var nInside = 0

        for (ci, key) in meta.channels.enumerated() {
            guard let t = truthByKey[key] else { continue }

            let leadsRef = leadsChannel(draws: draws, xScale: meta.xScale, channelIndex: ci, spend: t.refWeeklySpend)
            let cplDraws = leadsRef.map { t.refWeeklySpend / max($0, 1e-9) }
            let cplIv = iv(cplDraws)
            let insideCpl = cplIv.lo <= t.trueCplAtRef && t.trueCplAtRef <= cplIv.hi

            let halfLife = draws.alpha.map { row -> Double in
                let a = min(max(row[ci], 1e-6), 1 - 1e-6)
                return log(0.5) / log(a)
            }
            let hlIv = iv(halfLife)
            let insideHl = hlIv.lo <= t.adstockHalfLifeWeeks && t.adstockHalfLifeWeeks <= hlIv.hi

            let shareCol = (0..<shares.count).map { shares[$0][ci] }
            let shareIv = iv(shareCol)
            let insideShare = shareIv.lo <= t.contributionShare && t.contributionShare <= shareIv.hi

            let entries: [(String, String, Double, IntervalResult, Bool)] = [
                ("cpl", "$/lead", t.trueCplAtRef, cplIv, insideCpl),
                ("adstock_half_life", "weeks", t.adstockHalfLifeWeeks, hlIv, insideHl),
                ("contribution_share", "share", t.contributionShare, shareIv, insideShare),
            ]
            for (metric, unit, trueV, rec, inside) in entries {
                params.append(RecoveryParam(key: key, metric: metric, unit: unit,
                                             trueValue: roundTo(trueV, 4), recovered: rec, insideInterval: inside))
                if inside { nInside += 1 }
            }
        }

        let nParams = params.count
        let coverageRate = nParams > 0 ? roundTo(Double(nInside) / Double(nParams), 3) : 0.0
        return RecoveryResult(params: params, coverageRate: coverageRate, nParams: nParams, nInside: nInside)
    }

    // Posterior-predictive draws for every week (S, T) from a seeded
    // gaussian noise stream, in natural units: (mu_scaled + sigma * eps) *
    // yScale, matching PosteriorView.predictive() in posterior.py :96-100.
    // Returns per-week 5/50/95 percentiles rather than the raw (S, T)
    // matrix, since every caller (holdoutDiagnostics below, and the
    // artifacts port's diagnostics_artifact) only needs the bands.
    public static func predictiveSeries(draws: DrawsSubset, yScale: Double, seed: UInt64) -> (lo: [Double], med: [Double], hi: [Double]) {
        let T = draws.muScaled.first?.count ?? 0
        let S = draws.muScaled.count

        var rng = SplitMix64(seed: seed)
        var pred = Array(repeating: [Double](repeating: 0, count: T), count: S)
        for s in 0..<S {
            for t in 0..<T {
                let eps = RNGUtil.nextGaussian(&rng)
                pred[s][t] = (draws.muScaled[s][t] + draws.sigma[s] * eps) * yScale
            }
        }

        var lo = [Double](repeating: 0, count: T)
        var med = [Double](repeating: 0, count: T)
        var hi = [Double](repeating: 0, count: T)
        for t in 0..<T {
            let col = (0..<S).map { pred[$0][t] }
            let p = Percentile.percentiles(col, [5, 50, 95])
            lo[t] = p[0]; med[t] = p[1]; hi[t] = p[2]
        }
        return (lo, med, hi)
    }

    // MAPE / R^2 / 90%-interval coverage of a predictive median (and
    // lo/hi band) against actuals, matching the tail of
    // diagnostics_artifact (posterior.py :386-391) and grade.py's
    // diagnostics() function. Shared by holdoutDiagnostics below and the
    // artifacts port's diagnostics_artifact.
    public static func errorStats(actual: [Double], predMed: [Double], predLo: [Double], predHi: [Double]) -> (mapePct: Double, r2: Double, coverage90Pct: Double) {
        let n = actual.count

        var mapeSum = 0.0
        for i in 0..<n { mapeSum += abs(actual[i] - predMed[i]) / max(actual[i], 1e-9) }
        let mape = roundTo(100.0 * mapeSum / Double(n), 2)

        var meanActual = 0.0
        for a in actual { meanActual += a }
        meanActual /= Double(n)
        var ssRes = 0.0
        var ssTot = 0.0
        for i in 0..<n {
            ssRes += (actual[i] - predMed[i]) * (actual[i] - predMed[i])
            ssTot += (actual[i] - meanActual) * (actual[i] - meanActual)
        }
        let r2 = roundTo(1.0 - ssRes / max(ssTot, 1e-9), 3)

        var coverCount = 0
        for i in 0..<n where actual[i] >= predLo[i] && actual[i] <= predHi[i] { coverCount += 1 }
        let coverage90 = roundTo(100.0 * Double(coverCount) / Double(n), 1)

        return (mape, r2, coverage90)
    }

    // Posterior predictive from the HOLDOUT-fit mu (params fit on the first
    // T-holdoutWeeks weeks, mu evaluated over the full panel), scored
    // against the actual KPI over the last holdoutWeeks weeks.
    public static func holdoutDiagnostics(drawsHoldout: DrawsSubset, yRaw: [Double], yScale: Double,
                                           holdoutWeeks: Int, seed: UInt64 = 43) -> HoldoutDiagnostics {
        let T = yRaw.count
        let (lo, med, hi) = predictiveSeries(draws: drawsHoldout, yScale: yScale, seed: seed)

        let startIdx = T - holdoutWeeks
        let actual = Array(yRaw[startIdx..<T])
        let m = Array(med[startIdx..<T])
        let loSub = Array(lo[startIdx..<T])
        let hiSub = Array(hi[startIdx..<T])

        let stats = errorStats(actual: actual, predMed: m, predLo: loSub, predHi: hiSub)
        return HoldoutDiagnostics(mapePct: stats.mapePct, r2: stats.r2, coverage90Pct: stats.coverage90Pct)
    }
}
