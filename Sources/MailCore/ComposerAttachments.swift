import Foundation
import CalendarCore

/// A file or inline image going out with a draft. The bytes are held in memory (max 150 MB) because the draft is
/// re-created on every save until draft PATCH lands (see MailModel.saveDraft), so attachments are re-attached each time.
public struct OutgoingAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var contentType: String
    public var data: Data
    public var isInline: Bool
    /// Inline images: referenced from the body as `<img src="cid:…">`.
    public var contentId: String?
    public var size: Int { data.count }
    public init(id: UUID = UUID(), name: String, contentType: String, data: Data, isInline: Bool = false, contentId: String? = nil) {
        self.id = id; self.name = name; self.contentType = contentType; self.data = data; self.isInline = isInline; self.contentId = contentId
    }
}

/// Size rules for Graph attachments (learn.microsoft.com "attach large files": < 3 MB → POST …/attachments,
/// 3–150 MB → createUploadSession + sequential PUTs).
public enum AttachmentUpload {
    public static let smallLimit = 3 * 1024 * 1024
    public static let maxSize = 150 * 1024 * 1024
    /// UNVERIFIED: chunk size. Docs ask for ≤ 4 MB per PUT; 320 KiB multiples are the OneDrive convention. 12 × 320 KiB.
    public static let chunkSize = 12 * 320 * 1024
    /// Small attachments embedded in the create POST stay under this combined size (Graph's 4 MB request limit,
    /// with base64 overhead).
    public static let embedBudget = 2 * 1024 * 1024

    public static func isSmall(_ a: OutgoingAttachment) -> Bool { a.size < smallLimit }

    public static func chunks(total: Int, chunk: Int = chunkSize) -> [Range<Int>] {
        guard total > 0 else { return [] }
        return stride(from: 0, to: total, by: chunk).map { $0..<min($0 + chunk, total) }
    }

    public static func contentRange(_ r: Range<Int>, total: Int) -> String { "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(total)" }

    /// Splits small attachments into those embedded in the create POST (within `embedBudget`) and the rest.
    public static func embeddable(_ list: [OutgoingAttachment]) -> [OutgoingAttachment] {
        var used = 0
        return list.filter { a in
            guard isSmall(a), used + a.size <= embedBudget else { return false }
            used += a.size; return true
        }
    }

    /// Reason a file can't be attached at all (size).
    public static func invalidReason(size: Int, name: String) -> String? {
        if size <= 0 { return "\(name) is empty." }
        if size > maxSize { return "\(name) is larger than 150 MB, the most Outlook accepts." }
        return nil
    }

    public static func mimeType(forExtension e: String) -> String {
        switch e.lowercased() {
        case "png": "image/png"; case "jpg", "jpeg": "image/jpeg"; case "gif": "image/gif"; case "heic": "image/heic"
        case "tif", "tiff": "image/tiff"; case "webp": "image/webp"; case "pdf": "application/pdf"; case "txt": "text/plain"
        case "csv": "text/csv"; case "zip": "application/zip"; case "ics": "text/calendar"; case "eml": "message/rfc822"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "doc": "application/msword"; case "xls": "application/vnd.ms-excel"; case "ppt": "application/vnd.ms-powerpoint"
        default: "application/octet-stream"
        }
    }

    public static func formattedSize(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// Composer gate for adding attachments / inline images. `TrustPolicy` has no upload switch (only
/// `allowAttachmentsDownload`, which governs opening received files and is not loosened or reused here), so this gate
/// works on the label: the draft's policy merged with the original's on reply/forward.
/// Fails closed when the label isn't in the synced policy, or when the label encrypts and its rights are unknown
/// (niivo can't apply protection to the files; the server would send them as-is).
public enum AttachmentGate {
    public static func blockReason(_ policy: ContentPolicy) -> String? {
        if case .unknown = policy.labelState {
            return "Attachments are blocked: this message's label isn't in the synced label policy yet."
        }
        if policy.rightsSource == .encryptedUnknown || policy.rightsSource == .unknownLabel {
            return "Attachments are blocked: the label encrypts this message and your rights on it aren't known."
        }
        return nil
    }
}

/// Upload progress, reported by the Graph client per attachment id, observed by the composer.
public final class AttachmentProgress: @unchecked Sendable {
    public static let shared = AttachmentProgress()
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (Int, Int) -> Void] = [:]
    public init() {}
    public func observe(_ id: UUID, _ f: @escaping @Sendable (_ sent: Int, _ total: Int) -> Void) { lock.withLock { handlers[id] = f } }
    public func stop(_ id: UUID) { lock.withLock { _ = handlers.removeValue(forKey: id) } }
    public func report(_ id: UUID, sent: Int, total: Int) { lock.withLock { handlers[id] }?(sent, total) }
}

public extension MailDraft {
    /// Files + inline images going out with this draft.
    var attachments: [OutgoingAttachment] {
        get { _attachments ?? [] }
        set { _attachments = newValue.isEmpty ? nil : newValue }
    }
}
