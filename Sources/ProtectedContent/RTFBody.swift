import AppKit
import Foundation

// Protected (rpmsg) message bodies frequently come back as RTF: Outlook stores the body as compressed RTF
// (MS-OXRTFCP) that usually encapsulates the original HTML (MS-OXRTFEX, `\fromhtml1`). Everything here runs in
// memory only; the result goes through the normal HTML sanitiser in the reader.
//   https://learn.microsoft.com/openspecs/exchange_server_protocols/ms-oxrtfcp
//   https://learn.microsoft.com/openspecs/exchange_server_protocols/ms-oxrtfex

public enum RTFBody {
    /// RTF (compressed or not) → HTML. HTML-encapsulated RTF is de-encapsulated; plain RTF goes through AppKit.
    public static func html(from data: Data) -> String {
        let rtf = decompressIfNeeded(data)
        if let s = String(data: rtf.prefix(4096), encoding: .isoLatin1), s.contains("\\fromhtml") {
            if let html = deEncapsulateHTML(rtf), !html.isEmpty { return html }
        }
        return appKitHTML(rtf) ?? ProtectedBodyFormat.html(fromText: plainText(rtf))
    }

    // MARK: MS-OXRTFCP

    static let prebuf = Array((
        "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript " +
        "\\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par " +
        "\\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx").utf8)

    /// Compressed RTF ("LZFu") → raw RTF; "MELA" (uncompressed wrapper) → payload; anything else unchanged.
    public static func decompressIfNeeded(_ d: Data) -> Data {
        let b = [UInt8](d)
        guard b.count >= 16 else { return d }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        let rawSize = u32(4), type = u32(8)
        if type == 0x414c_454d {   // "MELA"
            return Data(b[16..<min(b.count, 16 + rawSize)])
        }
        guard type == 0x7546_5a4c else { return d }   // "LZFu"
        var dict = [UInt8](repeating: 0, count: 4096)
        for (i, c) in prebuf.enumerated() { dict[i] = c }
        var wp = prebuf.count
        var out: [UInt8] = []
        out.reserveCapacity(rawSize)
        var i = 16
        outer: while i < b.count {
            let control = b[i]; i += 1
            for bit in 0..<8 {
                guard i < b.count else { break outer }
                if control & (1 << bit) == 0 {
                    let c = b[i]; i += 1
                    out.append(c); dict[wp] = c; wp = (wp + 1) & 0xFFF
                } else {
                    guard i + 1 < b.count else { break outer }
                    let word = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                    let offset = word >> 4, length = (word & 0xF) + 2
                    if offset == wp { break outer }
                    for k in 0..<length {
                        let c = dict[(offset + k) & 0xFFF]
                        out.append(c); dict[wp] = c; wp = (wp + 1) & 0xFFF
                    }
                }
            }
        }
        if out.count > rawSize { out.removeLast(out.count - rawSize) }
        return Data(out)
    }

    // MARK: MS-OXRTFEX

    /// Rebuild the original HTML from HTML-encapsulated RTF. nil when it isn't encapsulated.
    public static func deEncapsulateHTML(_ rtf: Data) -> String? {
        let b = [UInt8](rtf)
        var pendingBytes: [UInt8] = []   // \'hh bytes, decoded with the codepage at flush
        var outText = ""
        var encoding = String.Encoding.windowsCP1252

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            outText += String(data: Data(pendingBytes), encoding: encoding) ?? String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll()
        }
        func emit(_ s: String) { flushBytes(); outText += s }
        func emitByte(_ c: UInt8) { pendingBytes.append(c) }

        struct Group { var skip: Bool; var htmltag: Bool; var htmlrtf: Bool; var uc: Int }
        var stack: [Group] = [Group(skip: false, htmltag: false, htmlrtf: false, uc: 1)]
        var sawFromHTML = false
        var skipChars = 0
        var i = 0
        // A destination group is skipped unless it's \*\htmltag (content) — fonttbl, colortbl, stylesheet, etc.
        let skippedDestinations: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
                                                "header", "footer", "listtable", "listoverridetable", "rsidtbl",
                                                "generator", "xmlnstbl", "latentstyles", "themedata", "datastore"]
        var groupStart = false
        var starDest = false

        func visible() -> Bool {
            guard let g = stack.last else { return false }
            if g.skip { return false }
            if g.htmltag { return true }
            return !g.htmlrtf
        }

        while i < b.count {
            let c = b[i]
            if skipChars > 0, c != UInt8(ascii: "{"), c != UInt8(ascii: "}") {
                // \ucN fallback characters after \uN: skip one char (or one \'hh) each.
                if c == UInt8(ascii: "\\"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "'") { i += 4 } else { i += 1 }
                skipChars -= 1
                continue
            }
            switch c {
            case UInt8(ascii: "{"):
                var g = stack.last ?? Group(skip: false, htmltag: false, htmlrtf: false, uc: 1)
                g.htmltag = false   // set by \htmltag inside the group
                stack.append(g); groupStart = true; starDest = false; i += 1
            case UInt8(ascii: "}"):
                if stack.count > 1 { stack.removeLast() }
                groupStart = false; starDest = false; i += 1
            case UInt8(ascii: "\\"):
                guard i + 1 < b.count else { i += 1; break }
                let n = b[i + 1]
                if n == UInt8(ascii: "'") , i + 3 < b.count {
                    let hex = String(bytes: b[(i + 2)...(i + 3)], encoding: .ascii) ?? ""
                    if visible(), let v = UInt8(hex, radix: 16) { emitByte(v) }
                    i += 4; groupStart = false; continue
                }
                if n == UInt8(ascii: "*") { starDest = groupStart; i += 2; continue }
                if !((n >= 65 && n <= 90) || (n >= 97 && n <= 122)) {
                    // Control symbol: \{ \} \\ literal; \~ nbsp; others ignored.
                    if visible() {
                        switch n {
                        case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\\"): emit(String(UnicodeScalar(n)))
                        case UInt8(ascii: "~"): emit("\u{00A0}")
                        default: break
                        }
                    }
                    i += 2; groupStart = false; continue
                }
                // Control word.
                var j = i + 1
                while j < b.count, (b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122) { j += 1 }
                let word = String(bytes: b[(i + 1)..<j], encoding: .ascii) ?? ""
                var k = j, neg = false
                if k < b.count, b[k] == UInt8(ascii: "-") { neg = true; k += 1 }
                let ds = k
                while k < b.count, b[k] >= 48, b[k] <= 57 { k += 1 }
                let param: Int? = k > ds ? (Int(String(bytes: b[ds..<k], encoding: .ascii) ?? "")).map { neg ? -$0 : $0 } : nil
                if k < b.count, b[k] == UInt8(ascii: " ") { k += 1 }
                i = k
                let first = groupStart; groupStart = false
                switch word {
                case "fromhtml": sawFromHTML = true
                case "ansicpg":
                    if let p = param {
                        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(p))
                        if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
                    }
                case "htmltag":
                    if first || starDest { stack[stack.count - 1].htmltag = true; stack[stack.count - 1].skip = false }
                case "mhtmltag":
                    stack[stack.count - 1].skip = true   // duplicate of htmltag with rewritten URLs
                case "htmlrtf":
                    stack[stack.count - 1].htmlrtf = (param ?? 1) != 0
                case "par", "line": if visible() { emit("\r\n") }
                case "tab": if visible() { emit("\t") }
                case "uc": stack[stack.count - 1].uc = param ?? 1
                case "u":
                    if visible(), var v = param {
                        if v < 0 { v += 65536 }
                        if let sc = UnicodeScalar(UInt32(v)) { emit(String(sc)) }
                    }
                    skipChars = stack.last?.uc ?? 1
                default:
                    if first, skippedDestinations.contains(word) || (starDest && word != "htmltag") {
                        stack[stack.count - 1].skip = true
                    }
                }
                starDest = false
            case 13, 10:
                i += 1   // raw newlines are formatting in RTF
            default:
                if visible() { emitByte(c) }
                groupStart = false
                i += 1
            }
        }
        flushBytes()
        return sawFromHTML ? outText : nil
    }

    // MARK: Plain RTF

    static func appKitHTML(_ rtf: Data) -> String? {
        guard let a = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil),
              let h = try? a.data(from: NSRange(location: 0, length: a.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return nil }
        return String(data: h, encoding: .utf8)
    }

    static func plainText(_ rtf: Data) -> String {
        (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                 documentAttributes: nil))?.string ?? ""
    }
}
