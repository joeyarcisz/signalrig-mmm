import Foundation

// Deterministic replacement for engine/model/posterior.py's
// _optimal_allocation() (:238-267, read-only reference at
// the Python reference implementation), which uses scipy's SLSQP.
// SLSQP is not ported (out of scope per the task packet -- it names this
// exact deviation and asks for "a deterministic concave-surface optimizer
// of your choice" instead).
//
// Method: projected-gradient ascent on the same surrogate surface Python
// optimizes (posterior-mean asymptote A, posterior-median kappa/slope per
// channel -- see posterior.py :241-243), maximizing total expected leads
// subject to a fixed weekly budget and per-channel bounds [0.3x, 3x]
// current spend. Each ascent step is followed by an exact Euclidean
// projection onto {lo <= x <= hi, sum(x) = budget}: a classic
// box-constrained continuous knapsack, solved by bisecting the shared
// Lagrange multiplier lambda in x_c(lambda) = clip(v_c - lambda, lo_c,
// hi_c) until sum(x(lambda)) == budget (sum is non-increasing in lambda,
// so bisection converges monotonically). This keeps every iterate
// feasible, not just the final answer.
//
// The Hill response curve is sigmoidal (convex near zero, then concave)
// for slope > 1, so the total objective is not guaranteed concave
// everywhere and a single ascent run could stall at a local optimum.
// Guarding against that without introducing randomness (the task packet
// wants a deterministic optimizer): run the ascent from several fixed,
// data-derived starting points (current spend, both bound extremes, and
// an asymptote-weighted split) and keep whichever converges to the
// highest objective value. See ArtifactsParityTests for the acceptance
// check against the Python SLSQP golden (constraint satisfaction to 1e-6,
// objective within 1% of the golden's delta_leads_weekly median).
public struct OptimalAllocationResult {
    public let budgetWeekly: Double
    public let allocations: [(key: String, current: Double, optimal: Double)]
    public let deltaLeadsWeekly: IntervalResult
    public let note: String

    public func toJSON() -> JSONValue {
        .object([
            "budget_weekly": .double(budgetWeekly),
            "allocations": .array(allocations.map {
                .object(["key": .string($0.key), "current": .double($0.current), "optimal": .double($0.optimal)])
            }),
            "delta_leads_weekly": deltaLeadsWeekly.toJSON(),
            "note": .string(note),
        ])
    }
}

public enum Optimizer {
    static func channelValue(_ xc: Double, kappa: Double, slope: Double, A: Double, M: Double) -> Double {
        let u = max(xc, 0.0) / M
        let xs = pow(u, slope)
        let kapS = pow(kappa, slope)
        return A * (xs / (kapS + xs))
    }

    static func objective(_ x: [Double], M: [Double], AMean: [Double], kappaMed: [Double], slopeMed: [Double]) -> Double {
        var total = 0.0
        for c in 0..<x.count {
            total += channelValue(x[c], kappa: kappaMed[c], slope: slopeMed[c], A: AMean[c], M: M[c])
        }
        return total
    }

    // Central finite-difference gradient of the objective (same finite-
    // difference philosophy posterior.py already uses for marginal CPL,
    // just applied to the optimizer's own surrogate surface).
    static func gradient(_ x: [Double], M: [Double], AMean: [Double], kappaMed: [Double], slopeMed: [Double]) -> [Double] {
        let C = x.count
        var g = [Double](repeating: 0, count: C)
        for c in 0..<C {
            let h = max(x[c] * 1e-4, 1e-3)
            let xp = x[c] + h
            let xm = max(x[c] - h, 0.0)
            let denom = xp - xm
            guard denom > 0 else { continue }
            let fp = channelValue(xp, kappa: kappaMed[c], slope: slopeMed[c], A: AMean[c], M: M[c])
            let fm = channelValue(xm, kappa: kappaMed[c], slope: slopeMed[c], A: AMean[c], M: M[c])
            g[c] = (fp - fm) / denom
        }
        return g
    }

    // Euclidean projection onto {lo <= x <= hi, sum(x) = budget}.
    static func projectOntoBudget(_ v: [Double], lo: [Double], hi: [Double], budget: Double) -> [Double] {
        func clipAt(_ lambda: Double) -> [Double] {
            (0..<v.count).map { min(max(v[$0] - lambda, lo[$0]), hi[$0]) }
        }
        func sumAt(_ lambda: Double) -> Double {
            clipAt(lambda).reduce(0, +)
        }
        // sumAt is non-increasing in lambda; bracket wide enough to cover
        // any realistic spend magnitude, then bisect to convergence well
        // past double precision for these magnitudes.
        var lambdaLo = -1e12
        var lambdaHi = 1e12
        for _ in 0..<200 {
            let mid = (lambdaLo + lambdaHi) / 2
            if sumAt(mid) > budget {
                lambdaLo = mid
            } else {
                lambdaHi = mid
            }
        }
        return clipAt((lambdaLo + lambdaHi) / 2)
    }

    static func ascend(from start: [Double], lo: [Double], hi: [Double], budget: Double,
                        M: [Double], AMean: [Double], kappaMed: [Double], slopeMed: [Double],
                        iterations: Int = 400) -> [Double] {
        var x = projectOntoBudget(start, lo: lo, hi: hi, budget: budget)
        let stepScale = 0.2 * (budget / Double(max(x.count, 1)))
        for iter in 0..<iterations {
            let g = gradient(x, M: M, AMean: AMean, kappaMed: kappaMed, slopeMed: slopeMed)
            let gnorm = sqrt(g.reduce(0) { $0 + $1 * $1 })
            guard gnorm > 1e-12 else { break }
            let stepSize = stepScale / (1.0 + Double(iter) * 0.05)
            let xNew = (0..<x.count).map { x[$0] + stepSize * g[$0] / gnorm }
            x = projectOntoBudget(xNew, lo: lo, hi: hi, budget: budget)
        }
        return x
    }

    public static func optimalAllocation(view: PosteriorView, R: [Double]) -> OptimalAllocationResult {
        let C = R.count
        let M = view.M

        let AMean: [Double] = (0..<C).map { c in
            var s = 0.0
            for row in view.A { s += row[c] }
            return s / Double(view.S)
        }
        let kappaMed: [Double] = (0..<C).map { c in Percentile.percentile(view.kappa.map { $0[c] }, 50) }
        let slopeMed: [Double] = (0..<C).map { c in Percentile.percentile(view.slope.map { $0[c] }, 50) }

        let lo = R.map { 0.3 * $0 }
        let hi = R.map { 3.0 * $0 }
        let budget = R.reduce(0, +)

        // Deterministic starting points: current spend, both bound
        // extremes (projected onto the budget constraint), and an
        // asymptote-weighted split -- no randomness.
        var starts: [[Double]] = [R, lo, hi]
        let totalA = AMean.reduce(0, +)
        if totalA > 0 {
            starts.append(AMean.map { budget * $0 / totalA })
        }

        var best = projectOntoBudget(R, lo: lo, hi: hi, budget: budget)
        var bestObj = objective(best, M: M, AMean: AMean, kappaMed: kappaMed, slopeMed: slopeMed)

        for start in starts {
            let x = ascend(from: start, lo: lo, hi: hi, budget: budget, M: M, AMean: AMean, kappaMed: kappaMed, slopeMed: slopeMed)
            let obj = objective(x, M: M, AMean: AMean, kappaMed: kappaMed, slopeMed: slopeMed)
            if obj > bestObj {
                bestObj = obj
                best = x
            }
        }

        // Final projection guards against any floating-point drift from
        // the ascent loop so the emitted allocation satisfies the budget
        // and bounds constraints exactly (to solver tolerance).
        let optimal = projectOntoBudget(best, lo: lo, hi: hi, budget: budget)

        let leadsOptimal = view.leadsAt(optimal)
        let leadsCurrent = view.leadsAt(R)
        let delta = (0..<view.S).map { s in leadsOptimal[s].reduce(0, +) - leadsCurrent[s].reduce(0, +) }
        let deltaIv = Metrics.iv(delta)

        let allocations = (0..<C).map { c in
            (key: view.channels[c], current: roundTo(R[c], 0), optimal: roundTo(optimal[c], 0))
        }

        return OptimalAllocationResult(
            budgetWeekly: roundTo(budget, 0),
            allocations: allocations,
            deltaLeadsWeekly: deltaIv,
            note: "Fixed-budget reallocation along the fitted response curves (projected-gradient ascent on the posterior-mean surface from several fixed starting points, exact box+budget projection each step; interval from evaluating the optimum across draws). Bounds: 0.3x-3x current per channel."
        )
    }
}
