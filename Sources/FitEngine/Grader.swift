import Foundation

// Composes DrawsReader + Metrics + DiagnosticsCalc into the combined
// {"recovery": ..., "diagnostics": ...} shape grade.py writes to
// out/grade_result.json (read-only reference at
// the historical Stan feasibility workspace/scripts/grade.py).
public enum GraderError: Error, CustomStringConvertible {
    case invalidMeta(String)
    case invalidTruth(String)
    case missingHoldoutPreprocessing
    case reusedFullFit

    public var description: String {
        switch self {
        case .invalidMeta(let path): return "could not parse panel meta at \(path)"
        case .invalidTruth(let path): return "could not parse truth file at \(path)"
        case .missingHoldoutPreprocessing:
            return "holdout preprocessing metadata is missing or legacy; refit the data before verifying holdout results"
        case .reusedFullFit:
            return "holdout requires independently fitted training-window draws; full-fit draws or their directory were reused"
        }
    }
}

public struct GradeOutput {
    public let recovery: RecoveryResult
    public let diagnostics: DiagnosticsResult
    public let holdout: HoldoutDiagnostics?

    public func toJSON() -> JSONValue {
        var diagObj: [String: JSONValue] = [
            "rhat_max": .double(diagnostics.rhatMax),
            "ess_bulk_min": .int(diagnostics.essBulkMin),
            "divergences": .int(diagnostics.divergences),
        ]
        if let h = holdout {
            diagObj["mape_holdout_pct"] = .double(h.mapePct)
            diagObj["r2_holdout"] = .double(h.r2)
            diagObj["coverage_90_pct"] = .double(h.coverage90Pct)
        } else {
            diagObj["mape_holdout_pct"] = .string("skipped")
            diagObj["r2_holdout"] = .string("skipped")
            diagObj["coverage_90_pct"] = .string("skipped")
        }
        return .object([
            "recovery": recovery.toJSON(),
            "diagnostics": .object(diagObj),
        ])
    }
}

public enum Grader {
    // Metadata is part of the unit conversion contract. Reject malformed
    // numeric cells rather than the permissive JSON array accessors that
    // substitute zero for a nonnumeric item.
    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard let number = value?.asDouble, number.isFinite else { return nil }
        return number
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let number = finiteNumber(value) else { return nil }
        return Int(exactly: number)
    }

    private static func numbers(_ value: JSONValue?) -> [Double]? {
        guard let array = value?.asArray else { return nil }
        let result = array.compactMap { finiteNumber($0) }
        return result.count == array.count ? result : nil
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard let array = value?.asArray else { return nil }
        let result = array.compactMap { $0.asString }
        return result.count == array.count ? result : nil
    }

    private static func matrix(_ value: JSONValue?) -> [[Double]]? {
        guard let array = value?.asArray else { return nil }
        let result = array.compactMap { numbers($0) }
        return result.count == array.count ? result : nil
    }

    private static func loadPreprocessing(_ value: JSONValue, path: String) throws -> PanelPreprocessing {
        guard integer(value["version"]) == PanelPreprocessing.version,
              let observedWeeks = integer(value["observed_weeks"]),
              let xScale = numbers(value["x_scale"]), let yScale = finiteNumber(value["y_scale"]),
              let refSpend = numbers(value["ref_spend"]),
              let controlNames = strings(value["control_names"]),
              let controlMean = numbers(value["control_mean"]), let controlStd = numbers(value["control_std"]),
              let priorCPL = numbers(value["prior_cpl"]), priorCPL.count == refSpend.count,
              priorCPL.allSatisfy({ $0 > 0 }), yScale > 0,
              let referenceMeanKPI = finiteNumber(value["reference_mean_kpi"]), referenceMeanKPI > 0,
              value["prior_source"]?.asString == PanelPreprocessing.priorSource,
              let betaCenter = numbers(value["beta_center"]) else {
            throw GraderError.invalidMeta(path)
        }
        // reported_cpl is per channel, null where the package gave none; a
        // receipt written before the field existed reads as all-null.
        var reportedCPL = [Double?](repeating: nil, count: refSpend.count)
        if let raw = value["reported_cpl"]?.asArray {
            guard raw.count == refSpend.count else { throw GraderError.invalidMeta(path) }
            for (i, item) in raw.enumerated() {
                if case .null = item { continue }
                guard let number = finiteNumber(item), number > 0 else { throw GraderError.invalidMeta(path) }
                reportedCPL[i] = number
            }
        }
        let preprocessing = PanelPreprocessing(
            observedWeeks: observedWeeks, xScale: xScale, yScale: yScale, refSpend: refSpend,
            controlNames: controlNames, controlMean: controlMean, controlStd: controlStd,
            referenceMeanKPI: referenceMeanKPI, reportedCPL: reportedCPL
        )
        // The stored prior must be exactly the one this receipt's own window implies.
        guard zip(priorCPL, preprocessing.priorCPL).allSatisfy({ actual, expected in
                  expected.isFinite && abs(actual - expected) <= max(1, abs(expected)) * 1e-12
              }),
              betaCenter.count == priorCPL.count,
              zip(betaCenter, preprocessing.betaCenter).allSatisfy({ actual, expected in
                  expected.isFinite && abs(actual - expected) <= max(1, abs(expected)) * 1e-12
              }) else {
            throw GraderError.invalidMeta(path)
        }
        return preprocessing
    }

    public static func loadPanelMeta(path: String) throws -> PanelMeta {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let json = try JSONParser.parse(text)
        guard let channels = strings(json["channels"]), let dates = strings(json["dates"]),
              let xScale = numbers(json["x_scale"]), let yScale = finiteNumber(json["y_scale"]),
              let refSpend = numbers(json["ref_spend"]), let xRaw = matrix(json["X_raw"]),
              let yRaw = numbers(json["y_raw"]), let holdoutWeeks = integer(json["holdout_weeks"]),
              let lMax = integer(json["l_max"]) else {
            throw GraderError.invalidMeta(path)
        }
        let fullPreprocessing = try json["full_preprocessing"].map { try loadPreprocessing($0, path: path + ": full_preprocessing") }
        let holdout = try json["holdout"].map { try loadPreprocessing($0, path: path + ": holdout") }
        return PanelMeta(channels: channels, dates: dates, xScale: xScale, yScale: yScale,
                          refSpend: refSpend, xRaw: xRaw, yRaw: yRaw, holdoutWeeks: holdoutWeeks, lMax: lMax,
                          fullPreprocessing: fullPreprocessing, holdout: holdout)
    }

    public static func loadTruth(path: String) throws -> [TruthChannel] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let json = try JSONParser.parse(text)
        guard let arr = json["channels"]?.asArray else {
            throw GraderError.invalidTruth(path)
        }
        return arr.compactMap { TruthChannel.parse($0) }
    }

    // maxDraws defaults to Int.max (all draws, no RNG subsampling; see
    // Metrics.subsampleDraws). Pass a smaller value only when a faster,
    // RNG-subsampled estimate is wanted instead of the exact one.
    static func validatePanelMeta(_ meta: PanelMeta, fit: StanFit) throws {
        guard meta.channels.count == fit.C, meta.dates.count == fit.T,
              Set(meta.channels).count == fit.C, Set(meta.dates).count == fit.T,
              meta.xScale.count == fit.C, meta.refSpend.count == fit.C,
              meta.xRaw.count == fit.T, meta.yRaw.count == fit.T,
              meta.xRaw.allSatisfy({ $0.count == fit.C && $0.allSatisfy { $0.isFinite && $0 >= 0 } }),
              meta.yRaw.allSatisfy({ $0.isFinite && $0 >= 0 }),
              meta.xScale.allSatisfy({ $0.isFinite && $0 > 0 }),
              meta.refSpend.allSatisfy({ $0.isFinite && $0 >= 0 }),
              meta.yScale.isFinite, meta.yScale > 0, meta.lMax > 0,
              meta.holdoutWeeks >= 0, meta.holdoutWeeks < fit.T else {
            throw ArtifactDiagnosticsError.incompatiblePanels
        }
        if let full = meta.fullPreprocessing {
            try validatePreprocessing(full, meta: meta, fit: fit)
            guard full.observedWeeks == fit.T, full.xScale == meta.xScale,
                  full.yScale == meta.yScale, full.refSpend == meta.refSpend else {
                throw ArtifactDiagnosticsError.incompatiblePanels
            }
        }
    }

    private static func validatePreprocessing(_ preprocessing: PanelPreprocessing, meta: PanelMeta, fit: StanFit) throws {
        guard preprocessing.observedWeeks > 0, preprocessing.observedWeeks <= fit.T,
              preprocessing.xScale.count == fit.C, preprocessing.refSpend.count == fit.C,
              preprocessing.referenceMeanKPI.isFinite, preprocessing.referenceMeanKPI > 0,
              preprocessing.priorCPL.allSatisfy({ $0.isFinite && $0 > 0 }),
              preprocessing.controlNames.count == fit.K, Set(preprocessing.controlNames).count == fit.K,
              preprocessing.controlMean.count == fit.K, preprocessing.controlStd.count == fit.K,
              preprocessing.controlMean.allSatisfy({ $0.isFinite }),
              preprocessing.controlStd.allSatisfy({ $0.isFinite && $0 >= 0 }),
              preprocessing.xScale.allSatisfy({ $0.isFinite && $0 > 0 }),
              preprocessing.refSpend.allSatisfy({ $0.isFinite && $0 > 0 }),
              preprocessing.yScale.isFinite, preprocessing.yScale > 0 else {
            throw ArtifactDiagnosticsError.incompatiblePanels
        }
    }

    // Legacy full-panel scales cannot safely rescale a newly trained
    // holdout model. A saved training-window receipt is required, with
    // its own KPI units and the same panel/column ordering as the full fit.
    static func holdoutPanelMeta(_ meta: PanelMeta, fit: StanFit) throws -> PanelMeta {
        try validatePanelMeta(meta, fit: fit)
        guard let full = meta.fullPreprocessing, let holdout = meta.holdout else {
            throw GraderError.missingHoldoutPreprocessing
        }
        try validatePreprocessing(holdout, meta: meta, fit: fit)
        guard meta.holdoutWeeks > 0, holdout.observedWeeks == fit.T - meta.holdoutWeeks,
              holdout.controlNames == full.controlNames else {
            throw ArtifactDiagnosticsError.incompatiblePanels
        }
        return PanelMeta(
            channels: meta.channels, dates: meta.dates, xScale: holdout.xScale, yScale: holdout.yScale,
            refSpend: holdout.refSpend, xRaw: meta.xRaw, yRaw: meta.yRaw,
            holdoutWeeks: meta.holdoutWeeks, lMax: meta.lMax, appliedPreprocessing: holdout
        )
    }

    static func validateFitDirectories(fullDir: String, holdoutDir: String) throws {
        let full = URL(fileURLWithPath: fullDir).resolvingSymlinksInPath().standardizedFileURL
        let holdout = URL(fileURLWithPath: holdoutDir).resolvingSymlinksInPath().standardizedFileURL
        guard full != holdout else { throw GraderError.reusedFullFit }
    }

    static func validateIndependentFits(full: StanFit, holdout: StanFit) throws {
        let parameters = DiagnosticsCalc.scalarColumnNames(C: full.C, K: full.K)
        for fullChain in full.chains {
            for holdoutChain in holdout.chains where parameters.allSatisfy({
                fullChain.columns[$0] == holdoutChain.columns[$0]
            }) {
                throw GraderError.reusedFullFit
            }
        }
    }

    public static func grade(fullDir: String, holdoutDir: String?, metaPath: String, truthPath: String,
                              maxDraws: Int = Int.max) throws -> GradeOutput {
        if let holdoutDir { try validateFitDirectories(fullDir: fullDir, holdoutDir: holdoutDir) }
        let meta = try loadPanelMeta(path: metaPath)
        let truth = try loadTruth(path: truthPath)

        let fitFull = try DrawsReader.readDirectory(dir: fullDir)
        try validatePanelMeta(meta, fit: fitFull)
        let drawsFull = Metrics.subsampleDraws(fit: fitFull, yScale: meta.yScale, maxDraws: maxDraws)
        let recovery = Metrics.recovery(draws: drawsFull, meta: meta, truth: truth, L: meta.lMax)
        var diagnostics = try DiagnosticsCalc.compute(fit: fitFull)

        var holdout: HoldoutDiagnostics?
        if let holdoutDir = holdoutDir, dirHasCSV(holdoutDir) {
            let fitHoldout = try DrawsReader.readDirectory(dir: holdoutDir)
            let holdoutMeta = try holdoutPanelMeta(meta, fit: fitHoldout)
            try validateIndependentFits(full: fitFull, holdout: fitHoldout)
            let holdoutDiagnostics = try DiagnosticsCalc.compute(fit: fitHoldout)
            diagnostics = DiagnosticsResult(
                rhatMax: max(diagnostics.rhatMax, holdoutDiagnostics.rhatMax),
                essBulkMin: min(diagnostics.essBulkMin, holdoutDiagnostics.essBulkMin),
                divergences: diagnostics.divergences + holdoutDiagnostics.divergences
            )
            let drawsHoldout = Metrics.subsampleDraws(fit: fitHoldout, yScale: holdoutMeta.yScale, maxDraws: maxDraws)
            holdout = Metrics.holdoutDiagnostics(drawsHoldout: drawsHoldout, yRaw: meta.yRaw, yScale: holdoutMeta.yScale,
                                                  holdoutWeeks: meta.holdoutWeeks)
        }

        return GradeOutput(recovery: recovery, diagnostics: diagnostics, holdout: holdout)
    }

    static func dirHasCSV(_ dir: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return contents.contains { $0.hasSuffix(".csv") }
    }
}
