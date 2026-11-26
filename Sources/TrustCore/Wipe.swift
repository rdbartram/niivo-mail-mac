import Foundation
import Security

/// A generic-password Keychain item to destroy on wipe (cache key, MSAL account entries the app owns, …).
public struct KeychainItemRef: Sendable, Hashable, Codable {
    public var service: String
    public var account: String?
    public var accessGroup: String?
    public init(service: String, account: String? = nil, accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }
}

public protocol SecretDeleting: Sendable {
    /// Deletes the item; a missing item is success.
    func delete(_ item: KeychainItemRef) throws
}

/// Real Keychain deletion (generic passwords). Tests inject a fake; never run this against real items in tests.
public struct SystemKeychainDeleter: SecretDeleting {
    public init() {}
    public func delete(_ item: KeychainItemRef) throws {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service]
        if let a = item.account { q[kSecAttrAccount as String] = a }
        if let g = item.accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = g
        }
        let s = SecItemDelete(q as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(s))
        }
    }
}

public struct WipeTombstone: Codable, Sendable, Equatable {
    public var reason: String
    public var wipedAt: Date
    /// false while deletion is in progress; an interrupted wipe resumes on next launch.
    public var completed: Bool
    public init(reason: String, wipedAt: Date, completed: Bool) {
        self.reason = reason; self.wipedAt = wipedAt; self.completed = completed
    }
}

public struct WipeReport: Sendable, Equatable {
    public var removedPaths: Int
    public var removedKeychainItems: Int
    /// Fixed-format failure notes (path basenames / service names only).
    public var failures: [String]
    /// Key vaults crypto-shredded (before any file was deleted).
    public var shreddedVaults: Int
    public init(removedPaths: Int, removedKeychainItems: Int, failures: [String], shreddedVaults: Int = 0) {
        self.removedPaths = removedPaths; self.removedKeychainItems = removedKeychainItems; self.failures = failures
        self.shreddedVaults = shreddedVaults
    }
}

public protocol WipeExecutor: Sendable {
    var tombstone: WipeTombstone? { get }
    /// Data may be served only when this is true.
    var canServeData: Bool { get }
    @discardableResult func wipe(reason: String) throws -> WipeReport
    /// Re-runs an interrupted wipe. Call at launch before opening any store.
    @discardableResult func resumeIfNeeded() throws -> WipeReport?
    /// Clears the tombstone only when an interactive sign-in just succeeded *and* the server confirmed the user is no
    /// longer revoked (fresh token + successful Graph call + wipe-group check negative).
    @discardableResult func clearTombstone(freshSignInSucceeded: Bool, serverConfirmedNotRevoked: Bool) -> Bool
}

public enum WipeError: Error, Equatable { case tombstoneInsideWipedLocation, tombstoneWriteFailed }

/// Write tombstone first → crypto-shred the key vaults (`EnclaveVault`: every cache sealed with their keys is unreadable
/// from here on, even if a later deletion fails) → delete directories, store files (+ -wal/-shm/-journal) and Keychain items → mark the
/// tombstone completed. Idempotent: running again re-deletes anything that reappeared and keeps the first reason.
/// The tombstone lives outside every wiped location so a restart can't "forget" the wipe.
public final class DefaultWipeExecutor: WipeExecutor, @unchecked Sendable {
    public let cacheDirectories: [URL]
    public let storeFiles: [URL]
    public let keychainItems: [KeychainItemRef]
    public let keychain: SecretDeleting
    /// Shredded first, before any file is touched.
    public let shredders: [CryptoShredding]
    public let tombstoneURL: URL
    let now: TrustNow
    private let lock = NSLock()

    public init(cacheDirectories: [URL], storeFiles: [URL], keychainItems: [KeychainItemRef], keychain: SecretDeleting,
                shredders: [CryptoShredding] = [], tombstoneURL: URL, now: @escaping TrustNow = { Date() }) throws {
        let t = tombstoneURL.standardizedFileURL.path
        for d in cacheDirectories where t.hasPrefix(d.standardizedFileURL.path + "/") {
            throw WipeError.tombstoneInsideWipedLocation
        }
        if storeFiles.contains(where: { $0.standardizedFileURL.path == t }) { throw WipeError.tombstoneInsideWipedLocation }
        self.cacheDirectories = cacheDirectories; self.storeFiles = storeFiles; self.keychainItems = keychainItems
        self.keychain = keychain; self.shredders = shredders; self.tombstoneURL = tombstoneURL; self.now = now
    }

    static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }()

    public var tombstone: WipeTombstone? {
        guard let d = try? Data(contentsOf: tombstoneURL) else { return nil }
        // An unreadable tombstone still means "wiped": fail closed.
        return (try? Self.coder.1.decode(WipeTombstone.self, from: d))
            ?? WipeTombstone(reason: "unreadableTombstone", wipedAt: .distantPast, completed: false)
    }

    public var canServeData: Bool { !FileManager.default.fileExists(atPath: tombstoneURL.path) }

    private func writeTombstone(_ t: WipeTombstone) throws {
        try FileManager.default.createDirectory(at: tombstoneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? Self.coder.0.encode(t) else { throw WipeError.tombstoneWriteFailed }
        do { try d.write(to: tombstoneURL, options: [.atomic]) } catch { throw WipeError.tombstoneWriteFailed }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tombstoneURL.path)
    }

    @discardableResult public func wipe(reason: String) throws -> WipeReport {
        try lock.withLock {
            var t = tombstone ?? WipeTombstone(reason: reason, wipedAt: now(), completed: false)
            t.completed = false
            // Delete even if the tombstone can't be written (full disk, unwritable dir): never fail open.
            var tombError: Error?
            do { try writeTombstone(t) } catch { tombError = error }
            let r = deleteAll()
            t.completed = r.failures.isEmpty
            do { try writeTombstone(t) } catch { tombError = tombError ?? error }
            if let tombError { throw tombError }
            return r
        }
    }

    @discardableResult public func resumeIfNeeded() throws -> WipeReport? {
        guard let t = tombstone, !t.completed else { return nil }
        return try wipe(reason: t.reason)
    }

    @discardableResult public func clearTombstone(freshSignInSucceeded: Bool, serverConfirmedNotRevoked: Bool) -> Bool {
        lock.withLock {
            guard freshSignInSucceeded, serverConfirmedNotRevoked, let t = tombstone, t.completed else { return false }
            return (try? FileManager.default.removeItem(at: tombstoneURL)) != nil
        }
    }

    private func deleteAll() -> WipeReport {
        let fm = FileManager.default
        var removed = 0, keys = 0, shredded = 0
        var failures: [String] = []
        // Crypto-shred first: if the process dies or a deletion fails below, the data is already unreadable.
        for (i, v) in shredders.enumerated() {
            do { try v.shred(); shredded += 1 } catch { failures.append("shred:\(i)") }
        }
        var paths = cacheDirectories
        for f in storeFiles {
            paths.append(f)
            for s in ["-wal", "-shm", "-journal"] { paths.append(URL(fileURLWithPath: f.path + s)) }
        }
        for u in paths where fm.fileExists(atPath: u.path) {
            do { try fm.removeItem(at: u); removed += 1 } catch { failures.append("path:\(u.lastPathComponent)") }
        }
        for k in keychainItems {
            do { try keychain.delete(k); keys += 1 } catch { failures.append("keychain:\(k.service)") }
        }
        return WipeReport(removedPaths: removed, removedKeychainItems: keys, failures: failures, shreddedVaults: shredded)
    }
}
