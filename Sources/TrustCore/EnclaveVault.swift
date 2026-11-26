import Foundation
import CryptoKit
import Security
import LocalAuthentication

// 1Password-style key protection for the cache keys (docs/MAIL-PLAN.md, "Threat model": stolen/lost device, data
// left behind).
//
// - Cache keys exist in plaintext only in memory, and only while the app is unlocked.
// - At rest, each one is wrapped (ECIES: ephemeral P-256 ECDH → HKDF-SHA256 per purpose → AES-GCM) against a
//   Secure Enclave P-256 key. That key is non-exportable and needs user presence (Touch ID or the Mac password).
// - Only the SE key's `dataRepresentation` is persisted: an SE-encrypted handle that is useless on any other Mac.
//   It sits in a 0600 file. Under ad-hoc signing the data-protection Keychain is unavailable (-34018, missing
//   entitlement), and the login Keychain re-prompts for ACL access on every rebuild.
// - Wrapping needs only the public key, which is stored beside the blob, so it never touches the SE and never prompts.
//   Unwrapping uses the SE, so that is where the prompt happens. With one authenticated LAContext, every key is
//   unwrapped behind a single prompt.
// - `shred()` deletes the blob and the wrapped keys. Every cache sealed with those keys becomes unreadable at once,
//   even if the cache files themselves can't be deleted (crypto-shredding).
//
// Memory hygiene: keys are held only as CryptoKit `SymmetricKey`, which keeps its bytes in a heap buffer it zeroes on
// deinit. Swift can't *guarantee* zeroing: copies may exist in transient buffers (`withUnsafeBytes`, the legacy
// Keychain `Data`), and the process can be swapped (encrypted swap on Apple silicon). Keys are never logged or
// described. `WrappedKey` holds only ciphertext.

/// What a wrapped key is for. The raw value is the HKDF context label, so a key wrapped for one purpose can't be
/// unwrapped as another.
public enum VaultPurpose: String, Sendable, Codable, CaseIterable {
    case calendarCache = "calendar-cache"
    case mailCache = "mail-cache"
    case mailIndex = "mail-index"
    case audit = "audit"
    case accountRegistry = "account-registry"   // ACCOUNTS-HOOK: sealed account list (docs/ACCOUNTS.md §2)
}

/// A symmetric key sealed against the vault's key-agreement public key. Ciphertext only, safe to persist.
public struct WrappedKey: Sendable, Codable, Equatable {
    public var version: Int
    /// Slot name, e.g. "<account>/calendar-cache". Bound into the AES-GCM AAD, so a blob can't be moved to another slot.
    public var name: String
    public var purpose: VaultPurpose
    /// Ephemeral P-256 public key (X9.63).
    public var ephemeralPublicKey: Data
    /// AES-GCM combined (nonce ‖ ciphertext ‖ tag).
    public var sealed: Data
    public init(version: Int, name: String, purpose: VaultPurpose, ephemeralPublicKey: Data, sealed: Data) {
        self.version = version; self.name = name; self.purpose = purpose
        self.ephemeralPublicKey = ephemeralPublicKey; self.sealed = sealed
    }
}

public enum VaultError: Error, Equatable {
    /// No key-agreement key (never created, or shredded).
    case noKey
    case noSuchKey(String)
    case createFailed(String)
    /// The SE refused, or the stored key no longer works (shredded, or the biometric set changed under
    /// `.biometryCurrentSet`). The caches it protected are gone: reset and resync.
    case keyUnusable(String)
    /// The user (or the system, e.g. on sleep) cancelled or failed authentication. The key is fine: stay locked.
    case authenticationRequired
    /// AES-GCM authentication failed: tampered, wrong purpose or name, or the wrong vault key.
    case unwrapFailed
    case persistFailed(String)
    case legacyDeleteFailed
}

/// Which backend holds the key-agreement private key.
public enum VaultBackendKind: String, Sendable, Codable {
    /// Secure Enclave: non-exportable, user presence enforced by the SE.
    case secureEnclave
    /// No SE (VM, old Intel Mac): a software key in the Keychain. Not hardware-bound and not presence-gated; only the
    /// app lock gates the UI. Posture reports `.restrict("noSecureEnclave")`.
    case keychainFallback
    /// Tests only: the blob *is* the private key.
    case software
}

/// The private half of the vault key, abstracted so the wrap/unwrap logic is testable without SE prompts.
public protocol VaultKeyBackend: Sendable {
    var kind: VaultBackendKind { get }
    /// Creates a new key. Returns an opaque blob to persist plus the public key.
    func create() throws -> (blob: Data, publicKey: P256.KeyAgreement.PublicKey)
    /// ECDH with the private key behind `blob`. `context` is an LAContext that has already been evaluated, so the SE
    /// doesn't prompt again. With nil, the SE shows its own prompt for each call.
    func sharedSecret(blob: Data, peer: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret
    /// Destroys anything the backend keeps outside the blob (e.g. the fallback's Keychain item). Missing is fine.
    func destroy() throws
}

/// Secure Enclave backend. The access control decides what the SE demands before each ECDH.
public struct SecureEnclaveBackend: VaultKeyBackend {
    public static let defaultFlags: SecAccessControlCreateFlags = [.privateKeyUsage, .userPresence]
    public let flags: SecAccessControlCreateFlags
    public var kind: VaultBackendKind { .secureEnclave }

    /// `[.privateKeyUsage, .userPresence]` by default: Touch ID or the Mac password. Use `[.privateKeyUsage,
    /// .biometryCurrentSet]` to invalidate the key when fingerprints change; for a cache that only means a resync.
    /// `[.privateKeyUsage]` alone means no presence check, which only the self-test uses.
    public init(flags: SecAccessControlCreateFlags = SecureEnclaveBackend.defaultFlags) { self.flags = flags }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public func create() throws -> (blob: Data, publicKey: P256.KeyAgreement.PublicKey) {
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &err) else {
            throw VaultError.createFailed("accessControl")
        }
        do {
            let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
            return (k.dataRepresentation, k.publicKey)
        } catch { throw VaultError.createFailed("secureEnclave") }
    }

    public func sharedSecret(blob: Data, peer: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        do {
            let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            return try k.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw Self.isAuthenticationError(error) ? VaultError.authenticationRequired : VaultError.keyUnusable("secureEnclave")
        }
    }

    /// Cancel / failed / not-allowed authentication (LAError, or the Keychain's -128 / -25293 / -25308), also when
    /// wrapped as an underlying error. These must never lead to a reset.
    public static func isAuthenticationError(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let n = e {
            if n.domain == LAErrorDomain { return true }
            if n.domain == NSOSStatusErrorDomain,
               [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(OSStatus(n.code)) { return true }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    public func destroy() throws {}  // The SE keeps nothing: the blob is the only handle.
}

/// Minimal secret storage, so the fallback backend can be tested without the real Keychain.
public protocol VaultSecretStore: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// One generic-password item. Uses the data-protection Keychain when `accessGroup` is set (needs the
/// keychain-access-groups entitlement, i.e. a real signature); otherwise the legacy login Keychain.
public struct KeychainSecretStore: VaultSecretStore {
    public var service: String, account: String, accessGroup: String?
    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }
    private var base: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let accessGroup { q[kSecUseDataProtectionKeychain as String] = true; q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
    public func read() -> Data? {
        var q = base; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    public func write(_ data: Data) throws {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
    public func delete() throws {
        let s = SecItemDelete(base as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
}

/// No-SE fallback: a software P-256 key kept in the Keychain. The blob file holds only a marker; deleting the Keychain
/// item (in `destroy`) is what shreds it.
public struct KeychainFallbackBackend: VaultKeyBackend {
    public let store: VaultSecretStore
    public var kind: VaultBackendKind { .keychainFallback }
    static let marker = Data("keychain-fallback-v1".utf8)
    public init(store: VaultSecretStore) { self.store = store }

    public func create() throws -> (blob: Data, publicKey: P256.KeyAgreement.PublicKey) {
        let k = P256.KeyAgreement.PrivateKey()
        do { try store.write(k.rawRepresentation) } catch { throw VaultError.createFailed("keychain") }
        return (Self.marker, k.publicKey)
    }
    public func sharedSecret(blob: Data, peer: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        guard blob == Self.marker, let raw = store.read(),
              let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { throw VaultError.keyUnusable("keychain") }
        do { return try k.sharedSecretFromKeyAgreement(with: peer) } catch { throw VaultError.keyUnusable("keychain") }
    }
    public func destroy() throws { try store.delete() }
}

/// TESTS ONLY: the blob is the raw private key. Same wrap/unwrap code paths as the SE backend, without prompts.
public struct SoftwareKeyBackend: VaultKeyBackend {
    public var kind: VaultBackendKind { .software }
    public init() {}
    public func create() throws -> (blob: Data, publicKey: P256.KeyAgreement.PublicKey) {
        let k = P256.KeyAgreement.PrivateKey()
        return (k.rawRepresentation, k.publicKey)
    }
    public func sharedSecret(blob: Data, peer: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        guard let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: blob) else { throw VaultError.keyUnusable("software") }
        return try k.sharedSecretFromKeyAgreement(with: peer)
    }
    public func destroy() throws {}
}

/// Something a wipe destroys first, so data is unreadable before (and even without) file deletion.
public protocol CryptoShredding: Sendable {
    /// Idempotent: a vault that is already shredded is success.
    func shred() throws
}

/// The vault: one key-agreement key (blob + public key) and the wrapped cache keys, all in one 0700 directory:
/// `vault-key.blob` (0600) and `wrapped-keys.json` (0600), excluded from Time Machine.
/// Thread-safe. All crypto is synchronous; the async `unwrap` is a thin wrapper.
public final class EnclaveVault: CryptoShredding, @unchecked Sendable {
    public static let wrapVersion = 1
    public let directory: URL
    public let backend: VaultKeyBackend
    private let lock = NSRecursiveLock()

    public var blobURL: URL { directory.appending(path: "vault-key.blob") }
    public var keysURL: URL { directory.appending(path: "wrapped-keys.json") }

    struct KeyFile: Codable {
        var version: Int
        var backend: VaultBackendKind
        var publicKey: Data
        var keys: [String: WrappedKey]
    }

    public init(directory: URL, backend: VaultKeyBackend) {
        self.directory = directory; self.backend = backend
    }

    /// The app's default: SE when available, otherwise the Keychain fallback (`fallbackStore`).
    public static func system(directory: URL, fallbackStore: VaultSecretStore,
                              flags: SecAccessControlCreateFlags = SecureEnclaveBackend.defaultFlags) -> EnclaveVault {
        EnclaveVault(directory: directory, backend: SecureEnclaveBackend.isAvailable
                     ? SecureEnclaveBackend(flags: flags) : KeychainFallbackBackend(store: fallbackStore))
    }

    /// `SecureEnclave.isAvailable` (VMs and Intel Macs without a T2 report false).
    public static var isAvailable: Bool { SecureEnclaveBackend.isAvailable }
    /// Is this vault hardware-backed?
    public var isHardwareBacked: Bool { backend.kind == .secureEnclave }

    // MARK: Files

    private func readFile() -> KeyFile? {
        guard let d = try? Data(contentsOf: keysURL) else { return nil }
        return try? JSONDecoder().decode(KeyFile.self, from: d)
    }

    private func writeFile(_ f: KeyFile) throws {
        do {
            let d = try JSONEncoder().encode(f)
            try d.write(to: keysURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysURL.path)
        } catch { throw VaultError.persistFailed("keys") }
        // Re-read: deleting a legacy key is only safe once the wrapped copy is durably readable.
        guard let back = readFile(), back.keys == f.keys, back.publicKey == f.publicKey else { throw VaultError.persistFailed("verify") }
    }

    private func blob() -> Data? { try? Data(contentsOf: blobURL) }

    /// Creates the key-agreement key on first use. Creating an SE key doesn't prompt.
    private func ensureKey() throws -> KeyFile {
        if let f = readFile(), blob() != nil { return f }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var dir = directory
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true
            try? dir.setResourceValues(rv)
        } catch { throw VaultError.persistFailed("directory") }
        // Half-present state (blob without keys file, or the reverse) can't unwrap anything: start clean.
        try? fm.removeItem(at: blobURL); try? fm.removeItem(at: keysURL)
        let (b, pub) = try backend.create()
        do {
            try b.write(to: blobURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL.path)
        } catch { throw VaultError.persistFailed("blob") }
        let f = KeyFile(version: Self.wrapVersion, backend: backend.kind, publicKey: pub.x963Representation, keys: [:])
        try writeFile(f)
        return f
    }

    // MARK: Crypto

    static func info(_ purpose: VaultPurpose) -> Data { Data("compliant-office.vault.v1/\(purpose.rawValue)".utf8) }
    static func aad(name: String, purpose: VaultPurpose) -> Data { Data("v1|\(purpose.rawValue)|\(name)".utf8) }

    static func kek(_ secret: SharedSecret, ephemeral: Data, recipient: Data, purpose: VaultPurpose) -> SymmetricKey {
        // Salt binds both public keys (as in ECIES), info binds the purpose.
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient, sharedInfo: info(purpose),
                                       outputByteCount: 32)
    }

    /// Wraps against a public key. Pure, never touches the SE, never prompts.
    public static func wrap(_ key: SymmetricKey, name: String, purpose: VaultPurpose,
                            to recipient: P256.KeyAgreement.PublicKey) throws -> WrappedKey {
        let eph = P256.KeyAgreement.PrivateKey()
        let secret = try eph.sharedSecretFromKeyAgreement(with: recipient)
        let ephPub = eph.publicKey.x963Representation
        let kek = kek(secret, ephemeral: ephPub, recipient: recipient.x963Representation, purpose: purpose)
        let raw = key.withUnsafeBytes { Data($0) }  // transient copy, see the memory-hygiene note above
        guard let combined = try AES.GCM.seal(raw, using: kek, authenticating: aad(name: name, purpose: purpose)).combined else {
            throw VaultError.persistFailed("seal")
        }
        return WrappedKey(version: wrapVersion, name: name, purpose: purpose, ephemeralPublicKey: ephPub, sealed: combined)
    }

    /// Wraps `key` with this vault's public key. Doesn't persist (see `store`). No prompt.
    public func wrap(_ key: SymmetricKey, name: String, purpose: VaultPurpose) throws -> WrappedKey {
        try lock.withLock {
            let f = try ensureKey()
            guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: f.publicKey) else { throw VaultError.noKey }
            return try Self.wrap(key, name: name, purpose: purpose, to: pub)
        }
    }

    /// Synchronous core of `unwrap`. `purpose` must match what the key was wrapped for (HKDF context separation).
    public func unwrapSync(_ w: WrappedKey, as purpose: VaultPurpose? = nil, context: LAContext?) throws -> SymmetricKey {
        try lock.withLock {
            guard let f = readFile(), let b = blob(),
                  let pub = try? P256.KeyAgreement.PublicKey(x963Representation: f.publicKey) else { throw VaultError.noKey }
            guard let eph = try? P256.KeyAgreement.PublicKey(x963Representation: w.ephemeralPublicKey) else { throw VaultError.unwrapFailed }
            let p = purpose ?? w.purpose
            let secret = try backend.sharedSecret(blob: b, peer: eph, context: context)
            let kek = Self.kek(secret, ephemeral: w.ephemeralPublicKey, recipient: pub.x963Representation, purpose: p)
            guard let box = try? AES.GCM.SealedBox(combined: w.sealed),
                  let raw = try? AES.GCM.open(box, using: kek, authenticating: Self.aad(name: w.name, purpose: p)) else {
                throw VaultError.unwrapFailed
            }
            return SymmetricKey(data: raw)
        }
    }

    /// The prompt happens here (unless `context` was already evaluated). Pass the same authenticated context for every
    /// key in one unlock to get a single prompt; `unwrapAll` does that.
    public func unwrap(_ w: WrappedKey, as purpose: VaultPurpose? = nil, context: LAContext?) async throws -> SymmetricKey {
        try unwrapSync(w, as: purpose, context: context)
    }

    // MARK: Stored keys

    /// Persists a wrapped key in its slot (replacing any previous one).
    public func store(_ w: WrappedKey) throws {
        try lock.withLock {
            var f = try ensureKey()
            f.keys[w.name] = w
            try writeFile(f)
        }
    }

    public func wrapped(named name: String) -> WrappedKey? { lock.withLock { readFile()?.keys[name] } }
    public var wrappedNames: [String] { lock.withLock { (readFile()?.keys.keys).map(Array.init)?.sorted() ?? [] } }

    /// Removes slots (e.g. on sign-out): crypto-shreds those caches without touching others.
    public func remove(names: [String]) throws {
        try lock.withLock {
            guard var f = readFile() else { return }
            for n in names { f.keys[n] = nil }
            try writeFile(f)
        }
    }

    /// Unwraps every stored key with one context. On Apple silicon that is one SE operation per key, all
    /// covered by the same evaluated LAContext, so the user sees one prompt.
    public func unwrapAll(context: LAContext?) throws -> [String: SymmetricKey] {
        try lock.withLock {
            guard let f = readFile() else { return [:] }
            var out: [String: SymmetricKey] = [:]
            for (n, w) in f.keys { out[n] = try unwrapSync(w, context: context) }
            return out
        }
    }

    /// Creates a fresh random key, wraps and persists it. No prompt.
    public func createKey(name: String, purpose: VaultPurpose) throws -> SymmetricKey {
        let k = SymmetricKey(size: .bits256)
        try store(try wrap(k, name: name, purpose: purpose))
        return k
    }

    /// First-run migration from a plain Keychain key: wrap it, persist and verify, then delete the plain copy. If the slot
    /// already holds a wrapped key, the legacy key is never re-adopted: any stray plain copy is just deleted. Returns the
    /// adopted key, or nil when there was nothing to adopt.
    public func adoptLegacy(name: String, purpose: VaultPurpose, legacy: () -> SymmetricKey?,
                            deleteLegacy: () throws -> Void) throws -> SymmetricKey? {
        try lock.withLock {
            if wrapped(named: name) != nil {
                if legacy() != nil { try? deleteLegacy() }
                return nil
            }
            guard let k = legacy() else { return nil }
            try store(try wrap(k, name: name, purpose: purpose))  // writeFile re-reads to verify
            do { try deleteLegacy() } catch { throw VaultError.legacyDeleteFailed }
            return k
        }
    }

    /// Should a failed unlock reset (shred) the vault? Only when the key or the wrapped data is unusable, never on
    /// cancelled or failed authentication (the cache and unsent outbox rows would be lost for nothing).
    public static func shouldReset(after error: Error) -> Bool {
        guard let v = error as? VaultError else { return false }
        switch v {
        case .keyUnusable, .unwrapFailed, .noKey: return true
        default: return false
        }
    }

    public var hasKey: Bool { lock.withLock { blob() != nil && readFile() != nil } }

    /// Crypto-shred: deletes the blob (the only handle to the SE key) and the wrapped keys, plus the fallback's Keychain
    /// item. Each step is attempted; it throws if any step failed. Idempotent.
    public func shred() throws {
        try lock.withLock {
            let fm = FileManager.default
            var failed: [String] = []
            for u in [blobURL, keysURL] where fm.fileExists(atPath: u.path) {
                // Overwriting first doesn't help on APFS (copy-on-write) and SSDs. The blob is useless off this Mac's SE,
                // and once the SE key is gone, so are the wrapped keys.
                do { try fm.removeItem(at: u) } catch { failed.append(u.lastPathComponent) }
            }
            do { try backend.destroy() } catch { failed.append("backend") }
            if (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true { try? fm.removeItem(at: directory) }
            if !failed.isEmpty { throw VaultError.persistFailed("shred:" + failed.joined(separator: ",")) }
        }
    }
}
