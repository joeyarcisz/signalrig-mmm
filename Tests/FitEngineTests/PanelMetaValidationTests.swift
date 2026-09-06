import XCTest
@testable import FitEngine

final class PanelMetaValidationTests: XCTestCase {
    private let fit = StanFit(chains: [], C: 1, T: 4, K: 0)

    private func meta(
        channels: [String] = ["search"], xScale: [Double] = [100], yScale: Double = 20,
        xRaw: [[Double]] = [[10], [20], [30], [40]], yRaw: [Double] = [1, 2, 3, 4],
        holdoutWeeks: Int = 1
    ) -> PanelMeta {
        PanelMeta(
            channels: channels, dates: ["2026-01-05", "2026-01-12", "2026-01-19", "2026-01-26"],
            xScale: xScale, yScale: yScale, refSpend: [25], xRaw: xRaw, yRaw: yRaw,
            holdoutWeeks: holdoutWeeks, lMax: 8
        )
    }

    func testValidPanelMetadataMatchesPosteriorDimensions() {
        XCTAssertNoThrow(try Grader.validatePanelMeta(meta(), fit: fit))
    }

    func testMismatchedArraysThrowBeforeDerivedArtifactIndexing() {
        for candidate in [
            meta(channels: ["search", "social"]), meta(xScale: []),
            meta(xRaw: [[1], [2], [3]]), meta(xRaw: [[1, 2], [2], [3], [4]]),
            meta(yRaw: [1, 2, 3]), meta(holdoutWeeks: 4),
        ] {
            XCTAssertThrowsError(try Grader.validatePanelMeta(candidate, fit: fit))
        }
    }

    func testInvalidScalingAndNonfiniteDataAreRejected() {
        for candidate in [
            meta(xScale: [0]), meta(yScale: .infinity), meta(yScale: 0),
            meta(xRaw: [[1], [2], [.nan], [4]]), meta(yRaw: [1, 2, -.infinity, 4]),
        ] {
            XCTAssertThrowsError(try Grader.validatePanelMeta(candidate, fit: fit))
        }
    }
}
