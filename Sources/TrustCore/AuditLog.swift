import Foundation
import CryptoKit

/// Security-relevant events. Typed on purpose: there is no free-text field, only ids, counts and reason codes.
public enum AuditEvent: Sendable, Equatable {
    case policyApplied(version: Int, sources: [String])
    case postureResult(decision: String, reasons: [String])
    case sessionClassified(outcome: String)
    case locked(LockReason)
    case unlocked
    case unlockFailed
    case wipeStarted(reason: String)
    case wipeCompleted(paths: Int, keychainItems: Int, failures: Int)
    case tombstoneCleared
    case aiAccess(client: String, tool: String, itemIds: [String], count: Int, decision: String)
    case copyBlocked(itemId: String, labelId: String?)
    case printBlocked(itemId: String, labelId: String?)
    case screenCaptureBlocked(itemId: String?)
    case openInBlocked(itemId: String, bundleId: String)

    var kind: String {
        switch self {
        case .policyApplied: "policyApplied"
        case .postureResult: "postureResult"
        case .sessionClassified: "sessionClassified"
        case .locked: "locked"
        case .unlocked: "unlocked"
        case .unlockFailed: "unlockFailed"
        case .wipeStarted: "wipeStarted"
        case .wipeCompleted: "wipeCompleted"
        case .tombstoneCleared: "tombstoneCleared"
        case .aiAccess: "aiAccess"
        case .copyBlocked: "copyBlocked"
        case .printBlocked: "printBlocked"
        case .screenCaptureBlocked: "screenCaptureBlocked"
        case .openInBlocked: "openInBlocked"
        }
    }

    var fields: [String: [String]] {
        switch self {
        case .policyApplied(let v, let s): ["version": ["\(v)"], "sources": s]
        case .postureResult(let d, let r): ["decision": [d], "reasons": r]
        case .sessionClassified(let o): ["outcome": [o]]
        case .locked(let r): ["reason": [r.rawValue]]
        case .unlocked, .unlockFailed, .tombstoneCleared: [:]
        case .wipeStarted(let r): ["reason": [r]]
        case .wipeCompleted(let p, let k, let f): ["paths": ["\(p)"], "keychainItems": ["\(k)"], "failures": ["\(f)"]]
        case .aiAccess(let c, let t, let ids, let n, let d):
            ["client": [c], "tool": [t], "itemIds": ids, "count": ["\(n)"], "decision": [d]]
        case .copyBlocked(let i, let l), .printBlocked(let i, let l): ["itemId": [i], "labelId": l.map { [$0] } ?? []]
        case .screenCaptureBlocked(let i): ["itemId": i.map { [$0] } ?? []]
        case .openInBlocked(let i, let b): ["itemId": [i], "bundleId": [b]]
        }
    }
}

public struct AuditRecord: Codable, Sendable, Equatable {
    public var seq: Int
    public var ts: Date
    public var kind: String
    public var fields: [String: [String]]
    /// SHA-256 (hex) of the previous plaintext record: deleting or reordering lines breaks the chain.
    public var prev: String
}

/// Append-only, encrypted-at-rest JSON-lines log. Each line is base64(seal(json)).
///
/// Content never enters: every value is reduced to an identifier token `[A-Za-z0-9._:,=+/-]{1,160}`; anything
/// else (spaces, "@", other characters → a subject, body text or an address) is replaced with "redacted".
public final class AuditLog: @unchecked Sendable {
    public typealias Sealer = @Sendable (Data) throws -> Data
    public let url: URL
    private let seal: Sealer
    private let now: TrustNow
    private let lock = NSLock()
    private var seq: Int
    private var lastHash: String

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// `open` is used once to recover the chain head when appending to an existing file.
    public init(url: URL, seal: @escaping Sealer, open: Sealer? = nil, now: @escaping TrustNow = { Date() }) throws {
        self.url = url; self.seal = seal; self.now = now
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        seq = 0; lastHash = ""
        if let open, let records = try? Self.read(url: url, open: open), let last = records.last {
            seq = last.seq + 1
            lastHash = Self.hash(try Self.encoder.encode(last))
        }
    }

    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    public static func sanitize(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:,=+/-")
        guard !s.isEmpty, s.count <= 160, s.allSatisfy({ ok.contains($0) }) else { return "redacted" }
        return s
    }

    /// The plaintext JSON line that will be sealed (exposed so tests can assert on what is actually written).
    func makeRecord(_ e: AuditEvent) -> AuditRecord {
        // Whole seconds so the ISO-8601 round trip re-encodes identically (the hash chain depends on it).
        AuditRecord(seq: seq, ts: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)), kind: e.kind, fields: e.fields.mapValues { $0.map(Self.sanitize) }, prev: lastHash)
    }

    public func append(_ e: AuditEvent) throws {
        try lock.withLock {
            let rec = makeRecord(e)
            let plain = try Self.encoder.encode(rec)
            let line = try seal(plain).base64EncodedString() + "\n"
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            seq += 1
            lastHash = Self.hash(plain)
        }
    }

    public static func read(url: URL, open: Sealer) throws -> [AuditRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            guard let d = Data(base64Encoded: String(line)) else { throw CocoaError(.coderReadCorrupt) }
            return try decoder.decode(AuditRecord.self, from: open(d))
        }
    }

    /// True when sequence numbers are contiguous from 0 and every `prev` matches.
    public static func verifyChain(_ records: [AuditRecord]) -> Bool {
        var prev = ""
        for (i, r) in records.enumerated() {
            guard r.seq == i, r.prev == prev, let d = try? encoder.encode(r) else { return false }
            prev = hash(d)
        }
        return true
    }
}
