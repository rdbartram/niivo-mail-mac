import Foundation

public enum DeviceProfile: String, Codable, Sendable, CaseIterable {
    case managed, byod
}

/// How much AI/MCP clients may see. Ordered strictest first.
public enum TrustAIAccess: String, Codable, Sendable, CaseIterable, Comparable {
    case off, metadataOnly, followLabels
    var rank: Int { switch self { case .off: 0; case .metadataOnly: 1; case .followLabels: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct AppLockPolicy: Codable, Sendable, Equatable {
    /// When true the app locks and needs LocalAuthentication (Touch ID or the Mac password) to unlock.
    public var requireBiometric: Bool
    /// Lock after this many idle minutes (0 = lock only on sleep, launch and policy change).
    public var idleMinutes: Int
    public init(requireBiometric: Bool, idleMinutes: Int) {
        self.requireBiometric = requireBiometric; self.idleMinutes = idleMinutes
    }
}

/// Dotted numeric OS version, compared numerically ("15.10" > "15.9").
public struct OSVersion: Codable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }
    public init?(_ s: String) {
        let p = s.split(separator: ".").map { Int($0) }
        guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.init(p[0]!, p.count > 1 ? p[1]! : 0, p.count > 2 ? p[2]! : 0)
    }
    public init(_ v: OperatingSystemVersion) { self.init(v.majorVersion, v.minorVersion, v.patchVersion) }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = OSVersion(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad OS version")) }
        self = v
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

/// The effective trust policy. Produced by `PolicyLoader` from managed prefs, the tenant-signed file and defaults.
public struct TrustPolicy: Codable, Sendable, Equatable {
    public var profile: DeviceProfile
    /// Max mail/calendar header window kept offline, in days.
    public var cacheWindowMaxDays: Int
    public var allowOfflineBodies: Bool
    /// Offline bodies for labelled (non-public) items; only meaningful when `allowOfflineBodies`.
    public var allowOfflineBodiesForLabelled: Bool
    public var allowAttachmentsDownload: Bool
    /// Apps that attachments may be opened in. Empty = none.
    public var approvedOpenInBundleIds: [String]
    public var allowPrint: Bool
    public var allowCopyOut: Bool
    public var allowScreenCapture: Bool
    public var appLock: AppLockPolicy
    /// No successful token refresh for this many days → app locks.
    public var offlineGraceDays: Int
    /// No successful token refresh for this many days → app wipes.
    public var offlineWipeDays: Int
    public var minimumOSVersion: OSVersion
    public var requireFileVault: Bool
    public var requireSIP: Bool
    public var requireScreenLock: Bool
    /// Entra group object id; membership (transitive) means wipe. Must not be a hidden-membership group: Graph
    /// omits those from checkMemberGroups for delegated callers who aren't members.
    public var wipeGroupId: String?
    /// How often the wipe group is checked while a wipe group is set (minutes). nil → `defaultWipeGroupCheckMinutes`.
    /// Shorter is stricter; values below `minimumWipeGroupCheckMinutes` are raised to it (0 never means "never").
    /// Optional so policies encoded before this key existed still decode.
    public var wipeGroupCheckMinutes: Int?
    public var blockExternalForwardRules: Bool
    public var aiAccess: TrustAIAccess
    /// On-device AI (Apple FoundationModels: content never leaves the Mac). nil → follows `aiAccess`.
    /// `aiAccess == .off` is the master switch: it turns on-device AI off too.
    public var onDeviceAIAccess: TrustAIAccess?
    /// AI providers the app may use ("on-device", "claude-cli", "openai-compatible"). nil → any.
    public var allowedAIProviders: [String]?
    public var version: Int
    public var issuedAt: Date?

    public init(profile: DeviceProfile, cacheWindowMaxDays: Int, allowOfflineBodies: Bool, allowOfflineBodiesForLabelled: Bool,
                allowAttachmentsDownload: Bool, approvedOpenInBundleIds: [String], allowPrint: Bool, allowCopyOut: Bool,
                allowScreenCapture: Bool, appLock: AppLockPolicy, offlineGraceDays: Int, offlineWipeDays: Int,
                minimumOSVersion: OSVersion, requireFileVault: Bool, requireSIP: Bool, requireScreenLock: Bool,
                wipeGroupId: String?, blockExternalForwardRules: Bool, aiAccess: TrustAIAccess, version: Int, issuedAt: Date?,
                onDeviceAIAccess: TrustAIAccess? = nil, allowedAIProviders: [String]? = nil, wipeGroupCheckMinutes: Int? = nil) {
        self.profile = profile; self.cacheWindowMaxDays = cacheWindowMaxDays; self.allowOfflineBodies = allowOfflineBodies
        self.allowOfflineBodiesForLabelled = allowOfflineBodiesForLabelled; self.allowAttachmentsDownload = allowAttachmentsDownload
        self.approvedOpenInBundleIds = approvedOpenInBundleIds; self.allowPrint = allowPrint; self.allowCopyOut = allowCopyOut
        self.allowScreenCapture = allowScreenCapture; self.appLock = appLock; self.offlineGraceDays = offlineGraceDays
        self.offlineWipeDays = offlineWipeDays; self.minimumOSVersion = minimumOSVersion; self.requireFileVault = requireFileVault
        self.requireSIP = requireSIP; self.requireScreenLock = requireScreenLock; self.wipeGroupId = wipeGroupId
        self.blockExternalForwardRules = blockExternalForwardRules; self.aiAccess = aiAccess; self.version = version
        self.issuedAt = issuedAt
        self.onDeviceAIAccess = onDeviceAIAccess; self.allowedAIProviders = allowedAIProviders
        self.wipeGroupCheckMinutes = wipeGroupCheckMinutes
    }

    public static let defaultWipeGroupCheckMinutes = 60
    public static let minimumWipeGroupCheckMinutes = 5
    /// The wipe-group cadence actually used (minutes).
    public var effectiveWipeGroupCheckMinutes: Int {
        max(Self.minimumWipeGroupCheckMinutes, wipeGroupCheckMinutes ?? Self.defaultWipeGroupCheckMinutes)
    }

    /// Effective on-device level (see `onDeviceAIAccess`).
    public var effectiveOnDeviceAIAccess: TrustAIAccess { aiAccess == .off ? .off : (onDeviceAIAccess ?? aiAccess) }

    /// Unmanaged Mac: strict.
    public static let byodDefault = TrustPolicy(
        profile: .byod, cacheWindowMaxDays: 30, allowOfflineBodies: true, allowOfflineBodiesForLabelled: false,
        // Attachments open/save by default (Ryan, 2026-11-19); label EXTRACT/PRINT still gate each item and a
        // tenant-signed policy can switch this off.
        allowAttachmentsDownload: true, approvedOpenInBundleIds: ["com.apple.Preview", "com.microsoft.Word",
                                                                 "com.microsoft.Excel", "com.microsoft.Powerpoint"],
        // Copy, print and screen capture follow Purview usage rights per item (EXTRACT / PRINT), not a blanket
        // device rule (Ryan, 2026-11-19). A tenant-signed policy can still switch them off.
        allowPrint: true, allowCopyOut: true, allowScreenCapture: true, appLock: .init(requireBiometric: true, idleMinutes: 5), offlineGraceDays: 3,
        offlineWipeDays: 14, minimumOSVersion: OSVersion(15), requireFileVault: true, requireSIP: true,
        requireScreenLock: true, wipeGroupId: nil, blockExternalForwardRules: true,
        // AI follows the labels, like copy/print/capture (Ryan, 2026-11-19: metadata-only made the AI help useless).
        // Content goes to AI only where the label allows it (EXTRACT for encrypted mail, label priority cap for cloud,
        // unknown/private excluded). A tenant-signed policy can still lower this; posture `.restrict` caps it.
        aiAccess: .followLabels,
        version: 0, issuedAt: nil,
        onDeviceAIAccess: nil)

    /// MDM-managed Mac: the device is already governed, so the app relaxes.
    public static let managedDefault = TrustPolicy(
        profile: .managed, cacheWindowMaxDays: 365, allowOfflineBodies: true, allowOfflineBodiesForLabelled: true,
        allowAttachmentsDownload: true, approvedOpenInBundleIds: ["com.apple.Preview", "com.microsoft.Word",
                                                                 "com.microsoft.Excel", "com.microsoft.Powerpoint"],
        allowPrint: true, allowCopyOut: true, allowScreenCapture: true, appLock: .init(requireBiometric: false, idleMinutes: 0),
        offlineGraceDays: 14, offlineWipeDays: 60, minimumOSVersion: OSVersion(15), requireFileVault: true,
        requireSIP: true, requireScreenLock: false, wipeGroupId: nil, blockExternalForwardRules: true,
        aiAccess: .followLabels, version: 0, issuedAt: nil)

    public static func defaults(for profile: DeviceProfile) -> TrustPolicy { profile == .byod ? .byodDefault : .managedDefault }

    /// Field-by-field strictest combination of two policies.
    public func stricter(_ o: TrustPolicy) -> TrustPolicy {
        var r = self
        r.apply(TrustPolicyOverlay(o), relax: false)
        r.version = max(version, o.version)
        return r
    }

    /// Posture `.restrict` tightens the policy: nothing new leaves the app and nothing sensitive is kept offline.
    public func restrictedForPosture() -> TrustPolicy {
        var r = self
        r.allowOfflineBodiesForLabelled = false
        r.allowAttachmentsDownload = false
        r.approvedOpenInBundleIds = []
        r.allowPrint = false; r.allowCopyOut = false; r.allowScreenCapture = false
        r.aiAccess = min(r.aiAccess, .metadataOnly)
        r.onDeviceAIAccess = min(r.effectiveOnDeviceAIAccess, .metadataOnly)
        return r
    }

    /// Applies the overlay's set keys. `relax == false` → stricter wins per field; `true` → overlay replaces
    /// (only for MDM-forced managed preferences).
    public mutating func apply(_ o: TrustPolicyOverlay, relax: Bool) {
        func allow(_ cur: inout Bool, _ v: Bool?) { if let v { cur = relax ? v : (cur && v) } }
        func require(_ cur: inout Bool, _ v: Bool?) { if let v { cur = relax ? v : (cur || v) } }
        func lower(_ cur: inout Int, _ v: Int?) { if let v { cur = relax ? max(0, v) : min(cur, max(0, v)) } }
        if let v = o.profile { profile = relax ? v : (profile == .byod || v == .byod ? .byod : .managed) }
        lower(&cacheWindowMaxDays, o.cacheWindowMaxDays)
        allow(&allowOfflineBodies, o.allowOfflineBodies)
        allow(&allowOfflineBodiesForLabelled, o.allowOfflineBodiesForLabelled)
        allow(&allowAttachmentsDownload, o.allowAttachmentsDownload)
        if let v = o.approvedOpenInBundleIds {
            approvedOpenInBundleIds = relax ? v : approvedOpenInBundleIds.filter { Set(v).contains($0) }
        }
        allow(&allowPrint, o.allowPrint)
        allow(&allowCopyOut, o.allowCopyOut)
        allow(&allowScreenCapture, o.allowScreenCapture)
        require(&appLock.requireBiometric, o.appLockRequireBiometric)
        if let v = o.appLockIdleMinutes {
            // 0 means "no idle lock", the most permissive value, so it only wins when relaxing.
            let v = max(0, v)
            if relax { appLock.idleMinutes = v }
            else if v > 0 { appLock.idleMinutes = appLock.idleMinutes == 0 ? v : min(appLock.idleMinutes, v) }
        }
        lower(&offlineGraceDays, o.offlineGraceDays)
        lower(&offlineWipeDays, o.offlineWipeDays)
        if let v = o.minimumOSVersion { minimumOSVersion = relax ? v : max(minimumOSVersion, v) }
        require(&requireFileVault, o.requireFileVault)
        require(&requireSIP, o.requireSIP)
        require(&requireScreenLock, o.requireScreenLock)
        // A wipe group is a control; a second source can add one but only forced MDM can remove or replace it.
        if let v = o.wipeGroupId { if relax || wipeGroupId == nil { wipeGroupId = v.isEmpty ? nil : v } }
        if let v = o.wipeGroupCheckMinutes {
            let v = max(Self.minimumWipeGroupCheckMinutes, v)
            wipeGroupCheckMinutes = relax ? v : min(effectiveWipeGroupCheckMinutes, v)
        }
        require(&blockExternalForwardRules, o.blockExternalForwardRules)
        let onDeviceBefore = effectiveOnDeviceAIAccess
        if let v = o.aiAccess { aiAccess = relax ? v : min(aiAccess, v) }
        if let v = o.onDeviceAIAccess { onDeviceAIAccess = relax ? v : min(onDeviceBefore, v) }
        if let v = o.allowedAIProviders {
            allowedAIProviders = relax ? v : (allowedAIProviders.map { cur in cur.filter { Set(v).contains($0) } } ?? v)
        }
        if offlineWipeDays < offlineGraceDays { offlineWipeDays = offlineGraceDays }
    }
}

/// A policy source's settings: every key optional, flat (so it maps 1:1 onto managed-preference keys and the
/// tenant JSON). Unknown keys are ignored; a key with the wrong type is rejected by `PolicyLoader` per key.
public struct TrustPolicyOverlay: Codable, Sendable, Equatable {
    public var profile: DeviceProfile?
    public var cacheWindowMaxDays: Int?
    public var allowOfflineBodies: Bool?
    public var allowOfflineBodiesForLabelled: Bool?
    public var allowAttachmentsDownload: Bool?
    public var approvedOpenInBundleIds: [String]?
    public var allowPrint: Bool?
    public var allowCopyOut: Bool?
    public var allowScreenCapture: Bool?
    public var appLockRequireBiometric: Bool?
    public var appLockIdleMinutes: Int?
    public var offlineGraceDays: Int?
    public var offlineWipeDays: Int?
    public var minimumOSVersion: OSVersion?
    public var requireFileVault: Bool?
    public var requireSIP: Bool?
    public var requireScreenLock: Bool?
    public var wipeGroupId: String?
    public var wipeGroupCheckMinutes: Int?
    public var blockExternalForwardRules: Bool?
    public var aiAccess: TrustAIAccess?
    public var onDeviceAIAccess: TrustAIAccess?
    public var allowedAIProviders: [String]?

    public init() {}
    public init(_ p: TrustPolicy) {
        profile = p.profile; cacheWindowMaxDays = p.cacheWindowMaxDays; allowOfflineBodies = p.allowOfflineBodies
        allowOfflineBodiesForLabelled = p.allowOfflineBodiesForLabelled; allowAttachmentsDownload = p.allowAttachmentsDownload
        approvedOpenInBundleIds = p.approvedOpenInBundleIds; allowPrint = p.allowPrint; allowCopyOut = p.allowCopyOut
        allowScreenCapture = p.allowScreenCapture; appLockRequireBiometric = p.appLock.requireBiometric
        appLockIdleMinutes = p.appLock.idleMinutes; offlineGraceDays = p.offlineGraceDays; offlineWipeDays = p.offlineWipeDays
        minimumOSVersion = p.minimumOSVersion; requireFileVault = p.requireFileVault; requireSIP = p.requireSIP
        requireScreenLock = p.requireScreenLock; wipeGroupId = p.wipeGroupId; blockExternalForwardRules = p.blockExternalForwardRules
        wipeGroupCheckMinutes = p.wipeGroupCheckMinutes
        aiAccess = p.aiAccess
        onDeviceAIAccess = p.onDeviceAIAccess; allowedAIProviders = p.allowedAIProviders
    }

    /// Managed-preference / JSON key names.
    public static let keys: [String] = [
        "profile", "cacheWindowMaxDays", "allowOfflineBodies", "allowOfflineBodiesForLabelled", "allowAttachmentsDownload",
        "approvedOpenInBundleIds", "allowPrint", "allowCopyOut", "allowScreenCapture", "appLockRequireBiometric",
        "appLockIdleMinutes", "offlineGraceDays", "offlineWipeDays", "minimumOSVersion", "requireFileVault", "requireSIP",
        "requireScreenLock", "wipeGroupId", "wipeGroupCheckMinutes", "blockExternalForwardRules", "aiAccess", "onDeviceAIAccess", "allowedAIProviders",
    ]

    public var setKeys: [String] {
        guard let d = try? JSONEncoder().encode(self),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return Self.keys.filter { o[$0] != nil }
    }

    /// Field-wise union, `other` winning where both are set.
    func overlaid(with other: TrustPolicyOverlay) -> TrustPolicyOverlay {
        guard let a = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
              let b = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as? [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: a.merging(b) { _, n in n }),
              let r = try? JSONDecoder().decode(TrustPolicyOverlay.self, from: d) else { return self }
        return r
    }
}
