// TrustCore — app-enforced BYOD protection (policy, posture, remote wipe, app lock). See docs/MAIL-PLAN.md,
// section "BYOD without MDM and without our own data gateway".
//
// Design constraints (Ryan, 2026-11-19): all data stays on the Mac and in the customer's tenant; no vendor server ever
// holds customer data. The control plane is the customer's own Entra/M365 tenant. Everything here is UI-free, takes
// its inputs (prefs, signed policy bytes, Graph/MSAL results, clocks, command output) by injection, and never prints.
//
// Honest limit: Entra can't tell this app from any other client on an unmanaged Mac, so these controls are
// app-enforced, not tenant-verified. A user with admin rights on their own Mac can patch the binary or edit stores.
import Foundation

/// Injectable wall clock. (Not named `Clock` to avoid the stdlib protocol.)
public typealias TrustNow = @Sendable () -> Date

/// Minimal key/value persistence for trust state (grace clock, high-water marks). The app may back this with the
/// Keychain so it is harder to tamper with than a plist; tests use `InMemoryTrustStore`.
public protocol TrustStateStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class InMemoryTrustStore: TrustStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

/// One file per key in a 0700 directory, files 0600, atomic writes.
public final class FileTrustStore: TrustStateStore, @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()
    public init(directory: URL) throws {
        dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }
        return dir.appending(path: String(safe))
    }
    public func data(forKey key: String) -> Data? { lock.withLock { try? Data(contentsOf: url(key)) } }
    public func set(_ data: Data?, forKey key: String) {
        lock.withLock {
            let u = url(key)
            guard let data else { try? FileManager.default.removeItem(at: u); return }
            try? data.write(to: u, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }
    }
}
