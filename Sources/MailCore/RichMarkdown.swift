import Foundation

/// Markdown → RichDoc (pasting a Markdown block) and the live-typing rules (Notion/Bear style). Deliberately a
/// pragmatic subset: headings (# ## ###), quotes, bullet/numbered lists with indentation, fenced code, **bold**,
/// __bold__, *italic*, _italic_, ~~strike~~, `code`, [text](url), <url>. Tables stay text.
public enum RichMarkdown {

    // MARK: Paste

    /// Heuristic: worth converting a plain-text paste?
    public static func looksLikeMarkdown(_ s: String) -> Bool {
        let block = try! NSRegularExpression(pattern: "^(\\s*([-*+]|[0-9]+[.)])\\s+\\S|#{1,6}\\s+\\S|>\\s|```)", options: [.anchorsMatchLines])
        let inline = try! NSRegularExpression(pattern: "(\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|~~[^~\\n]+~~|`[^`\\n]+`|\\[[^\\]\\n]+\\]\\([^)\\s]+\\))")
        let r = NSRange(s.startIndex..., in: s)
        return block.firstMatch(in: s, range: r) != nil || inline.firstMatch(in: s, range: r) != nil
    }

    public static func parse(_ s: String) -> RichDoc {
        var blocks: [RichBlock] = []
        var para: [String] = []
        var inFence = false
        func flushPara() {
            guard !para.isEmpty else { return }
            if let last = blocks.last, !last.isEmpty { blocks.append(RichBlock()) }
            blocks.append(RichBlock(runs: inline(para.joined(separator: RichRun.lineBreak))))
            para = []
        }
        for raw in s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flushPara(); inFence.toggle(); continue }
            if inFence { blocks.append(RichBlock(.code, runs: raw.isEmpty ? [] : [RichRun(raw)])); continue }
            if trimmed.isEmpty { flushPara(); continue }
            if let (kind, level, rest) = lineBlock(raw) {
                flushPara()
                if kind.isList, let last = blocks.last, !last.kind.isList, !last.isEmpty { blocks.append(RichBlock()) }
                blocks.append(RichBlock(kind, level: level, runs: kind == .code ? [RichRun(rest)] : inline(rest)))
                continue
            }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 { flushPara(); continue }
            para.append(trimmed)
        }
        flushPara()
        return RichDoc(blocks).normalised()
    }

    /// Block marker at line start → (kind, level, remaining text).
    static func lineBlock(_ line: String) -> (RichBlockKind, Int, String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let level = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let t = String(line.dropFirst(indent.count))
        for (prefix, kind) in [("### ", RichBlockKind.heading3), ("## ", .heading2), ("# ", .heading1), ("> ", .quote)] where t.hasPrefix(prefix) {
            return (kind, 0, String(t.dropFirst(prefix.count)))
        }
        if t.hasPrefix("####") , let sp = t.firstIndex(of: " "), t[..<sp].allSatisfy({ $0 == "#" }) { return (.heading3, 0, String(t[t.index(after: sp)...])) }
        if t == ">" { return (.quote, 0, "") }
        for p in ["- ", "* ", "+ "] where t.hasPrefix(p) {
            var rest = String(t.dropFirst(2))
            if rest.hasPrefix("[ ] ") { rest = "☐ " + rest.dropFirst(4) } else if rest.lowercased().hasPrefix("[x] ") { rest = "☑ " + rest.dropFirst(4) }
            return (.bullet, level, rest)
        }
        if let r = t.range(of: "^[0-9]{1,3}[.)] ", options: .regularExpression) { return (.number, level, String(t[r.upperBound...])) }
        return nil
    }

    /// Inline Markdown → runs.
    public static func inline(_ s: String, base: RichStyle = .plain) -> [RichRun] {
        var out: [RichRun] = []
        var buf = ""
        let chars = Array(s)
        var i = 0
        func flush() { if !buf.isEmpty { out.append(RichRun(buf, base)); buf = "" } }
        func find(_ delim: [Character], from: Int) -> Int? {
            var j = from
            while j + delim.count <= chars.count {
                if Array(chars[j..<j + delim.count]) == delim, j > from { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "*_`~[]()\\#>-".contains(chars[i + 1]) { buf.append(chars[i + 1]); i += 2; continue }
            if c == "`", let j = find(["`"], from: i + 1) {
                flush(); var st = base; st.code = true
                out.append(RichRun(String(chars[i + 1..<j]), st)); i = j + 1; continue
            }
            var consumed = false
            for (d, apply) in [(["*", "*"], { (st: inout RichStyle) in st.bold = true }), (["_", "_"], { $0.bold = true }),
                               (["~", "~"], { $0.strike = true })] as [([Character], (inout RichStyle) -> Void)] {
                if i + 2 <= chars.count, Array(chars[i..<i + 2]) == d, i + 2 < chars.count, chars[i + 2] != " ",
                   let j = find(d, from: i + 2) {
                    flush(); var st = base; apply(&st)
                    out += inline(String(chars[i + 2..<j]), base: st); i = j + 2
                    consumed = true; break
                }
            }
            if consumed { continue }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != c,
               c == "*" || i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber),
               let j = find([c], from: i + 1), chars[j - 1] != " " {
                flush(); var st = base; st.italic = true
                out += inline(String(chars[i + 1..<j]), base: st); i = j + 1; continue
            }
            if c == "[", let close = find(["]"], from: i + 1), close + 1 < chars.count, chars[close + 1] == "(",
               let end = find([")"], from: close + 1), let url = RichHTML.safeLink(String(chars[close + 2..<end])) {
                flush(); var st = base; st.link = url
                out += inline(String(chars[i + 1..<close]), base: st); i = end + 1; continue
            }
            if c == "<", let end = find([">"], from: i + 1), let url = RichHTML.safeLink(String(chars[i + 1..<end])) {
                flush(); var st = base; st.link = url
                out.append(RichRun(url, st)); i = end + 1; continue
            }
            buf.append(c); i += 1
        }
        flush()
        return out
    }

    // MARK: Live typing

    /// Typing a marker + space at the start of a plain paragraph turns it into that block. `prefix` is the paragraph's
    /// text up to and including the space just typed.
    public static func blockTrigger(_ prefix: String) -> (kind: RichBlockKind, level: Int)? {
        switch prefix {
        case "- ", "* ", "+ ": return (.bullet, 0)
        case "> ": return (.quote, 0)
        case "# ": return (.heading1, 0)
        case "## ": return (.heading2, 0)
        case "### ": return (.heading3, 0)
        case "``` ": return (.code, 0)
        default:
            if prefix.range(of: "^[0-9]{1,3}[.)] $", options: .regularExpression) != nil { return (.number, 0) }
            return nil
        }
    }

    public struct InlineMatch: Sendable, Equatable {
        /// Length (UTF-16) of the matched Markdown at the end of the text, to be replaced by `text` with `style` added.
        public var utf16Length: Int
        public var text: String
        public var bold = false, italic = false, strike = false, code = false
        public var link: String?
    }

    nonisolated(unsafe) static let liveRules: [(NSRegularExpression, (inout InlineMatch) -> Void)] = [
        (try! NSRegularExpression(pattern: "\\*\\*([^*\\s](?:[^*]*[^*\\s])?)\\*\\*$"), { $0.bold = true }),
        (try! NSRegularExpression(pattern: "(?<![_\\w])__([^_\\s](?:[^_]*[^_\\s])?)__$"), { $0.bold = true }),
        (try! NSRegularExpression(pattern: "~~([^~\\s](?:[^~]*[^~\\s])?)~~$"), { $0.strike = true }),
        (try! NSRegularExpression(pattern: "`([^`]+)`$"), { $0.code = true }),
        (try! NSRegularExpression(pattern: "(?<![*\\w])\\*([^*\\s](?:[^*]*[^*\\s])?)\\*$"), { $0.italic = true }),
        (try! NSRegularExpression(pattern: "(?<![_\\w])_([^_\\s](?:[^_]*[^_\\s])?)_$"), { $0.italic = true }),
    ]
    nonisolated(unsafe) static let linkRule = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)$")

    /// Checks the text before the cursor (current paragraph) right after a closing delimiter was typed.
    public static func inlineMatch(_ before: String) -> InlineMatch? {
        guard let last = before.last, "*_~`)".contains(last) else { return nil }
        let ns = before as NSString
        let r = NSRange(location: 0, length: ns.length)
        if last == ")" {
            guard let m = linkRule.firstMatch(in: before, range: r), let url = RichHTML.safeLink(ns.substring(with: m.range(at: 2))) else { return nil }
            return InlineMatch(utf16Length: m.range.length, text: ns.substring(with: m.range(at: 1)), link: url)
        }
        for (re, apply) in liveRules {
            if let m = re.firstMatch(in: before, range: r) {
                var out = InlineMatch(utf16Length: m.range.length, text: ns.substring(with: m.range(at: 1)))
                apply(&out)
                return out
            }
        }
        return nil
    }
}
