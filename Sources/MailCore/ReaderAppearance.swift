import Foundation

/// §17: how a message body follows the macOS appearance in the reader.
///
/// The reader's web view used to paint a fixed white page (`MailHTML.document(dark: false)` everywhere), so in Dark
/// Mode the body stayed white. This works on the app's own wrapper and on the *already sanitised* body, for display
/// only: the sanitiser, the CSP, the remote-load content rule list and the label/rights gates are untouched, and the
/// remap below only ever rewrites colour literals (never adds markup, URLs or properties).
public enum ReaderColourMode: String, Sendable, Equatable {
    /// The body sets no colours itself (plain text, simple HTML): a native dark stylesheet.
    case plain
    /// The body ships its own `prefers-color-scheme` rules: dark defaults only, its own dark rules do the rest.
    case selfAdapting
    /// The body hard-codes colours: in Dark Mode its colour literals are remapped (lightness inverted, hue kept)
    /// on top of the dark stylesheet. Images are never touched.
    case adapted
    /// "Show original colours": no dark rules, no remap; the message renders as sent.
    case original
}

public enum ReaderAppearance {
    /// Anything that sets a colour or background. Fails towards `.adapted` (remap), never towards leaving a
    /// hard-coded dark text colour on the dark ground.
    private static let colourPattern = try! NSRegularExpression(
        pattern: #"color\s*[:=]|background|bgcolor|\b(?:text|link|vlink|alink)\s*=|<font\b|-webkit-text-fill"#,
        options: [.caseInsensitive])

    /// True if the (sanitised) body sets its own colours or backgrounds.
    public static func setsOwnColours(_ html: String) -> Bool {
        colourPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    public static func mode(for html: String, original: Bool) -> ReaderColourMode {
        if original { return .original }
        if html.range(of: "prefers-color-scheme", options: .caseInsensitive) != nil { return .selfAdapting }
        return setsOwnColours(html) ? .adapted : .plain
    }

    /// Dark-appearance colours of the wrapper (niivo: the carbon card; system: the text background).
    public struct Palette: Sendable, Equatable {
        public var bg: String, fg: String, link: String, quote: String, quoteBar: String
    }

    public static func palette(brand: Bool) -> Palette {
        brand ? Palette(bg: "#111111", fg: "#F2F1EF", link: "#00D0FF", quote: "#8A8A86", quoteBar: "#F2F1EF")
              : Palette(bg: "#1E1E1E", fg: "#EDEDED", link: "#6CB4FF", quote: "#9A9A9A", quoteBar: "#8888")
    }

    /// CSS appended to the wrapper's `<style>` after its light defaults, inside a dark *screen* query (print stays
    /// light). The message's own `<style>` rules come later in the document and win over these defaults.
    /// - `dark`: the app's appearance as SwiftUI sees it. `.adapted` only gets dark rules when its body was
    ///   remapped for dark (`dark == true`); otherwise its hard-coded dark text could land on the dark ground.
    public static func darkCSS(_ mode: ReaderColourMode, brand: Bool, dark: Bool = true) -> String {
        if mode == .original || (mode == .adapted && !dark) { return "" }
        let p = palette(brand: brand)
        return """
        @media screen and (prefers-color-scheme: dark){
        :root{color-scheme:dark}
        html,body{background:\(p.bg);color:\(p.fg)}
        a{color:\(p.link)}
        blockquote{color:\(p.quote);border-left-color:\(p.quoteBar)}
        }
        """
    }

    /// The body to display: remapped only for `.adapted` in Dark Mode, otherwise unchanged.
    public static func displayBody(_ html: String, mode: ReaderColourMode, dark: Bool) -> String {
        guard dark, mode == .adapted else { return html }
        return remapForDark(html)
    }

    // MARK: - Colour remap

    /// NSCache is internally thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 32; return c }()

    /// Rewrites colour literals in `style="…"` values, `<style>` blocks and colour attributes inside tags, so the
    /// message keeps its hues but reads light-on-dark. Text nodes are never touched (a message quoting CSS shows
    /// as sent); images and `url(...)` are left alone. Memoised: the reader re-renders the same body often.
    public static func remapForDark(_ html: String) -> String {
        let key = html as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        let out = rewrite(html)
        cache.setObject(out as NSString, forKey: key)
        return out
    }

    private static let styleBlock = try! NSRegularExpression(pattern: #"(<style\b[^>]*>)([\s\S]*?)(</style\s*>)"#, options: [.caseInsensitive])
    private static let tag = try! NSRegularExpression(pattern: #"<[a-zA-Z][^>]*>"#)
    private static let styleAttr = try! NSRegularExpression(pattern: #"(\sstyle\s*=\s*)("[^"]*"|'[^']*')"#, options: [.caseInsensitive])
    private static let colourAttr = try! NSRegularExpression(
        pattern: #"(\s(?:bgcolor|color|text|link|vlink|alink)\s*=\s*)("[^"]*"|'[^']*'|[^\s>"']+)"#, options: [.caseInsensitive])
    private static let declaration = try! NSRegularExpression(
        pattern: #"(?<![-\w])((?:background-color|background|color|border(?:-(?:top|right|bottom|left))?(?:-color)?|outline(?:-color)?)\s*:\s*)([^;{}"'<>]+)"#,
        options: [.caseInsensitive])
    private static let urlPart = try! NSRegularExpression(pattern: #"url\([^)]*\)"#, options: [.caseInsensitive])
    private static let colourToken = try! NSRegularExpression(
        pattern: #"#[0-9a-f]{8}\b|#[0-9a-f]{6}\b|#[0-9a-f]{3,4}\b|rgba?\([^)]*\)|hsla?\([^)]*\)|\b[a-z]+\b"#, options: [.caseInsensitive])

    static func rewrite(_ html: String) -> String {
        // <style> blocks first (their contents are not tags), then every remaining start tag.
        var s = replace(styleBlock, in: html) { _, str in
            str(1) + remapCSS(str(2)) + str(3)
        }
        s = replace(tag, in: s) { _, str in
            var t = str(0)
            if t.lowercased().hasPrefix("<style") { return t }
            t = replace(styleAttr, in: t) { _, a in a(1) + remapCSS(a(2)) }
            t = replace(colourAttr, in: t) { _, a in
                let v = a(2)
                let q = v.first == "\"" || v.first == "'" ? String(v.first!) : ""
                let inner = q.isEmpty ? v : String(v.dropFirst().dropLast())
                return a(1) + q + (remapToken(inner.trimmingCharacters(in: .whitespaces)) ?? inner) + q
            }
            return t
        }
        return s
    }

    /// Remaps the colour values of colour-bearing declarations in a CSS fragment.
    static func remapCSS(_ css: String) -> String {
        replace(declaration, in: css) { _, d in d(1) + remapValue(d(2)) }
    }

    private static func remapValue(_ v: String) -> String {
        // Leave url(...) segments verbatim; remap tokens in between.
        var out = "", last = v.startIndex
        let ns = v as NSString
        for m in urlPart.matches(in: v, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: v) else { continue }
            out += remapTokens(String(v[last..<r.lowerBound])) + String(v[r])
            last = r.upperBound
        }
        return out + remapTokens(String(v[last...]))
    }

    private static func remapTokens(_ v: String) -> String {
        replace(colourToken, in: v) { _, t in remapToken(t(0)) ?? t(0) }
    }

    /// One colour literal → its dark-mode counterpart, or nil if it isn't a colour we parse (left as is).
    public static func remapToken(_ token: String) -> String? {
        guard let (r, g, b, a) = parse(token) else { return nil }
        let (h, s, l0) = hsl(r, g, b)
        let l = 0.07 + (1 - l0) * 0.86   // white ground → #121212, black text → #EDEDED, mid tones stay mid
        let (nr, ng, nb) = rgb(h, s, l)
        func c(_ x: Double) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        if a < 1 { return "rgba(\(c(nr)),\(c(ng)),\(c(nb)),\(String(format: "%.3g", a)))" }
        return String(format: "#%02X%02X%02X", c(nr), c(ng), c(nb))
    }

    private static let named: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "navy": 0x000080,
        "maroon": 0x800000, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080, "silver": 0xC0C0C0, "yellow": 0xFFFF00,
        "orange": 0xFFA500, "teal": 0x008080, "olive": 0x808000, "lime": 0x00FF00, "aqua": 0x00FFFF, "fuchsia": 0xFF00FF,
        "darkblue": 0x00008B, "darkred": 0x8B0000, "darkgreen": 0x006400, "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9,
        "dimgray": 0x696969, "dimgrey": 0x696969, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "whitesmoke": 0xF5F5F5,
        "gainsboro": 0xDCDCDC, "ivory": 0xFFFFF0, "beige": 0xF5F5DC, "linen": 0xFAF0E6, "snow": 0xFFFAFA,
        "windowtext": 0x000000, "window": 0xFFFFFF,
    ]

    public static func parse(_ token: String) -> (Double, Double, Double, Double)? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 8 {
                return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
            }
            return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        if t.hasPrefix("rgb") || t.hasPrefix("hsl"), let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")") {
            let parts = t[t.index(after: open)..<close].split(whereSeparator: { ",/ ".contains($0) }).map(String.init)
            guard parts.count >= 3 else { return nil }
            func num(_ s: String, scale: Double) -> Double? {
                s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : Double(s.replacingOccurrences(of: "deg", with: "")).map { $0 / scale }
            }
            let a = parts.count >= 4 ? (num(parts[3], scale: 1) ?? 1) : 1
            if t.hasPrefix("rgb") {
                guard let r = num(parts[0], scale: 255), let g = num(parts[1], scale: 255), let b = num(parts[2], scale: 255) else { return nil }
                return (r, g, b, a)
            }
            guard let h = num(parts[0], scale: 360), let s = num(parts[1], scale: 100), let l = num(parts[2], scale: 100) else { return nil }
            let (r, g, b) = rgb(h, s, l)
            return (r, g, b, a)
        }
        if let v = named[t] { return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1) }
        return nil
    }

    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    private static func rgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        func f(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0; if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        return (f(p, q, h + 1.0 / 3), f(p, q, h), f(p, q, h - 1.0 / 3))
    }

    /// Regex replace with a closure; `str(i)` returns capture group i ("" if absent).
    private static func replace(_ re: NSRegularExpression, in s: String,
                                _ make: (NSTextCheckingResult, (Int) -> String) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = "", last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += make(m) { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
