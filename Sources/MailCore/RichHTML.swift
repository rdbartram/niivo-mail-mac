import Foundation

/// RichDoc ⇄ email-safe HTML. Output: inline styles only (Outlook ignores `<style>`), no classes, no scripts, a
/// fragment (not a document) so it can be inserted inside the quoted `<body>` of a reply. The user's region is wrapped
/// in `<div id="niivo-compose">` so a reopened draft can be split into "ours" and "carried verbatim".
/// Input (RichHTMLParser.swift): a small tokenizer, not WebKit (`NSAttributedString(html:)` loads remote content).
public enum RichHTML {
    public static let composeMarker = "niivo-compose"
    public static let signatureMarker = "niivo-signature"
    static let mono = "Menlo,Consolas,'Courier New',monospace"

    public static func html(_ doc: RichDoc) -> String {
        let d = doc.normalised()
        var out = "<div id=\"\(composeMarker)\">"
        var lists: [RichBlockKind] = []   // open <ul>/<ol>, each with an open <li>
        var i = 0
        var inSignature = false
        func closeLists(to n: Int) { while lists.count > n { out += "</li>" + (lists.removeLast() == .number ? "</ol>" : "</ul>") } }
        while i < d.blocks.count {
            let b = d.blocks[i]
            if b.signature != inSignature {
                closeLists(to: 0)
                out += b.signature ? "<div id=\"\(signatureMarker)\">" : "</div>"
                inSignature = b.signature
            }
            switch b.kind {
            case .bullet, .number:
                let depth = b.level + 1
                closeLists(to: depth)
                if lists.count == depth, lists.last != b.kind { closeLists(to: depth - 1) }
                if lists.count == depth { out += "</li>" }
                while lists.count < depth {
                    let tag = b.kind == .number ? "ol" : "ul"
                    out += "<\(tag) style=\"margin:0;padding-left:24px\">"
                    lists.append(b.kind)
                    if lists.count < depth { out += "<li style=\"list-style-type:none\">" }
                }
                out += "<li\(alignAttr(b.align))>" + runs(b.runs)
                i += 1
            case .code:
                closeLists(to: 0)
                var lines: [String] = []
                while i < d.blocks.count, d.blocks[i].kind == .code, d.blocks[i].signature == b.signature {
                    lines.append(escape(d.blocks[i].text, keepSpaces: false)); i += 1
                }
                out += "<pre style=\"font-family:\(mono);font-size:13px;background-color:#F4F4F4;padding:8px;margin:0;white-space:pre-wrap\">"
                    + lines.joined(separator: "\n") + "</pre>"
            case .quote:
                closeLists(to: 0)
                out += "<blockquote style=\"margin:0;border-left:3px solid #CCCCCC;padding-left:10px\">"
                while i < d.blocks.count, d.blocks[i].kind == .quote, d.blocks[i].signature == b.signature {
                    out += paragraph(d.blocks[i]); i += 1
                }
                out += "</blockquote>"
            case .heading1, .heading2, .heading3:
                closeLists(to: 0)
                let (tag, px) = b.kind == .heading1 ? ("h1", 24) : b.kind == .heading2 ? ("h2", 20) : ("h3", 16)
                out += "<\(tag) style=\"margin:0;font-size:\(px)px;font-weight:bold\(alignCSS(b.align))\">\(content(b))</\(tag)>"
                i += 1
            case .paragraph:
                closeLists(to: 0)
                out += paragraph(b); i += 1
            case .rule:
                closeLists(to: 0)
                out += "<hr style=\"border:none;border-top:1px solid #BFBFBF;margin:8px 0\">"; i += 1
            case .table:
                closeLists(to: 0)
                var rows: [[[RichRun]]] = []
                while i < d.blocks.count, d.blocks[i].kind == .table, d.blocks[i].signature == b.signature {
                    rows.append(cells(d.blocks[i].runs)); i += 1
                }
                let cols = rows.map(\.count).max() ?? 1
                out += "<table \(tableMarker)=\"1\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse\">"
                for r in rows {
                    out += "<tr>"
                    for c in 0..<cols {
                        out += "<td style=\"border:1px solid #BFBFBF;padding:4px 8px;vertical-align:top\">"
                            + (c < r.count ? runs(r[c]) : "") + "</td>"
                    }
                    out += "</tr>"
                }
                out += "</table>"
            }
        }
        closeLists(to: 0)
        if inSignature { out += "</div>" }
        return out + "</div>"
    }

    /// Marks tables the composer wrote, so a reopened draft gets its grid back; other tables (pasted web layouts,
    /// signatures) still flatten to tab-separated paragraphs.
    public static let tableMarker = "data-niivo-table"

    /// A `.table` row's runs split at the tab characters into cells (styles kept).
    static func cells(_ rs: [RichRun]) -> [[RichRun]] {
        var out: [[RichRun]] = [[]]
        for r in rs {
            guard r.image == nil, r.text.contains(RichBlockKind.cellSeparator) else { out[out.count - 1].append(r); continue }
            let parts = r.text.split(separator: RichBlockKind.cellSeparator, omittingEmptySubsequences: false)
            for (k, p) in parts.enumerated() {
                if k > 0 { out.append([]) }
                if !p.isEmpty { out[out.count - 1].append(RichRun(String(p), r.style)) }
            }
        }
        return out
    }

    static func paragraph(_ b: RichBlock) -> String { "<p style=\"margin:0\(alignCSS(b.align))\">\(content(b))</p>" }
    static func content(_ b: RichBlock) -> String { b.isEmpty ? "<br>" : runs(b.runs) }
    static func alignCSS(_ a: RichAlign) -> String { a == .left ? "" : ";text-align:\(a.rawValue)" }
    static func alignAttr(_ a: RichAlign) -> String { a == .left ? "" : " style=\"text-align:\(a.rawValue)\"" }

    static func runs(_ rs: [RichRun]) -> String {
        rs.map { r in
            if let img = r.image {
                let w = img.width.map { " width=\"\($0)\"" } ?? ""
                return "<img src=\"cid:\(attr(img.cid))\" alt=\"\(attr(img.alt))\"\(w) style=\"max-width:100%\">"
            }
            var s = escape(r.text, keepSpaces: true)
            let st = r.style
            if st.code { s = "<code style=\"font-family:\(mono);background-color:#F4F4F4\">\(s)</code>" }
            if st.strike { s = "<s>\(s)</s>" }
            if st.underline { s = "<u>\(s)</u>" }
            if st.italic { s = "<i>\(s)</i>" }
            if st.bold { s = "<b>\(s)</b>" }
            var css: [String] = []
            if let c = st.color { css.append("color:\(c)") }
            if let h = st.highlight { css.append("background-color:\(h)") }
            if let z = st.size { css.append("font-size:\(z == .small ? 12 : 18)px") }
            if !css.isEmpty { s = "<span style=\"\(css.joined(separator: ";"))\">\(s)</span>" }
            if let l = st.link { s = "<a href=\"\(attr(l))\">\(s)</a>" }
            return s
        }.joined()
    }

    static func escape(_ t: String, keepSpaces: Bool) -> String {
        var s = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: RichRun.lineBreak, with: "<br>").replacingOccurrences(of: RichRun.objectReplacement, with: "")
        if keepSpaces {
            s = s.replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;").replacingOccurrences(of: "  ", with: " &nbsp;")
        }
        return s
    }
    static func attr(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Splits a draft body into (before our region, our region's inner HTML, after it). Without the marker the whole
    /// `<body>` content is ours and nothing is carried.
    public static func split(_ html: String) -> (prefix: String, editable: String, suffix: String) {
        // UNVERIFIED: whether Exchange keeps the id on stored drafts (received mail gets "x_" prefixes), so match loosely.
        if let open = html.range(of: "<div[^>]*\\bid\\s*=\\s*[\"']?(x_)?\(composeMarker)[\"']?[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var depth = 1
            var cursor = open.upperBound
            let re = try! NSRegularExpression(pattern: "<(/?)div\\b[^>]*>", options: [.caseInsensitive])
            while depth > 0, let m = re.firstMatch(in: html, range: NSRange(cursor..<html.endIndex, in: html)),
                  let r = Range(m.range, in: html) {
                depth += html[r].hasPrefix("</") ? -1 : 1
                if depth == 0 {
                    return (String(html[..<open.lowerBound]), String(html[open.upperBound..<r.lowerBound]), String(html[r.upperBound...]))
                }
                cursor = r.upperBound
            }
        }
        if let b = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards], range: b.upperBound..<html.endIndex)
            return (String(html[..<b.upperBound]), String(html[b.upperBound..<(end?.lowerBound ?? html.endIndex)]),
                    end.map { String(html[$0.lowerBound...]) } ?? "")
        }
        return ("", html, "")
    }
}
