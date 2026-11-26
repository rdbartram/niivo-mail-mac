import Foundation
import CalendarCore

// MARK: - Mail across accounts (docs/ACCOUNTS.md A3, A5, A7)

/// Something that belongs to one account: a message row, a search hit, a notification, an AI context item.
public struct AccountTagged<Value: Sendable>: Sendable {
    public var accountId: String
    public var value: Value
    public init(accountId: String, value: Value) { self.accountId = accountId; self.value = value }
}

extension AccountTagged: Equatable where Value: Equatable {}

// MARK: Forwarding / replying from another tenant's account (A7)

public enum CrossAccountForward {
    public enum Verdict: Equatable, Sendable {
        /// Same tenant, or nothing labelled: no prompt.
        case allow
        /// Labelled without protection: allowed only after the user confirms this warning.
        case confirm(warning: String)
        /// Encrypted, or a label we can't resolve (fail closed): never.
        case block(reason: String)
    }

    /// Content that is encrypted: an rpmsg wrapper, or a foreign label whose metadata says it encrypts.
    public static func isEncrypted(_ m: MailMessage) -> Bool {
        m.labelOrigin == .foreignProtected
            || m.attachments.contains { $0.name.lowercased().hasSuffix(".rpmsg") || $0.contentType.lowercased().contains("rpmsg") }
    }

    /// - Parameters:
    ///   - original: the message being forwarded / replied to (owned by `sourceAccount`).
    ///   - sourceTree: the source account's own label tree (labels are only ever resolved in their own tenant).
    ///   - sending: the account whose identity sends the draft.
    ///   - encrypted: extra signal from the protected-content path (decrypted body / licence present).
    public static func evaluate(original: MailMessage, sourceAccount: Account, sourceTree: LabelTree,
                                sending: Account, encrypted: Bool = false) -> Verdict {
        let enc = encrypted || isEncrypted(original)
        if sourceAccount.id == sending.id || sourceAccount.sameTenant(as: sending) {
            return .allow   // same organisation: the existing label floor (MailLabelFloor) applies as usual
        }
        if enc {
            return .block(reason: "This message is encrypted by \(sourceAccount.title)'s organisation. It can't be sent "
                          + "from \(sending.title), which belongs to another organisation.")
        }
        guard let id = original.labelId?.lowercased(), !id.isEmpty else { return .allow }
        guard let label = sourceTree.label(id) else {
            return .block(reason: "This message has a sensitivity label that can't be checked (labels not synced for "
                          + "\(sourceAccount.title)). It can't be sent from another organisation's account.")
        }
        if label.hasProtection {
            return .block(reason: "“\(label.name)” protects this message. It can't be sent from \(sending.title), "
                          + "which belongs to another organisation.")
        }
        return .confirm(warning: "This message is labelled “\(label.name)” by \(sourceAccount.title)'s organisation. "
                        + "Sending it from \(sending.title) takes it outside that organisation, and the label won't "
                        + "be applied there. Send anyway?")
    }
}

// MARK: Reply From default

public enum AccountIdentityDefault {
    /// The reply's From: the account that received the message, first an identity matching one of its recipients,
    /// otherwise that account's primary identity. Never another account's identity.
    public static func replyIdentity(receivedBy account: String, message: MailMessage,
                                     identities: [AccountTagged<SendIdentity>]) -> AccountTagged<SendIdentity>? {
        let mine = identities.filter { $0.accountId == account }
        let recipients = Set((message.toRecipients + message.ccRecipients).map { $0.address.lowercased() })
        return mine.first { recipients.contains($0.value.address.lowercased()) } ?? mine.first
    }
}

// MARK: AI context per account (A5)

public enum AIContextScope {
    /// Keeps only items of the request's own account, and only if that account's AI tier isn't `.off`.
    /// Never returns another account's content, whatever the other account's policy says.
    public static func filter<V>(_ items: [AccountTagged<V>], for account: String,
                                 aiAllowed: (String) -> Bool) -> [AccountTagged<V>] {
        guard aiAllowed(account) else { return [] }
        return items.filter { $0.accountId == account }
    }
}

// MARK: Mixed lists (A3)

public enum UnifiedRows {
    /// Per-row shielding on a mixed surface: each row is judged by its own account's rule only.
    public static func shielded<V>(_ rows: [AccountTagged<V>], isShielded: (String) -> Bool) -> [(row: AccountTagged<V>, shielded: Bool)] {
        rows.map { ($0, isShielded($0.accountId)) }
    }

    /// Merges per-account result lists (each already filtered by its own policy) by date, newest first. The merge never
    /// changes a row's account tag.
    public static func merge(_ perAccount: [String: [MailMessage]]) -> [AccountTagged<MailMessage>] {
        perAccount.flatMap { acc, msgs in msgs.map { AccountTagged(accountId: acc, value: $0) } }
            .sorted { ($0.value.received, $0.accountId) > ($1.value.received, $1.accountId) }
    }
}

// MARK: Store isolation (ACCOUNTS.md §2)

/// One encrypted `MailStore` per account. Writes name their account and land only in that account's store; an
/// unknown account is an error, never a fallback to another store.
public final class AccountStores: @unchecked Sendable {
    public enum StoreError: Error, Equatable { case unknownAccount(String) }
    private let lock = NSLock()
    private var stores: [String: MailStore] = [:]

    public init() {}

    public func attach(_ store: MailStore, for account: String) { lock.withLock { stores[account] = store } }
    @discardableResult public func detach(_ account: String) -> MailStore? { lock.withLock { stores.removeValue(forKey: account) } }
    public var accounts: [String] { lock.withLock { Array(stores.keys) } }

    public func store(for account: String) throws -> MailStore {
        guard let s = lock.withLock({ stores[account] }) else { throw StoreError.unknownAccount(account) }
        return s
    }

    public func upsert(_ messages: [MailMessage], account: String) throws {
        try store(for: account).upsert(messages: messages)
    }
}
