import Foundation

// MARK: - Where a message's label came from (foreign-tenant labels, 2026-11-20)
//
// `MIPMetadata.activeLabelId` keeps the label of *our* tenant and ignores other organisations' labels (SiteId ≠ home
// tenant). That alone isn't enough to keep foreign labels off screen: a label without a SiteId, a label parsed while
// the home tenant wasn't known yet, or a row cached before the v2 parser still reaches the UI as an id that isn't in
// our label tree — and the UI used to render any such id as a red "Unknown label — restricted" chip/banner with the
// raw GUID. The display rule below decides what is shown; the policy (fail closed for unknown ids) is unchanged.

/// Provenance of `labelId` on a message, recorded at parse time. nil on rows cached before it existed.
public enum LabelOrigin: String, Codable, Sendable, Hashable {
    /// `SiteId` equals the signed-in tenant: provably ours.
    case home
    /// Enabled label without a `SiteId` (can't tell whose it is; kept so an id that IS in our tree still applies).
    case noSite
    /// Parsed before the home tenant was known: the first enabled label, unverified.
    case tenantUnknown
    /// Only another organisation's label(s) were present; ignored, `labelId` is nil.
    case foreign
    /// As `foreign`, and that label's metadata says it applies encryption (ContentBits & 0x8).
    case foreignProtected
}

/// Result of reading one `msip_labels` value.
public struct LabelReading: Sendable, Equatable {
    public var labelId: String?
    public var origin: LabelOrigin?
    public init(labelId: String?, origin: LabelOrigin?) { self.labelId = labelId; self.origin = origin }
    public static let none = LabelReading(labelId: nil, origin: nil)
}

extension MIPMetadata {
    /// Parses `MSIP_Label_<guid>_Enabled=true; MSIP_Label_<guid>_SiteId=<tenant>; …` with provenance.
    /// Our tenant's label wins; then a label without SiteId; foreign labels are never returned.
    public static func read(_ raw: String?, homeTenant: String? = homeTenantId) -> LabelReading {
        guard let raw, !raw.isEmpty else { return .none }
        var enabled: [String] = [], site: [String: String] = [:], bits: [String: Int] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kv.hasPrefix("MSIP_Label_"), let eq = kv.firstIndex(of: "=") else { continue }
            let key = kv[kv.index(kv.startIndex, offsetBy: "MSIP_Label_".count)..<eq]
            let value = kv[kv.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let us = key.lastIndex(of: "_") else { continue }
            let guid = key[..<us].lowercased(), field = key[key.index(after: us)...].lowercased()
            if field == "enabled", value.lowercased() == "true", !enabled.contains(guid) { enabled.append(guid) }
            if field == "siteid" { site[guid] = normaliseTenant(value) }
            if field == "contentbits" { bits[guid] = Int(value) ?? Int(value.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        }
        guard !enabled.isEmpty else { return .none }
        guard let home = homeTenant.map(normaliseTenant), !home.isEmpty else {
            return LabelReading(labelId: enabled[0], origin: .tenantUnknown)
        }
        if let ours = enabled.first(where: { site[$0] == home }) { return LabelReading(labelId: ours, origin: .home) }
        if let bare = enabled.first(where: { site[$0] == nil }) { return LabelReading(labelId: bare, origin: .noSite) }
        // ContentBits 0x8 = encryption (UNVERIFIED: from memory of the MIP metadata format, not looked up). Used for
        // the census only; protection itself is detected from the content (rpmsg), never from this.
        let enc = enabled.contains { (bits[$0] ?? 0) & 0x8 != 0 }
        return LabelReading(labelId: nil, origin: enc ? .foreignProtected : .foreign)
    }

    static func normaliseTenant(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).lowercased()
    }
}

// MARK: - Display rule

/// What the UI shows for a message's label. Pure; the policy is computed separately and never loosened by this.
public enum LabelDisplay: Sendable, Equatable {
    /// A label from our tree: chip / banner with its name.
    case ours(SensitivityLabel)
    /// Provably our tenant's label but not in the synced tree: the honest "unknown label — restricted" state.
    case unknownOurs(id: String)
    /// Not in our tree and not proven ours (foreign, no SiteId, cached before v2): no chip; the reader's notice line
    /// says "External label". Policy stays fail-closed (AI excluded, nothing cached, capture blocked).
    case external
    /// Another organisation protected it: rights still come from its licence; shown as such, never as a label.
    case protectedElsewhere
    case none

    public static func decide(_ policy: ContentPolicy, origin: LabelOrigin?) -> LabelDisplay {
        switch policy.labelState {
        case .labeled(let l): return .ours(l)
        case .unknown(let id):
            return origin == .home ? .unknownOurs(id: id) : .external
        case .unlabeled:
            if origin == .foreign || origin == .foreignProtected, policy.bodyIsProtected { return .protectedElsewhere }
            return .none
        }
    }

    /// Something to put in the list row's label slot.
    public var showsChip: Bool {
        switch self { case .ours, .unknownOurs: true; default: false }
    }

    /// The synthetic marking the policy engine puts on an unknown id (Compliance.swift). Not a tenant marking.
    public static let unknownMarking = "Sensitivity label unavailable offline — restricted"

    /// The header marking to render: the tenant's own text always; the synthetic "unknown label" one only when the id
    /// is provably ours (otherwise it would present a foreign label as one of ours).
    public static func visibleMarking(_ p: ContentPolicy, origin: LabelOrigin?) -> String? {
        guard let h = p.headerMarking else { return nil }
        if h == unknownMarking, decide(p, origin: origin) == .external { return nil }
        return h
    }

    /// Short text for the reader's notice line (nil = nothing to say).
    public var noticeText: String? {
        switch self {
        case .external: "External label"
        case .protectedElsewhere: "Protected by another organisation"
        default: nil
        }
    }
}

// MARK: - Diagnostics

/// Content-free label census over cached rows (counts only; never ids, subjects or senders).
public struct LabelCensus: Sendable, Equatable {
    public var rows = 0, ours = 0, foreignIgnored = 0, noSite = 0, unknownId = 0, rpmsgForeign = 0
    public init() {}

    /// `known`: lower-cased ids of our label tree.
    public mutating func add(labelId: String?, origin: LabelOrigin?, known: Set<String>) {
        rows += 1
        switch origin {
        case .foreign: foreignIgnored += 1
        case .foreignProtected: foreignIgnored += 1; rpmsgForeign += 1
        case .noSite: noSite += 1
        default: break
        }
        guard let id = labelId?.lowercased(), !id.isEmpty else { return }
        if known.contains(id) { ours += 1 } else { unknownId += 1 }
    }

    public var logLine: String {
        "[Labels] rows=\(rows) ours=\(ours) foreignIgnored=\(foreignIgnored) noSite=\(noSite) unknownId=\(unknownId) rpmsgForeign=\(rpmsgForeign)"
    }
}

extension MIPMetadata {
    /// `tid` claim of an Entra access token (payload only, no signature check; used solely to tell our labels from
    /// other organisations' in processes without MSAL, e.g. OfficeMCP). nil if it isn't a readable JWT.
    public static func tenantId(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid = obj["tid"] as? String, !tid.isEmpty else { return nil }
        return tid.lowercased()
    }
}
