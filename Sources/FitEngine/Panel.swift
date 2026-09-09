import Foundation

// A fit's preprocessing is learned only from the weeks in its likelihood.
// The same transform can then be applied to later, known spend and controls
// for a conditional holdout forecast without changing the training model.
public struct PanelPreprocessing {
    public static let version = 2
    // The channel-coefficient prior is centered on a spend-proportional cost
    // per outcome learned from the training window itself: total reference
    // spend divided by the share of the mean outcome that media is assumed to
    // drive (one half). Every channel shares that blended center, so the data
    // decides which channels are cheaper or dearer; no channel-name lookup and
    // no bundled per-channel default can anchor the answer.
    public static let priorSource = "Spend-proportional blended CPL from the training window; media assumed to drive half of the outcome"
    public static let assumedMediaShareOfOutcome = 0.5
    public let observedWeeks: Int
    public let xScale: [Double]
    public let yScale: Double
    public let refSpend: [Double]
    public let controlNames: [String]
    public let controlMean: [Double]
    public let controlStd: [Double]
    public let referenceMeanKPI: Double

    // One blended prior CPL for every channel, derived from the reference window.
    public static func blendedPriorCPL(refSpend: [Double], referenceMeanKPI: Double) -> Double {
        let totalSpend = refSpend.reduce(0.0, +)
        let mediaOutcome = max(referenceMeanKPI, 1e-9) * assumedMediaShareOfOutcome
        return max(totalSpend / mediaOutcome, 1e-9)
    }

    public var priorCPL: [Double] {
        let blended = Self.blendedPriorCPL(refSpend: refSpend, referenceMeanKPI: referenceMeanKPI)
        return refSpend.map { _ in blended }
    }

    public var betaCenter: [Double] {
        refSpend.indices.map { c in max((refSpend[c] / priorCPL[c] / 0.5) / yScale, 1e-4) }
    }

    public static func fit(panel: Panel, observedWeeks: Int) -> PanelPreprocessing {
        precondition(observedWeeks > 0 && observedWeeks <= panel.T, "preprocessing requires a nonempty observed window within the panel")
        let xScale = (0..<panel.C).map { c in
            max((0..<observedWeeks).map { panel.X[$0][c] }.max() ?? 0, 1e-9)
        }
        let yScale = max(panel.y.prefix(observedWeeks).max() ?? 0, 1e-9)
        let referenceWeeks = min(52, observedWeeks)
        let referenceStart = observedWeeks - referenceWeeks
        let refSpend = (0..<panel.C).map { c in
            let spend = (referenceStart..<observedWeeks).reduce(0.0) { $0 + panel.X[$1][c] }
            return max(spend / Double(referenceWeeks), 1e-9)
        }
        let referenceMeanKPI = max(
            (referenceStart..<observedWeeks).reduce(0.0) { $0 + panel.y[$1] } / Double(referenceWeeks), 1e-9)

        var controlMean = [Double](repeating: 0, count: panel.K)
        var controlStd = [Double](repeating: 0, count: panel.K)
        for c in 0..<panel.K {
            let mean = (0..<observedWeeks).reduce(0.0) { $0 + panel.rawControls[$1][c] } / Double(observedWeeks)
            let variance = (0..<observedWeeks).reduce(0.0) {
                let delta = panel.rawControls[$1][c] - mean
                return $0 + delta * delta
            } / Double(observedWeeks)
            controlMean[c] = mean
            controlStd[c] = variance.squareRoot()
        }
        return PanelPreprocessing(
            observedWeeks: observedWeeks, xScale: xScale, yScale: yScale, refSpend: refSpend,
            controlNames: panel.controlNames, controlMean: controlMean, controlStd: controlStd,
            referenceMeanKPI: referenceMeanKPI
        )
    }

    public func standardizedControls(_ rawControls: [[Double]]) -> [[Double]] {
        rawControls.map { row in
            controlNames.indices.map { c in
                let denominator = controlStd[c] > 1e-9 ? controlStd[c] : 1.0
                return (row[c] - controlMean[c]) / denominator
            }
        }
    }

    public func toJSON() -> JSONValue {
        .object([
            "version": .int(Self.version),
            "observed_weeks": .int(observedWeeks),
            "x_scale": .doubleArray(xScale),
            "y_scale": .double(yScale),
            "ref_spend": .doubleArray(refSpend),
            "control_names": .stringArray(controlNames),
            "control_mean": .doubleArray(controlMean),
            "control_std": .doubleArray(controlStd),
            "reference_mean_kpi": .double(referenceMeanKPI),
            "prior_cpl": .doubleArray(priorCPL),
            "prior_source": .string(Self.priorSource),
            "beta_center": .doubleArray(betaCenter),
        ])
    }
}
