import Foundation

// Composes DrawsReader + Metrics + DiagnosticsCalc into the combined
// {"recovery": ..., "diagnostics": ...} shape grade.py writes to
// out/grade_result.json (read-only reference at
// the local spike workspace/scripts/grade.py).
public enum GraderError: Error, CustomStringConvertible {
    case invalidMeta(String)
    case invalidTruth(String)

    public var description: String {
        switch self {
        case .invalidMeta(let path): return "could not parse panel meta at \(path)"
        case .invalidTruth(let path): return "could not parse truth file at \(path)"
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
    public static func loadPanelMeta(path: String) throws -> PanelMeta {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let json = try JSONParser.parse(text)
        guard let channels = json["channels"]?.asStringArray,
              let dates = json["dates"]?.asStringArray,
              let xScale = json["x_scale"]?.asDoubleArray,
              let yScale = json["y_scale"]?.asDouble,
              let refSpend = json["ref_spend"]?.asDoubleArray,
              let xRaw = json["X_raw"]?.asDoubleMatrix,
              let yRaw = json["y_raw"]?.asDoubleArray,
              let holdoutWeeks = json["holdout_weeks"]?.asInt,
              let lMax = json["l_max"]?.asInt else {
            throw GraderError.invalidMeta(path)
        }
        return PanelMeta(channels: channels, dates: dates, xScale: xScale, yScale: yScale,
                          refSpend: refSpend, xRaw: xRaw, yRaw: yRaw, holdoutWeeks: holdoutWeeks, lMax: lMax)
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
    public static func grade(fullDir: String, holdoutDir: String?, metaPath: String, truthPath: String,
                              maxDraws: Int = Int.max) throws -> GradeOutput {
        let meta = try loadPanelMeta(path: metaPath)
        let truth = try loadTruth(path: truthPath)

        let fitFull = try DrawsReader.readDirectory(dir: fullDir)
        let drawsFull = Metrics.subsampleDraws(fit: fitFull, yScale: meta.yScale, maxDraws: maxDraws)
        let recovery = Metrics.recovery(draws: drawsFull, meta: meta, truth: truth, L: meta.lMax)
        let diagnostics = DiagnosticsCalc.compute(fit: fitFull)

        var holdout: HoldoutDiagnostics?
        if let holdoutDir = holdoutDir, dirHasCSV(holdoutDir) {
            let fitHoldout = try DrawsReader.readDirectory(dir: holdoutDir)
            let drawsHoldout = Metrics.subsampleDraws(fit: fitHoldout, yScale: meta.yScale, maxDraws: maxDraws)
            holdout = Metrics.holdoutDiagnostics(drawsHoldout: drawsHoldout, yRaw: meta.yRaw, yScale: meta.yScale,
                                                  holdoutWeeks: meta.holdoutWeeks)
        }

        return GradeOutput(recovery: recovery, diagnostics: diagnostics, holdout: holdout)
    }

    static func dirHasCSV(_ dir: String) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return contents.contains { $0.hasSuffix(".csv") }
    }
}
