import Foundation
import CryptoKit
import LocalAuthentication
import CalendarCore
import MailCore
import TrustCore

/// In-memory cache keys for the signed-in account, backed by the Secure Enclave vault (`TrustCore.EnclaveVault`).
///
/// - Locked: no keys in memory, and no file-backed store is open (AppModel/MailModel close theirs).
/// - Unlock: one authenticated LAContext unwraps every stored key, so the user sees one prompt.
/// - New keys are created and wrapped without a prompt (`wrap` uses only the stored public key).
/// - First run after the upgrade: an existing plain Keychain key is adopted (wrapped, verified, then the plain copy is
///   deleted). This is one-way: an older build of the app can no longer read that cache and would start a new one.
///
/// Keys are held only as `SymmetricKey` and never logged. Swift can't guarantee zeroing (see EnclaveVault.swift).
/// Fixture and dev-token modes don't use this: their stores are in-memory with ephemeral keys.
@MainActor
final class CacheKeyring {
    enum KeyringError: Error { case locked }

    let vault: EnclaveVault
    private var keys: [String: SymmetricKey] = [:]
    /// Keys were unwrapped (or there was nothing to unwrap) during the current unlock.
    private(set) var isOpen = false
    /// The last unlock found the vault unusable (shredded, or SE key invalidated) and started a fresh one.
    private(set) var didReset = false

    init(vault: EnclaveVault) { self.vault = vault }

    /// Vault directory beside the caches; the no-SE fallback key lives in the Keychain.
    static func system() -> CacheKeyring {
        let dir = AppConfig.supportDir.appending(path: "vault", directoryHint: .isDirectory)
        let fallback = KeychainSecretStore(service: "ai.niivo.mail.vault-fallback", account: "vault-key",
                                           accessGroup: KeychainCacheKey.accessGroup)
        return CacheKeyring(vault: .system(directory: dir, fallbackStore: fallback))
    }

    static func slot(_ account: String, _ p: VaultPurpose) -> String { "\(safeName(account))/\(p.rawValue)" }
    static func safeName(_ account: String) -> String {
        AccountStoreNaming.safeName(account)   // ACCOUNTS-HOOK: one naming function (account #1 keeps its files)
    }

    /// Unwraps every stored key. `ctx` is the context AppLock just authenticated. Nil (app lock disabled by policy, or a
    /// fixture-free race) → this evaluates its own context, which means one prompt. Returns false only when the
    /// user didn't authenticate. A vault that can't be read after a successful authentication is reset (shredded):
    /// the caches it protected are unreadable anyway and get resynced.
    func unlock(with ctx: AuthenticatedContext?) async -> Bool {
        if isOpen { return true }
        guard !vault.wrappedNames.isEmpty else { isOpen = true; return true }
        var context = ctx
        var own: AuthenticatedContext?
        if context == nil {
            own = await LocalAuthenticationAuthenticator().authenticateContext(reason: "Unlock your mail and calendar cache")
            guard own != nil else { return false }
            context = own
        }
        defer { own?.context.invalidate() }
        do {
            keys = try vault.unwrapAll(context: context?.context)
            didReset = false
        } catch where !EnclaveVault.shouldReset(after: error) {
            return false  // cancelled / failed authentication: stay locked, keep the vault
        } catch {
            // Never logs key material: the error carries only a fixed reason code.
            FileHandle.standardError.write(Data("vault: unwrap failed (\(error)); resetting the cache keys\n".utf8))
            try? vault.shred()
            keys = [:]
            didReset = true
        }
        isOpen = true
        return true
    }

    /// Lock: drop every key from memory. The stores holding ciphers must be released too (the models do that).
    func lock() {
        keys = [:]
        isOpen = false
    }

    /// ACCOUNTS-HOOK: key of the sealed account registry. Owned by no account, so removing any account keeps it.
    func registryKey() throws -> (key: SymmetricKey, fresh: Bool) {
        try key(account: AccountStoreNaming.registryKeyOwner, purpose: .accountRegistry, legacyAccount: nil)
    }

    /// Calendar cache key. `fresh` → newly created, so any existing cache file was sealed with a lost key and must go.
    func calendarKey(account: String) throws -> (key: SymmetricKey, fresh: Bool) {
        try key(account: account, purpose: .calendarCache, legacyAccount: account)
    }

    /// Mail payload key + blind-index key. Migrated mail caches keep the index derived from the legacy key (otherwise
    /// the existing index breaks); new caches get an independent random index key.
    func mailKeys(account: String) throws -> (cache: SymmetricKey, index: SymmetricKey, fresh: Bool) {
        guard isOpen else { throw KeyringError.locked }
        let legacyAccount = account + ".mail"
        let indexSlot = Self.slot(account, .mailIndex)
        // Index first, then the payload key (which deletes the legacy copy): an interruption in between stays consistent.
        if keys[indexSlot] == nil,
           let k = try vault.adoptLegacy(name: indexSlot, purpose: .mailIndex,
                                         legacy: { KeychainCacheKey.load(account: legacyAccount).map(MailStore.deriveIndexKey) },
                                         deleteLegacy: {}) {
            keys[indexSlot] = k
        }
        let cache = try key(account: account, purpose: .mailCache, legacyAccount: legacyAccount)
        let indexFresh = keys[indexSlot] == nil
        let index = try key(account: account, purpose: .mailIndex, legacyAccount: nil).key
        return (cache.key, index, cache.fresh || indexFresh)
    }

    private func key(account: String, purpose: VaultPurpose, legacyAccount: String?) throws -> (key: SymmetricKey, fresh: Bool) {
        guard isOpen else { throw KeyringError.locked }
        let slot = Self.slot(account, purpose)
        if let k = keys[slot] { return (k, false) }
        if let legacyAccount, let legacyKey = KeychainCacheKey.load(account: legacyAccount) {
            do {
                if let k = try vault.adoptLegacy(name: slot, purpose: purpose, legacy: { legacyKey },
                                                 deleteLegacy: { try KeychainCacheKey.delete(account: legacyAccount) }) {
                    keys[slot] = k
                    return (k, false)
                }
            } catch VaultError.legacyDeleteFailed {
                keys[slot] = legacyKey   // wrapped copy is stored; the stray plain copy is deleted next run
                return (legacyKey, false)
            }
        }
        // A wrapped key that is present but wasn't unwrapped this unlock was added by another process meanwhile:
        // replacing it is the safe outcome (the cache is resynced).
        let k = try vault.createKey(name: slot, purpose: purpose)
        keys[slot] = k
        return (k, true)
    }

    /// Sign-out: crypto-shred this account's caches (their wrapped keys go) and any legacy plain keys.
    func remove(account: String) {
        let names = VaultPurpose.allCases.map { Self.slot(account, $0) }
        for n in names { keys[n] = nil }
        try? vault.remove(names: names)
        KeychainCacheKey.destroy(account: account + ".mail")
        KeychainCacheKey.destroy(account: account)
    }

    /// Per-account wipe: the vault slots are already gone (TrustCore `VaultSlotShredder`); drop the in-memory copies.
    func forget(account: String) {
        for p in VaultPurpose.allCases { keys[Self.slot(account, p)] = nil }
    }

    /// Deletes a SQLite cache file and its sidecars (used when its key is fresh: the old contents are unreadable).
    static func discardStaleCache(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
