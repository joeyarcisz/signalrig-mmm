import XCTest
@testable import FitEngine

// Covers the task packet's section 5 requirements that must run WITHOUT any
// external fixture: the five malformed-input rejections, the foreign-drop
// prep path, a hygiene check of the full artifact set
// for a foreign package, JSONValue's non-finite guard, and the T-floor
// boundary. Every fixture this file reads lives under Tests/Fixtures/ in
// this repo (see generate_foreign_fixtures.py), so these tests run
// identically on any clean checkout -- no FITENGINE_* environment
// variables, no machine-specific paths.
final class ForeignFixtureTests: XCTestCase {
    static var fixturesDir: String {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()   // Tests/FitEngineTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures")
            .path
    }

    func fixturePath(_ name: String) -> String {
        (Self.fixturesDir as NSString).appendingPathComponent(name)
    }

    // MARK: - Rejection tests (frozen design decision 2 and 4)

    func testNaNKPIValueIsRejected() {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: fixturePath("fixture_nan_kpi"))) { error in
            guard let e = error as? PanelLoadError, case .malformedValue(let file, let row, let column, let text) = e else {
                XCTFail("expected PanelLoadError.malformedValue, got \(error)")
                return
            }
            XCTAssertEqual(file, "kpi.csv")
            XCTAssertEqual(row, 10)
            XCTAssertEqual(column, "kpi_value")
            XCTAssertEqual(text, "nan")
            print("[Rejection] fixture_nan_kpi -> \(e.description)")
        }
    }

    func testInfiniteSpendIsRejected() {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: fixturePath("fixture_inf_spend"))) { error in
            guard let e = error as? PanelLoadError, case .malformedValue(let file, let row, let column, let text) = e else {
                XCTFail("expected PanelLoadError.malformedValue, got \(error)")
                return
            }
            XCTAssertEqual(file, "paid_media.csv")
            XCTAssertEqual(row, 20)
            XCTAssertEqual(column, "spend")
            XCTAssertEqual(text, "inf")
            print("[Rejection] fixture_inf_spend -> \(e.description)")
        }
    }

    func testShortPanelIsRejected() {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: fixturePath("fixture_short_12wk"))) { error in
            guard let e = error as? PanelLoadError, case .insufficientWeeks(let weeks, let minimum) = e else {
                XCTFail("expected PanelLoadError.insufficientWeeks, got \(error)")
                return
            }
            XCTAssertEqual(weeks, 12)
            XCTAssertEqual(minimum, ArtifactConstants.minimumWeeks)
            print("[Rejection] fixture_short_12wk -> \(e.description)")
        }
    }

    func testMixedKPINameIsRejected() {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: fixturePath("fixture_mixed_kpi_name"))) { error in
            guard let e = error as? PanelLoadError, case .mixedKPIName(let file, let values) = e else {
                XCTFail("expected PanelLoadError.mixedKPIName, got \(error)")
                return
            }
            XCTAssertEqual(file, "kpi.csv")
            XCTAssertEqual(values, ["demo_requests", "signups"])
            print("[Rejection] fixture_mixed_kpi_name -> \(e.description)")
        }
    }

    func testNegativeSpendIsRejected() {
        XCTAssertThrowsError(try PanelLoader.load(dropDir: fixturePath("fixture_negative_spend"))) { error in
            guard let e = error as? PanelLoadError, case .negativeValue(let file, let row, let column, let text) = e else {
                XCTFail("expected PanelLoadError.negativeValue, got \(error)")
                return
            }
            XCTAssertEqual(file, "paid_media.csv")
            XCTAssertEqual(row, 15)
            XCTAssertEqual(column, "spend")
            XCTAssertEqual(text, "-50.0")
            print("[Rejection] fixture_negative_spend -> \(e.description)")
        }
    }

    // MARK: - T-floor boundary (self-contained, no committed fixture needed)

    func testFiftyOneWeekPanelIsRejectedAtTheBoundary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var kpiLines = ["date_week,geo,kpi_name,kpi_value"]
        var paidLines = ["date_week,geo,channel,spend"]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var date = DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2024, month: 1, day: 1).date!
        for t in 0..<51 {
            let ds = isoDate(date)
            kpiLines.append("\(ds),us,demo_requests,\(300 + t)")
            paidLines.append("\(ds),us,test_channel,\(100 + t)")
            date = cal.date(byAdding: .day, value: 7, to: date)!
        }
        try kpiLines.joined(separator: "\n").write(toFile: dir.appendingPathComponent("kpi.csv").path, atomically: true, encoding: .utf8)
        try paidLines.joined(separator: "\n").write(toFile: dir.appendingPathComponent("paid_media.csv").path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PanelLoader.load(dropDir: dir.path)) { error in
            guard let e = error as? PanelLoadError, case .insufficientWeeks(let weeks, let minimum) = e else {
                XCTFail("expected PanelLoadError.insufficientWeeks, got \(error)")
                return
            }
            XCTAssertEqual(weeks, 51)
            XCTAssertEqual(minimum, 52)
            print("[T-floor] 51-week panel -> \(e.description)")
        }
    }

    func isoDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - Foreign prep test (frozen design decisions 4, 5, 6)

    func testForeignDropLoadsAndPrepsCleanly() throws {
        let panel = try PanelLoader.load(dropDir: fixturePath("foreign_drop"))

        XCTAssertEqual(panel.kpiName, "demo_requests")
        XCTAssertEqual(panel.T, 64)
        XCTAssertEqual(panel.C, 4)
        XCTAssertEqual(panel.K, 1)
        // No registry channel is present, so order is purely alphabetical
        // (frozen design decision 6: unknown channels are first-class).
        XCTAssertEqual(panel.channels, ["email_nurture", "linkedin_ads", "out_of_home", "podcast_sponsorship"])

        let channelLabels = panel.channels.map { ChannelRegistry.label(forKey: $0) }
        XCTAssertEqual(channelLabels, ["Email Nurture", "Linkedin Ads", "Out Of Home", "Podcast Sponsorship"])
        print("[ForeignPrep] generated channel labels: \(channelLabels)")

        let geoWarning = panel.warnings.first { $0.contains("geos") }
        XCTAssertNotNil(geoWarning, "expected a geo-aggregation warning; got \(panel.warnings)")
        XCTAssertTrue(geoWarning?.contains("2 geos") ?? false)
        XCTAssertTrue(geoWarning?.contains("east") ?? false)
        XCTAssertTrue(geoWarning?.contains("west") ?? false)
        print("[ForeignPrep] geo warning: \(geoWarning ?? "<none>")")

        let built = StanDataBuilder.build(panel: panel)
        XCTAssertEqual(built.full.T, 64)
        XCTAssertEqual(built.full.obs, 64, "full obs must equal T (no holdout trim)")
        XCTAssertEqual(built.holdout.obs, 52, "holdout obs must be T - holdoutWeeks = 64 - 12")

        func assertAllFinite(_ json: JSONValue, path: String) {
            switch json {
            case .double(let d):
                XCTAssertTrue(d.isFinite, "\(path) is not finite: \(d)")
            case .array(let arr):
                for (i, v) in arr.enumerated() { assertAllFinite(v, path: "\(path)[\(i)]") }
            case .object(let dict):
                for (k, v) in dict { assertAllFinite(v, path: "\(path).\(k)") }
            default:
                break
            }
        }
        assertAllFinite(built.full.toJSON(), path: "data_full")
        assertAllFinite(built.holdout.toJSON(), path: "data_holdout")
        assertAllFinite(built.meta.toJSON(), path: "panel_meta")

        // Serializing must also succeed (JSONValue throws on any non-finite
        // double it is handed -- see JSONValueTests), which is a second,
        // independent way of confirming every value here is finite.
        _ = try built.full.toJSON().serialized()
        _ = try built.holdout.toJSON().serialized()
        _ = try built.meta.toJSON().serialized()
    }

    // MARK: - Brand-clean test (frozen design decision 7)

    // Builds a tiny, structurally-valid (not statistically meaningful)
    // 2-chains-by-50-draws CmdStan sampler CSV for C channels/T weeks/K
    // controls: every scalar posterior column DrawsReader/Metrics/
    // PosteriorView read, filled with small smooth deterministic values
    // (no RNG) that stay comfortably inside each parameter's valid domain
    // (adstock_alpha in (0,1), hill_kappa/hill_slope/sigma > 0). media_scaled
    // is omitted -- nothing in this package actually reads it (see
    // Diagnostics.swift's own comment).
    static func syntheticChainCSV(C: Int, K: Int, T: Int, draws: Int, drawOffset: Int) -> String {
        var header: [String] = []
        for c in 1...C { header.append("adstock_alpha.\(c)") }
        for c in 1...C { header.append("hill_kappa.\(c)") }
        for c in 1...C { header.append("hill_slope.\(c)") }
        for c in 1...C { header.append("channel_beta.\(c)") }
        header.append("intercept")
        header.append("trend")
        for f in 1...4 { header.append("fourier_beta.\(f)") }
        if K > 0 { for k in 1...K { header.append("control_gamma.\(k)") } }
        header.append("sigma")
        for t in 1...T { header.append("mu_scaled.\(t)") }
        header.append("divergent__")

        var lines = [header.joined(separator: ",")]
        for s in 0..<draws {
            let ds = Double(s + drawOffset)
            var vals: [Double] = []
            for c in 0..<C { vals.append(0.45 + 0.001 * ds + 0.01 * Double(c)) }   // adstock_alpha in (0,1)
            for c in 0..<C { vals.append(1.0 + 0.05 * Double(c)) }                 // hill_kappa > 0
            for c in 0..<C { vals.append(1.1 + 0.02 * Double(c)) }                 // hill_slope > 0
            for c in 0..<C { vals.append(0.004 + 0.0004 * Double(c)) }             // channel_beta (y-scaled units)
            vals.append(0.02)                                                       // intercept
            vals.append(0.001)                                                      // trend
            for _ in 0..<4 { vals.append(0.01) }                                    // fourier_beta
            for _ in 0..<K { vals.append(0.02) }                                    // control_gamma
            vals.append(0.05 + 0.0002 * ds)                                        // sigma > 0
            for t in 0..<T { vals.append(0.2 + 0.02 * sin(Double(t + s) / 6.0)) }   // mu_scaled
            vals.append(0)                                                          // divergent__
            lines.append(vals.map { String($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func writeSyntheticFit(dir: URL, C: Int, K: Int, T: Int, chains: Int, draws: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for chain in 1...chains {
            let text = Self.syntheticChainCSV(C: C, K: K, T: T, draws: draws, drawOffset: (chain - 1) * draws)
            try text.write(toFile: dir.appendingPathComponent("mmm_\(chain).csv").path, atomically: true, encoding: .utf8)
        }
    }

    func testForeignArtifactsAreBrandCleanForRealData() throws {
        let dropDir = fixturePath("foreign_drop")
        let panel = try PanelLoader.load(dropDir: dropDir)
        let built = StanDataBuilder.build(panel: panel)

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let metaPath = workDir.appendingPathComponent("panel_meta.json").path
        try (try built.meta.toJSON().serialized()).write(toFile: metaPath, atomically: true, encoding: .utf8)

        let fullDir = workDir.appendingPathComponent("full")
        let holdoutDir = workDir.appendingPathComponent("holdout")
        // 2 chains x 50 draws is plenty for a structural check; this is not
        // a real fit (see the packet's own allowance for a tiny in-code
        // Draws value via DrawsReader).
        try writeSyntheticFit(dir: fullDir, C: panel.C, K: panel.K, T: panel.T, chains: 2, draws: 50)
        try writeSyntheticFit(dir: holdoutDir, C: panel.C, K: panel.K, T: panel.T, chains: 2, draws: 50)

        let bundle = try ArtifactsPipeline.run(
            fullDir: fullDir.path,
            holdoutDir: holdoutDir.path,
            metaPath: metaPath,
            truthPath: nil,
            dropDir: dropDir,
            seed: 42,
            memoDate: "2026-01-01",
            packageLabel: "Demo Client",
            unavailableRecovery: true
        )

        let forbidden = ["NaN", "Infinity"]
        var assertionsRun: [String] = []
        for (name, value) in bundle.files {
            let text = try value.serialized()
            for f in forbidden {
                XCTAssertFalse(text.contains(f), "\(name) contains forbidden substring \"\(f)\"")
            }
        }
        assertionsRun.append("no artifact JSON string contains a non-finite number token")

        XCTAssertEqual(bundle.manifest["is_synthetic"]?.asBool, false)
        assertionsRun.append("manifest.is_synthetic == false")

        XCTAssertEqual(bundle.manifest["kpi_name"]?.asString, "demo_requests")
        assertionsRun.append("manifest.kpi_name == \"demo_requests\"")

        let title = bundle.memo["title"]?.asString ?? ""
        XCTAssertTrue(title.hasPrefix("Demo Client"), "memo title should start with the packageLabel parameter, got \(title)")
        assertionsRun.append("memo.title uses the packageLabel parameter (\"\(title)\")")

        let mape = bundle.diagnostics["mape_holdout_pct"]?.asDouble
        let r2 = bundle.diagnostics["r2_holdout"]?.asDouble
        let coverage = bundle.diagnostics["coverage_90_pct"]?.asDouble
        XCTAssertNotNil(mape, "diagnostics.mape_holdout_pct must be present")
        XCTAssertNotNil(r2, "diagnostics.r2_holdout must be present")
        XCTAssertNotNil(coverage, "diagnostics.coverage_90_pct must be present")
        XCTAssertTrue(mape?.isFinite ?? false, "diagnostics.mape_holdout_pct must be finite")
        XCTAssertTrue(r2?.isFinite ?? false, "diagnostics.r2_holdout must be finite")
        XCTAssertTrue(coverage?.isFinite ?? false, "diagnostics.coverage_90_pct must be finite")
        assertionsRun.append("diagnostics holdout numbers (mape=\(mape ?? .nan), r2=\(r2 ?? .nan), coverage=\(coverage ?? .nan)) are finite and present")

        print("[BrandClean] assertions checked:")
        for a in assertionsRun { print("  - \(a)") }
    }
}
