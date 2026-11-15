import Foundation

/// Aula's message and post HTML as plain text for the views. Block elements become paragraph
/// breaks, `<br>` and table rows line breaks, list items "• " lines; script, style and comments
/// go; entities are decoded; everything else keeps only its text. Runs of whitespace collapse to
/// one space, except inside `<pre>`. No hard wrapping: the views wrap to the screen.
enum AulaText {
    private static let paragraphTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "table",
        "dl", "hr", "section", "article", "header", "footer", "nav", "aside", "figure", "address",
    ]
    private static let lineTags: Set<String> = ["li", "tr", "dt", "dd"]

    static func plain(_ html: String) -> String {
        let s = Array(html)
        var out = ""
        var pre = 0
        var i = 0

        func trimTrailingSpaces() { while out.last == " " { out.removeLast() } }
        func breakLines(_ n: Int) {
            trimTrailingSpaces()
            guard !out.isEmpty else { return }
            let have = out.reversed().prefix(while: { $0 == "\n" }).count
            if have < n { out += String(repeating: "\n", count: n - have) }
        }
        func text(_ chunk: String) {
            let decoded = decodeEntities(chunk)
            if pre > 0 { out += decoded; return }
            for c in decoded {
                if c.isWhitespace {
                    if let last = out.last, last != " ", last != "\n" { out.append(" ") }
                } else {
                    out.append(c)
                }
            }
        }
        /// Index just past the next ">" from `j` that isn't inside a quoted attribute, or nil.
        func tagEnd(_ j: Int) -> Int? {
            var quote: Character?
            var k = j
            while k < s.count {
                let c = s[k]
                if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { return k + 1 }
                k += 1
            }
            return nil
        }
        /// Index just past "-->" from `j`, or the end.
        func commentEnd(_ j: Int) -> Int {
            var k = j
            while k + 2 < s.count { if s[k] == "-", s[k + 1] == "-", s[k + 2] == ">" { return k + 3 }; k += 1 }
            return s.count
        }

        var textStart = 0
        while i < s.count {
            guard s[i] == "<", i + 1 < s.count else { i += 1; continue }
            let next = s[i + 1]
            guard next.isLetter || next == "/" || next == "!" else { i += 1; continue }
            text(String(s[textStart..<i]))
            if next == "!" {
                i = String(s[i..<min(i + 4, s.count)]) == "<!--" ? commentEnd(i + 4) : (tagEnd(i) ?? s.count)
                textStart = i
                continue
            }
            guard let end = tagEnd(i) else { i = s.count; textStart = i; break }
            let closing = next == "/"
            let name = String(s[(i + (closing ? 2 : 1))..<end].prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
            i = end
            if !closing, name == "script" || name == "style" {
                // Skip to the matching end tag.
                let rest = String(s[i...]).lowercased()
                if let r = rest.range(of: "</\(name)") {
                    let offset = rest.distance(from: rest.startIndex, to: r.upperBound)
                    i = tagEnd(i + offset) ?? s.count
                } else {
                    i = s.count
                }
            } else if name == "br" {
                trimTrailingSpaces()
                if !out.isEmpty { out += "\n" }
            } else if paragraphTags.contains(name) {
                breakLines(2)
                if name == "pre" { pre = max(0, pre + (closing ? -1 : 1)) }
            } else if lineTags.contains(name) {
                if !closing {
                    breakLines(1)
                    if name == "li" { out += "• " }
                }
            } else if name == "td" || name == "th", !closing, let last = out.last, last != "\n" {
                out += " "
            }
            textStart = i
        }
        if textStart < s.count { text(String(s[textStart...])) }

        let lines = out.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        var result = lines.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&name;`, `&#65;` and `&#x41;` -> their characters. Unknown or invalid references stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{0,31});/) { match in
            let ref = String(match.output.1)
            if ref.hasPrefix("#") {
                let hex = ref.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = ref.dropFirst(hex ? 2 : 1)
                if let v = UInt32(digits, radix: hex ? 16 : 10), v >= 32, !(127...159).contains(v),
                   let scalar = Unicode.Scalar(v) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            if ref == "nbsp" { return " " }
            return HTMLEntities.table[ref] ?? String(match.output.0)
        }
    }
}
