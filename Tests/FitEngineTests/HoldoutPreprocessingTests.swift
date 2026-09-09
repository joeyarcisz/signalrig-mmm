import XCTest
@testable import FitEngine

final class HoldoutPreprocessingTests: XCTestCase {
    private func panel(weeks: Int = 64, controls: Bool = true) -> Panel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let dates = (0..<weeks).map { formatter.string(from: start.addingTimeInterval(Double($0) * 604800)) }
        return Panel(
            dates: dates, channels: ["client_search"], X: (0..<weeks).map { [100 + Double($0)] },
            y: (0..<weeks).map { 50 + Double($0) },
            rawControls: (0..<weeks).map { controls ? [Double($0), $0 < weeks - 12 ? 3 : 80] : [] },
            controlNames: controls ? ["temperature", "treatment_launch"] : [],
            kpiName: "leads", warnings: []
        )
    }

    private func changing(_ panel: Panel, X: [[Double]]? = nil, y: [Double]? = nil, controls: [[Double]]? = nil) -> Panel {
        Panel(
            dates: panel.dates, channels: panel.channels, X: X ?? panel.X, y: y ?? panel.y,
            rawControls: controls ?? panel.rawControls, controlNames: panel.controlNames,
            kpiName: panel.kpiName, warnings: panel.warnings
        )
    }

    private func withDrop(_ panel: Panel, _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HoldoutPrep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kpi = ["date_week,geo,kpi_name,kpi_value"] + (0..<panel.T).map {
            "\(panel.dates[$0]),national,leads,\(panel.y[$0])"
        }
        let spend = ["date_week,geo,channel,spend"] + (0..<panel.T).map {
            "\(panel.dates[$0]),national,client_search,\(panel.X[$0][0])"
        }
        try kpi.joined(separator: "\n").write(to: dir.appendingPathComponent("kpi.csv"), atomically: true, encoding: .utf8)
        try spend.joined(separator: "\n").write(to: dir.appendingPathComponent("paid_media.csv"), atomically: true, encoding: .utf8)
        if panel.K > 0 {
            let controls = ["date_week,geo,control_name,control_value"] + (0..<panel.T).flatMap { t in
                (0..<panel.K).map { c in "\(panel.dates[t]),national,\(panel.controlNames[c]),\(panel.rawControls[t][c])" }
            }
            try controls.joined(separator: "\n").write(to: dir.appendingPathComponent("controls.csv"), atomically: true, encoding: .utf8)
        }
        try body(dir)
    }

    private func writeFit(_ fit: StanFit, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, chain) in fit.chains.enumerated() {
            let rows = [chain.header.joined(separator: ",")] + (0..<chain.nDraws).map { draw in
                chain.header.map { String(chain.columns[$0]![draw]) }.joined(separator: ",")
            }
            try rows.joined(separator: "\n").write(
                to: directory.appendingPathComponent("mmm_\(index + 1).csv"), atomically: true, encoding: .utf8
            )
        }
    }

    func testLoaderPreservesRawControlsBeforeFittingTransforms() throws {
        let source = panel()
        try withDrop(source) { dir in
            let loaded = try PanelLoader.load(dropDir: dir.path)
            XCTAssertEqual(loaded.rawControls, source.rawControls)
            XCTAssertEqual(loaded.controlNames, source.controlNames)
            XCTAssertNotEqual(loaded.Z, loaded.rawControls)
        }
    }

    func testIgnoredOrganicFileProducesAnExplicitWarning() throws {
        try withDrop(panel()) { dir in
            try "date_week,channel,visits\n2025-01-06,organic,25".write(
                to: dir.appendingPathComponent("organic_owned.csv"), atomically: true, encoding: .utf8
            )
            let loaded = try PanelLoader.load(dropDir: dir.path)
            XCTAssertTrue(loaded.warnings.contains("organic_owned.csv is not used by the current model."))
        }
    }

    func testHeldOutKPICannotChangeAnyHoldoutSamplerInput() throws {
        let original = panel()
        let base = StanDataBuilder.build(panel: original)
        var y = original.y
        for t in base.holdout.obs..<original.T { y[t] = 1_000_000 + Double(t) }
        let changed = StanDataBuilder.build(panel: changing(original, y: y))

        XCTAssertEqual(try base.holdout.toJSON().serialized(), try changed.holdout.toJSON().serialized())
        XCTAssertEqual(try base.meta.holdout?.toJSON().serialized(), try changed.meta.holdout?.toJSON().serialized())
        XCTAssertNotEqual(base.meta.yScale, changed.meta.yScale, "the full fit should still use its complete observed panel")
        XCTAssertEqual(Array(changed.holdout.yS.suffix(12)), [Double](repeating: 0, count: 12))
        XCTAssertEqual(changed.meta.yRaw, y, "held-out outcomes remain available only for scoring")
    }

    func testFutureCovariatesDoNotChangeTrainingInputsOrPriorCenters() throws {
        let original = panel()
        let base = StanDataBuilder.build(panel: original)
        let observed = base.holdout.obs
        var X = original.X
        var controls = original.rawControls
        for t in observed..<original.T {
            X[t][0] = 1_000_000 + Double(t)
            controls[t][0] = -5_000 + Double(t)
            controls[t][1] = 2_000
        }
        let changed = StanDataBuilder.build(panel: changing(original, X: X, controls: controls))

        XCTAssertEqual(Array(base.holdout.xNorm.prefix(observed)), Array(changed.holdout.xNorm.prefix(observed)))
        XCTAssertEqual(Array(base.holdout.Z.prefix(observed)), Array(changed.holdout.Z.prefix(observed)))
        XCTAssertEqual(base.holdout.yS, changed.holdout.yS)
        XCTAssertEqual(base.holdout.betaCenter, changed.holdout.betaCenter)
        XCTAssertEqual(base.holdout.Fx, changed.holdout.Fx)
        XCTAssertEqual(base.holdout.tNorm, changed.holdout.tNorm)
        XCTAssertEqual(try base.meta.holdout?.toJSON().serialized(), try changed.meta.holdout?.toJSON().serialized())
        XCTAssertNotEqual(base.holdout.xNorm[observed], changed.holdout.xNorm[observed])
        XCTAssertNotEqual(base.holdout.Z[observed], changed.holdout.Z[observed])
        XCTAssertEqual(changed.holdout.xNorm[observed][0], X[observed][0] / 151, accuracy: 1e-10)
        XCTAssertEqual(changed.holdout.T, original.T, "keep training adstock history and later conditional inputs together")
    }

    func testControlMeanAndPopulationStdUseOnlyTrainingWeeks() throws {
        let built = StanDataBuilder.build(panel: panel())
        let preprocessing = try XCTUnwrap(built.meta.holdout)
        // Closed-form mean and population variance for integers 0...51.
        let expectedMean = 25.5
        let expectedStd = ((52.0 * 52.0 - 1) / 12).squareRoot()
        XCTAssertEqual(preprocessing.controlMean[0], expectedMean, accuracy: 1e-12)
        XCTAssertEqual(preprocessing.controlStd[0], expectedStd, accuracy: 1e-12)
        XCTAssertEqual(built.holdout.Z[0][0], (0 - expectedMean) / expectedStd, accuracy: 1e-12)
        XCTAssertEqual(built.holdout.Z[63][0], (63 - expectedMean) / expectedStd, accuracy: 1e-12)
        XCTAssertNotEqual(built.meta.fullPreprocessing?.controlMean[0], preprocessing.controlMean[0])
    }

    func testTrainingConstantControlUsesUnitDenominatorWithoutFutureLeakage() throws {
        let built = StanDataBuilder.build(panel: panel())
        let preprocessing = try XCTUnwrap(built.meta.holdout)
        XCTAssertEqual(preprocessing.controlMean[1], 3)
        XCTAssertEqual(preprocessing.controlStd[1], 0)
        XCTAssertTrue(built.holdout.Z.prefix(52).allSatisfy { $0[1] == 0 })
        XCTAssertEqual(built.holdout.Z[52][1], 77)
    }

    func testReferenceSpendAndPriorCenterEndAtTheTrainingBoundary() throws {
        let built = StanDataBuilder.build(panel: panel(weeks: 80))
        let preprocessing = try XCTUnwrap(built.meta.holdout)
        // Training weeks are 0...67. Its last 52 weeks are 16...67.
        XCTAssertEqual(preprocessing.observedWeeks, 68)
        XCTAssertEqual(preprocessing.xScale[0], 167)
        XCTAssertEqual(preprocessing.yScale, 117)
        XCTAssertEqual(preprocessing.refSpend[0], 141.5)
        // The prior center is learned from the same training-only window: the
        // blended CPL is total reference spend over half of the mean outcome.
        let source = panel(weeks: 80)
        let meanKPI = (16..<68).reduce(0.0) { $0 + source.y[$1] } / 52.0
        XCTAssertEqual(preprocessing.referenceMeanKPI, meanKPI, accuracy: 1e-9)
        let blended = 141.5 / (0.5 * meanKPI)
        XCTAssertEqual(preprocessing.priorCPL.count, 1)
        XCTAssertEqual(preprocessing.priorCPL[0], blended, accuracy: 1e-9)
        XCTAssertEqual(built.holdout.betaCenter[0], 2 * 141.5 / (blended * 117), accuracy: 1e-9)
        XCTAssertEqual(preprocessing.toJSON()["prior_source"]?.asString, PanelPreprocessing.priorSource)
        XCTAssertEqual(preprocessing.toJSON()["reference_mean_kpi"]?.asDouble, meanKPI)
        XCTAssertEqual(preprocessing.toJSON()["beta_center"]?.asDoubleArray, built.holdout.betaCenter)
    }

    func testSeparatePreprocessingReceiptsSurviveMetadataRoundTrip() throws {
        let source = panel()
        let built = StanDataBuilder.build(panel: source)
        try withDrop(source) { dir in
            let path = dir.appendingPathComponent("panel_meta.json")
            try built.meta.toJSON().serialized().write(to: path, atomically: true, encoding: .utf8)
            let loaded = try Grader.loadPanelMeta(path: path.path)
            XCTAssertEqual(try loaded.toJSON().serialized(), try built.meta.toJSON().serialized())
            XCTAssertEqual(loaded.yScale, 113)
            XCTAssertEqual(loaded.holdout?.yScale, 101)
            XCTAssertEqual(loaded.fullPreprocessing?.observedWeeks, 64)
            XCTAssertEqual(loaded.holdout?.observedWeeks, 52)
        }
    }

    func testArtifactsAndCLIGradeUseHoldoutKPIUnits() throws {
        let original = panel(controls: false)
        let source = changing(original, y: (0..<original.T).map { $0 < 52 ? 100 : 200 })
        let built = StanDataBuilder.build(panel: source)
        let fit = PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T)
        let holdoutFit = PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T, seedOffset: 1)
        try withDrop(source) { dir in
            let fullDir = dir.appendingPathComponent("full")
            let holdoutDir = dir.appendingPathComponent("holdout")
            try writeFit(fit, to: fullDir)
            try writeFit(holdoutFit, to: holdoutDir)
            let metaPath = dir.appendingPathComponent("panel_meta.json")
            try built.meta.toJSON().serialized().write(to: metaPath, atomically: true, encoding: .utf8)
            let truthPath = dir.appendingPathComponent("truth.json")
            try "{\"channels\":[]}".write(to: truthPath, atomically: true, encoding: .utf8)

            let expectedDraws = Metrics.subsampleDraws(fit: holdoutFit, yScale: 100)
            let expected = Metrics.holdoutDiagnostics(drawsHoldout: expectedDraws, yRaw: source.y, yScale: 100, holdoutWeeks: 12)
            let wrong = Metrics.holdoutDiagnostics(drawsHoldout: expectedDraws, yRaw: source.y, yScale: 200, holdoutWeeks: 12)
            XCTAssertNotEqual(expected.mapePct, wrong.mapePct)

            let grade = try Grader.grade(fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path, truthPath: truthPath.path)
            XCTAssertEqual(grade.holdout?.mapePct, expected.mapePct)
            let bundle = try ArtifactsPipeline.run(
                fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path,
                truthPath: nil, dropDir: dir.path, unavailableRecovery: true
            )
            XCTAssertEqual(bundle.diagnostics["mape_holdout_pct"]?.asDouble, expected.mapePct)
            XCTAssertEqual(bundle.diagnostics["quality_policy_version"]?.asInt, 4)
            let firstPrediction = try XCTUnwrap(bundle.diagnostics["holdout"]?.asArray?.first?["pred_med"]?.asDouble)
            // Week 53 has fixture mean 0.57, in training KPI units (100).
            // Applying the full-panel scale (200) would incorrectly give 114.
            XCTAssertEqual(firstPrediction, 57, accuracy: 1)
        }
    }

    func testLegacyMetadataCannotCertifyHoldoutButCanGradeHistoricalFullFit() throws {
        let source = panel(controls: false)
        let built = StanDataBuilder.build(panel: source)
        let fit = PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T)
        try withDrop(source) { dir in
            let fullDir = dir.appendingPathComponent("full")
            let holdoutDir = dir.appendingPathComponent("holdout")
            try writeFit(fit, to: fullDir)
            try writeFit(PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T, seedOffset: 1), to: holdoutDir)
            var legacy = try XCTUnwrap(built.meta.toJSON().asObject)
            legacy.removeValue(forKey: "full_preprocessing")
            legacy.removeValue(forKey: "holdout")
            let metaPath = dir.appendingPathComponent("panel_meta.json")
            try JSONValue.object(legacy).serialized().write(to: metaPath, atomically: true, encoding: .utf8)
            let truthPath = dir.appendingPathComponent("truth.json")
            try "{\"channels\":[]}".write(to: truthPath, atomically: true, encoding: .utf8)

            let historical = try Grader.grade(fullDir: fullDir.path, holdoutDir: nil, metaPath: metaPath.path, truthPath: truthPath.path)
            XCTAssertNil(historical.holdout)
            XCTAssertThrowsError(try Grader.grade(fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path, truthPath: truthPath.path)) { error in
                guard let error = error as? GraderError, case .missingHoldoutPreprocessing = error else {
                    return XCTFail("expected a legacy-holdout refit error, got \(error)")
                }
            }
            XCTAssertThrowsError(try ArtifactsPipeline.run(
                fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path,
                truthPath: nil, dropDir: dir.path, unavailableRecovery: true
            ))
        }
    }

    func testIncorrectSavedTrainingBoundaryIsRejected() throws {
        let source = panel(controls: false)
        let built = StanDataBuilder.build(panel: source)
        let fit = PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T)
        try withDrop(source) { dir in
            var object = try XCTUnwrap(built.meta.toJSON().asObject)
            var holdout = try XCTUnwrap(object["holdout"]?.asObject)
            holdout["observed_weeks"] = .int(source.T)
            object["holdout"] = .object(holdout)
            let path = dir.appendingPathComponent("panel_meta.json")
            try JSONValue.object(object).serialized().write(to: path, atomically: true, encoding: .utf8)
            let meta = try Grader.loadPanelMeta(path: path.path)
            XCTAssertThrowsError(try Grader.holdoutPanelMeta(meta, fit: fit))
        }
    }

    func testMalformedPreprocessingNumbersAreNotSubstitutedWithZeros() throws {
        let source = panel()
        let built = StanDataBuilder.build(panel: source)
        try withDrop(source) { dir in
            for (key, bad) in [
                ("control_mean", JSONValue.array([.string("missing"), .double(3)])),
                ("observed_weeks", .double(52.5)),
                ("prior_cpl", .array([.double(0)])),
                ("prior_cpl", .array([.double(181)])),
                ("reference_mean_kpi", .double(0)),
                ("beta_center", .array([.double(9_999)])),
            ] {
                var object = try XCTUnwrap(built.meta.toJSON().asObject)
                var holdout = try XCTUnwrap(object["holdout"]?.asObject)
                holdout[key] = bad
                object["holdout"] = .object(holdout)
                let path = dir.appendingPathComponent("panel_meta.json")
                try JSONValue.object(object).serialized().write(to: path, atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try Grader.loadPanelMeta(path: path.path), "malformed \(key) must fail")
            }
        }
    }

    func testReusedFullFitIsRejectedByArtifactsAndGrade() throws {
        let source = panel(controls: false)
        let built = StanDataBuilder.build(panel: source)
        let fit = PosteriorDiagnosticFixture.fit(draws: 32, weeks: source.T)
        try withDrop(source) { dir in
            let fullDir = dir.appendingPathComponent("full")
            try writeFit(fit, to: fullDir)
            let metaPath = dir.appendingPathComponent("panel_meta.json")
            try built.meta.toJSON().serialized().write(to: metaPath, atomically: true, encoding: .utf8)
            let truthPath = dir.appendingPathComponent("truth.json")
            try "{\"channels\":[]}".write(to: truthPath, atomically: true, encoding: .utf8)

            let linkedDir = dir.appendingPathComponent("holdout-link")
            try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: fullDir)
            let copiedDir = dir.appendingPathComponent("holdout-copy")
            try writeFit(fit, to: copiedDir)
            for holdoutDir in [fullDir, linkedDir, copiedDir] {
                XCTAssertThrowsError(try Grader.grade(
                    fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path, truthPath: truthPath.path
                )) { error in
                    guard let error = error as? GraderError, case .reusedFullFit = error else {
                        return XCTFail("expected reused-full-fit error, got \(error)")
                    }
                }
                XCTAssertThrowsError(try ArtifactsPipeline.run(
                    fullDir: fullDir.path, holdoutDir: holdoutDir.path, metaPath: metaPath.path,
                    truthPath: nil, dropDir: dir.path, unavailableRecovery: true
                )) { error in
                    guard let error = error as? GraderError, case .reusedFullFit = error else {
                        return XCTFail("expected reused-full-fit error, got \(error)")
                    }
                }
            }
        }
    }
}
