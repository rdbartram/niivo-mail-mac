import Foundation

/// An image inside a signature, sent as an inline attachment (`cid:`).
public struct SignatureImage: Codable, Sendable, Hashable {
    public var cid: String
    public var name: String
    public var contentType: String
    public var data: Data
    public init(cid: String, name: String, contentType: String, data: Data) {
        self.cid = cid; self.name = name; self.contentType = contentType; self.data = data
    }
}

/// A rich signature. Graph has no roaming-signature API, so they live locally (sealed in the MailStore kv).
public struct MailSignature: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Email-safe HTML from RichHTML (same editor as the composer).
    public var html: String
    public var images: [SignatureImage]
    public init(id: UUID = UUID(), name: String, html: String, images: [SignatureImage] = []) {
        self.id = id; self.name = name; self.html = html; self.images = images
    }
    public var doc: RichDoc { RichHTML.parse(RichHTML.split(html).editable).doc }
    /// Fresh inline attachments for one insertion (same cids as the HTML).
    public var inlineAttachments: [OutgoingAttachment] {
        images.map { OutgoingAttachment(name: $0.name, contentType: $0.contentType, data: $0.data, isInline: true, contentId: $0.cid) }
    }
}

/// Composer preferences: signatures + defaults per identity, live Markdown. Separate sealed key (not MailSettings,
/// whose decode-failure fallback would reset identities if the schema moved).
public struct ComposerPreferences: Codable, Sendable, Hashable {
    public static let storeKey = "composer.preferences"
    /// Key for "any identity" in the default maps.
    public static let anyIdentity = "*"

    public var signatures: [MailSignature] = []
    /// Identity address (lowercased) or `anyIdentity` → signature for new mail.
    public var newMailDefaults: [String: UUID] = [:]
    /// Same for replies and forwards.
    public var replyDefaults: [String: UUID] = [:]
    public var liveMarkdown = true
    /// COMPOSE2: R / ⌘R (the default reply) replies to all. Explicit Reply / Reply All buttons are unchanged.
    public var defaultReplyAll = false
    /// COMPOSE2: what a reply / forward carries below the user's text.
    public var replyHistory: ReplyHistory = .include
    public enum ReplyHistory: String, Codable, Sendable, CaseIterable { case include, omit }
    /// Per-identity default meaning "no signature" (overrides the any-identity default).
    public static let noSignature = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public init(signatures: [MailSignature] = [], newMailDefaults: [String: UUID] = [:], replyDefaults: [String: UUID] = [:],
                liveMarkdown: Bool = true) {
        self.signatures = signatures; self.newMailDefaults = newMailDefaults; self.replyDefaults = replyDefaults
        self.liveMarkdown = liveMarkdown
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        signatures = try c.decodeIfPresent([MailSignature].self, forKey: .signatures) ?? []
        newMailDefaults = try c.decodeIfPresent([String: UUID].self, forKey: .newMailDefaults) ?? [:]
        replyDefaults = try c.decodeIfPresent([String: UUID].self, forKey: .replyDefaults) ?? [:]
        liveMarkdown = try c.decodeIfPresent(Bool.self, forKey: .liveMarkdown) ?? true
        defaultReplyAll = try c.decodeIfPresent(Bool.self, forKey: .defaultReplyAll) ?? false
        replyHistory = (try? c.decodeIfPresent(ReplyHistory.self, forKey: .replyHistory)) ?? .include
    }

    public func signature(id: UUID?) -> MailSignature? { id.flatMap { i in signatures.first { $0.id == i } } }

    /// Default for this identity (nil address = own mailbox), falling back to the "any identity" default.
    public func defaultSignature(identity address: String?, reply: Bool) -> MailSignature? {
        let map = reply ? replyDefaults : newMailDefaults
        let key = address?.lowercased() ?? Self.anyIdentity
        if map[key] == Self.noSignature { return nil }   // explicitly none for this identity
        return signature(id: map[key]) ?? signature(id: map[Self.anyIdentity])
    }

    public mutating func remove(_ id: UUID) {
        signatures.removeAll { $0.id == id }
        newMailDefaults = newMailDefaults.filter { $0.value != id }
        replyDefaults = replyDefaults.filter { $0.value != id }
    }
}

public extension MailStore {
    func composerPreferences() -> ComposerPreferences { sealed(ComposerPreferences.self, for: ComposerPreferences.storeKey) ?? ComposerPreferences() }
    func save(composerPreferences p: ComposerPreferences) throws { try setSealed(p, for: ComposerPreferences.storeKey) }
}
