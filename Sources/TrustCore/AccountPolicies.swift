import Foundation

// MARK: - Per-account trust policies (docs/ACCOUNTS.md A1–A6)
//
// Policies are per account (owner decision, 2026-11-20): each account's device-trust policy, AI access, capture,
// copy-out and offline storage apply only to that account's content. Keyed by the account id string so TrustCore
// stays free of CalendarCore. The only cross-account combination is a window-level setting that can hold one value
// (NSWindow.sharingType): most restrictive across the accounts *visible in that window* (A4).

public struct AccountPolicies: Sendable, Equatable {
    public private(set) var byAccount: [String: TrustPolicy]
    /// Applied to an account without a policy of its own yet (e.g. just added, tenant policy not loaded): the device
    /// default, never something looser.
    public var fallback: TrustPolicy

    public init(_ byAccount: [String: TrustPolicy] = [:], fallback: TrustPolicy = .byodDefault) {
        self.byAccount = byAccount; self.fallback = fallback
    }

    public mutating func set(_ p: TrustPolicy, for account: String) { byAccount[account] = p }
    public mutating func remove(_ account: String) { byAccount[account] = nil }

    /// The policy that governs one account's content (reader, composer, single-account window, its AI requests).
    public func policy(for account: String?) -> TrustPolicy {
        account.flatMap { byAccount[$0] } ?? fallback
    }

    /// Mixed surfaces (All Inboxes, unified search, notifications): a row is shielded when *its own* account blocks
    /// capture. Other accounts' rows are unaffected (A3).
    public func rowShielded(account: String?) -> Bool { !policy(for: account).allowScreenCapture }

    /// Copy-out of one item follows its own account (a multi-selection is allowed only if every item's account allows).
    public func allowsCopyOut(accounts: [String?]) -> Bool { accounts.allSatisfy { policy(for: $0).allowCopyOut } }

    /// Window-level capture (NSWindow.sharingType): only one value per window, so the most restrictive among the
    /// accounts currently visible in it. An empty window follows the fallback (A4).
    public func windowAllowsCapture(visible: Set<String>) -> Bool {
        visible.isEmpty ? fallback.allowScreenCapture : visible.allSatisfy { policy(for: $0).allowScreenCapture }
    }

    /// AI tier for a request built from one account's content (A5). Never combined across accounts.
    public func aiAccess(for account: String?) -> TrustAIAccess { policy(for: account).aiAccess }
}
