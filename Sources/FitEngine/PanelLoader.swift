import Foundation

// Mirrors engine/model/mmm.py Panel (read-only Python reference at
// the historical Python research engine). X and Z are stored row-major
// (T outer, C/K inner) to match how the Python arrays are shaped and
// iterated when this code was ported.
public struct Panel {
    public let dates: [String]
    public let channels: [String]
    public let X: [[Double]]      // (T, C) raw weekly spend
    public let y: [Double]        // (T,) raw KPI
    public let rawControls: [[Double]] // (T, K) controls + treatments before normalization
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

    // Compatibility accessor for full-panel inspection. The holdout
    // builder always fits a separate transform to rawControls.
    public var Z: [[Double]] {
        PanelPreprocessing.fit(panel: self, observedWeeks: T).standardizedControls(rawControls)
    }

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
    case malformedDate(file: String, row: Int, text: String)
    case invalidWeeklyCadence(previous: String, current: String)
    case dateCoverageMismatch(file: String, missing: [String], unexpected: [String])
    case dateOutsideKPI(file: String, row: Int, date: String)
    case conflictingCovariate(file: String, date: String, name: String)

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
        case .malformedDate(let file, let row, let text):
            return "\(file): row \(row), column \"date_week\": expected a valid YYYY-MM-DD date, got \"\(text)\""
        case .invalidWeeklyCadence(let previous, let current):
            return "kpi.csv: date_week must be exactly 7 days apart; found \(previous) and \(current)"
        case .dateCoverageMismatch(let file, let missing, let unexpected):
            var details: [String] = []
            if !missing.isEmpty { details.append("missing dates: \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { details.append("unexpected dates: \(unexpected.joined(separator: ", "))") }
            return "\(file): date_week must match kpi.csv; \(details.joined(separator: "; ")). Include explicit zero-spend rows for weeks with no spend."
        case .dateOutsideKPI(let file, let row, let date):
            return "\(file): row \(row), date_week \(date) is not present in kpi.csv"
        case .conflictingCovariate(let file, let date, let name):
            return "\(file): conflicting values for \(name) on \(date); provide one national value or identical values across geos"
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
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("organic_owned.csv").path) {
            warnings.append("organic_owned.csv is not used by the current model.")
        }

        // Require canonical calendar dates before sorting or joining tables.
        var dateSet = Set<String>()
        var calendarDates: [String: Date] = [:]
        for (rowIdx, r) in kpi.rows.enumerated() {
            let date = try parseRequiredDate(r["date_week"], file: "kpi.csv", row: rowIdx + 1)
            let text = r["date_week"]!
            dateSet.insert(text)
            calendarDates[text] = date
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

        for t in 1..<T {
            let previous = dates[t - 1]
            let current = dates[t]
            guard calendarDates[current]!.timeIntervalSince(calendarDates[previous]!) == 7 * 24 * 60 * 60 else {
                throw PanelLoadError.invalidWeeklyCadence(previous: previous, current: current)
            }
        }

        var paidDates = Set<String>()
        for (rowIdx, r) in paidMedia.rows.enumerated() {
            _ = try parseRequiredDate(r["date_week"], file: "paid_media.csv", row: rowIdx + 1)
            paidDates.insert(r["date_week"]!)
        }
        let missingPaidDates = dateSet.subtracting(paidDates).sorted()
        let unexpectedPaidDates = paidDates.subtracting(dateSet).sorted()
        guard missingPaidDates.isEmpty && unexpectedPaidDates.isEmpty else {
            throw PanelLoadError.dateCoverageMismatch(
                file: "paid_media.csv", missing: missingPaidDates, unexpected: unexpectedPaidDates
            )
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

        // Covariates represent one national value per date and name.
        // Identical repeats across geos are harmless; conflicts are ambiguous.
        var controlCols: [String: [Double]] = [:]

        let controlsPath = dir.appendingPathComponent("controls.csv").path
        if FileManager.default.fileExists(atPath: controlsPath) {
            let controls = try CSVReader.read(path: controlsPath)
            var seenValues: [String: [String: Double]] = [:]
            for (rowIdx, r) in controls.rows.enumerated() {
                let (date, idx) = try requirePanelDate(r["date_week"], file: "controls.csv", row: rowIdx + 1, dateIndex: dateIndex)
                guard let name = r["control_name"], !name.isEmpty else { continue }
                var col = controlCols[name] ?? [Double](repeating: 0, count: T)
                let value = try parseRequiredDouble(r["control_value"], file: "controls.csv", row: rowIdx + 1, column: "control_value")
                if let previous = seenValues[name]?[date], previous != value {
                    throw PanelLoadError.conflictingCovariate(file: "controls.csv", date: date, name: name)
                }
                seenValues[name, default: [:]][date] = value
                col[idx] = value
                controlCols[name] = col
            }
        }

        let treatmentsPath = dir.appendingPathComponent("non_media_treatments.csv").path
        if FileManager.default.fileExists(atPath: treatmentsPath) {
            let treatments = try CSVReader.read(path: treatmentsPath)
            var seenValues: [String: [String: Double]] = [:]
            for (rowIdx, r) in treatments.rows.enumerated() {
                let (date, idx) = try requirePanelDate(r["date_week"], file: "non_media_treatments.csv", row: rowIdx + 1, dateIndex: dateIndex)
                guard let name = r["treatment_name"], !name.isEmpty else { continue }
                let colName = "treatment_" + name
                var col = controlCols[colName] ?? [Double](repeating: 0, count: T)
                let value = try parseRequiredDouble(r["treatment_value"], file: "non_media_treatments.csv", row: rowIdx + 1, column: "treatment_value")
                if let previous = seenValues[name]?[date], previous != value {
                    throw PanelLoadError.conflictingCovariate(file: "non_media_treatments.csv", date: date, name: name)
                }
                seenValues[name, default: [:]][date] = value
                col[idx] = value
                controlCols[colName] = col
            }
        }

        let controlNames = controlCols.keys.sorted()
        let K = controlNames.count
        var rawControls = Array(repeating: [Double](repeating: 0, count: K), count: T)
        for (ci, name) in controlNames.enumerated() {
            let col = controlCols[name]!
            for t in 0..<T {
                rawControls[t][ci] = col[t]
            }
        }

        return Panel(dates: dates, channels: channels, X: X, y: y, rawControls: rawControls, controlNames: controlNames,
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

    private static func parseRequiredDate(_ raw: String?, file: String, row: Int) throws -> Date {
        let text = raw ?? ""
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let shapeIsValid = parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
        guard shapeIsValid,
              let year = Int(parts[0]), year >= 1,
              let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw PanelLoadError.malformedDate(file: file, row: row, text: text)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw PanelLoadError.malformedDate(file: file, row: row, text: text)
        }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else {
            throw PanelLoadError.malformedDate(file: file, row: row, text: text)
        }
        return date
    }

    private static func requirePanelDate(_ raw: String?, file: String, row: Int, dateIndex: [String: Int]) throws -> (String, Int) {
        _ = try parseRequiredDate(raw, file: file, row: row)
        let date = raw!
        guard let idx = dateIndex[date] else {
            throw PanelLoadError.dateOutsideKPI(file: file, row: row, date: date)
        }
        return (date, idx)
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
