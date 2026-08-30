import Foundation

// Translates engine/memo.py's build_memo() (:69-123, read-only reference
// the Python reference implementation) verbatim, including its
// Python f-string number formatting (thousands separators, signed
// one-decimal deltas, zero-decimal percentages) reproduced by hand below
// since Swift has no direct equivalent of Python's format-spec mini
// language. build_narratives() and bench.json generation are out of
// scope for this port (static content, handled elsewhere per the task
// packet); build_memo only needs two numbers from bench.json's "blended"
// section (cpl_prior, cpl_calibrated), supplied as plain parameters here.
public struct MemoSection {
    public let heading: String
    public let body: String

    public func toJSON() -> JSONValue {
        .object(["heading": .string(heading), "body": .string(body)])
    }
}

public struct MemoArtifact {
    public let title: String
    public let date: String
    public let sections: [MemoSection]

    public func toJSON() -> JSONValue {
        .object([
            "title": .string(title),
            "date": .string(date),
            "sections": .array(sections.map { $0.toJSON() }),
        ])
    }
}

public enum MemoBuilder {
    // Python's f"{x:,.0f}": thousands-grouped, zero decimal places,
    // locale-independent (always a comma, regardless of host locale).
    static func formatThousands(_ x: Double) -> String {
        let n = Int(x.rounded())
        let isNeg = n < 0
        let digits = Array(String(abs(n)))
        var groups: [String] = []
        var i = digits.count
        while i > 0 {
            let start = max(0, i - 3)
            groups.insert(String(digits[start..<i]), at: 0)
            i = start
        }
        return (isNeg ? "-" : "") + groups.joined(separator: ",")
    }

    // Python's f"{x:+.1f}": always-signed, one decimal place.
    static func formatSigned1(_ x: Double) -> String {
        let s = String(format: "%.1f", abs(x))
        return (x < 0 ? "-" : "+") + s
    }

    // Python's f"{x:.0%}": x is a 0..1 fraction, multiplied by 100,
    // rounded to the nearest whole percent, with a trailing "%".
    static func formatPercent0(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }

    public static func build(
        channels: ChannelsArtifact,
        scenarios: ScenariosArtifact,
        diagnostics: DiagnosticsArtifact,
        blendedCplPrior: Double,
        blendedCplCalibrated: Double,
        date: String,
        packageLabel: String = ArtifactConstants.defaultPackageLabel,
        kpiName: String = ArtifactConstants.defaultKPIName,
        isSynthetic: Bool = false
    ) -> MemoArtifact {
        let chans = channels.channels
        let byMarginalCpl = chans.sorted { $0.marginalCpl.med < $1.marginalCpl.med }
        let cheapNames = byMarginalCpl.prefix(3).map { $0.label }.joined(separator: ", ")
        let expNames = byMarginalCpl.suffix(2).map { $0.label }.joined(separator: " and ")

        let best = scenarios.rows
            .filter { $0.pPositive >= 0.75 }
            .max { $0.deltaLeadsWeekly.med < $1.deltaLeadsWeekly.med }

        var sections: [MemoSection] = []

        // "YouTube, Display, and Audio were optimistic..." (removed vendor-specific
        // sentence) named two things specific to the bundled synthetic
        // twin: three of ITS channel labels, and ITS ad-buying vendor. A
        // package without those channels still got this
        // sentence verbatim before this fix -- a brand-clean violation
        // (frozen design decision 7) independent of isSynthetic, since it
        // is about which CLIENT this is, not whether the run is synthetic.
        // Generalized here to name the run's own highest-marginal-CPL
        // channels (expNames, already computed from this run's own data)
        // instead of a hardcoded channel list, and no vendor name.
        sections.append(MemoSection(
            heading: "What the model found",
            body: "On the last year of weekly data, the cheapest next leads sit in \(cheapNames). "
                + "\(expNames) carry the highest marginal cost per lead at current spend. "
                + "Vendor benchmarks for those channels were optimistic relative to this market \u{2014} "
                + "the calibrated planning view prices the full mix at "
                + "~$\(Int(blendedCplCalibrated.rounded()))/lead blended, versus the vendor's "
                + "$\(Int(blendedCplPrior.rounded())) math."
        ))

        let decisionBody: String
        if let best = best,
           let sourceLabel = chans.first(where: { $0.key == best.source })?.label,
           let targetLabel = chans.first(where: { $0.key == best.target })?.label {
            decisionBody = "Shift \(best.shiftPct)% of weekly \(sourceLabel) spend "
                + "($\(formatThousands(best.shiftDollars))/wk) into \(targetLabel): "
                + "modeled lift \(formatSigned1(best.deltaLeadsWeekly.med)) leads/week "
                + "(90% interval \(formatSigned1(best.deltaLeadsWeekly.lo)) to \(formatSigned1(best.deltaLeadsWeekly.hi))), "
                + "improving with probability \(formatPercent0(best.pPositive)). The scenario planner carries the exact interval for any size."
        } else {
            decisionBody = "The scenario planner carries the exact interval for any proposed shift."
        }
        sections.append(MemoSection(heading: "The decision on the table", body: decisionBody))

        // The claim "recovered intervals contained the truth" is only true
        // when this run actually had hidden synthetic ground truth to
        // recover against (isSynthetic); real client data has no such
        // truth (frozen design decision 1's recovery-unavailable variant),
        // so that sentence must not appear for it (audit finding: real-data
        // memos were claiming hidden synthetic truth regardless).
        let trustCore = "All chains converged (R-hat \(diagnostics.rhatMax), \(diagnostics.divergences) divergences). "
            + "On \(diagnostics.holdoutWeeks) held-out weeks the model never saw, forecast error was "
            + "\(diagnostics.mapeHoldoutPct)% MAPE with \(diagnostics.coverage90Pct)% interval coverage."
        let trustBody = isSynthetic
            ? trustCore + " On synthetic data with hidden ground truth, recovered intervals contained the truth \u{2014} the full receipt is on the Model Card."
            : trustCore
        sections.append(MemoSection(heading: "Why these numbers can be trusted", body: trustBody))

        // Likewise, the sample-brief calibration sentence is
        // only true for that one synthetic twin; a real client's own data
        // gets a generic sentence naming no fixture (frozen design
        // decision 7: brand-clean for real data).
        let limitsBody = isSynthetic
            ? "Weekly grain, last-click stance, and correlated channel activity. Lift tests and a control sheet "
                + "(promos, inventory, pricing) are the cheapest upgrades to model confidence. Today's fit runs on a "
                + "synthetic twin calibrated to the sample brief; the identical pipeline retrains the day the real export lands."
            : "Weekly grain, last-click stance, and correlated channel activity. Lift tests and a control sheet "
                + "(promos, inventory, pricing) are the cheapest upgrades to model confidence. This fit runs on "
                + "\(packageLabel)'s own data; the identical pipeline retrains whenever a fresh export lands."
        sections.append(MemoSection(heading: "What limits the answer", body: limitsBody))

        // Title/headline derive from packageLabel (CLI --label, default
        // "Client package") and the data-derived kpi_name (frozen design
        // decision 7) -- never a hardcoded fixture brand, even when the
        // run happens to be against the bundled synthetic twin: that case
        // gets its brand identity by the caller actually passing
        // an explicit --label, not by this code detecting or assuming it.
        let kpiTitle = ChannelRegistry.titleCase(kpiName)
        return MemoArtifact(title: "\(packageLabel) \u{2014} \(kpiTitle): Measurement & Planning Memo", date: date, sections: sections)
    }
}
