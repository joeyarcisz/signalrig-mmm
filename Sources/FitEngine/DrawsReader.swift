import Foundation

// Parses CmdStan sampler output CSVs. Comment lines (starting with '#') can
// appear before the header, immediately after the header (adaptation info),
// and at end of file (timing); all are skipped regardless of position.
public struct ChainDraws {
    public let header: [String]
    public let columns: [String: [Double]]   // column name -> draws, in file order
    public let nDraws: Int
}

public enum DrawsReaderError: Error, CustomStringConvertible {
    case noFilesFound(String)
    case headerNotFound(String)

    public var description: String {
        switch self {
        case .noFilesFound(let dir): return "no chain CSV files found in \(dir)"
        case .headerNotFound(let path): return "no header row found in \(path)"
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

    public func stackedColumn(_ name: String) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(totalDraws)
        for chain in chains {
            out.append(contentsOf: chain.columns[name] ?? [Double](repeating: 0, count: chain.nDraws))
        }
        return out
    }

    // Stacks dot-indexed vector variables (e.g. "adstock_alpha.1".."adstock_alpha.C")
    // into a (S, count) row-major matrix across all chains.
    public func stackedIndexed(_ prefix: String, count: Int) -> [[Double]] {
        var out = Array(repeating: [Double](repeating: 0, count: count), count: totalDraws)
        var offset = 0
        for chain in chains {
            let cols: [[Double]] = (1...count).map { chain.columns["\(prefix).\($0)"] ?? [Double](repeating: 0, count: chain.nDraws) }
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
        Int(stackedColumn("divergent__").reduce(0, +).rounded())
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
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        var header: [String]?
        var rows: [[Double]] = []
        content.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("#") { return }
            if header == nil {
                header = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            } else {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                var vals = [Double](repeating: 0, count: fields.count)
                for (i, f) in fields.enumerated() {
                    vals[i] = Double(f) ?? 0
                }
                rows.append(vals)
            }
        }
        guard let hdr = header else {
            throw DrawsReaderError.headerNotFound(path)
        }
        var columns: [String: [Double]] = [:]
        columns.reserveCapacity(hdr.count)
        for (ci, name) in hdr.enumerated() {
            var col = [Double](repeating: 0, count: rows.count)
            for (ri, row) in rows.enumerated() {
                col[ri] = ci < row.count ? row[ci] : 0
            }
            columns[name] = col
        }
        return ChainDraws(header: hdr, columns: columns, nDraws: rows.count)
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
        return StanFit(chains: chains, C: C, T: T, K: K)
    }
}
