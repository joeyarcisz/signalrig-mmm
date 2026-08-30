import Foundation

// Split rank-normalized R-hat and bulk ESS, per Vehtari, Gelman, Simpson,
// Carpenter, Burkner (2021). This implements the BULK statistic only (rank
// normalize raw draws, classic R-hat formula on split chains) as specified
// in the task packet section 3f; it does not compute the tail-folded
// R-hat that CmdStan's stansummary additionally maxes against, since the
// packet's formula definition is explicit and does not mention folding.
public struct DiagnosticsResult {
    public let rhatMax: Double
    public let essBulkMin: Int
    public let divergences: Int
}

public enum DiagnosticsCalc {
    // Scalar (non-vector-of-weeks) posterior columns, in CmdStan's 1-based
    // dot-indexed naming. Excludes lp__ (sampler bookkeeping) and
    // media_scaled.*/mu_scaled.* (T-length per-week vectors, not scalars).
    public static func scalarColumnNames(C: Int, K: Int) -> [String] {
        var names: [String] = []
        names += (1...C).map { "adstock_alpha.\($0)" }
        names += (1...C).map { "hill_kappa.\($0)" }
        names += (1...C).map { "hill_slope.\($0)" }
        names += (1...C).map { "channel_beta.\($0)" }
        names.append("intercept")
        names.append("trend")
        names += (1...4).map { "fourier_beta.\($0)" }
        if K > 0 {
            names += (1...K).map { "control_gamma.\($0)" }
        }
        names.append("sigma")
        return names
    }

    public static func compute(fit: StanFit) -> DiagnosticsResult {
        let names = scalarColumnNames(C: fit.C, K: fit.K)
        var rhatMax = -Double.infinity
        var essMin = Double.infinity

        for name in names {
            let perChain = fit.chains.map { $0.columns[name] ?? [] }
            guard perChain.allSatisfy({ !$0.isEmpty }) else { continue }

            let allValues = perChain.flatMap { $0 }
            // Constant-column guard (packet section 3f): Stan itself would
            // report NaN here; instead treat R-hat as 1 and ESS as the full
            // raw draw count, and still include it in the running min/max
            // (documented choice: "use S as ESS" rather than skipping).
            let isConstant = allValues.allSatisfy { $0 == allValues[0] }
            if isConstant {
                rhatMax = max(rhatMax, 1.0)
                essMin = min(essMin, Double(allValues.count))
                continue
            }

            let z = rankNormalize(allValues)
            var zPerChain: [[Double]] = []
            zPerChain.reserveCapacity(perChain.count)
            var offset = 0
            for chain in perChain {
                zPerChain.append(Array(z[offset..<(offset + chain.count)]))
                offset += chain.count
            }
            let split = splitChains(zPerChain)
            let rhat = classicRhat(split)
            let ess = bulkESS(split)

            rhatMax = max(rhatMax, rhat)
            essMin = min(essMin, ess)
        }

        if rhatMax == -Double.infinity { rhatMax = 1.0 }
        if essMin == Double.infinity { essMin = Double(fit.totalDraws) }

        return DiagnosticsResult(
            rhatMax: roundTo(rhatMax, 4),
            essBulkMin: roundToInt(essMin),
            divergences: fit.divergences
        )
    }

    // MARK: - Rank normalization

    // Averaged ranks (1-based, ties share the mean rank of their group).
    static func averageRanks(_ values: [Double]) -> [Double] {
        let n = values.count
        let order = (0..<n).sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && values[order[j + 1]] == values[order[i]] {
                j += 1
            }
            let avgRank = Double(i + 1 + j + 1) / 2.0
            for k in i...j { ranks[order[k]] = avgRank }
            i = j + 1
        }
        return ranks
    }

    // z = Phi^-1((rank - 3/8) / (N + 1/4)), the rank-normalization transform
    // from Vehtari et al. 2021, section 4.1.
    static func rankNormalize(_ values: [Double]) -> [Double] {
        let n = values.count
        let ranks = averageRanks(values)
        return ranks.map { r in inverseNormalCDF((r - 3.0 / 8.0) / (Double(n) + 1.0 / 4.0)) }
    }

    // Peter J. Acklam's rational approximation to the inverse standard
    // normal CDF; accurate to about 1.15e-9 relative error, ample for the
    // packet's rhat (0.01 absolute) and ESS (20% relative) tolerances.
    static func inverseNormalCDF(_ p: Double) -> Double {
        let a: [Double] = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                             1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b: [Double] = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                             6.680131188771972e+01, -1.328068155288572e+01]
        let c: [Double] = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                            -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d: [Double] = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                            3.754408661907416e+00]
        let pLow = 0.02425
        let pHigh = 1 - pLow

        if p <= 0 { return -Double.infinity }
        if p >= 1 { return Double.infinity }

        if p < pLow {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                   ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= pHigh {
            let q = p - 0.5
            let r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                   (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                    ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
    }

    // MARK: - Split chains

    // Splits each chain into first/second halves. For odd chain length n,
    // the middle draw is dropped (first gets floor(n/2), second gets the
    // trailing floor(n/2)); not exercised by the fixtures (n is always even).
    static func splitChains(_ perChain: [[Double]]) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(perChain.count * 2)
        for chain in perChain {
            let n = chain.count
            let half = n / 2
            out.append(Array(chain[0..<half]))
            out.append(Array(chain[(n - half)..<n]))
        }
        return out
    }

    // MARK: - Classic R-hat

    // sqrt((W*(n-1)/n + B/n) / W) over m split chains of length n each.
    static func classicRhat(_ chains: [[Double]]) -> Double {
        let m = chains.count
        guard m > 0, let n = chains.first?.count, n > 1 else { return 1.0 }

        var chainMeans = [Double](repeating: 0, count: m)
        var chainVars = [Double](repeating: 0, count: m)
        for (i, chain) in chains.enumerated() {
            let mean = chain.reduce(0, +) / Double(n)
            var v = 0.0
            for x in chain { v += (x - mean) * (x - mean) }
            v /= Double(n - 1) // sample variance, ddof 1
            chainMeans[i] = mean
            chainVars[i] = v
        }
        let W = chainVars.reduce(0, +) / Double(m)
        if W <= 0 { return 1.0 } // constant-column guard

        var B = 0.0
        if m > 1 {
            let grandMean = chainMeans.reduce(0, +) / Double(m)
            var between = 0.0
            for mu in chainMeans { between += (mu - grandMean) * (mu - grandMean) }
            B = Double(n) * between / Double(m - 1)
        }
        let varPlus = (Double(n - 1) / Double(n)) * W + B / Double(n)
        return (varPlus / W).squareRoot()
    }

    // MARK: - Bulk ESS (autocorrelation + Geyer's initial monotone sequence)

    // Biased autocovariance (denominator n, not n - lag), the same quantity
    // Stan computes via FFT for speed; computed directly here since
    // per-chain draw counts are small (hundreds), which is mathematically
    // identical up to floating-point rounding.
    static func autocovariance(_ x: [Double]) -> [Double] {
        let n = x.count
        let mean = x.reduce(0, +) / Double(n)
        var acov = [Double](repeating: 0, count: n)
        for lag in 0..<n {
            var s = 0.0
            for i in 0..<(n - lag) {
                s += (x[i] - mean) * (x[i + lag] - mean)
            }
            acov[lag] = s / Double(n)
        }
        return acov
    }

    static func bulkESS(_ chains: [[Double]]) -> Double {
        let m = chains.count
        guard m > 0, let n = chains.first?.count, n > 3 else {
            return Double(chains.reduce(0) { $0 + $1.count })
        }

        var acov = Array(repeating: [Double](repeating: 0, count: n), count: m)
        var chainMeans = [Double](repeating: 0, count: m)
        var chainVars = [Double](repeating: 0, count: m)
        for c in 0..<m {
            let a = autocovariance(chains[c])
            acov[c] = a
            chainMeans[c] = chains[c].reduce(0, +) / Double(n)
            chainVars[c] = a[0] * Double(n) / Double(n - 1)
        }
        let meanVar = chainVars.reduce(0, +) / Double(m)
        var varPlus = meanVar * Double(n - 1) / Double(n)
        if m > 1 {
            let grandMean = chainMeans.reduce(0, +) / Double(m)
            var between = 0.0
            for mu in chainMeans { between += (mu - grandMean) * (mu - grandMean) }
            varPlus += between / Double(m - 1)
        }
        guard varPlus > 0 else { return Double(m * n) } // constant-column guard

        func meanAcovAtLag(_ lag: Int) -> Double {
            var s = 0.0
            for c in 0..<m { s += acov[c][lag] }
            return s / Double(m)
        }

        // rhoHat has n+1 slots: the Geyer sequence index can reach n (see
        // derivation in the packet), one past the last valid lag index.
        var rhoHat = [Double](repeating: 0, count: n + 1)
        rhoHat[0] = 1.0
        var rhoHatEven = 1.0
        var rhoHatOdd = 1 - (meanVar - meanAcovAtLag(1)) / varPlus
        rhoHat[1] = rhoHatOdd

        var t = 2
        while t < n - 1 && !(rhoHatEven + rhoHatOdd).isNaN && (rhoHatEven + rhoHatOdd) > 0 {
            rhoHatEven = 1 - (meanVar - meanAcovAtLag(t)) / varPlus
            rhoHatOdd = 1 - (meanVar - meanAcovAtLag(t + 1)) / varPlus
            if rhoHatEven + rhoHatOdd >= 0 {
                rhoHat[t] = rhoHatEven
                rhoHat[t + 1] = rhoHatOdd
            }
            t += 2
        }
        let maxT = t
        if rhoHatEven > 0, maxT < rhoHat.count {
            rhoHat[maxT] = rhoHatEven
        }

        // Geyer's initial monotone sequence: pairwise-average down any
        // non-monotone bump in the running sum.
        var tt = 2
        while tt <= maxT - 2 {
            if rhoHat[tt] + rhoHat[tt + 1] > rhoHat[tt - 2] + rhoHat[tt - 1] {
                rhoHat[tt] = (rhoHat[tt - 2] + rhoHat[tt - 1]) / 2
                rhoHat[tt + 1] = rhoHat[tt]
            }
            tt += 2
        }

        var sumRho = 0.0
        let upper = min(maxT, rhoHat.count)
        for i in 0..<max(upper, 0) { sumRho += rhoHat[i] }
        let lastTerm = maxT < rhoHat.count ? max(rhoHat[maxT], 0) : 0
        var tauHat = -1 + 2 * sumRho + lastTerm
        let totalDraws = Double(m * n)
        tauHat = max(tauHat, 1.0 / log10(totalDraws))
        return totalDraws / tauHat
    }
}
