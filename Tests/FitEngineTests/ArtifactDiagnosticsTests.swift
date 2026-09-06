import XCTest
@testable import FitEngine

final class ArtifactDiagnosticsTests: XCTestCase {
    private func diagnostic(rhat: Double = 1, ess: Int = 400, divergences: Int = 0) -> DiagnosticsResult {
        DiagnosticsResult(rhatMax: rhat, essBulkMin: ess, divergences: divergences)
    }

    private func gates(
        full: DiagnosticsResult? = nil, fullChains: Int = 4,
        holdout: DiagnosticsResult? = nil, holdoutChains: Int = 4,
        mape: Double = 5, r2: Double = 0.5, coverage: Double = 90
    ) -> Gates {
        ArtifactDiagnosticsBuilder.makeGates(
            full: full ?? diagnostic(), fullChains: fullChains,
            holdout: holdout ?? diagnostic(), holdoutChains: holdoutChains,
            mapeHoldoutPct: mape, r2Holdout: r2, coverage90Pct: coverage
        )
    }

    private func artifact(full: StanFit, holdout: StanFit, holdoutWeeks: Int = 12) throws -> DiagnosticsArtifact {
        let meta = PosteriorDiagnosticFixture.meta(weeks: full.T)
        let holdoutMeta = try Grader.holdoutPanelMeta(meta, fit: holdout)
        return try ArtifactDiagnosticsBuilder.build(
            fitFull: full, fitHoldout: holdout,
            viewFull: PosteriorView(fit: full, meta: meta),
            viewHoldout: PosteriorView(fit: holdout, meta: holdoutMeta),
            holdoutWeeks: holdoutWeeks
        )
    }

    func testFourChainsAtTheESSBoundaryCanUnlock() {
        let result = gates()
        XCTAssertTrue(result.converged)
        XCTAssertTrue(result.fitOk)
        XCTAssertTrue(result.optimizerUnlocked)
    }

    func testLowESSInEitherFitBlocksRecommendations() {
        XCTAssertFalse(gates(full: diagnostic(ess: 399)).optimizerUnlocked)
        XCTAssertFalse(gates(holdout: diagnostic(ess: 399)).optimizerUnlocked)
        XCTAssertFalse(gates(full: diagnostic(ess: 499), fullChains: 5).optimizerUnlocked)
        XCTAssertFalse(gates(holdout: diagnostic(ess: 499), holdoutChains: 5).optimizerUnlocked)
        XCTAssertTrue(gates(full: diagnostic(ess: 500), fullChains: 5).optimizerUnlocked)
        XCTAssertTrue(gates(holdout: diagnostic(ess: 500), holdoutChains: 5).optimizerUnlocked)
    }

    func testBothFitsRequireAtLeastFourChains() {
        for count in [0, 1, 2, 3] {
            XCTAssertFalse(gates(fullChains: count).optimizerUnlocked)
            XCTAssertFalse(gates(holdoutChains: count).optimizerUnlocked)
        }
    }

    func testAnyDivergenceInEitherFitBlocksRecommendations() {
        for count in [1, 5, 6] {
            XCTAssertFalse(gates(full: diagnostic(divergences: count)).optimizerUnlocked)
            XCTAssertFalse(gates(holdout: diagnostic(divergences: count)).optimizerUnlocked)
        }
    }

    func testRhatBoundaryAndInvalidDiagnosticsBlockBothFits() {
        for rhat in [Double(1.01), 1.02, 0, -1, .nan, .infinity, -.infinity] {
            XCTAssertFalse(gates(full: diagnostic(rhat: rhat)).optimizerUnlocked)
            XCTAssertFalse(gates(holdout: diagnostic(rhat: rhat)).optimizerUnlocked)
        }
        XCTAssertTrue(gates(full: diagnostic(rhat: 1.0099), holdout: diagnostic(rhat: 1.0099)).optimizerUnlocked)
    }

    func testInvalidOrPoorHoldoutErrorBlocksRecommendations() {
        for mape in [Double(-1), 15, 100, .nan, .infinity, -.infinity] {
            let result = gates(mape: mape)
            XCTAssertTrue(result.converged)
            XCTAssertFalse(result.fitOk)
            XCTAssertFalse(result.optimizerUnlocked)
        }
    }

    func testBalancedFullAndHoldoutFitsProduceVersionedFiniteArtifact() throws {
        let fit = PosteriorDiagnosticFixture.fit()
        let result = try artifact(full: fit, holdout: PosteriorDiagnosticFixture.fit(seedOffset: 1))
        XCTAssertTrue(result.gates.optimizerUnlocked)
        XCTAssertEqual(result.holdout.count, 12)
        XCTAssertEqual(result.ppc.count, 4)
        XCTAssertEqual(result.toJSON()["quality_policy_version"]?.asInt, 4)
        XCTAssertNoThrow(try result.toJSON().serialized())
    }

    func testLowPercentageErrorCannotOverrideNegativeOrInvalidR2() {
        for r2 in [Double(-8.048), -1, 0, 1.01, .nan, .infinity, -.infinity] {
            let result = gates(mape: 3, r2: r2)
            XCTAssertTrue(result.converged)
            XCTAssertFalse(result.fitOk)
            XCTAssertFalse(result.optimizerUnlocked)
        }
        XCTAssertTrue(gates(r2: 0.001).optimizerUnlocked)
        XCTAssertTrue(gates(r2: 1).optimizerUnlocked)
    }

    func testUndercoveredOrInvalidIntervalsCannotUnlock() {
        for coverage in [Double(-1), 41.7, 79.999, 100.01, .nan, .infinity, -.infinity] {
            XCTAssertFalse(gates(coverage: coverage).optimizerUnlocked)
        }
        XCTAssertTrue(gates(coverage: 80).optimizerUnlocked)
        XCTAssertTrue(gates(coverage: 100).optimizerUnlocked)
    }

    func testObservedForeignDemoMetricsAreHeldBack() {
        let result = gates(
            full: diagnostic(rhat: 1.0057, ess: 2083),
            holdout: diagnostic(rhat: 1.0057, ess: 2083),
            mape: 14.09, r2: -8.048, coverage: 41.7
        )
        XCTAssertTrue(result.converged)
        XCTAssertFalse(result.fitOk)
        XCTAssertFalse(result.optimizerUnlocked)
    }

    func testAccurateHoldoutPredictionsCannotOverridePoorHoldoutChains() throws {
        let good = PosteriorDiagnosticFixture.fit()
        let bad = PosteriorDiagnosticFixture.scaleMismatch(in: PosteriorDiagnosticFixture.fit(seedOffset: 1))
        let result = try artifact(full: good, holdout: bad)
        XCTAssertTrue(result.gates.fitOk, "the predictive mean is unchanged by the scale-mismatch fixture")
        XCTAssertFalse(result.gates.converged)
        XCTAssertFalse(result.gates.optimizerUnlocked)
        let fullDiagnostics = try DiagnosticsCalc.compute(fit: good)
        let holdoutDiagnostics = try DiagnosticsCalc.compute(fit: bad)
        XCTAssertEqual(result.rhatMax, max(fullDiagnostics.rhatMax, holdoutDiagnostics.rhatMax))
        XCTAssertEqual(result.essBulkMin, Double(min(fullDiagnostics.essBulkMin, holdoutDiagnostics.essBulkMin)))
    }

    func testAccurateHoldoutPredictionsCannotOverridePoorFullChains() throws {
        let good = PosteriorDiagnosticFixture.fit()
        let result = try artifact(full: PosteriorDiagnosticFixture.scaleMismatch(in: good), holdout: PosteriorDiagnosticFixture.fit(seedOffset: 1))
        XCTAssertTrue(result.gates.fitOk)
        XCTAssertFalse(result.gates.converged)
        XCTAssertFalse(result.gates.optimizerUnlocked)
    }

    func testDivergencesFromBothFitsAreReportedAndBlockUnlock() throws {
        let good = PosteriorDiagnosticFixture.fit()
        let one = PosteriorDiagnosticFixture.replacing("divergent__", in: good) { chain, draw, old in
            chain == 0 && draw == 0 ? 1 : old
        }
        let two = PosteriorDiagnosticFixture.replacing("divergent__", in: PosteriorDiagnosticFixture.fit(seedOffset: 1)) { chain, draw, old in
            chain == 1 && draw < 2 ? 1 : old
        }
        let result = try artifact(full: one, holdout: two)
        XCTAssertEqual(result.divergences, 3)
        XCTAssertTrue(result.gates.fitOk)
        XCTAssertFalse(result.gates.optimizerUnlocked)
    }

    func testInvalidHeldOutWindowsAreRejected() throws {
        let fit = PosteriorDiagnosticFixture.fit()
        for weeks in [-1, 0, fit.T, fit.T + 1] {
            XCTAssertThrowsError(try artifact(full: fit, holdout: fit, holdoutWeeks: weeks)) { error in
                XCTAssertTrue(error is ArtifactDiagnosticsError)
            }
        }
    }

    func testMismatchedFullAndHoldoutPanelsAreRejected() throws {
        let full = PosteriorDiagnosticFixture.fit()
        let holdout = PosteriorDiagnosticFixture.fit(weeks: 15)
        XCTAssertThrowsError(try artifact(full: full, holdout: holdout)) { error in
            XCTAssertTrue(error is ArtifactDiagnosticsError)
        }
    }

    func testLegacyAndFullWindowViewsCannotCertifyHoldout() throws {
        let full = PosteriorDiagnosticFixture.fit()
        let holdout = PosteriorDiagnosticFixture.fit(seedOffset: 1)
        let meta = PosteriorDiagnosticFixture.meta()
        let legacy = PanelMeta(
            channels: meta.channels, dates: meta.dates, xScale: meta.xScale, yScale: meta.yScale,
            refSpend: meta.refSpend, xRaw: meta.xRaw, yRaw: meta.yRaw,
            holdoutWeeks: meta.holdoutWeeks, lMax: meta.lMax
        )
        for unverified in [legacy, meta] {
            XCTAssertThrowsError(try ArtifactDiagnosticsBuilder.build(
                fitFull: full, fitHoldout: holdout,
                viewFull: PosteriorView(fit: full, meta: meta),
                viewHoldout: PosteriorView(fit: holdout, meta: unverified), holdoutWeeks: 12
            )) { error in
                guard let error = error as? ArtifactDiagnosticsError, case .unverifiedPreprocessing = error else {
                    return XCTFail("expected unverified preprocessing, got \(error)")
                }
            }
        }
    }

    func testCopiedFullFitDrawsCannotCertifyHoldoutThroughPublicBuilder() throws {
        let fit = PosteriorDiagnosticFixture.fit()
        let meta = PosteriorDiagnosticFixture.meta()
        let holdoutMeta = try Grader.holdoutPanelMeta(meta, fit: fit)
        XCTAssertThrowsError(try ArtifactDiagnosticsBuilder.build(
            fitFull: fit, fitHoldout: fit, viewFull: PosteriorView(fit: fit, meta: meta),
            viewHoldout: PosteriorView(fit: fit, meta: holdoutMeta), holdoutWeeks: 12
        )) { error in
            guard let error = error as? GraderError, case .reusedFullFit = error else {
                return XCTFail("expected reused-full-fit error, got \(error)")
            }
        }
    }
}
