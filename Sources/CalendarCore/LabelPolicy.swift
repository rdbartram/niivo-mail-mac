import Foundation

// MARK: - Purview label policy (default label, mandatory labelling, downgrade justification)
//
// Source of truth: the MIP Policy SDK (`PolicyEngine::GetDefaultSensitivityLabel("email")`, `IsLabelingRequired`,
// `IsDowngradeJustificationRequired`), loaded through the bridge (`nmb_policy_load`, docs/MIP.md). Graph's label list
// carries no policy settings, so without the bridge the app falls back to `.graphFallback`: no default label, no
// mandatory block, no justification prompt (nothing is invented). Pure values + functions; tested in CoreSelfTest.

/// How a label protects content (Policy SDK `Label::Has…Protection()`, 1.18+).
public enum LabelProtectionKind: Int, Sendable, Codable, Equatable {
    case none = 0, template = 1, doNotForward = 2, encryptOnly = 3, adhoc = 4
}

public struct LabelPolicySettings: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable { case mipPolicy, graphFallback }
    /// Default label for new mail (and new meetings: Outlook labels both with the "email" content format).
    public var defaultLabelId: String?
    /// "Users must apply a label to their emails" (IsLabelingRequired("email")).
    public var mandatory: Bool
    /// "Users must provide a justification to remove a label or lower its classification".
    public var justificationRequired: Bool
    /// Per label (lower-cased id) protection kind from the policy; Graph's `hasProtection` covers the fallback.
    public var protection: [String: LabelProtectionKind]
    /// Tenant the policy belongs to (SiteId of msip_labels).
    public var tenantId: String?
    public var source: Source

    public init(defaultLabelId: String? = nil, mandatory: Bool = false, justificationRequired: Bool = false,
                protection: [String: LabelProtectionKind] = [:], tenantId: String? = nil, source: Source = .graphFallback) {
        self.defaultLabelId = defaultLabelId?.isEmpty == true ? nil : defaultLabelId?.lowercased()
        self.mandatory = mandatory; self.justificationRequired = justificationRequired
        self.protection = protection; self.tenantId = tenantId; self.source = source
    }

    /// No policy known: no default, nothing mandatory, no justification.
    public static let graphFallback = LabelPolicySettings()

    /// Parses the bridge's `label_protection` lines ("id\tkind\n").
    public static func parseProtection(_ text: String) -> [String: LabelProtectionKind] {
        var out: [String: LabelProtectionKind] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count == 2, let n = Int(f[1]), let k = LabelProtectionKind(rawValue: n) else { continue }
            out[String(f[0]).lowercased()] = k
        }
        return out
    }
}

/// Why a send / save is refused before anything leaves the Mac.
public enum LabelSendBlock: Sendable, Equatable {
    /// Mandatory labelling and no label chosen.
    case labelRequired
    /// The label encrypts (or is Do Not Forward / Encrypt-Only). niivo can't build an Outlook-compatible protected
    /// message (see docs/MIP.md "Encrypt on send"), so it refuses instead of sending a labelled-but-clear message.
    case encrypts(labelName: String)
    /// The label was lowered or removed and the policy needs a justification first.
    case justificationNeeded

    public var message: String {
        switch self {
        case .labelRequired: "Your organisation requires a sensitivity label. Choose one before sending."
        case .encrypts(let n): "“\(n)” encrypts. niivo can't encrypt mail yet — send it from Outlook."
        case .justificationNeeded: "You lowered or removed the label. Give a reason before sending."
        }
    }
}

public enum LabelGate {
    /// The label a composer starts with: a reply/forward keeps the original's label (floor); otherwise the policy's
    /// default when it's an appliable label the user has. `isDefault` = applied automatically (Method=Standard).
    public static func initialLabel(floorLabelId: String?, settings: LabelPolicySettings, tree: LabelTree)
        -> (id: String?, isDefault: Bool) {
        if let f = floorLabelId, !f.isEmpty { return (f.lowercased(), false) }
        if let d = settings.defaultLabelId, tree.isSelectable(d) { return (d, true) }
        return (nil, false)
    }

    /// Lowering or removing a label. Sub-labels of one parent rank equal (sibling swap isn't a downgrade, as in
    /// `MailLabelFloor`). A move to an unknown label from a known one counts as a downgrade (fail closed).
    public static func isDowngrade(from old: String?, to new: String?, tree: LabelTree) -> Bool {
        guard let o = old?.lowercased(), !o.isEmpty else { return false }
        guard let n = new?.lowercased(), !n.isEmpty else { return true }
        if o == n { return false }
        guard let or = tree.floorRank(o) else { return false }   // baseline unknown to the policy: can't compare
        guard let nr = tree.floorRank(n) else { return true }
        return nr < or
    }

    /// Does this label encrypt? Policy kind when known, else Graph's `hasProtection`.
    public static func protection(of id: String?, settings: LabelPolicySettings, tree: LabelTree) -> LabelProtectionKind {
        guard let id = id?.lowercased(), !id.isEmpty else { return .none }
        if let k = settings.protection[id] { return k }
        return tree.label(id)?.hasProtection == true ? .template : .none
    }

    /// The send gate, in the order the user should fix things.
    /// `baseline` = the label the draft started with (default, reopened draft or reply floor).
    public static func sendBlock(labelId: String?, baseline: String?, justification: String?,
                                 settings: LabelPolicySettings, tree: LabelTree) -> LabelSendBlock? {
        let id = labelId?.lowercased()
        if settings.mandatory, id == nil || id?.isEmpty == true { return .labelRequired }
        if protection(of: id, settings: settings, tree: tree) != .none {
            return .encrypts(labelName: tree.label(id)?.name ?? "This label")
        }
        if settings.justificationRequired, isDowngrade(from: baseline, to: id, tree: tree),
           (justification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            return .justificationNeeded
        }
        return nil
    }
}

// MARK: - msip_labels value

/// Builds the `msip_labels` value written on outgoing mail and new meetings.
/// Format (learn.microsoft.com/information-protection/develop/concept-mip-metadata#email): all
/// `MSIP_Label_<guid>_<Attribute>=value` pairs in one header, delimited by "; ". Enabled and SiteId are mandatory;
/// Method is Privileged for a user's pick, Standard for a default; SetDate is extended ISO 8601; ContentBits only
/// states what niivo really did (no header/footer/watermark text is inserted into the body and nothing is encrypted,
/// so 0). ActionId was removed in MIP SDK 1.8 and isn't written.
public struct LabelMetadata: Sendable, Equatable {
    public var entries: [(key: String, value: String)]
    public init(entries: [(key: String, value: String)]) { self.entries = entries }

    public static func == (a: LabelMetadata, b: LabelMetadata) -> Bool {
        a.entries.map { "\($0.key)=\($0.value)" } == b.entries.map { "\($0.key)=\($0.value)" }
    }

    /// Hand-built fallback when the Policy SDK isn't available. nil without a tenant (SiteId is mandatory).
    public static func build(labelId: String, tenantId: String?, privileged: Bool, setDate: Date,
                             name: String? = nil) -> LabelMetadata? {
        guard let tid = tenantId?.lowercased(), !tid.isEmpty else { return nil }
        let p = "MSIP_Label_\(labelId.lowercased())_"
        var e: [(key: String, value: String)] = [(p + "Enabled", "true"), (p + "SetDate", iso(setDate)),
                                                 (p + "Method", privileged ? "Privileged" : "Standard")]
        if let n = name, !n.isEmpty { e.append((p + "Name", n)) }
        e.append((p + "SiteId", tid))
        e.append((p + "ContentBits", "0"))
        return LabelMetadata(entries: e)
    }

    /// From the bridge's `metadata_add` ("key=value\n").
    public static func parse(lines: String) -> LabelMetadata {
        LabelMetadata(entries: lines.split(separator: "\n").compactMap { l in
            guard let eq = l.firstIndex(of: "="), eq != l.startIndex else { return nil }
            return (String(l[..<eq]), String(l[l.index(after: eq)...]))
        })
    }

    /// The header value: "; "-delimited.
    public var headerValue: String { entries.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }

    /// "key=value\n" lines for the bridge (`existing_metadata`).
    public static func lines(fromHeader raw: String) -> String {
        raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("=") }
            .joined(separator: "\n")
    }

    /// Extended ISO 8601 with a numeric offset, as in Learn's example (2018-11-08T21:13:16-0800).
    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f.string(from: d)
    }
}

// MARK: - Seam for the Policy SDK

/// What the Policy SDK says about applying a label to one outgoing item.
public struct LabelPlan: Sendable, Equatable {
    public var metadata: LabelMetadata
    public var needsJustification: Bool
    public var appliesProtection: Bool
    public var committed: Bool
    public init(metadata: LabelMetadata, needsJustification: Bool = false, appliesProtection: Bool = false,
                committed: Bool = false) {
        self.metadata = metadata; self.needsJustification = needsJustification
        self.appliesProtection = appliesProtection; self.committed = committed
    }
}

/// Implemented over the bridge in ProtectedContent (`MIPLabelPolicyProvider`); a stub in CoreSelfTest.
public protocol LabelPolicyProvider: Sendable {
    func loadPolicy() async throws -> LabelPolicySettings
    /// `commit` = record the change in Purview (NotifyCommittedActions → audit, including `justification`).
    func plan(labelId: String?, existingHeader: String?, privileged: Bool, justification: String?,
              contentId: String, commit: Bool) async throws -> LabelPlan
}


// MARK: - The stamp must never break sending / saving

/// If Graph refuses the msip_labels extended property (400/422 naming it), the write is retried once without it,
/// the rejection is remembered for the session (later writes skip the stamp straight away), a content-free line
/// `[Purview] stamp rejected status=<code>` is logged and `onRejected` tells the app (toast).
public enum LabelStampGuard {
    nonisolated(unsafe) private static var _rejected = false
    nonisolated(unsafe) private static var _onRejected: (@Sendable (Int) -> Void)?
    private static let lock = NSLock()

    public static var isRejected: Bool { lock.withLock { _rejected } }
    public static var onRejected: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onRejected } }
        set { lock.withLock { _onRejected = newValue } }
    }

    /// 400/422 whose error text names the extended property or msip_labels.
    public static func isRejection(status: Int, message: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let m = message.lowercased()
        return m.contains("extendedpropert") || m.contains("extended property") || m.contains("msip") || m.contains("singlevalue")
    }

    public static func noteRejected(status: Int) {
        lock.withLock { _rejected = true }
        FileHandle.standardError.write(Data("[Purview] stamp rejected status=\(status)\n".utf8))
        onRejected?(status)
    }

    /// Tests / sign-out.
    public static func resetForSession() { lock.withLock { _rejected = false } }

    /// Removes the label property from a JSON body (event POST). nil if the body has none.
    public static func stripped(_ body: Data) -> Data? {
        guard var j = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              j["singleValueExtendedProperties"] != nil else { return nil }
        j["singleValueExtendedProperties"] = nil
        return try? JSONSerialization.data(withJSONObject: j)
    }
}
