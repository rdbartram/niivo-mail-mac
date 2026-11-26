import Foundation
import CryptoKit

// MARK: Managed preferences

/// Read access to managed preferences for one app. Injected so tests never touch the real preference domains.
public protocol ManagedPreferencesReading: Sendable {
    /// A property-list value (Bool/NSNumber/String/Array/Dictionary) or nil.
    func value(forKey key: String) -> Any?
    /// True when an MDM configuration profile forces the key (the user cannot override it).
    func isForced(key: String) -> Bool
}

/// The real reader: CFPreferences for the app's bundle id. Forced keys come from configuration profiles installed
/// by MDM (/Library/Managed Preferences); unforced values may simply be the user's own `defaults write`.
public struct CFManagedPreferences: ManagedPreferencesReading {
    public let bundleId: String
    public init(bundleId: String = "ai.niivo.mail") { self.bundleId = bundleId }
    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, bundleId as CFString)
    }
    public func isForced(key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, bundleId as CFString)
    }
}

/// Test double.
public struct StaticManagedPreferences: ManagedPreferencesReading, @unchecked Sendable {
    public var values: [String: Any]
    public var forced: Set<String>
    public init(values: [String: Any] = [:], forced: Set<String> = []) { self.values = values; self.forced = forced }
    public func value(forKey key: String) -> Any? { values[key] }
    public func isForced(key: String) -> Bool { forced.contains(key) && values[key] != nil }
}

// MARK: Tenant-signed policy

/// The signed tenant policy document. The signature covers the exact bytes of this JSON as fetched.
///
/// Fetching is not TrustCore's job: the app downloads `trust-policy.json` and `trust-policy.json.sig` from a
/// SharePoint/OneDrive location in the customer's own tenant through Graph with the signed-in user's delegated token
/// (driveItem content). No vendor server is involved. The caller passes the bytes in.
public struct SignedTenantPolicy: Codable, Sendable {
    public var keyId: String
    public var tenantId: String?
    public var version: Int
    public var issuedAt: Date
    public var expiresAt: Date
    public var policy: TrustPolicyOverlay
    public init(keyId: String, tenantId: String?, version: Int, issuedAt: Date, expiresAt: Date, policy: TrustPolicyOverlay) {
        self.keyId = keyId; self.tenantId = tenantId; self.version = version; self.issuedAt = issuedAt
        self.expiresAt = expiresAt; self.policy = policy
    }
}

public struct PinnedPolicyKeys: Sendable {
    /// keyId → Ed25519 public key. Pinned in app config (shipped in the bundle or forced by MDM).
    public var keys: [String: Curve25519.Signing.PublicKey]
    /// Expected tenant id; nil = don't check.
    public var tenantId: String?
    /// Reject documents older than this, whatever their `expiresAt` says.
    public var maxAge: TimeInterval
    /// Tolerated clock skew for `issuedAt` in the future.
    public var clockSkew: TimeInterval
    public init(keys: [String: Curve25519.Signing.PublicKey], tenantId: String? = nil,
                maxAge: TimeInterval = 180 * 86400, clockSkew: TimeInterval = 600) {
        self.keys = keys; self.tenantId = tenantId; self.maxAge = maxAge; self.clockSkew = clockSkew
    }
    /// Parses "keyId:base64(raw 32-byte key)" entries.
    public init(config: [String], tenantId: String? = nil) {
        var k: [String: Curve25519.Signing.PublicKey] = [:]
        for entry in config {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let raw = Data(base64Encoded: parts[1]),
               let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) { k[parts[0]] = key }
        }
        self.init(keys: k, tenantId: tenantId)
    }
}

public enum PolicyRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed, unknownKey(String), badSignature, expired, notYetValid, tooOld, wrongTenant, rollback(seen: Int, got: Int)
    public var description: String {
        switch self {
        case .malformed: "malformed"
        case .unknownKey(let k): "unknownKey:\(k)"
        case .badSignature: "badSignature"
        case .expired: "expired"
        case .notYetValid: "notYetValid"
        case .tooOld: "tooOld"
        case .wrongTenant: "wrongTenant"
        case .rollback(let s, let g): "rollback:\(g)<\(s)"
        }
    }
}

public enum TenantPolicyVerifier {
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Verifies the detached Ed25519 signature (raw 64 bytes or base64 text) over `json` exactly as received,
    /// then validity window, tenant and anti-rollback.
    public static func verify(json: Data, signature: Data, keys: PinnedPolicyKeys, now: Date,
                              minimumVersion: Int = 0) -> Result<SignedTenantPolicy, PolicyRejection> {
        // keyId is read before verification only to select the pinned key; nothing else is trusted until verified.
        guard let doc = try? decoder.decode(SignedTenantPolicy.self, from: json) else { return .failure(.malformed) }
        guard let key = keys.keys[doc.keyId] else { return .failure(.unknownKey(doc.keyId)) }
        let sig: Data
        if signature.count == 64 { sig = signature }
        else if let s = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                let d = Data(base64Encoded: s), d.count == 64 { sig = d }
        else { return .failure(.badSignature) }
        guard key.isValidSignature(sig, for: json) else { return .failure(.badSignature) }
        if let t = keys.tenantId, doc.tenantId?.lowercased() != t.lowercased() { return .failure(.wrongTenant) }
        if doc.issuedAt > now.addingTimeInterval(keys.clockSkew) { return .failure(.notYetValid) }
        if now >= doc.expiresAt { return .failure(.expired) }
        if now.timeIntervalSince(doc.issuedAt) > keys.maxAge { return .failure(.tooOld) }
        if doc.version < minimumVersion { return .failure(.rollback(seen: minimumVersion, got: doc.version)) }
        return .success(doc)
    }
}

// MARK: Loader

public enum PolicySourceKind: String, Codable, Sendable { case managedForced, managedUnforced, tenantSigned, defaults }

public struct PolicySourceReport: Sendable, Equatable {
    public var source: PolicySourceKind
    public var applied: Bool
    /// Why a source or key was ignored (fixed codes; never content).
    public var notes: [String]
    public var keys: [String]
}

public struct LoadedPolicy: Sendable {
    public var policy: TrustPolicy
    public var sources: [PolicySourceReport]
}

public struct PolicyLoader: Sendable {
    public var prefs: ManagedPreferencesReading
    public var pinnedKeys: PinnedPolicyKeys
    public var now: TrustNow
    /// Highest tenant policy version previously applied (anti-rollback); persist it alongside the grace clock.
    public var minimumTenantVersion: Int

    public init(prefs: ManagedPreferencesReading, pinnedKeys: PinnedPolicyKeys, now: @escaping TrustNow = { Date() },
                minimumTenantVersion: Int = 0) {
        self.prefs = prefs; self.pinnedKeys = pinnedKeys; self.now = now; self.minimumTenantVersion = minimumTenantVersion
    }

    /// Merge rule: start from the defaults for the profile (BYOD unless MDM *forces* `profile = managed`), then the
    /// verified tenant file and unforced prefs may only tighten; MDM-forced keys are applied last and may relax.
    public func load(tenantJSON: Data?, tenantSignature: Data?) -> LoadedPolicy {
        var reports: [PolicySourceReport] = []
        let (forced, unforced, prefNotes) = readPrefs()

        let profile: DeviceProfile = forced.profile ?? .byod
        var policy = TrustPolicy.defaults(for: profile)

        // Tenant-signed file.
        var tReport = PolicySourceReport(source: .tenantSigned, applied: false, notes: [], keys: [])
        if let json = tenantJSON, let sig = tenantSignature {
            switch TenantPolicyVerifier.verify(json: json, signature: sig, keys: pinnedKeys, now: now(),
                                               minimumVersion: minimumTenantVersion) {
            case .success(let doc):
                var o = doc.policy
                o.profile = nil // the profile can only come from a forced MDM key
                policy.apply(o, relax: false)
                policy.version = doc.version
                policy.issuedAt = doc.issuedAt
                tReport.applied = true; tReport.keys = o.setKeys
            case .failure(let why):
                tReport.notes.append("rejected:\(why)")
            }
        } else if tenantJSON != nil || tenantSignature != nil {
            tReport.notes.append("rejected:missingPart")
        } else {
            tReport.notes.append("absent")
        }

        // Unforced prefs: the user's own `defaults write` on a BYOD Mac → tighten only.
        var u = unforced; u.profile = nil
        policy.apply(u, relax: false)
        let uKeys = u.setKeys
        reports.append(PolicySourceReport(source: .managedUnforced, applied: !uKeys.isEmpty,
                                          notes: prefNotes.unforced, keys: uKeys))
        reports.append(tReport)

        // Forced MDM keys win, including relaxing.
        policy.apply(forced, relax: true)
        let fKeys = forced.setKeys
        reports.insert(PolicySourceReport(source: .managedForced, applied: !fKeys.isEmpty, notes: prefNotes.forced,
                                          keys: fKeys), at: 0)
        reports.append(PolicySourceReport(source: .defaults, applied: true, notes: [profile.rawValue], keys: []))
        return LoadedPolicy(policy: policy, sources: reports)
    }

    private func readPrefs() -> (TrustPolicyOverlay, TrustPolicyOverlay, (forced: [String], unforced: [String])) {
        var forced = TrustPolicyOverlay(), unforced = TrustPolicyOverlay()
        var notes: (forced: [String], unforced: [String]) = ([], [])
        for key in TrustPolicyOverlay.keys {
            guard let raw = prefs.value(forKey: key) else { continue }
            let isForced = prefs.isForced(key: key)
            // Decode one key at a time so a single bad value doesn't discard the rest.
            guard JSONSerialization.isValidJSONObject([key: raw]),
                  let d = try? JSONSerialization.data(withJSONObject: [key: raw]),
                  let one = try? JSONDecoder().decode(TrustPolicyOverlay.self, from: d), one.setKeys == [key] else {
                if isForced { notes.forced.append("invalid:\(key)") } else { notes.unforced.append("invalid:\(key)") }
                continue
            }
            if isForced { forced = forced.overlaid(with: one) } else { unforced = unforced.overlaid(with: one) }
        }
        return (forced, unforced, notes)
    }
}
