import Foundation

public struct CSVTable {
    public let header: [String]
    public let rows: [[String: String]]
}

public enum CSVError: Error, CustomStringConvertible {
    case fileNotFound(String)
    public var description: String {
        switch self {
        case .fileNotFound(let path): return "CSV file not found: \(path)"
        }
    }
}

public enum CSVReader {
    public static func read(path: String) throws -> CSVTable {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CSVError.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var content = String(decoding: data, as: UTF8.self)
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }
        return parse(content)
    }

    public static func parse(_ content: String) -> CSVTable {
        let rawRows = parseRows(content)
        guard let header = rawRows.first else {
            return CSVTable(header: [], rows: [])
        }
        var dataRows: [[String: String]] = []
        dataRows.reserveCapacity(rawRows.count - 1)
        for raw in rawRows.dropFirst() {
            var dict: [String: String] = [:]
            for (i, col) in header.enumerated() {
                dict[col] = i < raw.count ? raw[i] : ""
            }
            dataRows.append(dict)
        }
        return CSVTable(header: header, rows: dataRows)
    }

    // RFC4180-ish state machine: handles quoted fields, doubled-quote
    // escaping, and both \n and \r\n line endings. The fixture files here are
    // plain comma-separated with no quoted fields, but quoting is supported
    // regardless per spec.
    private static func parseRows(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(content.unicodeScalars)
        let n = chars.count
        var i = 0

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // Drop a lone trailing blank line (single empty field), which is
            // not a real data row.
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while i < n {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < n, chars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.unicodeScalars.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                i += 1
            case ",":
                endField()
                i += 1
            case "\r":
                if i + 1 < n, chars[i + 1] == "\n" {
                    endRow()
                    i += 2
                } else {
                    endRow()
                    i += 1
                }
            case "\n":
                endRow()
                i += 1
            default:
                field.unicodeScalars.append(c)
                i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }
}
