import Foundation
import CryptoKit
import Security

/// Encrypts cached payloads at rest. Index columns (times, calendar, label id) stay plaintext so range
/// queries remain index-only; subjects, bodies and attendees are only ever stored sealed.
public protocol PayloadCipher: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

public struct AESGCMCipher: PayloadCipher {
    private let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    public func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}

/// Cache key lives in the login Keychain, never on disk next to the database.
/// Signing out deletes the key — which crypto-shreds the cache even if file deletion fails.
public enum KeychainCacheKey {
    static let service = "ai.niivo.mail.cachekey"

    /// Set to "<TeamID>.<bundle id>" when the app is signed with keychain-access-groups: the key then lives in the
    /// data-protection keychain (no per-build ACL prompts, not readable by other apps). nil → legacy login keychain.
    nonisolated(unsafe) public static var accessGroup: String?

    private static func base(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Reads an existing key without creating one. Used to migrate legacy plain keys into the Secure Enclave vault
    /// (`TrustCore.EnclaveVault.adoptLegacy`); the app no longer creates plain keys for file-backed caches.
    public static func load(account: String) -> SymmetricKey? {
        var query = base(account: account)
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    /// Deletes the plain key; a missing item is success.
    public static func delete(account: String) throws {
        let s = SecItemDelete(base(account: account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }

    /// Legacy: plain key in the Keychain. Superseded in the app by the Secure Enclave vault.
    public static func loadOrCreate(account: String) throws -> SymmetricKey {
        var query = base(account: account)
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = raw
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }

    public static func destroy(account: String) {
        SecItemDelete(base(account: account) as CFDictionary)
    }
}
