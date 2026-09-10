import Foundation

// Parses CmdStan sampler output CSVs. Comment lines (starting with '#') can
// appear before the header, immediately after the header (adaptation info),
// and at end of file (timing); all are skipped regardless of position.
public struct ChainDraws {
    public let header: [String]
    public let columns: [String: [Double]]   // column name -> draws, in file order
    public let nDraws: Int
    // The sampler's acceptance target, read from CmdStan's own comment
    // header ("#       delta = 0.97"), so a receipt records what actually
    // ran rather than what the caller meant to pass. nil when absent.
    public var adaptDelta: Double? = nil

    static func parseAdaptDelta(commentLine: String) -> Double? {
        // Matches "#       delta = 0.97" and "#       delta = 0.8 (Default)".
        let trimmed = commentLine.dropFirst().trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("delta =") else { return nil }
        let rest = trimmed.dropFirst("delta =".count).trimmingCharacters(in: .whitespaces)
        let token = rest.split(separator: " ").first.map(String.init) ?? ""
        guard let value = Double(token), value.isFinite, value > 0, value < 1 else { return nil }
        return value
    }
}

public enum DrawsReaderError: Error, CustomStringConvertible {
    case noFilesFound(String)
    case headerNotFound(String)
    case invalidUTF8(String)
    case malformedHeader(path: String, reason: String)
    case noDraws(String)
    case wrongFieldCount(path: String, line: Int, expected: Int, actual: Int)
    case invalidValue(path: String, line: Int, column: String)
    case invalidSchema(path: String, reason: String)
    case inconsistentHeaders(path: String)
    case inconsistentDrawCounts(path: String, expected: Int, actual: Int)
    case duplicateChains(path: String, matchingPath: String)

    public var description: String {
        switch self {
        case .noFilesFound(let dir): return "no chain CSV files found in \(dir)"
        case .headerNotFound(let path): return "no header row found in \(path)"
        case .invalidUTF8(let path): return "chain CSV is not valid UTF-8: \(path)"
        case .malformedHeader(let path, let reason): return "invalid chain CSV header in \(path): \(reason)"
        case .noDraws(let path): return "chain CSV contains no posterior draws: \(path)"
        case .wrongFieldCount(let path, let line, let expected, let actual):
            return "\(path): line \(line) has \(actual) values; expected \(expected)"
        case .invalidValue(let path, let line, let column):
            return "\(path): line \(line), column \(column) must contain a finite numeric posterior value (divergent__ must be 0 or 1)"
        case .invalidSchema(let path, let reason): return "invalid posterior schema in \(path): \(reason)"
        case .inconsistentHeaders(let path): return "chain headers do not match: \(path)"
        case .inconsistentDrawCounts(let path, let expected, let actual):
            return "\(path): chain has \(actual) draws; expected \(expected) to match the other chains"
        case .duplicateChains(let path, let matchingPath):
            return "\(path): posterior parameter draws exactly duplicate \(matchingPath); independent chains are required"
        }
    }
}

// Holds per-chain draws (needed, unstacked, for R-hat/ESS which operate on
// individual chains) plus convenience accessors for stacking across chains
// (needed for grading, which treats the posterior as one pool of draws).
public struct StanFit {
    public let chains: [ChainDraws]   // ascending chain-file order
    public let C: Int
    public let T: Int
    public let K: Int

    public var nChains: Int { chains.count }
    public var totalDraws: Int { chains.reduce(0) { $0 + $1.nDraws } }

    // One acceptance target for the whole fit, or nil if any chain lacks
    // it or the chains disagree.
    public var adaptDelta: Double? {
        let values = chains.map { $0.adaptDelta }
        guard let first = values.first ?? nil, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    public func stackedColumn(_ name: String) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(totalDraws)
        for chain in chains {
            // readDirectory validates this invariant before exposing a fit.
            // A programmer requesting an absent column must not invent data.
            guard let column = chain.columns[name], column.count == chain.nDraws else {
                preconditionFailure("required posterior column is unavailable: \(name)")
            }
            out.append(contentsOf: column)
        }
        return out
    }

    // Stacks dot-indexed vector variables (e.g. "adstock_alpha.1".."adstock_alpha.C")
    // into a (S, count) row-major matrix across all chains.
    public func stackedIndexed(_ prefix: String, count: Int) -> [[Double]] {
        precondition(count >= 0, "posterior column count must be non-negative")
        var out = Array(repeating: [Double](repeating: 0, count: count), count: totalDraws)
        if count == 0 { return out }
        var offset = 0
        for chain in chains {
            let cols: [[Double]] = (1...count).map { index in
                let name = "\(prefix).\(index)"
                guard let column = chain.columns[name], column.count == chain.nDraws else {
                    preconditionFailure("required posterior column is unavailable: \(name)")
                }
                return column
            }
            for s in 0..<chain.nDraws {
                for c in 0..<count {
                    out[offset + s][c] = cols[c][s]
                }
            }
            offset += chain.nDraws
        }
        return out
    }

    public var divergences: Int {
        stackedColumn("divergent__").filter { $0 == 1 }.count
    }
}

public enum DrawsReader {
    public static func listChainFiles(dir: String, pattern: String = "*.csv") throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: dir)
        let filtered = contents.filter { name in
            guard matchesGlob(name, pattern: pattern) else { return false }
            if name.contains("diagnostics") { return false }
            if name.hasSuffix("-stdout.txt") { return false }
            return true
        }
        let sortedNames = filtered.sorted()
        if sortedNames.isEmpty {
            throw DrawsReaderError.noFilesFound(dir)
        }
        return sortedNames.map { (dir as NSString).appendingPathComponent($0) }
    }

    // Only '*' is supported as a wildcard, sufficient for "*.csv" style patterns.
    static func matchesGlob(_ name: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        guard let re = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return re.firstMatch(in: name, range: range) != nil
    }

    public static func readChain(path: String) throws -> ChainDraws {
        var adaptDelta: Double? = nil
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let content = String(data: data, encoding: .utf8) else {
            throw DrawsReaderError.invalidUTF8(path)
        }
        var header: [String]?
        var columns: [String: [Double]] = [:]
        var draws = 0
        for (offset, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if adaptDelta == nil, let value = ChainDraws.parseAdaptDelta(commentLine: line) { adaptDelta = value }
                continue
            }
            if line.isEmpty { continue }
            if header == nil {
                let names = line.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
                    throw DrawsReaderError.malformedHeader(path: path, reason: "column names must be nonempty and unique")
                }
                header = names
                for name in names { columns[name] = [] }
            } else {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                let names = header!
                guard fields.count == names.count else {
                    throw DrawsReaderError.wrongFieldCount(path: path, line: offset + 1, expected: names.count, actual: fields.count)
                }
                for (index, field) in fields.enumerated() {
                    let name = names[index]
                    guard let value = Double(field.trimmingCharacters(in: .whitespaces)), value.isFinite,
                          name != "divergent__" || value == 0 || value == 1 else {
                        throw DrawsReaderError.invalidValue(path: path, line: offset + 1, column: name)
                    }
                    columns[name]!.append(value)
                }
                draws += 1
            }
        }
        guard let hdr = header else {
            throw DrawsReaderError.headerNotFound(path)
        }
        guard draws > 0 else { throw DrawsReaderError.noDraws(path) }
        return ChainDraws(header: hdr, columns: columns, nDraws: draws, adaptDelta: adaptDelta)
    }

    // Dimensions are inferred from the header (never hardcoded), by finding
    // the highest 1-based dot index present for each prefix.
    static func inferDimensions(header: [String]) -> (C: Int, T: Int, K: Int) {
        func maxIndex(prefix: String) -> Int {
            let dotPrefix = prefix + "."
            var maxIdx = 0
            for h in header where h.hasPrefix(dotPrefix) {
                if let idx = Int(h.dropFirst(dotPrefix.count)) {
                    maxIdx = max(maxIdx, idx)
                }
            }
            return maxIdx
        }
        let C = maxIndex(prefix: "adstock_alpha")
        let T = maxIndex(prefix: "mu_scaled")
        let K = maxIndex(prefix: "control_gamma")
        return (C, T, K)
    }

    public static func readDirectory(dir: String, pattern: String = "*.csv") throws -> StanFit {
        let files = try listChainFiles(dir: dir, pattern: pattern)
        let chains = try files.map { try readChain(path: $0) }
        guard let first = chains.first else {
            throw DrawsReaderError.noFilesFound(dir)
        }
        let (C, T, K) = inferDimensions(header: first.header)
        let fit = StanFit(chains: chains, C: C, T: T, K: K)
        try validate(fit: fit, paths: files)
        return fit
    }

    // Also used by diagnostics to validate fits constructed inside this
    // module. Imported files can only reach callers through readDirectory.
    static func validate(fit: StanFit, paths: [String]? = nil) throws {
        guard let first = fit.chains.first else { throw DrawsReaderError.noFilesFound("posterior") }
        guard fit.C > 0, fit.T > 0, fit.K >= 0,
              fit.C <= first.header.count, fit.T <= first.header.count, fit.K <= first.header.count else {
            throw DrawsReaderError.invalidSchema(path: paths?.first ?? "posterior", reason: "invalid channel, week, or control dimensions")
        }
        let vectorDimensions = [
            ("adstock_alpha", fit.C), ("hill_kappa", fit.C), ("hill_slope", fit.C),
            ("channel_beta", fit.C), ("fourier_beta", 4), ("control_gamma", fit.K), ("mu_scaled", fit.T),
        ]
        let requiredScalars = ["intercept", "trend", "sigma", "divergent__"]

        for (index, chain) in fit.chains.enumerated() {
            let path = paths?[index] ?? "chain \(index + 1)"
            let names = Set(chain.header)
            guard names.count == chain.header.count, !names.contains(""), names == Set(chain.columns.keys) else {
                throw DrawsReaderError.malformedHeader(path: path, reason: "column names must be nonempty, unique, and match the stored columns")
            }
            guard chain.header == first.header else { throw DrawsReaderError.inconsistentHeaders(path: path) }
            guard chain.nDraws > 0 else { throw DrawsReaderError.noDraws(path) }
            guard chain.nDraws == first.nDraws else {
                throw DrawsReaderError.inconsistentDrawCounts(path: path, expected: first.nDraws, actual: chain.nDraws)
            }
            for scalar in requiredScalars where !names.contains(scalar) {
                throw DrawsReaderError.invalidSchema(path: path, reason: "missing required column \(scalar)")
            }
            for (prefix, count) in vectorDimensions {
                let expected = Set((0..<count).map { "\(prefix).\($0 + 1)" })
                let actual = Set(names.filter { $0 == prefix || $0.hasPrefix(prefix + ".") })
                guard actual == expected else {
                    throw DrawsReaderError.invalidSchema(path: path, reason: "\(prefix) must have exactly the contiguous indices 1 through \(count)")
                }
            }
            let mediaColumns = Set(names.filter { $0 == "media_scaled" || $0.hasPrefix("media_scaled.") })
            if !mediaColumns.isEmpty && mediaColumns != Set((1...fit.T).map { "media_scaled.\($0)" }) {
                throw DrawsReaderError.invalidSchema(path: path, reason: "media_scaled dimensions must match mu_scaled")
            }
            for name in chain.header {
                let values = chain.columns[name]!
                guard values.count == chain.nDraws else {
                    throw DrawsReaderError.inconsistentDrawCounts(path: "\(path), column \(name)", expected: chain.nDraws, actual: values.count)
                }
                for (draw, value) in values.enumerated() where !value.isFinite || (name == "divergent__" && value != 0 && value != 1) {
                    throw DrawsReaderError.invalidValue(path: path, line: draw + 2, column: name)
                }
            }
        }

        // Renamed files, changed sampler metadata, or regenerated per-week
        // predictions do not turn copied parameter draws into independent
        // chains. Compare the model parameters themselves in draw order.
        let parameterNames = ["intercept", "trend", "sigma"] + vectorDimensions
            .filter { $0.0 != "mu_scaled" }
            .flatMap { prefix, count in (0..<count).map { "\(prefix).\($0 + 1)" } }
        for index in fit.chains.indices {
            for previous in 0..<index where parameterNames.allSatisfy({
                fit.chains[index].columns[$0] == fit.chains[previous].columns[$0]
            }) {
                throw DrawsReaderError.duplicateChains(
                    path: paths?[index] ?? "chain \(index + 1)",
                    matchingPath: paths?[previous] ?? "chain \(previous + 1)"
                )
            }
        }
    }
}
