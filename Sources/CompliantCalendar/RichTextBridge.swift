import AppKit
import MailCore

/// Semantic attributes in the composer's NSTextStorage. Display attributes (font, colour, paragraph style) are always
/// derived from these by `RichTextBridge.restyle`, so the stored formatting is exactly what the user set.
extension NSAttributedString.Key {
    static let nvBold = NSAttributedString.Key("niivo.bold")
    static let nvItalic = NSAttributedString.Key("niivo.italic")
    static let nvUnderline = NSAttributedString.Key("niivo.underline")
    static let nvStrike = NSAttributedString.Key("niivo.strike")
    static let nvCode = NSAttributedString.Key("niivo.code")
    static let nvSize = NSAttributedString.Key("niivo.size")          // "small" / "large"
    static let nvColor = NSAttributedString.Key("niivo.color")        // "#RRGGBB"
    static let nvHighlight = NSAttributedString.Key("niivo.highlight")
    static let nvLink = NSAttributedString.Key("niivo.link")
    static let nvCID = NSAttributedString.Key("niivo.cid")
    // Paragraph level (set on every character of the paragraph, incl. its newline).
    static let nvBlock = NSAttributedString.Key("niivo.block")
    static let nvLevel = NSAttributedString.Key("niivo.level")
    static let nvAlign = NSAttributedString.Key("niivo.align")
    static let nvSignature = NSAttributedString.Key("niivo.signature")

    static let nvInline: [NSAttributedString.Key] = [.nvBold, .nvItalic, .nvUnderline, .nvStrike, .nvCode, .nvSize, .nvColor, .nvHighlight, .nvLink]
    static let nvParagraph: [NSAttributedString.Key] = [.nvBlock, .nvLevel, .nvAlign, .nvSignature]
}

@MainActor
enum RichTextBridge {
    static var brandFont = false
    static var baseSize: CGFloat { brandFont ? 15 : 14 }

    /// Simple-grid geometry in the editor (the sent HTML uses a real table).
    nonisolated static let tableColumn: CGFloat = 140
    nonisolated static let tableInset: CGFloat = 8

    static func baseFont(_ size: CGFloat) -> NSFont {
        if brandFont, let f = NSFont(name: "Instrument Sans", size: size) { return f }
        return .systemFont(ofSize: size)
    }

    // MARK: Attributes

    static func inlineAttrs(_ s: RichStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        if s.bold { a[.nvBold] = true }
        if s.italic { a[.nvItalic] = true }
        if s.underline { a[.nvUnderline] = true }
        if s.strike { a[.nvStrike] = true }
        if s.code { a[.nvCode] = true }
        if let z = s.size { a[.nvSize] = z.rawValue }
        if let c = s.color { a[.nvColor] = c }
        if let h = s.highlight { a[.nvHighlight] = h }
        if let l = s.link { a[.nvLink] = l }
        return a
    }

    nonisolated static func style(_ a: [NSAttributedString.Key: Any]) -> RichStyle {
        RichStyle(bold: a[.nvBold] as? Bool == true, italic: a[.nvItalic] as? Bool == true, underline: a[.nvUnderline] as? Bool == true,
                  strike: a[.nvStrike] as? Bool == true, code: a[.nvCode] as? Bool == true,
                  size: (a[.nvSize] as? String).flatMap(RichSize.init(rawValue:)), color: a[.nvColor] as? String,
                  highlight: a[.nvHighlight] as? String, link: a[.nvLink] as? String)
    }

    static func blockAttrs(_ b: RichBlock) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.nvBlock: b.kind.rawValue, .nvLevel: b.level, .nvAlign: b.align.rawValue]
        if b.signature { a[.nvSignature] = true }
        return a
    }

    nonisolated static func block(_ a: [NSAttributedString.Key: Any]) -> RichBlock {
        RichBlock(RichBlockKind(rawValue: a[.nvBlock] as? String ?? "") ?? .paragraph, level: a[.nvLevel] as? Int ?? 0,
                  align: RichAlign(rawValue: a[.nvAlign] as? String ?? "") ?? .left, signature: a[.nvSignature] as? Bool == true)
    }

    /// Display attributes for one character, derived from its semantic attributes.
    static func display(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let s = style(a), b = block(a)
        var size = baseSize
        var bold = s.bold
        switch b.kind {
        case .heading1: size = 24; bold = true
        case .heading2: size = 20; bold = true
        case .heading3: size = 16; bold = true
        default: if let z = s.size { size = z == .small ? 12 : 18 }
        }
        var font = (s.code || b.kind == .code) ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: bold ? .bold : .regular) : baseFont(size)
        if bold && !(s.code || b.kind == .code) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if s.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var out: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle(b)]
        out[.foregroundColor] = s.color.flatMap(NSColor.init(hex:)) ?? (s.link != nil ? NSColor.linkColor : b.kind == .quote ? NSColor.secondaryLabelColor : NSColor.textColor)
        if let h = s.highlight.flatMap(NSColor.init(hex:)) { out[.backgroundColor] = h }
        else if s.code && b.kind != .code { out[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25) }
        if s.underline || s.link != nil { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.strike { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let l = s.link, let u = URL(string: l) { out[.link] = u }
        return out
    }

    static func paragraphStyle(_ b: RichBlock) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch b.kind {
        case .bullet, .number:
            let indent = CGFloat(b.level + 1) * 24
            p.headIndent = indent; p.firstLineHeadIndent = indent
        case .quote: p.headIndent = 14; p.firstLineHeadIndent = 14
        case .code: p.headIndent = 8; p.firstLineHeadIndent = 8
        case .heading1, .heading2, .heading3: p.paragraphSpacingBefore = 4; p.paragraphSpacing = 2
        case .paragraph: break
        case .rule: p.minimumLineHeight = 16; p.paragraphSpacingBefore = 2; p.paragraphSpacing = 2
        case .table:
            // Cells are tab-separated: fixed columns, drawn as a grid by ComposerLayoutManager.
            p.headIndent = tableInset; p.firstLineHeadIndent = tableInset
            p.tabStops = (1...12).map { NSTextTab(textAlignment: .left, location: tableInset + CGFloat($0) * tableColumn) }
            p.defaultTabInterval = tableColumn
            p.paragraphSpacingBefore = 3; p.paragraphSpacing = 3
        }
        p.alignment = switch b.align { case .left: .natural; case .center: .center; case .right: .right; case .justify: .justified }
        p.lineSpacing = 1.5
        return p
    }

    /// Re-derives display attributes over `range` (whole paragraphs recommended).
    static func restyle(_ s: NSTextStorage, _ range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= s.length else { return }
        s.beginEditing()
        s.enumerateAttributes(in: range) { a, r, _ in
            var d = display(a)
            if a[.attachment] != nil { d.removeValue(forKey: .backgroundColor) }
            for k in [NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .link, .paragraphStyle] {
                if let v = d[k] { s.addAttribute(k, value: v, range: r) } else { s.removeAttribute(k, range: r) }
            }
        }
        s.endEditing()
    }

    /// Attributes for typing at a position with the given block (no inline formatting).
    static func typing(block b: RichBlock, style: RichStyle = .plain) -> [NSAttributedString.Key: Any] {
        var a = blockAttrs(b).merging(inlineAttrs(style)) { $1 }
        a.merge(display(a)) { $1 }
        return a
    }

    // MARK: Doc ⇄ attributed string

    static func attributed(_ doc: RichDoc, images: [String: OutgoingAttachment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = doc.blocks.isEmpty ? [RichBlock()] : doc.blocks
        for (i, b) in blocks.enumerated() {
            let ba = blockAttrs(b)
            for r in b.runs {
                if let img = r.image {
                    let att = NSTextAttachment()
                    if let data = images[img.cid]?.data, let image = NSImage(data: data) {
                        att.image = image
                        att.bounds = fittedBounds(image.size, width: img.width)
                    }
                    let s = NSMutableAttributedString(attachment: att)
                    s.addAttributes(ba.merging([.nvCID: img.cid]) { $1 }, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                } else {
                    out.append(NSAttributedString(string: r.text, attributes: ba.merging(inlineAttrs(r.style)) { $1 }))
                }
            }
            if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n", attributes: ba)) }
        }
        let m = NSTextStorage(attributedString: out)
        restyle(m, NSRange(location: 0, length: m.length))
        return m
    }

    static func fittedBounds(_ size: NSSize, width: Int?) -> NSRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let w = min(CGFloat(width ?? Int(size.width)), 480)
        return NSRect(x: 0, y: 0, width: w, height: size.height * w / size.width)
    }

    static func doc(_ s: NSAttributedString) -> RichDoc {
        let ns = s.string as NSString
        var blocks: [RichBlock] = []
        var loc = 0
        repeat {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            var content = pr
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            var b = pr.length > 0 ? block(s.attributes(at: pr.location, effectiveRange: nil)) : RichBlock()
            if content.length > 0 {
                s.enumerateAttributes(in: content) { a, r, _ in
                    if a[.attachment] != nil {
                        if let cid = a[.nvCID] as? String {
                            for _ in 0..<r.length { b.runs.append(RichRun("", style(a), image: RichImage(cid: cid))) }
                        }
                    } else {
                        b.runs.append(RichRun(ns.substring(with: r), style(a)))
                    }
                }
            }
            blocks.append(b)
            loc = NSMaxRange(pr)
        } while loc < ns.length
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 {   // trailing newline → an empty last paragraph
            blocks.append(block(s.attributes(at: ns.length - 1, effectiveRange: nil)).with(runs: []))
        }
        return RichDoc(blocks).normalised()
    }

    /// RTF / foreign attributed text (no niivo attributes) → doc, inferring formatting from fonts and attributes.
    static func infer(_ s: NSAttributedString) -> RichDoc {
        let ns = s.string as NSString
        var blocks: [RichBlock] = []
        var loc = 0
        let marker = try! NSRegularExpression(pattern: "^\\t?[•◦▪∙·\\-–*]?[0-9a-zA-Z]{0,3}[.)]?\\t")
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            var content = pr
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            var b = RichBlock()
            if let ps = s.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle {
                if let list = ps.textLists.last {
                    b.kind = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha")
                        || list.markerFormat.rawValue.contains("roman") ? .number : .bullet
                    b.level = ps.textLists.count - 1
                }
                b.align = switch ps.alignment { case .center: .center; case .right: .right; case .justified: .justify; default: .left }
            }
            if b.kind.isList, let m = marker.firstMatch(in: ns.substring(with: content), range: NSRange(location: 0, length: content.length)) {
                content.location += m.range.length; content.length -= m.range.length
            }
            if content.length > 0 {
                s.enumerateAttributes(in: content) { a, r, _ in
                    guard a[.attachment] == nil else { return }
                    var st = RichStyle()
                    if let f = a[.font] as? NSFont {
                        let t = NSFontManager.shared.traits(of: f)
                        st.bold = t.contains(.boldFontMask); st.italic = t.contains(.italicFontMask)
                        st.code = t.contains(.fixedPitchFontMask) || f.isFixedPitch
                        st.size = f.pointSize <= 11 ? .small : f.pointSize >= 17 ? .large : nil
                    }
                    st.underline = (a[.underlineStyle] as? Int ?? 0) != 0
                    st.strike = (a[.strikethroughStyle] as? Int ?? 0) != 0
                    if let c = (a[.foregroundColor] as? NSColor)?.hexString, !isNeutral(c) { st.color = c }
                    if let c = (a[.backgroundColor] as? NSColor)?.hexString, !isNeutral(c) { st.highlight = c }
                    if let l = (a[.link] as? URL)?.absoluteString ?? a[.link] as? String { st.link = RichHTML.safeLink(l); if st.link != nil { st.underline = false } }
                    b.runs.append(RichRun(ns.substring(with: r), st))
                }
            }
            blocks.append(b)
            loc = NSMaxRange(pr)
        }
        return RichDoc(blocks).normalised()
    }

    static func isNeutral(_ hex: String) -> Bool { RichHTML.isNeutral(hex) }
}

extension RichBlock {
    func with(runs: [RichRun]) -> RichBlock { var b = self; b.runs = runs; return b }
}

extension NSColor {
    convenience init?(hex: String) {
        guard let h = RichHTML.color(hex) else { return nil }
        let v = Int(h.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB), c.alphaComponent > 0.4 else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
