import Foundation

/// HTML → RichDoc for paste (web / Word / Teams), reopened drafts and signatures. Runs `HTMLSanitizer` first
/// (defence in depth), then keeps only allow-listed structure: tags not understood are ignored (their text kept),
/// script/style/head/iframe/object/svg… are dropped with their content, links must be http(s)/mailto/tel, colours
/// must parse as hex/rgb/basic names, remote images are dropped (never fetched), `data:` images become inline
/// attachments. Tables flatten to tab-separated paragraphs, except the composer's own grids (`RichHTML.tableMarker`),
/// which come back as `.table` rows; `<hr>` becomes a `.rule` block.
public extension RichHTML {
    struct DataImage: Sendable, Hashable { public var cid: String; public var mime: String; public var data: Data }

    struct Parsed: Sendable {
        public var doc: RichDoc
        public var dataImages: [DataImage]
        public var droppedRemoteImages: Int
    }

    static func parse(_ html: String, makeCID: () -> String = { UUID().uuidString.lowercased() + "@niivo" }) -> Parsed {
        var p = HTMLDocParser()
        p.run(HTMLSanitizer.sanitize(html, allowRemote: true).html, makeCID: makeCID)
        return Parsed(doc: RichDoc(p.blocks).normalised(), dataImages: p.dataImages, droppedRemoteImages: p.dropped)
    }
}

struct HTMLDocParser {
    struct Frame { var tag: String; var style: RichStyle; var align: RichAlign?; var sig = false }

    var blocks: [RichBlock] = []
    var runs: [RichRun] = []
    var sawContent = false
    var stack: [Frame] = []
    var lists: [RichBlockKind] = []
    var quoteDepth = 0, preDepth = 0
    var heading: RichBlockKind?
    var wordList: (kind: RichBlockKind, level: Int)?
    var dataImages: [RichHTML.DataImage] = []
    var dropped = 0
    var cellOpen = false
    var skipUntil: String?
    /// Open tables, true = written by the composer (`RichHTML.tableMarker`): their rows become `.table` blocks.
    var tables: [Bool] = []
    var inGrid: Bool { tables.last == true }

    var style: RichStyle { stack.last?.style ?? .plain }
    var currentAlign: RichAlign { stack.reversed().compactMap(\.align).first ?? .left }

    static let skip: Set<String> = ["head", "style", "script", "title", "xml", "template", "noscript", "iframe", "object",
                                    "embed", "svg", "math", "select", "textarea", "option"]
    static let block: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "ul", "ol",
                                     "table", "tr", "section", "article", "header", "footer", "dl", "dt", "dd", "center"]
    static let void: Set<String> = ["br", "img", "hr", "meta", "link", "input", "col", "area", "base", "wbr", "source"]

    mutating func flush(force: Bool = false) {
        var rs = runs
        if let last = rs.last, last.image == nil, last.text.hasSuffix(RichRun.lineBreak) { rs[rs.count - 1].text.removeLast() }
        if preDepth == 0, let f = rs.first, f.image == nil { rs[0].text = String(f.text.drop { $0 == " " }) }
        if preDepth == 0, let l = rs.last, l.image == nil { rs[rs.count - 1].text = String(l.text.reversed().drop { $0 == " " }.reversed()) }
        if sawContent || force {
            var kind: RichBlockKind = .paragraph, level = 0
            if preDepth > 0 { kind = .code }
            else if inGrid { kind = .table }
            else if let h = heading { kind = h }
            else if let l = lists.last { kind = l; level = lists.count - 1 }
            else if let w = wordList { kind = w.kind; level = w.level }
            else if quoteDepth > 0 { kind = .quote }
            let onlySpace = rs.allSatisfy { $0.image == nil && $0.text.allSatisfy { $0 == " " || $0 == "\u{00A0}" } }
            blocks.append(RichBlock(kind, level: level, align: currentAlign, runs: onlySpace ? [] : rs, signature: stack.last?.sig ?? false))
        }
        runs = []; sawContent = false; cellOpen = false
    }

    mutating func text(_ raw: String) {
        let t = HTMLDocParser.decodeEntities(raw)
        if preDepth > 0 {
            for (k, line) in t.components(separatedBy: "\n").enumerated() {
                if k > 0 { flush(force: true) }
                if !line.isEmpty { runs.append(RichRun(line, style)); sawContent = true }
            }
            return
        }
        var s = ""
        var lastSpace = runs.last.map { $0.text.hasSuffix(" ") || $0.text.hasSuffix(RichRun.lineBreak) } ?? true
        for ch in t {
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" || ch == "\r\n" {
                if !lastSpace { s.append(" "); lastSpace = true }
            } else { s.append(ch); lastSpace = false }
        }
        guard !s.isEmpty else { return }
        if !sawContent && s.allSatisfy({ $0 == " " }) { return }
        if s.contains("\u{00A0}") {   // &nbsp; is spacing, not content: a blank Word line stays a blank line
            if s.allSatisfy({ $0 == "\u{00A0}" || $0 == " " }) { sawContent = true; return }
            s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        runs.append(RichRun(s, style)); sawContent = true
    }

    mutating func run(_ html: String, makeCID: () -> String) {
        var i = html.startIndex
        var textStart = i
        while i < html.endIndex {
            guard html[i] == "<" else { i = html.index(after: i); continue }
            if textStart < i { text(String(html[textStart..<i])) }
            let rest = html[i...]
            if rest.hasPrefix("<!--") {
                i = rest.range(of: "-->")?.upperBound ?? html.endIndex
            } else if rest.hasPrefix("<![if") || rest.hasPrefix("<![IF") {
                // Word fake list markers: <![if !supportLists]>1.&nbsp;<![endif]> → number vs bullet from the marker.
                let end = rest.range(of: "<![endif]>", options: .caseInsensitive)
                let marker = String(html[i..<(end?.lowerBound ?? html.endIndex)])
                if marker.lowercased().contains("supportlists"), var w = wordList {
                    let plain = marker.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                    w.kind = plain.range(of: "[0-9a-zA-Z]+[.)]", options: .regularExpression) != nil ? .number : .bullet
                    wordList = w
                }
                i = end?.upperBound ?? html.endIndex
            } else if rest.hasPrefix("<!") || rest.hasPrefix("<?") {
                i = rest.firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
            } else if let close = rest.firstIndex(of: ">") {
                tag(String(html[html.index(after: i)..<close]), makeCID: makeCID)
                i = html.index(after: close)
                if let t = skipUntil {
                    if let r = html.range(of: "</\(t)", options: .caseInsensitive, range: i..<html.endIndex) {
                        i = html[r.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                    } else { i = html.endIndex }
                    skipUntil = nil
                }
            } else { i = html.endIndex }
            textStart = i
        }
        if textStart < html.endIndex { text(String(html[textStart...])) }
        flush()
    }

    mutating func tag(_ raw: String, makeCID: () -> String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = body.hasPrefix("/")
        if closing { body.removeFirst() }
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }
        let nameEnd = body.firstIndex { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" } ?? body.endIndex
        let name = body[..<nameEnd].lowercased()
        guard !name.isEmpty, name.first?.isLetter == true else { return }
        if closing { end(name); return }
        if Self.skip.contains(name) { if !selfClosing { skipUntil = name }; return }
        start(name, HTMLDocParser.parseAttrs(String(body[nameEnd...])), makeCID: makeCID)
        if selfClosing && !Self.void.contains(name) { end(name) }
    }

    mutating func start(_ name: String, _ a: [String: String], makeCID: () -> String) {
        let css = HTMLDocParser.parseCSS(a["style"] ?? "")
        switch name {
        case "br": runs.append(RichRun(RichRun.lineBreak, style)); sawContent = true; return
        case "img": image(a, makeCID: makeCID); return
        case "hr":
            flush()
            blocks.append(RichBlock(.rule, signature: stack.last?.sig ?? false))
            return
        case "td", "th":
            if cellOpen || sawContent { runs.append(RichRun("\t", style)) }
            cellOpen = true
            if inGrid { sawContent = true }   // a row of empty cells is still a row
        case "table": flush(); tables.append(a[RichHTML.tableMarker] != nil)
        default: break
        }
        if Self.block.contains(name) { flush() }
        var st = style
        var al: RichAlign?
        switch name {
        case "b", "strong": st.bold = true
        case "i", "em", "cite", "var": st.italic = true
        case "u", "ins": st.underline = true
        case "s", "strike", "del": st.strike = true
        case "code", "kbd", "tt", "samp": st.code = true
        case "a": st.link = a["href"].flatMap(RichHTML.safeLink)
        case "font":
            if let c = a["color"].flatMap(RichHTML.color), !RichHTML.isNeutral(c) { st.color = c }
            if let z = a["size"].flatMap(Int.init) { st.size = z <= 2 ? .small : z >= 4 ? .large : nil }
        case "h1": heading = .heading1
        case "h2": heading = .heading2
        case "h3", "h4", "h5", "h6": heading = .heading3
        case "ul": lists.append(.bullet)
        case "ol": lists.append(.number)
        case "blockquote": quoteDepth += 1
        case "pre": preDepth += 1
        case "center": al = .center
        case "p", "div":
            if let m = css["mso-list"], let r = m.range(of: "level[0-9]+", options: .regularExpression),
               let n = Int(m[r].dropFirst(5)) { wordList = (.bullet, max(0, n - 1)) }
        default: break
        }
        HTMLDocParser.apply(css, to: &st)
        // Block-level presentation (heading size/weight, <pre> font) is the block kind, not run formatting.
        if name.count == 2, name.hasPrefix("h"), name.last?.isNumber == true { st.bold = style.bold; st.size = style.size }
        if name == "pre" { st.code = style.code }
        if let t = (css["text-align"] ?? a["align"])?.lowercased() { al = RichAlign(rawValue: t == "start" ? "left" : t) ?? al }
        let sig = (stack.last?.sig ?? false) || (name == "div" && [RichHTML.signatureMarker, "x_" + RichHTML.signatureMarker].contains(a["id"] ?? ""))
        if !Self.void.contains(name) { stack.append(Frame(tag: name, style: st, align: Self.block.contains(name) ? al : nil, sig: sig)) }
    }

    mutating func end(_ name: String) {
        guard let idx = stack.lastIndex(where: { $0.tag == name }) else { return }
        if Self.block.contains(name) { flush() }
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6": heading = nil
        case "ul", "ol": if !lists.isEmpty { lists.removeLast() }
        case "blockquote": quoteDepth = max(0, quoteDepth - 1)
        case "pre": preDepth = max(0, preDepth - 1)
        case "p", "div": wordList = nil
        case "table": if !tables.isEmpty { tables.removeLast() }
        default: break
        }
        stack.removeSubrange(idx...)
    }

    mutating func image(_ a: [String: String], makeCID: () -> String) {
        let src = (a["src"] ?? "").trimmingCharacters(in: .whitespaces)
        let alt = a["alt"] ?? ""
        let width = a["width"].flatMap { Int($0.filter(\.isNumber)) }
        if src.lowercased().hasPrefix("cid:") {
            runs.append(RichRun("", style, image: RichImage(cid: String(src.dropFirst(4)), alt: alt, width: width))); sawContent = true
        } else if src.lowercased().hasPrefix("data:image/"), src != HTMLSanitizer.blockedImagePlaceholder,
                  let comma = src.firstIndex(of: ","), src[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...])), !data.isEmpty {
            let mime = String(src[src.index(src.startIndex, offsetBy: 5)..<comma].dropLast(7))
            let cid = makeCID()
            dataImages.append(RichHTML.DataImage(cid: cid, mime: mime, data: data))
            runs.append(RichRun("", style, image: RichImage(cid: cid, alt: alt, width: width))); sawContent = true
        } else {
            dropped += 1
            if !alt.isEmpty { text(alt) }
        }
    }

    static func apply(_ css: [String: String], to st: inout RichStyle) {
        if let w = css["font-weight"]?.lowercased() {
            if w == "bold" || w == "bolder" || (Int(w) ?? 0) >= 600 { st.bold = true }
            else if w == "normal" || w == "lighter" || (Int(w).map { $0 < 600 } ?? false) { st.bold = false }
        }
        if let f = css["font-style"]?.lowercased() { st.italic = f == "italic" || f == "oblique" }
        if let d = (css["text-decoration"] ?? css["text-decoration-line"])?.lowercased() {
            if d.contains("underline") { st.underline = true }
            if d.contains("line-through") { st.strike = true }
            if d == "none" { st.underline = false; st.strike = false }
        }
        if let c = css["color"].flatMap(RichHTML.color), !RichHTML.isNeutral(c) { st.color = c }
        if let h = (css["background-color"] ?? css["background"]).flatMap(RichHTML.color), !RichHTML.isNeutral(h) { st.highlight = h }
        if let z = css["font-size"].flatMap(pixels) { st.size = z <= 11.5 ? .small : z >= 17 ? .large : nil }
        if let fam = css["font-family"]?.lowercased(),
           fam.contains("monospace") || fam.hasPrefix("courier") || fam.hasPrefix("consolas") || fam.hasPrefix("menlo") { st.code = true }
    }

    static func parseAttrs(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*(?:=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?")
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s) else { continue }
            let v = [3, 4, 5].lazy.compactMap { Range(m.range(at: $0), in: s) }.first.map { decodeEntities(String(s[$0])) } ?? ""
            out[s[k].lowercased()] = v
        }
        return out
    }

    static func parseCSS(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for decl in s.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                kv[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static func pixels(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("px"), let v = Double(s.dropLast(2)) { return v }
        if s.hasSuffix("pt"), let v = Double(s.dropLast(2)) { return v * 4 / 3 }
        if s.hasSuffix("em"), let v = Double(s.dropLast(2)) { return v * 14 }
        switch s { case "small", "x-small", "xx-small", "smaller": return 11; case "large", "x-large", "xx-large", "larger": return 18; default: return nil }
    }

    static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
                                             "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
                                             "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "euro": "€",
                                             "middot": "·", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö",
                                             "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç"]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = s[s.index(after: i)..<semi]
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { rep = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { rep = entities[String(name)] }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}

public extension RichHTML {
    static func safeLink(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = s.lowercased()
        guard l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("mailto:") || l.hasPrefix("tel:") else { return nil }
        guard !s.contains("\"") && !s.contains("<") && !s.contains(">") && !s.contains(" ") else { return nil }
        return s
    }

    static let namedColours: [String: String] = ["red": "#FF0000", "green": "#008000", "blue": "#0000FF", "yellow": "#FFFF00",
                                                 "orange": "#FFA500", "purple": "#800080", "black": "#000000", "white": "#FFFFFF",
                                                 "gray": "#808080", "grey": "#808080", "navy": "#000080", "teal": "#008080",
                                                 "maroon": "#800000", "olive": "#808000", "lime": "#00FF00", "aqua": "#00FFFF",
                                                 "fuchsia": "#FF00FF", "silver": "#C0C0C0"]

    /// Normalises a CSS colour to "#RRGGBB"; nil if it isn't one we accept.
    static func color(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = namedColours[s] { return n }
        if s.hasPrefix("#") {
            let h = s.dropFirst()
            guard h.allSatisfy(\.isHexDigit) else { return nil }
            if h.count == 3 { return "#" + h.map { "\($0)\($0)" }.joined().uppercased() }
            if h.count == 6 { return "#" + h.uppercased() }
            return nil
        }
        if s.hasPrefix("rgb") {
            let nums = s.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard nums.count >= 3 else { return nil }
            if nums.count == 4, let a = Double(nums[3]), a < 0.5 { return nil }
            let v = nums.prefix(3).compactMap { Int($0) }
            guard v.count == 3, v.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
        }
        return nil
    }

    /// Greys (incl. black/white) are the source's theme, not emphasis: dropped on paste so the draft follows the
    /// reader's light/dark appearance.
    static func isNeutral(_ hex: String) -> Bool {
        let v = Array(hex.dropFirst())
        guard v.count == 6, let r = Int(String(v[0...1]), radix: 16), let g = Int(String(v[2...3]), radix: 16),
              let b = Int(String(v[4...5]), radix: 16) else { return true }
        return max(r, g, b) - min(r, g, b) < 24
    }
}
