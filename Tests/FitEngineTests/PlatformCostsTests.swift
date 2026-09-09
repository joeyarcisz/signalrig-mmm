import XCTest
@testable import FitEngine

// platform_costs.csv is the one place a package can hand the model a
// per-channel prior center: the cost per outcome the platform itself
// reports. These tests pin the loader's fail-closed rules, the prior
// selection in the preprocessing receipt, and the prior-dominance
// arithmetic, using only the committed foreign fixture.
final class PlatformCostsTests: XCTestCase {
    static var fixturesDir: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .path
    }

    func makeDrop(costs: String?) throws -> String {
        let src = (Self.fixturesDir as NSString).appendingPathComponent("foreign_drop")
        let dst = NSTemporaryDirectory() + "signalrig-costs-" + UUID().uuidString
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        if let costs = costs {
            try costs.write(toFile: (dst as NSString).appendingPathComponent(PanelLoader.platformCostsFile), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dst) }
        return dst
    }

    func testNoCostsFileMeansEveryChannelUsesTheBlendedCenter() throws {
        let panel = try PanelLoader.load(dropDir: try makeDrop(costs: nil))
        XCTAssertTrue(panel.reportedCPL.allSatisfy { $0 == nil })
        let preprocessing = PanelPreprocessing.fit(panel: panel, observedWeeks: panel.T)
        let blended = PanelPreprocessing.blendedPriorCPL(refSpend: preprocessing.refSpend, referenceMeanKPI: preprocessing.referenceMeanKPI)
        for center in preprocessing.priorCenters {
            XCTAssertEqual(center.source, .blended)
            XCTAssertEqual(center.cpl, blended, accuracy: 1e-12)
        }
        XCTAssertEqual(preprocessing.toJSON()["prior_cpl_source"]?.asArray?.count, panel.C)
    }

    func testReportedCostsBecomeThoseChannelsPriorCentersAndSurviveTheReceipt() throws {
        let costs = """
        channel,reported_cost_per_outcome
        linkedin_ads,240
        out_of_home,1250.5
        """
        let panel = try PanelLoader.load(dropDir: try makeDrop(costs: costs))
        let preprocessing = PanelPreprocessing.fit(panel: panel, observedWeeks: panel.T)
        let byKey = Dictionary(uniqueKeysWithValues: zip(panel.channels, preprocessing.priorCenters))
        XCTAssertEqual(byKey["linkedin_ads"]?.source, .reported)
        XCTAssertEqual(byKey["linkedin_ads"]?.cpl, 240)
        XCTAssertEqual(byKey["out_of_home"]?.cpl, 1250.5)
        XCTAssertEqual(byKey["podcast_sponsorship"]?.source, .blended)
        XCTAssertEqual(byKey["email_nurture"]?.source, .blended)

        // The receipt carries the reported costs and the grader rebuilds the
        // same centers from it.
        let built = StanDataBuilder.build(panel: panel)
        let text = try built.meta.toJSON().serialized()
        let dir = NSTemporaryDirectory() + "signalrig-meta-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("panel_meta.json")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let meta = try Grader.loadPanelMeta(path: path)
        let reloaded = try XCTUnwrap(meta.fullPreprocessing)
        XCTAssertEqual(reloaded.priorCPL, preprocessing.priorCPL)
        XCTAssertEqual(reloaded.priorCenters.map { $0.source }, preprocessing.priorCenters.map { $0.source })
        for (c, center) in preprocessing.priorCenters.enumerated() {
            let expected = max((preprocessing.refSpend[c] / center.cpl / 0.5) / preprocessing.yScale, 1e-4)
            XCTAssertEqual(built.full.betaCenter[c], expected, accuracy: 1e-12)
        }
    }

    func testChannelsWithoutSpendAreNotedAndIgnored() throws {
        let costs = """
        channel,reported_cost_per_outcome
        linkedin_ads,240
        tiktok,55
        """
        let panel = try PanelLoader.load(dropDir: try makeDrop(costs: costs))
        XCTAssertEqual(panel.reportedCPL.compactMap { $0 }, [240])
        XCTAssertTrue(panel.warnings.contains { $0.contains("tiktok") && $0.contains(PanelLoader.platformCostsFile) })
    }

    func testMalformedCostsFailClosed() throws {
        let header = "channel,reported_cost_per_outcome\n"
        for (label, body) in [
            ("zero", "linkedin_ads,0"),
            ("negative", "linkedin_ads,-5"),
            ("text", "linkedin_ads,cheap"),
            ("empty", "linkedin_ads,"),
            ("duplicate", "linkedin_ads,10\nlinkedin_ads,12"),
        ] {
            XCTAssertThrowsError(try PanelLoader.load(dropDir: try makeDrop(costs: header + body)), label)
        }
        XCTAssertThrowsError(try PanelLoader.load(dropDir: try makeDrop(costs: "channel,cost\nlinkedin_ads,10")), "missing column")
    }

    func testPriorDiagnosticFlagsAnIntervalTheDataDidNotNarrow() {
        let center = PanelPreprocessing.PriorCenter(cpl: 180, source: .blended)
        let wide = ChannelsArtifactBuilder.priorDiagnostic(cplIv: IntervalResult(lo: 54, med: 167, hi: 720), center: center)
        XCTAssertTrue(wide.dominated)
        XCTAssertLessThan(wide.shrinkage, 0.1)
        let tight = ChannelsArtifactBuilder.priorDiagnostic(cplIv: IntervalResult(lo: 27, med: 40, hi: 59), center: center)
        XCTAssertFalse(tight.dominated)
        XCTAssertGreaterThan(tight.shrinkage, 0.6)
        let moved = ChannelsArtifactBuilder.priorDiagnostic(cplIv: IntervalResult(lo: 400, med: 1200, hi: 4000), center: center)
        XCTAssertFalse(moved.dominated)
        let reported = ChannelsArtifactBuilder.priorDiagnostic(cplIv: IntervalResult(lo: 54, med: 167, hi: 720),
                                                                center: PanelPreprocessing.PriorCenter(cpl: 150, source: .reported))
        XCTAssertEqual(reported.source, "reported")
        XCTAssertTrue(reported.dominated)
    }
}
