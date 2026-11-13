import Foundation

// Reading Aula's JSON (JSONSerialization output) with the semantics the Python server relied on:
// `dict.get(k, default)` (default only when the key is absent; an explicit null is None),
// `get_in` (default on missing *or* null), truthiness, `str()`, and Python's string helpers.
// Used only inside `actor Aula`: raw JSON never leaves it.

typealias JSONObject = [String: Any]

enum J {
    static func isNone(_ v: Any?) -> Bool { v == nil || v is NSNull }

    /// `v if v is not None` with JSON null mapped to nil.
    static func val(_ v: Any?) -> Any? { isNone(v) ? nil : v }

    /// `d.get(key)`: nil for a missing key or null.
    static func get(_ d: Any?, _ key: String) -> Any? { val((d as? JSONObject)?[key]) }

    /// `d.get(key, default)`: the default only when the key is absent.
    static func get(_ d: Any?, _ key: String, default def: Any?) -> Any? {
        guard let d = d as? JSONObject else { return def }
        guard let v = d[key] else { return def }
        return val(v)
    }

    static func has(_ d: Any?, _ key: String) -> Bool { (d as? JSONObject)?[key] != nil }

    /// `get_in(data, "a.b")`: walks dicts only; missing or null at any step gives nil.
    static func getIn(_ data: Any?, _ path: String) -> Any? {
        var cur: Any? = data
        for key in path.split(separator: ".") {
            guard let d = cur as? JSONObject, let next = d[String(key)] else { return nil }
            cur = next
        }
        return val(cur)
    }

    static func dict(_ v: Any?) -> JSONObject? { v as? JSONObject }
    static func list(_ v: Any?) -> [Any]? { v as? [Any] }
    static func str(_ v: Any?) -> String? { v as? String }

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// `isinstance(v, bool)`.
    static func bool(_ v: Any?) -> Bool? { isBool(v) ? (v as! NSNumber).boolValue : nil }

    /// An int that isn't a bool or a float.
    static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !isBool(n), !CFNumberIsFloatType(n as CFNumber) else { return nil }
        return n.intValue
    }

    /// Python truthiness.
    static func truthy(_ v: Any?) -> Bool {
        switch val(v) {
        case nil: return false
        case let n as NSNumber: return isBool(n) ? n.boolValue : n.doubleValue != 0
        case let s as String: return !s.isEmpty
        case let a as [Any]: return !a.isEmpty
        case let d as JSONObject: return !d.isEmpty
        default: return true
        }
    }

    /// `a or b`.
    static func or(_ a: Any?, _ b: @autoclosure () -> Any?) -> Any? { truthy(a) ? val(a) : val(b()) }

    /// Python `==` for JSON values (True == 1, like Python).
    static func eq(_ a: Any?, _ b: Any?) -> Bool {
        switch (val(a), val(b)) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (x as NSNumber, y as NSNumber): return x == y
        case let (x as String, y as String): return x == y
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }

    /// `str(v)` / an f-string field.
    static func pyStr(_ v: Any?) -> String {
        switch val(v) {
        case nil: return "None"
        case let s as String: return s
        case let n as NSNumber:
            if isBool(n) { return n.boolValue ? "True" : "False" }
            if !CFNumberIsFloatType(n as CFNumber) { return n.stringValue }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        case let other?: return "\(other)"
        }
    }

    /// nil -> JSON null, for building answers and payloads (JSONSerialization can't take an Optional).
    static func out(_ v: Any?) -> Any { val(v) ?? NSNull() }

    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }
}

// MARK: Python string semantics (lengths and slices count code points; whitespace is str.isspace)

enum Py {
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }

    static func len(_ s: String) -> Int { s.unicodeScalars.count }

    static func prefix(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }

    static func strip(_ s: String) -> String { rstrip(lstrip(s)) }

    static func lstrip(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.drop(while: isSpace)))
    }

    static func rstrip(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `s.lstrip(chars)`.
    static func lstrip(_ s: String, chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return String(String.UnicodeScalarView(s.unicodeScalars.drop(while: { set.contains($0) })))
    }

    /// `s.split()`: runs of whitespace, no empty parts.
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if isSpace(c) {
                if !cur.isEmpty { out.append(String(cur)); cur = .init() }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// `s.isdigit()` for route ids (ASCII digits; Python also takes other scripts' digits).
    static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }

    /// `html.escape(s)` (quote=True).
    static func htmlEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Python's `\s` as an ICU character class.
    static let s = "[\\t\\n\\x{0B}\\f\\r\\x{1C}-\\x{1F}\\x{85}\\p{Z}]"
    /// Python's `\w` (str patterns).
    static let w = "[\\p{L}\\p{N}_]"

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `re.sub(pattern, template, s)` with an NSRegularExpression template.
    static func sub(_ re: NSRegularExpression, _ template: String, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
