import Foundation

// MARK: - Per-item licence rights (MIP SDK), the production `ItemRightsProvider`

extension UsageRights {
    /// Maps the rights list of an item's use licence (MIP `ProtectionHandler::GetRights()`, RMS names such as
    /// `VIEW`, `EXTRACT`, `REPLYALL`) to `UsageRights`. Unlike `parse`, an empty or unrecognised list yields an
    /// explicit EMPTY set, never nil: a licence that grants nothing we understand must not fall back to the label's
    /// (possibly broader) Graph rights. `AUDITEDEXTRACT` is deliberately ignored: it is not EXTRACT, it means "extract
    /// with an audit prompt" and we have no audited-extract UX (names: https://learn.microsoft.com/purview/rights-management-usage-rights#usage-rights-and-descriptions).
    /// OWNER expands to every right.
    public static func fromLicence(_ rights: [String]) -> UsageRights {
        let map = Dictionary(encodings.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        var r: UsageRights = []
        for raw in rights.flatMap({ $0.split(separator: ",") }) {
            let t = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if let right = map[t] { r.insert(right) }
        }
        return r.normalized
    }
}

/// In-memory store of per-item licence rights, filled by the MIP decrypt path (`ProtectedContent`) and read
/// synchronously by `CachedLabelPolicyEngine` via `ItemRightsProvider`. Never persisted: licence rights are
/// re-established each session by decrypting again (BYOD threat model, docs/MIP.md).
///
/// Wire it in once: `CachedLabelPolicyEngine(labels:…, itemRights: LicenceRightsStore.shared)`.
public final class LicenceRightsStore: ItemRightsProvider, @unchecked Sendable {
    public static let shared = LicenceRightsStore()

    private let lock = NSLock()
    private var byItem: [String: UsageRights] = [:]
    /// Bounded so a long session over a huge mailbox can't grow without limit; oldest entries are dropped first.
    public let capacity: Int
    private var order: [String] = []

    public init(capacity: Int = 5_000) { self.capacity = max(1, capacity) }

    /// nil = never decrypted in this session (fall through to label rights). A stored empty set stays empty.
    public func rights(itemId: String, labelId: String?) -> UsageRights? {
        lock.lock(); defer { lock.unlock() }
        return byItem[itemId]
    }

    public func set(_ rights: UsageRights, for itemId: String) {
        lock.lock(); defer { lock.unlock() }
        if byItem.updateValue(rights, forKey: itemId) == nil {
            order.append(itemId)
            if order.count > capacity { byItem.removeValue(forKey: order.removeFirst()) }
        }
    }

    public func remove(_ itemId: String) {
        lock.lock(); defer { lock.unlock() }
        byItem.removeValue(forKey: itemId)
        order.removeAll { $0 == itemId }
    }

    /// Sign-out / wipe.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byItem.removeAll(); order.removeAll()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return byItem.count }
}
