import Foundation

// Minimal hand-rolled JSON value tree. Used instead of Codable so callers
// control exact shape (e.g. Z emitted as top-level [] when K == 0, rather
// than an array of T empty rows) and exact double formatting.
public indirect enum JSONValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public func serialized() throws -> String {
        var out = ""
        out.reserveCapacity(4096)
        try write(&out)
        return out
    }

    private func write(_ out: inout String) throws {
        switch self {
        case .string(let s):
            writeJSONString(s, into: &out)
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += try JSONValue.doubleLiteral(d)
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        case .array(let arr):
            out += "["
            for (i, v) in arr.enumerated() {
                if i > 0 { out += "," }
                try v.write(&out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            let keys = dict.keys.sorted()
            for (i, k) in keys.enumerated() {
                if i > 0 { out += "," }
                writeJSONString(k, into: &out)
                out += ":"
                try dict[k]!.write(&out)
            }
            out += "}"
        }
    }

    // Swift's Double -> String conversion produces the shortest decimal
    // string that round-trips to the same Double (SwiftDtoa), which
    // satisfies "full double precision (17 significant digits or shortest
    // round-trip)" without needing a manual %.17g formatter.
    //
    // Frozen design decision 3: NaN/infinity throw here instead of being
    // silently coerced to 0 (the old behavior, and the source of the
    // audit's "holdout metrics serialized as zero" finding). The explicit
    // .null case is untouched and stays the way to emit an intentional
    // JSON null.
    static func doubleLiteral(_ d: Double) throws -> String {
        guard d.isFinite else {
            throw JSONValueError.nonFiniteDouble(d)
        }
        return String(d)
    }

    private func writeJSONString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue {
    public static func doubleArray(_ v: [Double]) -> JSONValue {
        .array(v.map { .double($0) })
    }

    public static func doubleMatrix(_ v: [[Double]]) -> JSONValue {
        .array(v.map { .doubleArray($0) })
    }

    public static func stringArray(_ v: [String]) -> JSONValue {
        .array(v.map { .string($0) })
    }
}

// Thrown by JSONValue.serialized()/doubleLiteral when a .double payload is
// NaN or infinite. There is no silent fallback (not 0, not "NaN", not
// null): a non-finite number reaching serialization is a bug upstream that
// should fail loudly rather than produce a self-contradictory artifact.
public enum JSONValueError: Error, CustomStringConvertible {
    case nonFiniteDouble(Double)
    public var description: String {
        switch self {
        case .nonFiniteDouble(let d):
            return "JSONValue cannot serialize non-finite double (\(d)); refusing to silently emit 0"
        }
    }
}

public enum JSONParseError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let msg): return "JSON parse error: \(msg)"
        }
    }
}

// Small recursive-descent JSON parser (Foundation's JSONSerialization would
// also work, but this keeps the tree fully typed and avoids NSNumber
// round-tripping surprises for Int vs Double).
public enum JSONParser {
    public static func parse(_ text: String) throws -> JSONValue {
        var chars = Array(text.unicodeScalars)
        var i = 0
        let value = try parseValue(&chars, &i)
        skipWhitespace(&chars, &i)
        return value
    }

    private static func skipWhitespace(_ chars: inout [Unicode.Scalar], _ i: inout Int) {
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
            } else {
                break
            }
        }
    }

    private static func parseValue(_ chars: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        skipWhitespace(&chars, &i)
        guard i < chars.count else { throw JSONParseError.invalid("unexpected end of input") }
        switch chars[i] {
        case "{": return try parseObject(&chars, &i)
        case "[": return try parseArray(&chars, &i)
        case "\"": return .string(try parseString(&chars, &i))
        case "t":
            try expectLiteral("true", &chars, &i)
            return .bool(true)
        case "f":
            try expectLiteral("false", &chars, &i)
            return .bool(false)
        case "n":
            try expectLiteral("null", &chars, &i)
            return .null
        default:
            return try parseNumber(&chars, &i)
        }
    }

    private static func expectLiteral(_ lit: String, _ chars: inout [Unicode.Scalar], _ i: inout Int) throws {
        for s in lit.unicodeScalars {
            guard i < chars.count, chars[i] == s else { throw JSONParseError.invalid("expected literal \(lit)") }
            i += 1
        }
    }

    private static func parseObject(_ chars: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        i += 1 // {
        var dict: [String: JSONValue] = [:]
        skipWhitespace(&chars, &i)
        if i < chars.count, chars[i] == "}" {
            i += 1
            return .object(dict)
        }
        while true {
            skipWhitespace(&chars, &i)
            let key = try parseString(&chars, &i)
            skipWhitespace(&chars, &i)
            guard i < chars.count, chars[i] == ":" else { throw JSONParseError.invalid("expected ':'") }
            i += 1
            let value = try parseValue(&chars, &i)
            dict[key] = value
            skipWhitespace(&chars, &i)
            guard i < chars.count else { throw JSONParseError.invalid("unexpected end in object") }
            if chars[i] == "," {
                i += 1
                continue
            } else if chars[i] == "}" {
                i += 1
                break
            } else {
                throw JSONParseError.invalid("expected ',' or '}'")
            }
        }
        return .object(dict)
    }

    private static func parseArray(_ chars: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        i += 1 // [
        var arr: [JSONValue] = []
        skipWhitespace(&chars, &i)
        if i < chars.count, chars[i] == "]" {
            i += 1
            return .array(arr)
        }
        while true {
            let value = try parseValue(&chars, &i)
            arr.append(value)
            skipWhitespace(&chars, &i)
            guard i < chars.count else { throw JSONParseError.invalid("unexpected end in array") }
            if chars[i] == "," {
                i += 1
                continue
            } else if chars[i] == "]" {
                i += 1
                break
            } else {
                throw JSONParseError.invalid("expected ',' or ']'")
            }
        }
        return .array(arr)
    }

    private static func parseString(_ chars: inout [Unicode.Scalar], _ i: inout Int) throws -> String {
        guard i < chars.count, chars[i] == "\"" else { throw JSONParseError.invalid("expected string") }
        i += 1
        var out = String.UnicodeScalarView()
        while i < chars.count, chars[i] != "\"" {
            if chars[i] == "\\" {
                i += 1
                guard i < chars.count else { throw JSONParseError.invalid("bad escape") }
                switch chars[i] {
                case "\"": out.append("\""); i += 1
                case "\\": out.append("\\"); i += 1
                case "/": out.append("/"); i += 1
                case "n": out.append("\n"); i += 1
                case "t": out.append("\t"); i += 1
                case "r": out.append("\r"); i += 1
                case "b": out.append("\u{08}"); i += 1
                case "f": out.append("\u{0C}"); i += 1
                case "u":
                    i += 1
                    guard i + 4 <= chars.count else { throw JSONParseError.invalid("bad unicode escape") }
                    let hex = String(String.UnicodeScalarView(chars[i..<(i + 4)]))
                    guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                        throw JSONParseError.invalid("bad unicode escape")
                    }
                    out.append(scalar)
                    i += 4
                default:
                    throw JSONParseError.invalid("bad escape")
                }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        guard i < chars.count else { throw JSONParseError.invalid("unterminated string") }
        i += 1 // closing quote
        return String(out)
    }

    private static func parseNumber(_ chars: inout [Unicode.Scalar], _ i: inout Int) throws -> JSONValue {
        let start = i
        if i < chars.count, chars[i] == "-" { i += 1 }
        while i < chars.count, isDigit(chars[i]) { i += 1 }
        var isDouble = false
        if i < chars.count, chars[i] == "." {
            isDouble = true
            i += 1
            while i < chars.count, isDigit(chars[i]) { i += 1 }
        }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            isDouble = true
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            while i < chars.count, isDigit(chars[i]) { i += 1 }
        }
        guard i > start else { throw JSONParseError.invalid("expected number") }
        let text = String(String.UnicodeScalarView(chars[start..<i]))
        if isDouble {
            guard let d = Double(text) else { throw JSONParseError.invalid("bad number \(text)") }
            return .double(d)
        } else {
            if let n = Int(text) {
                return .int(n)
            }
            guard let d = Double(text) else { throw JSONParseError.invalid("bad number \(text)") }
            return .double(d)
        }
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.value >= 48 && s.value <= 57
    }
}

extension JSONValue {
    public var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var asArray: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var asDoubleArray: [Double]? {
        guard let a = asArray else { return nil }
        return a.map { $0.asDouble ?? 0 }
    }
    public var asDoubleMatrix: [[Double]]? {
        guard let a = asArray else { return nil }
        return a.map { $0.asDoubleArray ?? [] }
    }
    public var asStringArray: [String]? {
        guard let a = asArray else { return nil }
        return a.map { $0.asString ?? "" }
    }
    public subscript(key: String) -> JSONValue? {
        asObject?[key]
    }
}
