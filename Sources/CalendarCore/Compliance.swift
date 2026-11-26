import Foundation

// MARK: - Usage rights (Azure Rights Management / Purview)

/// The Rights Management usage rights a user holds on one item. The app does not invent copy/print rules; it honours
/// these, as Outlook does.
///
/// Names and meanings: "Configure usage rights for the Azure Rights Management service"
/// https://learn.microsoft.com/purview/rights-management-usage-rights#usage-rights-and-descriptions
///  * VIEW: open and read. EDIT ("Save"): save to the current location. DOCEDIT ("Edit Content, Edit"): modify content
///    in the app, not save it.
///  * EXTRACT ("Copy"): copy data, *including screen captures*, into another item. In Copilot and other AI apps it
///    also allows the LLM to access and summarise the content.
///  * PRINT: print. EXPORT ("Save As, Export"): save under another name or export, e.g. Send to OneNote.
///  * FORWARD / REPLY / REPLYALL: the email actions. OWNER ("Full Control"): every right.
///  * OBJMODEL ("Allow Macros"): programmatic access. VIEWRIGHTSDATA / EDITRIGHTSDATA: see / change the policy.
///  * COMMENT: annotations. Not supported by Office, but Graph's `usageRights` enum returns it.
/// Graph's enum (same names in camelCase): https://learn.microsoft.com/graph/api/resources/usagerights?view=graph-rest-1.0
public struct UsageRights: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let view           = UsageRights(rawValue: 1 << 0)
    public static let edit           = UsageRights(rawValue: 1 << 1)
    public static let docEdit        = UsageRights(rawValue: 1 << 2)
    public static let extract        = UsageRights(rawValue: 1 << 3)
    public static let print          = UsageRights(rawValue: 1 << 4)
    public static let export         = UsageRights(rawValue: 1 << 5)
    public static let forward        = UsageRights(rawValue: 1 << 6)
    public static let reply          = UsageRights(rawValue: 1 << 7)
    public static let replyAll       = UsageRights(rawValue: 1 << 8)
    public static let owner          = UsageRights(rawValue: 1 << 9)
    public static let objModel       = UsageRights(rawValue: 1 << 10)
    public static let viewRightsData = UsageRights(rawValue: 1 << 11)
    public static let editRightsData = UsageRights(rawValue: 1 << 12)
    public static let comment        = UsageRights(rawValue: 1 << 13)

    public static let all: UsageRights = [.view, .edit, .docEdit, .extract, .print, .export, .forward, .reply, .replyAll,
                                          .owner, .objModel, .viewRightsData, .editRightsData, .comment]
    /// Fail-closed set for encrypted content whose rights we can't determine.
    public static let viewOnly: UsageRights = [.view]
    /// Label unknown to the synced policy: as before this change, copy/export (and now print) are blocked, but the
    /// mail actions stay available. A tenant where the label list 403s would otherwise lose reply/forward on every
    /// labelled message indefinitely.
    public static let unknownLabel: UsageRights = all.subtracting([.extract, .export, .print, .owner, .editRightsData])

    /// RMS policy encoding (EXTRACT, REPLYALL, …) ↔ right.
    public static let encodings: [(String, UsageRights)] = [
        ("VIEW", .view), ("EDIT", .edit), ("DOCEDIT", .docEdit), ("EXTRACT", .extract), ("PRINT", .print),
        ("EXPORT", .export), ("FORWARD", .forward), ("REPLY", .reply), ("REPLYALL", .replyAll), ("OWNER", .owner),
        ("OBJMODEL", .objModel), ("VIEWRIGHTSDATA", .viewRightsData), ("EDITRIGHTSDATA", .editRightsData),
        ("COMMENT", .comment),
    ]

    /// OWNER ("Full Control") grants all rights to the item, so expand it. Without this a bare `owner` would block copy.
    public var normalized: UsageRights { contains(.owner) ? .all : self }

    /// Parses Graph's `usageRightsIncluded.value`. The example response is a comma-separated string
    /// (`"docEdit, edit, forward, …"`), while the enum page says callers see a list of names, so both shapes are accepted.
    /// Matching is case-insensitive (`replyAll` = `REPLYALL`). Unknown tokens and error sentinels (`accessDenied`,
    /// `labelNotFoundException`, `unknown`, …) are ignored and grant nothing. Returns nil when nothing parsed.
    public static func parse(_ tokens: [String]) -> UsageRights? {
        let map = Dictionary(encodings.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        var r: UsageRights = []
        var any = false
        for raw in tokens.flatMap({ $0.split(separator: ",") }) {
            let t = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if let right = map[t] { r.insert(right); any = true }
        }
        return any ? r.normalized : nil
    }
    public static func parse(_ value: String) -> UsageRights? { parse([value]) }

    public var names: [String] { Self.encodings.filter { contains($0.1) }.map(\.0) }
}

/// Per-item licence rights from the MIP Protection SDK (`ProtectionHandler::AccessCheck` on the item's publishing
/// licence). This is the authoritative source: Learn notes that an item's usage rights can differ from its label's
/// configuration, e.g. when encryption was applied before or after the label
/// (https://learn.microsoft.com/purview/ai-m365-copilot-considerations#information-protection-considerations-for-microsoft-365-copilot).
///
/// Production conformer: `LicenceRightsStore` (LicenceRights.swift), filled by the `ProtectedContent` decrypt path
/// (MIP File SDK, docs/MIP.md) behind a setting that defaults off. Until an item has been decrypted in this session
/// it returns nil, so resolution falls through to the label's Graph rights, then to the fallback.
public protocol ItemRightsProvider: Sendable {
    /// nil = no licence information for this item (not encrypted, or not evaluated). A non-nil value means the item is
    /// encrypted and these are the signed-in user's rights on it.
    func rights(itemId: String, labelId: String?) -> UsageRights?
}

// MARK: - Content policy

/// What the UI and storage layers are allowed to do with one event.
/// Everything downstream (views, pasteboard, cache writer, window) reads ONLY this — never the label directly.
public struct ContentPolicy: Sendable, Hashable {
    public enum LabelState: Sendable, Hashable {
        case unlabeled
        case labeled(SensitivityLabel)
        /// Item carries a label ID we have no definition for (policy not synced, label deleted or out of scope).
        case unknown(id: String)
    }

    /// Where `rights` came from (resolution order, most authoritative first).
    public enum RightsSource: String, Sendable, Hashable {
        /// Per-item licence from the MIP SDK.
        case itemLicence
        /// The label's rights for this user, from Graph `sensitivityLabel/rights`.
        case label
        /// No encryption → Purview imposes no usage restrictions (markings still apply).
        case unencrypted
        /// Encrypted, rights unknown → VIEW only.
        case encryptedUnknown
        /// Label unknown to the synced policy → no copy/export/print (fail closed, as before).
        case unknownLabel
    }

    public var labelState: LabelState
    /// Hide subject/body/attendees (legacy `private` flag on someone else's calendar).
    public var redactDetails: Bool
    /// Body is RMS-encrypted; we cannot render it without the MIP Protection SDK.
    public var bodyIsProtected: Bool
    /// The user's usage rights on this item. Copy/print/export/forward/reply decisions derive from this alone.
    public var rights: UsageRights
    public var rightsSource: RightsSource
    /// May the body/attendees be written to the local cache at all.
    public var allowOfflineDetails: Bool
    /// Ask the window server to exclude our window from screenshots/screen sharing.
    public var preventScreenCapture: Bool
    public var headerMarking: String?
    public var footerMarking: String?
    public var watermark: String?

    /// Copy (EXTRACT).
    public var allowCopy: Bool { rights.contains(.extract) }
    /// Print (PRINT).
    public var allowPrint: Bool { rights.contains(.print) }
    /// Save As / Export (EXPORT).
    public var allowExport: Bool { rights.contains(.export) }
    /// Forward (FORWARD).
    public var allowForward: Bool { rights.contains(.forward) }
    /// Reply (REPLY).
    public var allowReply: Bool { rights.contains(.reply) }
    /// Reply all (REPLYALL).
    public var allowReplyAll: Bool { rights.contains(.replyAll) }

    /// Copilot's rule for AI: encrypted content may be summarised or returned only with VIEW **and** EXTRACT; with VIEW
    /// but not EXTRACT, only a link. https://learn.microsoft.com/copilot/plan/architecture-data-protection-auditing#how-microsoft-copilot-works-with-sensitivity-labels-and-encryption
    /// Keyed on encryption, so an admin overlay that strips EXTRACT from an *unencrypted* label doesn't change AI access
    /// (that is governed by the separate `aiMaxPriority` admin setting).
    public var aiMayReadContent: Bool {
        !bodyIsProtected || rights.isSuperset(of: [.view, .extract])
    }

    public static let open = ContentPolicy(labelState: .unlabeled, redactDetails: false, bodyIsProtected: false,
                                           rights: .all, rightsSource: .unencrypted, allowOfflineDetails: true,
                                           preventScreenCapture: false, headerMarking: nil, footerMarking: nil,
                                           watermark: nil)

    public var label: SensitivityLabel? {
        if case .labeled(let l) = labelState { return l }
        return nil
    }

    /// Combine two policies, keeping the strictest of each control (used for a whole visible window).
    public func merged(with o: ContentPolicy) -> ContentPolicy {
        var r = self
        r.redactDetails = redactDetails || o.redactDetails
        r.bodyIsProtected = bodyIsProtected || o.bodyIsProtected
        r.rights = rights.intersection(o.rights)
        r.allowOfflineDetails = allowOfflineDetails && o.allowOfflineDetails
        r.preventScreenCapture = preventScreenCapture || o.preventScreenCapture
        return r
    }
}

/// The context needed to evaluate an item: where it lives and what we know about it.
public struct ComplianceContext: Sendable {
    public var calendarAccess: CalendarAccess
    public init(calendarAccess: CalendarAccess) { self.calendarAccess = calendarAccess }
}

/// Seam between the app and Purview. Two implementations:
///  * `CachedLabelPolicyEngine` — label definitions from Graph, evaluated locally (works offline). Ships today.
///  * `MIPPolicyEngine` — MIP SDK Policy/Protection engine via an ObjC++ shim. Needs the macOS SDK zip; see docs.
public protocol ComplianceEngine: Sendable {
    func policy(for event: CalendarEvent, context: ComplianceContext) -> ContentPolicy
    /// Labels the user may apply (for a future compose/edit UI), most sensitive last.
    func availableLabels() -> [SensitivityLabel]
    var isPolicySynced: Bool { get }
}

/// Tunables a tenant admin would set. By default there are none: copy/print/export follow the label's usage rights.
public struct EnforcementSettings: Sendable {
    /// Optional admin overlay, applied ON TOP of the usage rights and only when configured. It can only restrict.
    /// This is the app's old priority rule, kept for tenants that want it (MAIL-PLAN threat model: off by default).
    public struct ExtraRestrictions: Sendable, Hashable {
        /// Labels at or above this priority lose EXTRACT and EXPORT even without encryption.
        public var restrictCopyAtPriority: Int
        /// Labels at or above this priority also block screenshots.
        public var blockCaptureAtPriority: Int
        public init(restrictCopyAtPriority: Int = 2, blockCaptureAtPriority: Int = 3) {
            self.restrictCopyAtPriority = restrictCopyAtPriority
            self.blockCaptureAtPriority = blockCaptureAtPriority
        }
    }
    public var extraRestrictions: ExtraRestrictions?
    public init(extraRestrictions: ExtraRestrictions? = nil) { self.extraRestrictions = extraRestrictions }
}

public final class CachedLabelPolicyEngine: ComplianceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var labelsById: [String: SensitivityLabel] = [:]
    private var synced = false
    public let settings: EnforcementSettings
    /// Per-item licence rights (MIP SDK), normally `LicenceRightsStore.shared`. nil = label rights only.
    public let itemRights: ItemRightsProvider?

    public init(labels: [SensitivityLabel] = [], synced: Bool = false, settings: EnforcementSettings = .init(),
                itemRights: ItemRightsProvider? = nil) {
        self.settings = settings
        self.itemRights = itemRights
        update(labels: labels, synced: synced)
    }

    public func update(labels: [SensitivityLabel], synced: Bool) {
        lock.lock(); defer { lock.unlock() }
        labelsById = Dictionary(labels.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        self.synced = synced
    }

    public var isPolicySynced: Bool { lock.lock(); defer { lock.unlock() }; return synced }

    /// Labels that can be applied, in Microsoft order (least sensitive first). Group headers (a parent with
    /// sub-labels) are not included; use `labelTree()` for the hierarchy.
    public func availableLabels() -> [SensitivityLabel] { labelTree().appliable }

    /// Every synced label, including parents and inactive ones (name/path lookups, floor ranks).
    public func allLabels() -> [SensitivityLabel] {
        lock.lock(); defer { lock.unlock() }
        return labelsById.values.sorted(by: SensitivityLabel.microsoftOrder)
    }

    /// The published labels as Outlook's picker shows them.
    public func labelTree() -> LabelTree { LabelTree(allLabels()) }

    public func policy(for event: CalendarEvent, context: ComplianceContext) -> ContentPolicy {
        policy(labelId: event.labelId, isPrivate: event.legacySensitivity == .private, access: context.calendarAccess,
               itemId: event.id)
    }

    /// Label-keyed core shared by calendar items, mail and the MCP gate.
    ///
    /// Rights resolution, most authoritative first:
    ///  1. per-item licence rights (`ItemRightsProvider`, MIP SDK; not integrated yet);
    ///  2. the label's rights for this user from Graph (`SensitivityLabel.rights`);
    ///  3. fallback: unencrypted label → `.all` (Purview imposes no usage restrictions without encryption; markings
    ///     still apply); encrypted with unknown rights → VIEW only; unknown label → fail closed as before (no
    ///     copy/export/print, capture blocked, not cached; reply/forward stay available).
    /// Then the legacy-private redaction and the optional admin overlay can only take rights away.
    public func policy(labelId: String?, isPrivate: Bool, access: CalendarAccess, itemId: String? = nil) -> ContentPolicy {
        var p = ContentPolicy.open
        let rawId = labelId?.lowercased() ?? ""

        if rawId.isEmpty {
            // Unlabelled. Still honour a per-item licence (encryption applied without a label, e.g. IRM).
            applyItemLicence(&p, itemId: itemId, labelId: nil)
        } else {
            lock.lock(); let label = labelsById[rawId]; lock.unlock()
            guard let label else {
                // Fail closed: labelled with something we can't interpret.
                p.labelState = .unknown(id: rawId)
                p.rights = .unknownLabel
                p.rightsSource = .unknownLabel
                p.allowOfflineDetails = false
                p.preventScreenCapture = true
                p.headerMarking = LabelDisplay.unknownMarking
                applyPrivate(&p, isPrivate: isPrivate, access: access)
                return p
            }
            p.labelState = .labeled(label)
            p.headerMarking = label.headerText
            p.footerMarking = label.footerText
            p.watermark = label.watermarkText

            if label.hasProtection {
                p.bodyIsProtected = true
                p.allowOfflineDetails = false
                if let r = label.rights {
                    p.rights = r.normalized; p.rightsSource = .label
                } else {
                    // Encrypted, rights unknown → VIEW only. In practice the body isn't readable anyway until MIP decryption.
                    p.rights = .viewOnly; p.rightsSource = .encryptedUnknown
                }
            }
            applyItemLicence(&p, itemId: itemId, labelId: rawId)

            if let extra = settings.extraRestrictions {
                if label.priority >= extra.restrictCopyAtPriority { p.rights.subtract([.extract, .export]) }
                if label.priority >= extra.blockCaptureAtPriority { p.preventScreenCapture = true }
            }
        }
        applyCaptureRule(&p)
        applyPrivate(&p, isPrivate: isPrivate, access: access)
        return p
    }

    private func applyItemLicence(_ p: inout ContentPolicy, itemId: String?, labelId: String?) {
        guard let itemId, let r = itemRights?.rights(itemId: itemId, labelId: labelId) else { return }
        p.rights = r.normalized
        p.rightsSource = .itemLicence
        p.bodyIsProtected = true
        p.allowOfflineDetails = false
    }

    /// Screen capture: blocked only for encrypted content without EXTRACT. EXTRACT "enables options to copy data
    /// (including screen captures)" (https://learn.microsoft.com/purview/rights-management-usage-rights#usage-rights-and-descriptions);
    /// MIP SDK guidance for UI apps: "EXTRACT? If yes, enable copying and screenshots"
    /// (https://learn.microsoft.com/information-protection/develop/concept-accesscheck#scenarios).
    /// Office on Windows blocks capture without Copy; Office for Mac does for Word/Excel/PowerPoint but NOT Outlook
    /// (https://learn.microsoft.com/purview/azure-rights-management-learn-about#frequently-asked-questions), so on this
    /// point we mirror Windows and are stricter than Outlook for Mac.
    private func applyCaptureRule(_ p: inout ContentPolicy) {
        if p.bodyIsProtected && !p.rights.contains(.extract) { p.preventScreenCapture = true }
    }

    /// Legacy Outlook sensitivity. `private` items on calendars we don't own must not show details, even if Exchange
    /// handed them to us (delegates with "can view private items"). Removes copy/export only; doesn't touch capture.
    private func applyPrivate(_ p: inout ContentPolicy, isPrivate: Bool, access: CalendarAccess) {
        guard isPrivate && access != .own else { return }
        p.redactDetails = true
        p.rights.subtract([.extract, .export])
        p.allowOfflineDetails = false
    }
}
