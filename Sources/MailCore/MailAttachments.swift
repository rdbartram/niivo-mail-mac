import Foundation
import CalendarCore

// Attachments in the reader: inline `cid:` images resolved in memory, plus the rights decision for open / save /
// drag / open-in. Nothing here touches the disk; the app layer owns the (app-private, short-lived) temp files.

// MARK: - Service

/// One attachment's bytes, fetched on demand and held in memory only.
public struct AttachmentContent: Sendable, Hashable {
    public var id: String
    public var name: String
    public var contentType: String
    /// `fileAttachment.contentId` (the `cid:` an HTML body refers to), if any.
    public var contentId: String?
    public var isInline: Bool
    public var data: Data
    public init(id: String, name: String, contentType: String, contentId: String?, isInline: Bool, data: Data) {
        self.id = id; self.name = name; self.contentType = contentType; self.contentId = contentId
        self.isInline = isInline; self.data = data
    }
}

/// Separate from `MailService` so existing services and stubs don't have to change. Graph and fixtures conform.
public protocol MailAttachmentFetching: Sendable {
    /// Single attachment incl. `contentId` + `contentBytes` (for inline images; small by construction).
    func inlineAttachment(messageId: String, attachmentId: String, mailbox: String) async throws -> AttachmentContent
    /// Raw bytes (`/$value`) for opening or saving a file attachment.
    func attachmentBytes(messageId: String, attachmentId: String, mailbox: String) async throws -> Data
}

// MARK: - Inline images (cid:)

public enum InlineImages {
    /// Caps: one image, all images of one message, number of fetches per message.
    public static let maxPartBytes = 5 * 1024 * 1024
    public static let maxTotalBytes = 20 * 1024 * 1024
    public static let maxParts = 40

    public struct Part: Sendable, Hashable {
        public var contentType: String
        public var data: Data
        public init(contentType: String, data: Data) { self.contentType = contentType; self.data = data }
    }

    /// `cid:` → bare id: drops the scheme and `<>`, percent-decodes, trims, lower-cases.
    public static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cid:") { s = String(s.dropFirst(4)) }
        s = s.removingPercentEncoding ?? s
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let imgRe = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    private static let srcRe = try! NSRegularExpression(pattern: "(\\ssrc\\s*=\\s*)([\"']?)\\s*cid:([^\"'\\s>]*)\\2",
                                                        options: [.caseInsensitive])

    /// Content ids referenced by `<img src="cid:…">` (normalised).
    public static func referencedIds(in html: String) -> Set<String> {
        var out = Set<String>()
        let ns = html as NSString
        for m in imgRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let tns = tag as NSString
            for h in srcRe.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                out.insert(normalise(tns.substring(with: h.range(at: 3))))
            }
        }
        return out
    }

    /// Which attachments to fetch for a body: none unless it refers to `cid:` images; then inline ones and images,
    /// each within the per-part cap, within the total and count caps (declared size; real bytes re-checked later).
    public static func candidates(_ attachments: [AttachmentInfo], html: String) -> [AttachmentInfo] {
        guard !referencedIds(in: html).isEmpty else { return [] }
        var total = 0
        var out: [AttachmentInfo] = []
        let ordered = attachments.filter(\.isInline) + attachments.filter { !$0.isInline && isImage($0.contentType) }
        for a in ordered where a.size <= maxPartBytes && out.count < maxParts {
            guard total + a.size <= maxTotalBytes else { continue }
            total += a.size
            out.append(a)
        }
        return out
    }

    /// Raster image types only (SVG can carry its own references, so it stays unresolved).
    public static func isImage(_ contentType: String) -> Bool {
        let t = contentType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return ["image/png", "image/jpeg", "image/jpg", "image/pjpeg", "image/gif", "image/bmp", "image/webp", "image/tiff",
                "image/heic", "image/x-icon", "image/vnd.microsoft.icon"].contains(t)
    }

    /// Builds the cid → part map from fetched contents, enforcing the caps on the real byte counts.
    public static func parts(from contents: [AttachmentContent]) -> [String: Part] {
        var out: [String: Part] = [:]
        var total = 0
        for c in contents {
            guard isImage(c.contentType), c.data.count <= maxPartBytes, total + c.data.count <= maxTotalBytes else { continue }
            let keys = [c.contentId.map(normalise), normalise(c.name)].compactMap { $0 }.filter { !$0.isEmpty }
            guard !keys.isEmpty else { continue }
            total += c.data.count
            for k in keys where out[k] == nil { out[k] = Part(contentType: c.contentType, data: c.data) }
        }
        return out
    }

    /// Rewrites `<img src="cid:…">` to `data:` URLs for parts we hold. Run on sanitised HTML; unknown ids stay as they
    /// are (the web view can't resolve them, so nothing loads).
    public static func rewrite(_ html: String, parts: [String: Part]) -> (html: String, resolved: Int, unresolved: Int) {
        guard !parts.isEmpty || html.range(of: "cid:", options: .caseInsensitive) != nil else { return (html, 0, 0) }
        var resolved = 0, unresolved = 0
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in imgRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tag = ns.substring(with: m.range)
            let tns = tag as NSString
            var t = ""
            var tl = 0
            for h in srcRe.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                t += tns.substring(with: NSRange(location: tl, length: h.range.location - tl))
                let id = normalise(tns.substring(with: h.range(at: 3)))
                if let p = parts[id], isImage(p.contentType) {
                    let type = p.contentType.split(separator: ";").first.map(String.init) ?? p.contentType
                    t += tns.substring(with: h.range(at: 1)) + "\"data:\(type.lowercased());base64,\(p.data.base64EncodedString())\""
                    resolved += 1
                } else {
                    t += tns.substring(with: h.range)
                    unresolved += 1
                }
                tl = h.range.location + h.range.length
            }
            t += tns.substring(from: tl)
            out += t
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, resolved, unresolved)
    }
}

// MARK: - Rights for attachment actions

public enum AttachmentAction: Sendable, Hashable {
    case preview, save, drag
    case openIn(bundleId: String)
}

/// The device side of the decision (from TrustCore's `TrustPolicy`; MailCore doesn't import TrustCore).
public struct AttachmentDeviceRules: Sendable, Hashable {
    public var allowDownload: Bool
    public var allowCopyOut: Bool
    public var allowPrint: Bool
    /// Empty = no app.
    public var approvedOpenIn: [String]
    public init(allowDownload: Bool, allowCopyOut: Bool, allowPrint: Bool, approvedOpenIn: [String]) {
        self.allowDownload = allowDownload; self.allowCopyOut = allowCopyOut; self.allowPrint = allowPrint
        self.approvedOpenIn = approvedOpenIn
    }
}

/// One gate for every attachment action. Returns nil when allowed, else the reason shown to the user.
/// * private-redacted, unknown label, encrypted message → nothing (attachments of protected mail are encrypted too);
/// * device policy `allowAttachmentsDownload` → nothing at all without it;
/// * label EXTRACT → required for every action (the preview can select and copy text);
/// * a file that leaves the app (save, drag, open in another app) also needs device copy-out and PRINT (label and
///   device), because the app can't enforce either once the file is outside;
/// * open in: only apps on `approvedOpenInBundleIds`.
public enum AttachmentRights {
    public static func check(_ action: AttachmentAction, policy p: ContentPolicy, device d: AttachmentDeviceRules) -> String? {
        if p.redactDetails { return "Marked private by the owner" }
        if case .unknown = p.labelState { return "This message's label isn't in your synced policy" }
        if p.bodyIsProtected { return "Attachments of encrypted mail can't be opened here yet. Use Outlook on the web" }
        if !d.allowDownload { return "Downloading attachments is blocked by this Mac's trust policy" }
        if !p.allowCopy { return "The sensitivity label doesn't allow extracting content (EXTRACT)" }
        switch action {
        case .preview: return nil
        case .save, .drag, .openIn:
            if !d.allowCopyOut { return "Copying files out of the app is blocked by this Mac's trust policy" }
            if !p.allowPrint { return "The sensitivity label doesn't allow printing (PRINT), so the file can't leave the app" }
            if !d.allowPrint { return "Printing is blocked by this Mac's trust policy, so the file can't leave the app" }
        }
        if case .openIn(let b) = action, !d.approvedOpenIn.contains(where: { $0.caseInsensitiveCompare(b) == .orderedSame }) {
            return "This app isn't approved for attachments on this Mac"
        }
        return nil
    }
}

// MARK: - File names

public enum AttachmentFiles {
    /// The attachment name is sender-controlled: keep the last path component only, drop control characters,
    /// separators and leading dots, cap the length (keeping the extension).
    public static func safeName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        s = s.split(separator: "/").last.map(String.init) ?? ""
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "attachment" }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            let stem = (s as NSString).deletingPathExtension
            s = String(stem.prefix(ext.isEmpty ? 120 : max(1, 119 - ext.count))) + (ext.isEmpty ? "" : "." + ext.prefix(16))
        }
        return s
    }
}

public extension AttachmentFiles {
    /// COMPOSE2 "Save All": safe, unique file names for a folder (case-insensitive like APFS by default): "a.pdf",
    /// "a 2.pdf", … skipping names already in the folder. Order is kept.
    static func uniqueNames(_ raw: [String], existing: Set<String> = []) -> [String] {
        var taken = Set(existing.map { $0.lowercased() })
        return raw.map { r in
            let safe = safeName(r)
            let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            var name = safe, n = 2
            while taken.contains(name.lowercased()) {
                name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(name.lowercased())
            return name
        }
    }
}
