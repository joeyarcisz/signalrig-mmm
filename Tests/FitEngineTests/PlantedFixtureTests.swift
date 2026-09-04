import XCTest
@testable import FitEngine

// Covers the committed planted-truth fixture that makes the project's
// recovery claim reproducible (see Tests/Fixtures/generate_planted_fixture.py).
// Recovery grading itself needs a compiled Stan binary and two full fits, so
// it is not run here; what these tests guard is the data that run depends on,
// and in particular the silent-failure mode: Metrics.recovery skips any
// channel with no matching truth entry, so a single key typo would quietly
// grade fewer parameters instead of failing. Runs on any clean checkout with
// no environment variables and no CmdStan.
final class PlantedFixtureTests: XCTestCase {
    static var fixturesDir: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FitEngineTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .path
    }

    private func fixturePath(_ name: String) -> String {
        (Self.fixturesDir as NSString).appendingPathComponent(name)
    }

    private var dropDir: String { fixturePath("planted_drop") }
    private var truthPath: String { fixturePath("planted_truth.json") }

    func testPlantedDropLoadsWithTheAdvertisedShape() throws {
        let panel = try PanelLoader.load(dropDir: dropDir)
        XCTAssertEqual(panel.T, 104, "generator emits 104 weekly rows")
        XCTAssertEqual(panel.C, 8, "generator emits 8 channels")
        XCTAssertEqual(panel.kpiName, "signups")
        print("[Planted] T=\(panel.T) C=\(panel.C) channels=\(panel.channels)")
    }

    func testEveryPlantedChannelHasATruthEntry() throws {
        let panel = try PanelLoader.load(dropDir: dropDir)
        let truth = try Grader.loadTruth(path: truthPath)
        let truthKeys = Set(truth.map { $0.key })

        XCTAssertEqual(truth.count, panel.C,
                       "one truth entry per channel, or recovery silently grades fewer parameters")
        for key in panel.channels {
            XCTAssertTrue(truthKeys.contains(key),
                          "channel \(key) has no truth entry; Metrics.recovery would skip it")
        }
        // 8 channels x 3 graded metrics (cpl, adstock half life, contribution
        // share) is the 24 the recovery benchmark reports.
        XCTAssertEqual(truth.count * 3, 24)
    }

    func testPlantedTruthValuesAreWellFormed() throws {
        let truth = try Grader.loadTruth(path: truthPath)
        for t in truth {
            XCTAssertGreaterThan(t.trueCplAtRef, 0, "\(t.key) cpl must be positive")
            XCTAssertGreaterThan(t.refWeeklySpend, 0, "\(t.key) reference spend must be positive")
            XCTAssertTrue(t.adstockHalfLifeWeeks > 0 && t.adstockHalfLifeWeeks < 8,
                          "\(t.key) half life \(t.adstockHalfLifeWeeks) should sit inside the L=8 carryover window")
            XCTAssertTrue(t.contributionShare > 0 && t.contributionShare < 1,
                          "\(t.key) share \(t.contributionShare) must be a proper share")
        }
    }

    func testPlantedContributionSharesSumToOne() throws {
        let truth = try Grader.loadTruth(path: truthPath)
        let total = truth.reduce(0.0) { $0 + $1.contributionShare }
        XCTAssertEqual(total, 1.0, accuracy: 1e-9,
                       "shares are a distribution over channels; recovery grades each against it")
        print("[Planted] shares sum to \(total) across \(truth.count) channels")
    }
}
