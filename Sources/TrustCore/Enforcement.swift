import Foundation

// MARK: - Session enforcement (the app's single entry point into SessionHealth)
//
// The app feeds every MSAL result on the calendar and mail token paths in here, asks `evaluate` what to do, and acts on
// the returned `TrustAction`. Everything is per account: account A's failures, strikes, grace clock and wipe-group
// result never affect account B. UI-free and injected (store, clock) so CoreSelfTest drives the exact code the app runs.

/// File/slot-safe account name. Same rule as `CalendarCore.AccountStoreNaming.safeName` (TrustCore can't import
/// CalendarCore; CoreSelfTest checks the two agree).
public enum TrustAccountNaming {
    public static func safeName(_ account: String) -> String {
        account.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
    }
}

/// Prefixes every key with the account, so the fixed keys of `OfflineGraceClock` / `RevocationGuard` become per account.
public struct AccountScopedTrustStore: TrustStateStore {
    public let base: TrustStateStore
    public let account: String
    public init(base: TrustStateStore, account: String) { self.base = base; self.account = account }
    var prefix: String { "acct.\(TrustAccountNaming.safeName(account))." }
    public func data(forKey key: String) -> Data? { base.data(forKey: prefix + key) }
    public func set(_ data: Data?, forKey key: String) { base.set(data, forKey: prefix + key) }
}

/// Who a wipe applies to. Every signal `SessionHealth` knows about today (revocation codes, wipe group, offline
/// deadline) belongs to one signed-in account, so it maps to `.account`. `.device` is reserved for device-level
/// triggers; none exists yet (posture blocks/restricts, managed preferences only shape the policy).
public enum WipeScope: Sendable, Equatable {
    case account(String)
    case device
}

/// What the app does with a `TrustDecision` for one account.
public enum TrustAction: Sendable, Equatable {
    case none
    /// Keep showing cached content, ask for sign-in (the existing "Sign-in required" state). Reason = `ReauthReason`.
    case reauthPrompt(String)
    /// Hide content, close the stores, and require a successful sign-in / refresh before anything is shown again.
    case lock(String)
    case wipe(scope: WipeScope, reason: String)
}

public enum TrustEnforcement {
    /// Reauth reasons that lock instead of prompting: the grant was revoked (50173/50133, which a password change also
    /// causes, so never a wipe) or a first unconfirmed revocation strike. Every other reauth reason (MFA, CA, consent,
    /// interaction required…) keeps today's prompt so a missing mail consent can't take the calendar down.
    public static let lockingReauth: Set<String> = [ReauthReason.grantRevoked.rawValue, ReauthReason.revocationUnconfirmed.rawValue]

    public static func action(for d: TrustDecision, account: String) -> TrustAction {
        switch d {
        case .ok, .restricted: return .none
        case .wipe(let r): return .wipe(scope: .account(account), reason: r)
        case .locked(let r):
            if r.hasPrefix("reauth:") {
                let why = String(r.dropFirst("reauth:".count))
                return lockingReauth.contains(why) ? .lock(r) : .reauthPrompt(why)
            }
            return .lock(r)
        }
    }
}

/// Per-account session state + the decision. Thread-safe; the app calls it from the main actor.
public final class SessionEnforcer: @unchecked Sendable {
    public let store: TrustStateStore
    public let now: TrustNow
    /// Two-strike interval on the silent path (`RevocationGuard`).
    public let minimumInterval: TimeInterval
    /// A success within this interval of the last recorded one (and with no error pending) isn't re-written to disk.
    public let successWriteInterval: TimeInterval
    private let lock = NSLock()
    private var lastError: [String: SessionErrorClass] = [:]
    private var groupMembers: [String: [String]] = [:]
    private var lastRecorded: [String: Date] = [:]
    static let knownKey = "trust.accounts.known"
    static let groupCheckKey = "trust.wipeGroup.lastCheck"

    public init(store: TrustStateStore, now: @escaping TrustNow = { Date() }, minimumInterval: TimeInterval = 60,
                successWriteInterval: TimeInterval = 300) {
        self.store = store; self.now = now; self.minimumInterval = minimumInterval
        self.successWriteInterval = successWriteInterval
    }

    public func accountStore(_ account: String) -> TrustStateStore { AccountScopedTrustStore(base: store, account: account) }
    public func clock(_ account: String) -> OfflineGraceClock { OfflineGraceClock(store: accountStore(account), now: now) }

    /// Accounts that refreshed successfully on this Mac at least once (identifiers only, no content).
    public var knownAccounts: [String] {
        lock.withLock { store.data(forKey: Self.knownKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
    }
    private func setKnown(_ ids: [String]) { store.set(try? JSONEncoder().encode(ids), forKey: Self.knownKey) }

    /// A token for this account was issued (calendar or mail set). Re-anchors the grace clock, remembers the tenant +
    /// client (misconfiguration guard) and clears any error / strike.
    public func recordSuccess(account: String, tenantId: String, clientId: String) {
        let t = now()
        let skip: Bool = lock.withLock {
            let pending = lastError[account] != nil
            if !pending, let last = lastRecorded[account], t.timeIntervalSince(last) < successWriteInterval, t >= last { return true }
            lastError[account] = nil
            lastRecorded[account] = t
            return false
        }
        if skip { return }
        clock(account).recordSuccessfulRefresh(tenantId: tenantId, clientId: clientId)
        lock.withLock {
            var k = (store.data(forKey: Self.knownKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
            if !k.contains(account) { k.append(account); setKnown(k) }
        }
    }

    /// Classifies a token failure through `RevocationGuard` (per account: guard, two strikes). A transient failure
    /// keeps the previous error; anything else replaces it.
    @discardableResult
    public func recordFailure(_ f: AuthFailure, path: AuthPath, account: String, tenantId: String, clientId: String) -> SessionErrorClass {
        let c = RevocationGuard(store: accountStore(account), now: now, minimumInterval: minimumInterval)
            .evaluate(f, path: path, tenantId: tenantId, clientId: clientId)
        if c != .transient { lock.withLock { lastError[account] = c; lastRecorded[account] = nil } }
        return c
    }

    public func lastError(account: String) -> SessionErrorClass? { lock.withLock { lastError[account] } }

    // MARK: Wipe group

    /// The wipe-group check is due: the policy sets a group and the last *successful* check is older than the cadence.
    public func isWipeGroupCheckDue(account: String, policy: TrustPolicy) -> Bool {
        guard let g = policy.wipeGroupId, !g.isEmpty else { return false }
        guard let d = accountStore(account).data(forKey: Self.groupCheckKey),
              let last = try? JSONDecoder().decode(Date.self, from: d) else { return true }
        let t = now()
        if t < last { return true }   // clock moved back: check again
        return t.timeIntervalSince(last) >= Double(policy.effectiveWipeGroupCheckMinutes) * 60
    }

    /// `returned` nil = the call failed: no decision, and not counted as a check (it is retried next tick).
    public func recordWipeGroupCheck(account: String, returned: [String]?) {
        guard let returned else { return }
        lock.withLock { groupMembers[account] = returned }
        accountStore(account).set(try? JSONEncoder().encode(now()), forKey: Self.groupCheckKey)
    }

    // MARK: Decision

    /// The decision for one account. Posture is deliberately not part of it: posture is device-level and the app shows
    /// a block as a banner (TrustModel), so it must not mask an account's grace / revocation state here.
    public func evaluate(account: String, policy: TrustPolicy, tombstoned: Bool) -> (decision: TrustDecision, action: TrustAction) {
        let (err, members) = lock.withLock { (lastError[account], groupMembers[account]) }
        let d = SessionHealth.decide(policy: policy, lastError: err, wipeGroupMembers: members,
                                     grace: clock(account).status(policy: policy), posture: .allow, tombstoned: tombstoned)
        return (d, TrustEnforcement.action(for: d, account: account))
    }

    /// After a wipe: the account's session state goes. The grace anchor is dropped (a wiped account needs a fresh
    /// sign-in, so `status` reports locked until then); the high-water mark and the "seen" tenant + client stay.
    public func forget(account: String) {
        lock.withLock {
            lastError[account] = nil; groupMembers[account] = nil; lastRecorded[account] = nil
            var k = (store.data(forKey: Self.knownKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
            k.removeAll { $0 == account }
            setKnown(k)
        }
        let s = accountStore(account)
        s.set(nil, forKey: OfflineGraceClock.lastKey)
        s.set(nil, forKey: RevocationGuard.strikeKey)
        s.set(nil, forKey: Self.groupCheckKey)
    }
}

// MARK: - Per-account wipe

/// Removes named vault slots: crypto-shreds one account's caches without touching the vault key or other slots.
public struct VaultSlotShredder: CryptoShredding {
    public let vault: EnclaveVault
    public let names: [String]
    public init(vault: EnclaveVault, names: [String]) { self.vault = vault; self.names = names }
    public func shred() throws { try vault.remove(names: names) }
}

/// Anything else destroyed before files go (e.g. the account's MSAL refresh token). Must be idempotent.
public struct ClosureShredder: CryptoShredding {
    public let body: @Sendable () throws -> Void
    public init(_ body: @escaping @Sendable () throws -> Void) { self.body = body }
    public func shred() throws { try body() }
}

/// Where one account's data and its tombstone live. Tombstones are in their own directory, outside every wiped path.
public struct AccountWipeLayout: Sendable {
    public let supportDirectory: URL
    public let tombstoneDirectory: URL
    public init(supportDirectory: URL, tombstoneDirectory: URL) {
        self.supportDirectory = supportDirectory; self.tombstoneDirectory = tombstoneDirectory
    }

    /// The account's vault slots (`CacheKeyring.slot`): one per purpose, never the registry's own slot.
    public static func vaultSlots(account: String) -> [String] {
        VaultPurpose.allCases.map { "\(TrustAccountNaming.safeName(account))/\($0.rawValue)" }
    }

    public func tombstoneURL(account: String) -> URL {
        tombstoneDirectory.appending(path: "\(TrustAccountNaming.safeName(account)).json")
    }

    public func isTombstoned(account: String) -> Bool { FileManager.default.fileExists(atPath: tombstoneURL(account: account).path) }

    /// Safe names of accounts with a tombstone (complete or not).
    public var tombstonedAccounts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tombstoneDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The executor for one account. `storeFileNames` are relative to the support directory (the caller passes
    /// `AccountStoreNaming.files(id)`); sidecars (-wal/-shm/-journal) go with them. Shred order: vault slots, then
    /// `extraShredders` (MSAL account), then files and keychain items.
    public func executor(account: String, storeFileNames: [String], cacheDirectories: [URL] = [],
                         keychainItems: [KeychainItemRef] = [], keychain: SecretDeleting = SystemKeychainDeleter(),
                         vault: EnclaveVault?, extraShredders: [CryptoShredding] = [],
                         now: @escaping TrustNow = { Date() }) throws -> DefaultWipeExecutor {
        var shredders: [CryptoShredding] = []
        if let vault { shredders.append(VaultSlotShredder(vault: vault, names: Self.vaultSlots(account: account))) }
        shredders += extraShredders
        return try DefaultWipeExecutor(cacheDirectories: cacheDirectories,
                                       storeFiles: storeFileNames.map { supportDirectory.appending(path: $0) },
                                       keychainItems: keychainItems, keychain: keychain, shredders: shredders,
                                       tombstoneURL: tombstoneURL(account: account), now: now)
    }
}

// MARK: - Signed tenant policy: where the bytes come from

/// There is no niivo server and no defined SharePoint location, so the signed policy document is delivered the two
/// ways an administrator already controls:
/// 1. **Managed preferences** (an MDM configuration profile for the app's bundle id): `tenantPolicyDocument` (the exact
///    JSON bytes as Data, or a String holding the JSON or its base64) and `tenantPolicySignature` (Data, or base64).
/// 2. **A file pair next to config.json**: `trust-policy.json` + `trust-policy.json.sig` (used when (1) is absent).
/// The verifying keys come only from a **forced** managed preference `tenantPolicyPinnedKeys` (["keyId:base64"]),
/// optionally bound to `tenantPolicyTenantId`. Without forced keys a document is rejected (`unknownKey`), so a user
/// can't pin their own key. Whatever the source, a verified document can only tighten (`PolicyLoader`).
/// Honest limit: on BYOD the user can delete the file pair, which falls back to the (strict) defaults; an MDM-delivered
/// document can't be removed by the user.
public enum TenantPolicySource {
    public static let documentKey = "tenantPolicyDocument"
    public static let signatureKey = "tenantPolicySignature"
    public static let pinnedKeysKey = "tenantPolicyPinnedKeys"
    public static let tenantKey = "tenantPolicyTenantId"
    public static let fileName = "trust-policy.json"
    public static let signatureFileName = "trust-policy.json.sig"
    static let maxVersionKey = "trust.policy.maxVersion"

    public struct Material: Sendable {
        public var json: Data?
        public var signature: Data?
        /// "managedPreferences", "file" or "none".
        public var origin: String
        public var pinned: PinnedPolicyKeys
    }

    static func bytes(_ v: Any?, jsonText: Bool) -> Data? {
        if let d = v as? Data { return d }
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText, t.hasPrefix("{") { return Data(s.utf8) }   // exact bytes as delivered (signature covers them)
        return Data(base64Encoded: t) ?? (jsonText ? nil : Data(t.utf8))
    }

    public static func read(prefs: ManagedPreferencesReading, directory: URL?) -> Material {
        let forcedKeys = prefs.isForced(key: pinnedKeysKey) ? (prefs.value(forKey: pinnedKeysKey) as? [String] ?? []) : []
        let tenant = prefs.isForced(key: tenantKey) ? prefs.value(forKey: tenantKey) as? String : nil
        let pinned = PinnedPolicyKeys(config: forcedKeys, tenantId: tenant)
        let pj = bytes(prefs.value(forKey: documentKey), jsonText: true)
        let ps = bytes(prefs.value(forKey: signatureKey), jsonText: false)
        if pj != nil || ps != nil { return Material(json: pj, signature: ps, origin: "managedPreferences", pinned: pinned) }
        if let dir = directory {
            let fj = try? Data(contentsOf: dir.appending(path: fileName))
            let fs = try? Data(contentsOf: dir.appending(path: signatureFileName))
            if fj != nil || fs != nil { return Material(json: fj, signature: fs, origin: "file", pinned: pinned) }
        }
        return Material(json: nil, signature: nil, origin: "none", pinned: pinned)
    }

    /// Loads the effective policy from managed prefs + the signed document, with anti-rollback persisted in `store`
    /// (the highest tenant version ever applied).
    public static func load(prefs: ManagedPreferencesReading, directory: URL?, store: TrustStateStore,
                            now: @escaping TrustNow = { Date() }) -> (loaded: LoadedPolicy, origin: String) {
        let m = read(prefs: prefs, directory: directory)
        let minVersion = store.data(forKey: maxVersionKey).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let loader = PolicyLoader(prefs: prefs, pinnedKeys: m.pinned, now: now, minimumTenantVersion: minVersion)
        let loaded = loader.load(tenantJSON: m.json, tenantSignature: m.signature)
        if loaded.sources.contains(where: { $0.source == .tenantSigned && $0.applied }), loaded.policy.version > minVersion {
            store.set(Data(String(loaded.policy.version).utf8), forKey: maxVersionKey)
        }
        return (loaded, m.origin)
    }
}
