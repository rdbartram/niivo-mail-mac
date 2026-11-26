import Foundation
import CalendarCore

// Inline attachment previews in the reader: which renderer a file gets, whether (and when) its bytes may be fetched
// for a preview, and the bookkeeping of the short-lived files QuickLook needs. UI-free so CoreSelfTest covers it; the
// app layer (AttachmentPreviews.swift) renders and owns the lifecycle.

// MARK: - Type → renderer

public enum AttachmentPreviewKind: String, Sendable, Hashable, CaseIterable {
    /// NSImage from memory (raster only).
    case image
    /// PDFKit from memory.
    case pdf
    /// First lines as text, from memory.
    case text
    /// Office and other document formats: QLThumbnailGenerator / QLPreviewView, which need a file URL.
    case quickLook
    /// Icon only (executables, archives, HTML, SVG, protected containers, unknown types).
    case none

    /// Needs bytes on disk (QuickLook). Everything else renders from `Data`.
    public var needsFile: Bool { self == .quickLook }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "ico"]
    static let textExts: Set<String> = ["txt", "text", "csv", "tsv", "json", "md", "markdown", "log", "xml", "yaml", "yml", "ini", "conf"]
    static let quickLookExts: Set<String> = ["doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlsb", "ppt", "pptx",
                                             "pptm", "pps", "ppsx", "rtf", "odt", "ods", "odp", "pages", "numbers", "key", "vsdx"]
    /// Never previewed, whatever the content type says (active content, archives, protected containers).
    static let neverExts: Set<String> = ["rpmsg", "pfile", "ppdf", "ptxt", "pjpg", "ppng", "svg", "svgz", "html", "htm", "xhtml",
                                         "mht", "mhtml", "eml", "msg", "zip", "7z", "rar", "gz", "tar", "dmg", "pkg", "app",
                                         "exe", "msi", "bat", "cmd", "ps1", "sh", "command", "js", "vbs", "jar", "scpt", "lnk"]

    /// Extension first (sender-controlled content types are often `application/octet-stream`); then the content type.
    public static func kind(name: String, contentType: String) -> AttachmentPreviewKind {
        let ext = (AttachmentFiles.safeName(name) as NSString).pathExtension.lowercased()
        let ct = contentType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if neverExts.contains(ext) || ct.contains("svg") || ct.contains("html") || ct.hasSuffix("rpmsg") { return .none }
        if ext == "pdf" { return .pdf }
        if imageExts.contains(ext) { return .image }
        if textExts.contains(ext) { return .text }
        if quickLookExts.contains(ext) { return .quickLook }
        if !ext.isEmpty, ct == "application/octet-stream" || ct.isEmpty { return .none }
        if ct == "application/pdf" { return .pdf }
        if InlineImages.isImage(ct) { return .image }
        if ["text/plain", "text/csv", "text/tab-separated-values", "text/markdown", "application/json", "text/json",
            "application/xml", "text/xml"].contains(ct) { return .text }
        if ct.contains("officedocument") || ct.contains("msword") || ct.contains("ms-excel") || ct.contains("ms-powerpoint")
            || ct.contains("opendocument") || ct == "application/rtf" || ct == "text/rtf" { return .quickLook }
        return .none
    }
}

// MARK: - Setting

/// "Show attachment previews" + the size up to which previews load by themselves. Device-local (UserDefaults): it
/// holds no mail content.
public struct AttachmentPreviewSettings: Sendable, Hashable {
    public var enabled: Bool
    public var maxBytes: Int
    public static let defaultMaxMB = 20
    public static let choicesMB = [5, 10, 20, 50]
    /// Above this even "Load preview" isn't offered (memory: the bytes are held in RAM while the reader shows them).
    public static let hardCapBytes = 100 * 1024 * 1024

    public init(enabled: Bool = true, maxBytes: Int = defaultMaxMB * 1024 * 1024) {
        self.enabled = enabled; self.maxBytes = Self.clamp(maxBytes)
    }
    public static let `default` = AttachmentPreviewSettings()

    public var maxMB: Int {
        get { maxBytes / (1024 * 1024) }
        set { maxBytes = Self.clamp(newValue * 1024 * 1024) }
    }

    public static func clamp(_ bytes: Int) -> Int { min(hardCapBytes, max(1024 * 1024, bytes)) }

    static let enabledKey = "attachmentPreviews.enabled", maxKey = "attachmentPreviews.maxBytes"
    public static func load(_ d: UserDefaults = .standard) -> AttachmentPreviewSettings {
        AttachmentPreviewSettings(enabled: d.object(forKey: enabledKey) as? Bool ?? true,
                                  maxBytes: d.object(forKey: maxKey) as? Int ?? defaultMaxMB * 1024 * 1024)
    }
    public func save(_ d: UserDefaults = .standard) {
        d.set(enabled, forKey: Self.enabledKey); d.set(maxBytes, forKey: Self.maxKey)
    }
}

// MARK: - Gate

public enum AttachmentPreviewMode: Sendable, Hashable {
    /// Setting off: the plain chips only.
    case disabled
    /// Encrypted (rpmsg) mail: nothing is fetched here; the Purview in-memory path (`ProtectedAttachmentsSection`) shows it.
    case protectedPath
    /// Rights say no; the reason is shown.
    case blocked(String)
    /// No renderer for this type: icon, click keeps the existing open behaviour.
    case iconOnly
    /// Over the hard cap: icon only.
    case tooLarge
    /// Over the user's cap: "Load preview" button.
    case onDemand
    /// Fetched as soon as the reader shows the message.
    case automatic
}

public struct AttachmentPreviewDecision: Sendable, Hashable {
    public var kind: AttachmentPreviewKind
    public var mode: AttachmentPreviewMode
    /// A preview may be fetched (now or on request).
    public var mayFetch: Bool { mode == .automatic || mode == .onDemand }
}

public enum AttachmentPreviewGate {
    /// Shown for QuickLook formats when the label or device doesn't let bytes touch the disk.
    public static let notAllowedForLabel = "Preview not allowed for this label"

    /// One decision per attachment. Layered on `AttachmentRights.check(.preview…)` (private, unknown label, encrypted,
    /// device download switch, label EXTRACT), plus: QuickLook formats need a file, so they also need the label's
    /// offline permission (`allowOfflineDetails`) and the device download switch; sizes against the setting.
    public static func decide(_ a: AttachmentInfo, policy p: ContentPolicy, device d: AttachmentDeviceRules,
                              settings s: AttachmentPreviewSettings) -> AttachmentPreviewDecision {
        let kind = AttachmentPreviewKind.kind(name: a.name, contentType: a.contentType)
        func out(_ m: AttachmentPreviewMode) -> AttachmentPreviewDecision { AttachmentPreviewDecision(kind: kind, mode: m) }
        guard s.enabled else { return out(.disabled) }
        if p.redactDetails { return out(.blocked("Marked private by the owner")) }
        if case .unknown = p.labelState { return out(.blocked("This message's label isn't in your synced policy")) }
        if p.bodyIsProtected { return out(.protectedPath) }
        if let why = AttachmentRights.check(.preview, policy: p, device: d) { return out(.blocked(why)) }
        if kind == .none { return out(.iconOnly) }
        if kind.needsFile && !(p.allowOfflineDetails && d.allowDownload) { return out(.blocked(notAllowedForLabel)) }
        if a.size > AttachmentPreviewSettings.hardCapBytes { return out(.tooLarge) }
        if a.size > s.maxBytes { return out(.onDemand) }
        return out(.automatic)
    }

    /// What loads by itself for one message: automatic ones only, in order, within a total budget and count (declared
    /// sizes; real byte counts are re-checked after the fetch).
    public static let autoBudgetBytes = 60 * 1024 * 1024
    public static let autoMaxCount = 24
    public static func autoPlan(_ attachments: [AttachmentInfo], policy p: ContentPolicy, device d: AttachmentDeviceRules,
                                settings s: AttachmentPreviewSettings) -> [AttachmentInfo] {
        var total = 0
        var out: [AttachmentInfo] = []
        for a in attachments where !a.isInline && out.count < autoMaxCount {
            guard decide(a, policy: p, device: d, settings: s).mode == .automatic, total + a.size <= autoBudgetBytes else { continue }
            total += a.size
            out.append(a)
        }
        return out
    }

    /// Real bytes after the fetch: the declared size can lie.
    public static func acceptsFetched(_ count: Int, requested: AttachmentPreviewMode, settings s: AttachmentPreviewSettings) -> Bool {
        switch requested {
        case .automatic: return count <= s.maxBytes
        case .onDemand: return count <= AttachmentPreviewSettings.hardCapBytes
        default: return false
        }
    }
}

// MARK: - Text

public enum AttachmentPreviewText {
    /// First `lines` lines (each cut at `width`), from at most the first 16 KB. nil for binary (NUL in the sample).
    public static func firstLines(_ data: Data, lines: Int = 8, width: Int = 120) -> String? {
        let sample = data.prefix(16 * 1024)
        if sample.prefix(4096).contains(0) { return nil }
        var s = String(decoding: sample, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let out = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(lines)
            .map { $0.count > width ? String($0.prefix(width)) + "…" : String($0) }
        return out.joined(separator: "\n")
    }
}

// MARK: - Scratch files (QuickLook only)

/// Short-lived files for QuickLook (thumbnail generator / preview view need a URL). One session directory (0700)
/// under `root`; one sub-directory per item (0700) holding one file (0600, complete file protection, excluded from
/// backups). Keys are "messageId#attachmentId". Everything goes on collapse / reader change / lock / quit, and stale
/// sessions are swept at start. Not thread-safe: use from one actor (the app's main actor).
public final class PreviewScratch {
    public let root: URL
    public let session: URL
    public private(set) var files: [String: URL] = [:]

    public init(root: URL, sweep: Bool = true) {
        self.root = root
        if sweep { try? FileManager.default.removeItem(at: root) }
        session = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    public static func key(messageId: String, attachmentId: String) -> String { "\(messageId)#\(attachmentId)" }

    /// Writes (replacing an earlier file for the same key). The name is made safe; the file can't leave `session`.
    @discardableResult
    public func write(_ data: Data, name: String, key: String) throws -> URL {
        remove(key: key)
        let fm = FileManager.default
        for dir in [root, session] where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var r = root; try? r.setResourceValues(rv)
        let dir = session.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = dir.appending(path: AttachmentFiles.safeName(name))
        do {
            try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        files[key] = url
        return url
    }

    public func url(for key: String) -> URL? { files[key] }

    public func remove(key: String) {
        guard let u = files.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
    }

    /// Every file of one message.
    public func remove(messageId: String) {
        for k in files.keys where k.hasPrefix(messageId + "#") { remove(key: k) }
    }

    public func removeAll() {
        files = [:]
        try? FileManager.default.removeItem(at: session)
    }
}
