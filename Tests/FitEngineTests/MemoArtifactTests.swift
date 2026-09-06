import XCTest
@testable import FitEngine

final class MemoArtifactTests: XCTestCase {
    private func interval(_ median: Double) -> IntervalResult {
        IntervalResult(lo: min(median * 0.8, median * 1.2), med: median, hi: max(median * 0.8, median * 1.2))
    }

    private func channel(_ key: String, label: String, marginalCpl: Double) -> ChannelSummary {
        ChannelSummary(
            key: key, label: label, platform: "", spendWeeklyAvg: 100, spendTotal: 6400,
            contributionShare: interval(0.25), contributionLeadsWeekly: interval(10),
            cpl: interval(10), marginalCpl: interval(marginalCpl), saturationPct: 40,
            adstockHalfLifeWeeks: 1, confidence: ConfidenceInfo(grade: "medium", basis: "Test interval"),
            decisionHint: "Review the interval."
        )
    }

    private func buildMemo(
        isSynthetic: Bool, prior: Double = 82, calibrated: Double = 85,
        scenarioMedian: Double = 4, shiftDollars: Double = 20, probability: Double = 0.9
    ) -> MemoArtifact {
        let channels = ChannelsArtifact(
            channels: [
                channel("podcast", label: "Podcast Sponsorship", marginalCpl: 60),
                channel("search", label: "Client Search", marginalCpl: 10),
                channel("events", label: "Trade Events", marginalCpl: 30),
                channel("social", label: "Client Social", marginalCpl: 20),
            ],
            baselineShare: interval(0.4), totalWeeklyLeadsMean: 100
        )
        let scenarios = ScenariosArtifact(
            referenceTotalWeeklySpend: 400, shiftPctMin: 1, shiftPctMax: 24,
            rows: [ScenarioRow(
                source: "podcast", target: "search", shiftPct: 20, shiftDollars: shiftDollars,
                deltaLeadsWeekly: interval(scenarioMedian), pPositive: probability, blendedCplAfter: 8
            )],
            optimalAllocation: OptimalAllocationResult(
                budgetWeekly: 400, allocations: [], deltaLeadsWeekly: interval(4), note: "Test allocation"
            )
        )
        let diagnostics = DiagnosticsArtifact(
            rhatMax: 1.002, essBulkMin: 800, divergences: 0,
            mapeHoldoutPct: 7.5, r2Holdout: 0.8, coverage90Pct: 91.7,
            holdoutWeeks: 12, ppc: [], holdout: [],
            gates: Gates(converged: true, fitOk: true, optimizerUnlocked: true),
            sampler: "NUTS (4 chains)", draws: 1000, chains: 4
        )
        return MemoBuilder.build(
            channels: channels, scenarios: scenarios, diagnostics: diagnostics,
            blendedCplPrior: prior, blendedCplCalibrated: calibrated,
            date: "2026-09-06", packageLabel: "Client One", kpiName: "demo_requests",
            isSynthetic: isSynthetic
        )
    }

    func testRealMemoUsesClientFindingsWithoutSampleBenchmarkClaims() {
        let memo = buildMemo(isSynthetic: false, prior: 9182, calibrated: 9285)
        let findings = memo.sections[0].body
        let text = ([memo.title] + memo.sections.map { $0.body }).joined(separator: "\n")

        XCTAssertTrue(findings.contains("Client Search, Client Social, Trade Events"))
        XCTAssertTrue(findings.contains("Trade Events and Podcast Sponsorship"))
        XCTAssertFalse(text.lowercased().contains("vendor"))
        XCTAssertFalse(text.contains("9182"))
        XCTAssertFalse(text.contains("9285"))
        XCTAssertFalse(text.contains("last year"))
        XCTAssertFalse(text.contains("recovered intervals contained the truth"))
        XCTAssertFalse(text.contains("leads/week"))
        XCTAssertTrue(text.contains("outcomes/week"))
        XCTAssertTrue(findings.contains("cost per outcome"))
        XCTAssertFalse(text.contains("the model never saw"))
        XCTAssertTrue(memo.sections[1].body.contains("Podcast Sponsorship"))
        XCTAssertTrue(memo.sections[1].body.contains("Client Search"))
        XCTAssertTrue(memo.sections[2].body.contains("7.5% MAPE"))
        XCTAssertTrue(memo.sections[3].body.contains("Client One's own data"))
    }

    func testSyntheticMemoRetainsItsKnownBenchmarkComparison() {
        let memo = buildMemo(isSynthetic: true)
        XCTAssertTrue(memo.sections[0].body.contains("~$85/lead blended"))
        XCTAssertTrue(memo.sections[0].body.contains("$82 math"))
        XCTAssertTrue(memo.sections[2].body.contains("recovered intervals contained the truth"))
    }

    func testNoQualifyingScenarioDoesNotRecommendAShift() {
        for (median, dollars, probability) in [(0.0, 20.0, 0.9), (-4.0, 20.0, 0.9), (4.0, 0.0, 0.9), (4.0, 20.0, 0.7)] {
            let memo = buildMemo(isSynthetic: false, scenarioMedian: median, shiftDollars: dollars, probability: probability)
            let decision = memo.sections[1].body
            XCTAssertTrue(decision.contains("No budget shift clears"))
            XCTAssertTrue(decision.contains("Hold the current allocation"))
            XCTAssertFalse(decision.contains("Shift 20%"))
        }
    }

    func testBothMemoVariantsUsePermittedPunctuation() {
        for synthetic in [false, true] {
            let memo = buildMemo(isSynthetic: synthetic)
            let text = ([memo.title] + memo.sections.flatMap { [$0.heading, $0.body] }).joined(separator: "\n")
            XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x2014 })
        }
    }
}
