import Foundation
import CryptoKit
import Security
import TrustCore

/// Every tool call → one encrypted TrustCore `AuditEvent.aiAccess` record (tool, ids, count, decision — never
/// content) plus one content-free stderr line.
public final class AuditSink: Sendable {
    let log: AuditLog?
    public let location: String

    init(log: AuditLog?, location: String) { self.log = log; self.location = location }

    /// Fixtures: temp file, ephemeral in-memory key (unreadable after exit, by design).
    /// Graph: Application Support file, AES key in the login Keychain (created on first run).
    public static func make(fixtures: Bool, path: String?) -> AuditSink {
        let url: URL
        if let path { url = URL(fileURLWithPath: path) }
        else if fixtures {
            url = FileManager.default.temporaryDirectory
                .appending(path: "OfficeMCP-\(ProcessInfo.processInfo.processIdentifier)/mcp-audit.log")
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/CompliantOffice/mcp-audit.log")
        }
        let key: SymmetricKey
        if fixtures { key = SymmetricKey(size: .bits256) }
        else if let k = KeychainKey.loadOrCreate() { key = k }
        else {
            Log.err("audit: Keychain key unavailable — audit log disabled")
            return AuditSink(log: nil, location: "disabled")
        }
        let seal: AuditLog.Sealer = { data in
            guard let c = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.coderInvalidValue) }
            return c
        }
        let open: AuditLog.Sealer = { data in try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
        do {
            return AuditSink(log: try AuditLog(url: url, seal: seal, open: open), location: url.path)
        } catch {
            Log.err("audit: could not open log — audit disabled")
            return AuditSink(log: nil, location: "disabled")
        }
    }

    func record(client: String, tool: String, ids: [String], count: Int, decision: String) {
        let event = AuditEvent.aiAccess(client: Self.token(client), tool: Self.token(tool),
                                        itemIds: ids.prefix(100).map(Self.idToken), count: count, decision: Self.token(decision))
        do { try log?.append(event) } catch { Log.err("audit: append failed") }
    }

    /// AuditLog.sanitize accepts `[A-Za-z0-9._:,=+/-]{1,160}` and stores anything else as "redacted".
    /// Underscores (tool names) become hyphens; other characters become ".".
    static func token(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:,=+/-")
        let mapped = String(s.prefix(160).map { $0 == "_" ? "-" : ok.contains($0) ? $0 : "." })
        return mapped.isEmpty ? "none" : mapped
    }

    /// Ids that wouldn't survive sanitize (Graph ids are long and contain "_") are logged as a stable hash.
    static func idToken(_ id: String) -> String {
        if AuditLog.sanitize(id) == id { return id }
        let h = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "sha256:" + h
    }
}

enum KeychainKey {
    static let service = "ai.niivo.mail.mcp-audit"

    static func loadOrCreate() -> SymmetricKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "audit-key", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            return SymmetricKey(data: d)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "audit-key", kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

/// stderr only. stdout is reserved for JSON-RPC (see `StdoutChannel`).
public enum Log {
    public static func err(_ s: String) {
        FileHandle.standardError.write(Data(("OfficeMCP: " + s + "\n").utf8))
    }
}
