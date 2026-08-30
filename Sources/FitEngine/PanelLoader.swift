import Foundation

// Mirrors engine/model/mmm.py Panel (read-only Python reference at
// the Python reference implementation). X and Z are stored row-major
// (T outer, C/K inner) to match how the Python arrays are shaped and
// iterated when this code was ported.
public struct Panel {
    public let dates: [String]
    public let channels: [String]
    public let X: [[Double]]      // (T, C) raw weekly spend
    public let y: [Double]        // (T,) raw KPI
    public let Z: [[Double]]      // (T, K) standardized controls + treatments
    public let controlNames: [String]

    // KPI display name, read from kpi.csv's own kpi_name column (see
    // PanelLoader.resolveKPIName) -- never a hardcoded fixture string.
    public let kpiName: String

    // Human-readable notes about lossy or aggregating decisions the loader
    // made silently before this fix (geo aggregation, duplicate date+
    // channel spend rows, a missing/empty kpi_name column). Empty when
    // nothing of note happened. CLI commands print these; callers that
    // don't care are free to ignore the list.
    public let warnings: [String]

    public var T: Int { dates.count }
    public var C: Int { channels.count }
    public var K: Int { controlNames.count }

    // Per-channel spend normalizer: max spend across the panel, floored at 1e-9.
    public var xScale: [Double] {
        (0..<C).map { c in
            var m = 0.0
            for t in 0..<T { m = max(m, X[t][c]) }
            return max(m, 1e-9)
        }
    }

    public var yScale: Double {
        var m = 0.0
        for v in y { m = max(m, v) }
        return max(m, 1e-9)
    }

    // Mean spend over the last min(52, T) weeks, floored at 1e-9.
    public var refSpend: [Double] {
        let tailLen = min(52, T)
        let tailStart = T - tailLen
        return (0..<C).map { c in
            var s = 0.0
            for t in tailStart..<T { s += X[t][c] }
            return max(s / Double(tailLen), 1e-9)
        }
    }
}

public enum PanelLoadError: Error, CustomStringConvertible {
    case missingRequiredFile(String)

    // Fail-closed input parsing (frozen design decision 2): empty string,
    // non-numeric text, NaN, or infinity in kpi_value/spend/control_value/
    // treatment_value throws instead of silently becoming 0. This is a
    // deliberate divergence from the Python engine's permissive
    // `float(x or 0)`, which zeroes exactly these cases.
    case malformedValue(file: String, row: Int, column: String, text: String)

    // Negative spend or negative kpi_value (frozen design decision 2);
    // control_value/treatment_value are not sign-checked, since those can
    // legitimately be negative (a YoY delta, a competitor-spend index, etc).
    case negativeValue(file: String, row: Int, column: String, text: String)

    // kpi_name must be read from the data and agree across every row
    // (frozen design decision 4); a package that mixes KPI names is
    // ambiguous, not something to silently pick a winner from.
    case mixedKPIName(file: String, values: [String])

    // Fitting requires at least ArtifactConstants.minimumWeeks weeks so the
    // always-on 12-week holdout refit still has real training data left
    // (frozen design decision 1: there is no more "skip the holdout"
    // escape hatch for a short panel).
    case insufficientWeeks(weeks: Int, minimum: Int)

    public var description: String {
        switch self {
        case .missingRequiredFile(let name):
            return "drop directory is missing required file: \(name)"
        case .malformedValue(let file, let row, let column, let text):
            return "\(file): row \(row), column \"\(column)\": expected a finite number, got \"\(text)\""
        case .negativeValue(let file, let row, let column, let text):
            return "\(file): row \(row), column \"\(column)\": expected a non-negative number, got \"\(text)\""
        case .mixedKPIName(let file, let values):
            return "\(file): column \"kpi_name\" has conflicting values across rows: \(values.joined(separator: ", "))"
        case .insufficientWeeks(let weeks, let minimum):
            return "panel has \(weeks) week(s) of data; fitting requires at least \(minimum) weeks " +
                   "(the holdout refit always reserves the trailing \(ArtifactConstants.holdoutWeeks) weeks)"
        }
    }
}

public enum PanelLoader {
    public static func load(dropDir: String) throws -> Panel {
        let dir = URL(fileURLWithPath: dropDir, isDirectory: true)

        let kpiPath = dir.appendingPathComponent("kpi.csv").path
        let paidMediaPath = dir.appendingPathComponent("paid_media.csv").path
        guard FileManager.default.fileExists(atPath: kpiPath) else {
            throw PanelLoadError.missingRequiredFile("kpi.csv")
        }
        guard FileManager.default.fileExists(atPath: paidMediaPath) else {
            throw PanelLoadError.missingRequiredFile("paid_media.csv")
        }
        let kpi = try CSVReader.read(path: kpiPath)
        let paidMedia = try CSVReader.read(path: paidMediaPath)

        var warnings: [String] = []

        // dates = sorted set of date_week from kpi.csv; lexicographic sort on
        // ISO date strings equals chronological order.
        var dateSet = Set<String>()
        for r in kpi.rows {
            if let d = r["date_week"] { dateSet.insert(d) }
        }
        let dates = dateSet.sorted()
        var dateIndex: [String: Int] = [:]
        dateIndex.reserveCapacity(dates.count)
        for (i, d) in dates.enumerated() { dateIndex[d] = i }
        let T = dates.count

        // Hard floor before doing any further work: a panel this short
        // cannot support the always-on 12-week holdout refit with any real
        // training data left (frozen design decision 1).
        guard T >= ArtifactConstants.minimumWeeks else {
            throw PanelLoadError.insufficientWeeks(weeks: T, minimum: ArtifactConstants.minimumWeeks)
        }

        // Geo aggregation stays (matches the Python engine: every geo's KPI
        // and spend fold into one national weekly total), but is no longer
        // silent -- surface it as a warning naming the geos involved
        // (frozen design decision 5).
        var geoSet = Set<String>()
        for r in kpi.rows {
            if let g = r["geo"], !g.isEmpty { geoSet.insert(g) }
        }
        if geoSet.count > 1 {
            let names = geoSet.sorted().joined(separator: ", ")
            warnings.append("Aggregated \(geoSet.count) geos to national weekly totals: \(names)")
        }

        // kpi_name comes from the data, not a hardcoded fixture string
        // (frozen design decision 4).
        let (kpiName, kpiNameWarning) = try resolveKPIName(table: kpi, file: "kpi.csv")
        if let w = kpiNameWarning { warnings.append(w) }

        var y = [Double](repeating: 0, count: T)
        for (rowIdx, r) in kpi.rows.enumerated() {
            guard let dw = r["date_week"], let idx = dateIndex[dw] else { continue }
            let v = try parseRequiredNonNegativeDouble(r["kpi_value"], file: "kpi.csv", row: rowIdx + 1, column: "kpi_value")
            y[idx] += v
        }

        // Channel order: CHANNEL_KEYS filtered to channels present in
        // paid_media.csv, then unseen channels sorted alphabetically.
        // Unknown channels are first-class here (frozen design decision 6):
        // any channel key found in paid_media.csv ends up in this list,
        // registered or not.
        var seen = Set<String>()
        for r in paidMedia.rows {
            if let ch = r["channel"], !ch.isEmpty { seen.insert(ch) }
        }
        let known = Set(ChannelRegistry.channelKeys)
        let extras = seen.subtracting(known).sorted()
        let channels = ChannelRegistry.channelKeys.filter { seen.contains($0) } + extras
        var chIndex: [String: Int] = [:]
        chIndex.reserveCapacity(channels.count)
        for (i, c) in channels.enumerated() { chIndex[c] = i }
        let C = channels.count

        var X = Array(repeating: [Double](repeating: 0, count: C), count: T)
        var duplicateSpendRows = 0
        var seenDateChannel = Set<Int>()
        for (rowIdx, r) in paidMedia.rows.enumerated() {
            guard let dw = r["date_week"], let tIdx = dateIndex[dw] else { continue }
            guard let ch = r["channel"], let cIdx = chIndex[ch] else { continue }
            let v = try parseRequiredNonNegativeDouble(r["spend"], file: "paid_media.csv", row: rowIdx + 1, column: "spend")
            let pairKey = tIdx * C + cIdx
            if !seenDateChannel.insert(pairKey).inserted {
                duplicateSpendRows += 1
            }
            X[tIdx][cIdx] += v
        }
        if duplicateSpendRows > 0 {
            warnings.append("Aggregated \(duplicateSpendRows) duplicate date+channel spend row(s) in paid_media.csv")
        }

        // Controls/treatments: assignment (not accumulation) into a column
        // per name, column order = sorted(all names).
        var controlCols: [String: [Double]] = [:]

        let controlsPath = dir.appendingPathComponent("controls.csv").path
        if FileManager.default.fileExists(atPath: controlsPath) {
            let controls = try CSVReader.read(path: controlsPath)
            for (rowIdx, r) in controls.rows.enumerated() {
                guard let name = r["control_name"], !name.isEmpty else { continue }
                var col = controlCols[name] ?? [Double](repeating: 0, count: T)
                if let dw = r["date_week"], let idx = dateIndex[dw] {
                    col[idx] = try parseRequiredDouble(r["control_value"], file: "controls.csv", row: rowIdx + 1, column: "control_value")
                }
                controlCols[name] = col
            }
        }

        let treatmentsPath = dir.appendingPathComponent("non_media_treatments.csv").path
        if FileManager.default.fileExists(atPath: treatmentsPath) {
            let treatments = try CSVReader.read(path: treatmentsPath)
            for (rowIdx, r) in treatments.rows.enumerated() {
                guard let name = r["treatment_name"], !name.isEmpty else { continue }
                let colName = "treatment_" + name
                var col = controlCols[colName] ?? [Double](repeating: 0, count: T)
                if let dw = r["date_week"], let idx = dateIndex[dw] {
                    col[idx] = try parseRequiredDouble(r["treatment_value"], file: "non_media_treatments.csv", row: rowIdx + 1, column: "treatment_value")
                }
                controlCols[colName] = col
            }
        }

        let controlNames = controlCols.keys.sorted()
        let K = controlNames.count
        var Z = Array(repeating: [Double](repeating: 0, count: K), count: T)
        for (ci, name) in controlNames.enumerated() {
            let col = controlCols[name]!
            var mean = 0.0
            for v in col { mean += v }
            mean /= Double(T)
            var variance = 0.0
            for v in col { variance += (v - mean) * (v - mean) }
            // Population std, ddof 0, matching numpy's default Z.std(axis=0).
            variance /= Double(T)
            let std = variance.squareRoot()
            let denom = std > 1e-9 ? std : 1.0
            for t in 0..<T {
                Z[t][ci] = (col[t] - mean) / denom
            }
        }

        return Panel(dates: dates, channels: channels, X: X, y: y, Z: Z, controlNames: controlNames,
                     kpiName: kpiName, warnings: warnings)
    }

    // Reads just kpi.csv's kpi_name column, for callers (the artifacts
    // pipeline) that already have a fitted panel from a prior `prep` step
    // and only need the KPI display name -- panel_meta.json intentionally
    // does not carry kpi_name (it stays byte-identical to the Python
    // engine's own prep output), so this re-reads the drop directory
    // directly, the same way ManifestBuilder.dataSha256 already does for
    // the data fingerprint.
    public static func readKPIName(dropDir: String) throws -> (name: String, warning: String?) {
        let dir = URL(fileURLWithPath: dropDir, isDirectory: true)
        let kpiPath = dir.appendingPathComponent("kpi.csv").path
        guard FileManager.default.fileExists(atPath: kpiPath) else {
            throw PanelLoadError.missingRequiredFile("kpi.csv")
        }
        let kpi = try CSVReader.read(path: kpiPath)
        return try resolveKPIName(table: kpi, file: "kpi.csv")
    }

    // Absent column: default to ArtifactConstants.defaultKPIName ("kpi")
    // and surface that in the loader warnings (frozen design decision 4).
    // Present but every row blank: same fallback and warning. Mixed
    // non-empty values across rows: a thrown error listing the distinct
    // values, since picking one silently would be a guess.
    static func resolveKPIName(table: CSVTable, file: String) throws -> (name: String, warning: String?) {
        guard table.header.contains("kpi_name") else {
            return (ArtifactConstants.defaultKPIName,
                    "\(file): kpi_name column absent; defaulting kpi_name to \"\(ArtifactConstants.defaultKPIName)\"")
        }
        var distinct = Set<String>()
        for r in table.rows {
            if let v = r["kpi_name"], !v.isEmpty { distinct.insert(v) }
        }
        if distinct.isEmpty {
            return (ArtifactConstants.defaultKPIName,
                    "\(file): kpi_name column present but empty in every row; defaulting kpi_name to \"\(ArtifactConstants.defaultKPIName)\"")
        }
        if distinct.count > 1 {
            throw PanelLoadError.mixedKPIName(file: file, values: distinct.sorted())
        }
        return (distinct.first!, nil)
    }

    // Fail-closed numeric parsing (frozen design decision 2): empty string,
    // non-numeric text, NaN, and infinity all throw, naming the file, the
    // 1-based data row, the column, and the offending text verbatim.
    static func parseRequiredDouble(_ raw: String?, file: String, row: Int, column: String) throws -> Double {
        guard let raw = raw, !raw.isEmpty, let v = Double(raw), v.isFinite else {
            throw PanelLoadError.malformedValue(file: file, row: row, column: column, text: raw ?? "")
        }
        return v
    }

    static func parseRequiredNonNegativeDouble(_ raw: String?, file: String, row: Int, column: String) throws -> Double {
        let v = try parseRequiredDouble(raw, file: file, row: row, column: column)
        guard v >= 0 else {
            throw PanelLoadError.negativeValue(file: file, row: row, column: column, text: raw ?? "")
        }
        return v
    }
}
