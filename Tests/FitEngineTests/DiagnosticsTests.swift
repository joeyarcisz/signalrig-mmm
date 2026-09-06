import XCTest
@testable import FitEngine

// Deterministic, balanced posterior fixtures. Every split chain contains
// the same quantiles in a different order; no model or sampler is run.
enum PosteriorDiagnosticFixture {
    static func fit(chains: Int = 4, draws: Int = 256, weeks: Int = 16, seedOffset: Int = 0) -> StanFit {
        let scalars = DiagnosticsCalc.scalarColumnNames(C: 1, K: 0)
        let header = scalars + ["divergent__"] + (1...weeks).map { "mu_scaled.\($0)" }
        let half = max(draws / 2, 1)
        let quantiles = (0..<half).map { DiagnosticsCalc.inverseNormalCDF((Double($0) + 0.5) / Double(half)) }
        let result = (0..<chains).map { chain -> ChainDraws in
            var columns: [String: [Double]] = [:]
            for (parameter, name) in header.enumerated() {
                if name == "divergent__" {
                    columns[name] = [Double](repeating: 0, count: draws)
                    continue
                }
                var rng = SplitMix64(seed: UInt64((chain + 1) * 10_000 + parameter + seedOffset * 1_000_000))
                var first = quantiles
                var second = quantiles
                first.shuffle(using: &rng)
                second.shuffle(using: &rng)
                let values = Array((first + second + [0]).prefix(draws))
                let center: Double
                if name == "adstock_alpha.1" { center = 0.35 }
                else if name == "hill_kappa.1" { center = 0.45 }
                else if name == "hill_slope.1" { center = 1.5 }
                else if name == "channel_beta.1" { center = 0.03 }
                else if name == "intercept" { center = 0.5 }
                else if name == "sigma" { center = 0.02 }
                else if name.hasPrefix("mu_scaled."), let week = Int(name.split(separator: ".").last!) {
                    center = 0.55 + 0.01 * Double((week - 1) % 10)
                }
                else { center = 0.01 }
                columns[name] = values.map { center + 0.001 * $0 }
            }
            return ChainDraws(header: header, columns: columns, nDraws: draws)
        }
        return StanFit(chains: result, C: 1, T: weeks, K: 0)
    }

    static func replacing(_ name: String, in fit: StanFit, value: (Int, Int, Double) -> Double) -> StanFit {
        let chains = fit.chains.enumerated().map { chainIndex, chain -> ChainDraws in
            var columns = chain.columns
            columns[name] = columns[name]!.enumerated().map { draw, old in value(chainIndex, draw, old) }
            return ChainDraws(header: chain.header, columns: columns, nDraws: chain.nDraws)
        }
        return StanFit(chains: chains, C: fit.C, T: fit.T, K: fit.K)
    }

    static func scaleMismatch(in fit: StanFit) -> StanFit {
        replacing("intercept", in: fit) { chain, _, value in
            0.5 + (chain == 0 ? 0.1 : 10) * (value - 0.5)
        }
    }

    static func meta(weeks: Int = 16) -> PanelMeta {
        let panel = Panel(
            dates: (0..<weeks).map { "week-\($0)" }, channels: ["client_search"],
            X: Array(repeating: [1000], count: weeks),
            y: [100] + (1..<weeks).map { 55 + Double($0 % 10) },
            rawControls: Array(repeating: [], count: weeks), controlNames: [],
            kpiName: "leads", warnings: []
        )
        return StanDataBuilder.build(panel: panel).meta
    }
}

final class DiagnosticsTests: XCTestCase {
    func testBalancedChainsHaveFiniteDiagnostics() throws {
        let result = try DiagnosticsCalc.compute(fit: PosteriorDiagnosticFixture.fit())
        XCTAssertTrue(result.rhatMax.isFinite)
        XCTAssertLessThan(result.rhatMax, 1.01)
        XCTAssertGreaterThanOrEqual(result.essBulkMin, 400)
        XCTAssertEqual(result.divergences, 0)
    }

    func testFoldedRhatDetectsEqualLocationButDifferentScale() throws {
        let fit = PosteriorDiagnosticFixture.scaleMismatch(in: PosteriorDiagnosticFixture.fit())
        let split = DiagnosticsCalc.splitChains(fit.chains.map { $0.columns["intercept"]! })
        let ranked = DiagnosticsCalc.rankNormalize(split.flatMap { $0 })
        let length = split[0].count
        let rankChains = split.indices.map { Array(ranked[($0 * length)..<(($0 + 1) * length)]) }
        XCTAssertLessThan(DiagnosticsCalc.classicRhat(rankChains), 1.01, "location-only R-hat misses this scale failure")
        let result = try DiagnosticsCalc.compute(fit: fit)
        XCTAssertGreaterThan(result.rhatMax, 1.1, "folded R-hat must catch the scale difference")
    }

    func testParameterConstantAcrossAllChainsIsAnError() {
        let fit = PosteriorDiagnosticFixture.replacing("intercept", in: PosteriorDiagnosticFixture.fit()) { _, _, _ in 0.5 }
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: fit)) { error in
            guard let error = error as? DiagnosticsError, case .constantParameter("intercept") = error else {
                return XCTFail("expected constant-parameter diagnostic error, got \(error)")
            }
        }
    }

    func testChainsStuckAtDifferentConstantsAreAnError() {
        let fit = PosteriorDiagnosticFixture.replacing("intercept", in: PosteriorDiagnosticFixture.fit()) { chain, _, _ in Double(chain) }
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: fit)) { error in
            guard let error = error as? DiagnosticsError, case .undefinedDiagnostic("intercept") = error else {
                return XCTFail("expected undefined diagnostic for stuck chains, got \(error)")
            }
        }
    }

    func testZeroWithinChainVarianceDoesNotReturnOne() {
        XCTAssertEqual(DiagnosticsCalc.classicRhat([[0, 0, 0, 0], [1, 1, 1, 1]]), .infinity)
        XCTAssertTrue(DiagnosticsCalc.classicRhat([[1, 1, 1, 1], [1, 1, 1, 1]]).isNaN)
    }

    func testOneChainCannotEstablishConvergence() {
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: PosteriorDiagnosticFixture.fit(chains: 1))) { error in
            guard let error = error as? DiagnosticsError, case .insufficientChains(1) = error else {
                return XCTFail("expected insufficientChains, got \(error)")
            }
        }
    }

    func testTooFewDrawsCannotEstablishConvergence() {
        let fit = PosteriorDiagnosticFixture.replacing("intercept", in: PosteriorDiagnosticFixture.fit(draws: 3)) { chain, _, value in
            value + 0.001 * Double(chain)
        }
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: fit)) { error in
            guard let error = error as? DiagnosticsError, case .insufficientDraws(3) = error else {
                return XCTFail("expected insufficientDraws, got \(error)")
            }
        }
    }

    func testNonfiniteDirectlyConstructedFitIsRejected() {
        let fit = PosteriorDiagnosticFixture.replacing("intercept", in: PosteriorDiagnosticFixture.fit()) { chain, draw, old in
            chain == 0 && draw == 0 ? .nan : old
        }
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: fit))
    }

    func testMissingColumnInDirectlyConstructedFitIsRejected() {
        let fit = PosteriorDiagnosticFixture.fit()
        var firstColumns = fit.chains[0].columns
        firstColumns.removeValue(forKey: "sigma")
        let first = ChainDraws(header: fit.chains[0].header, columns: firstColumns, nDraws: fit.chains[0].nDraws)
        let invalid = StanFit(chains: [first] + Array(fit.chains.dropFirst()), C: fit.C, T: fit.T, K: fit.K)
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: invalid))
    }

    func testMismatchedColumnLengthsAreRejected() {
        let fit = PosteriorDiagnosticFixture.fit()
        var firstColumns = fit.chains[0].columns
        firstColumns["intercept"]!.removeLast()
        let first = ChainDraws(header: fit.chains[0].header, columns: firstColumns, nDraws: fit.chains[0].nDraws)
        let invalid = StanFit(chains: [first] + Array(fit.chains.dropFirst()), C: fit.C, T: fit.T, K: fit.K)
        XCTAssertThrowsError(try DiagnosticsCalc.compute(fit: invalid))
    }
}
