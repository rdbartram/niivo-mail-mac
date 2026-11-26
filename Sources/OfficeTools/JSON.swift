import Foundation

/// Minimal Sendable JSON value. Parsing goes through JSONSerialization; encoding is hand-rolled so the output is
/// compact, single-line (stdio framing forbids embedded newlines) and deterministic (sorted keys).
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Parse

    static func parse(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(any)
    }

    private static func from(_ any: Any) -> JSON? {
        switch any {
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let t = String(cString: n.objCType)
            if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(t) { return .int(n.intValue) }
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 9.0e15 { return .int(Int(d)) }
            return .double(d)
        case let a as [Any]:
            var out: [JSON] = []
            for x in a { guard let j = from(x) else { return nil }; out.append(j) }
            return .array(out)
        case let o as [String: Any]:
            var out: [String: JSON] = [:]
            for (k, v) in o { guard let j = from(v) else { return nil }; out[k] = j }
            return .object(out)
        default: return nil
        }
    }

    // MARK: Encode

    var encoded: String {
        var s = ""
        write(into: &s)
        return s
    }

    private func write(into s: inout String) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .int(let i): s += String(i)
        case .double(let d): s += d.isFinite ? (d.rounded() == d && abs(d) < 9.0e15 ? String(Int(d)) : String(d)) : "null"
        case .string(let str): Self.escape(str, into: &s)
        case .array(let a):
            s += "["
            for (i, x) in a.enumerated() { if i > 0 { s += "," }; x.write(into: &s) }
            s += "]"
        case .object(let o):
            s += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { s += "," }
                Self.escape(k, into: &s); s += ":"; o[k]!.write(into: &s)
            }
            s += "}"
        }
    }

    private static func escape(_ str: String, into s: inout String) {
        s += "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{2028}": s += "\\u2028"
            case "\u{2029}": s += "\\u2029"
            default:
                if u.value < 0x20 || u.value == 0x7F { s += String(format: "\\u%04x", u.value) }
                else { s.unicodeScalars.append(u) }
            }
        }
        s += "\""
    }

    // MARK: Access

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int(d)
        default: return nil
        }
    }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(integerLiteral v: Int) { self = .int(v) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSON {
    static func str(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    static func date(_ d: Date?) -> JSON { d.map { .string(ISO.format($0)) } ?? .null }
}

/// ISO-8601 helpers. Formatters are created per call (they are not Sendable).
enum ISO {
    static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Accepts `2026-11-20T09:00:00Z`, offsets (`+01:00`), fractional seconds, and a bare date (local midnight,
    /// in `timeZone`).
    static func parse(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
