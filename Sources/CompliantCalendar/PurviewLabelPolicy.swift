import SwiftUI
import CalendarCore
import MailCore
import ProtectedContent

/// Purview label policy in the app: default label (mail + new meetings), mandatory labelling, downgrade
/// justification, the msip_labels stamp, and the "this label encrypts" send block. Pure rules live in
/// CalendarCore/LabelPolicy.swift; this model keeps per-composer state (no stored properties on ComposerState, so the
/// composer files only carry one-line `// PURVIEW-HOOK` calls).
///
/// Policy source: the MIP Policy SDK through the bridge when it is installed and protected messages are switched on
/// (Settings → Mail → Protected messages), else `.graphFallback` (no default / mandatory / justification).
/// Loading is async and never blocks opening a composer; the gate is re-checked at send.
@MainActor @Observable
final class PurviewPolicy {
    static let shared = PurviewPolicy()

    /// Kill switch for the msip_labels stamp (`defaults write <bundle-id> PurviewLabelStampDisabled -bool true`).
    static let stampDisabledKey = "PurviewLabelStampDisabled"
    static var stampDisabled: Bool { UserDefaults.standard.bool(forKey: stampDisabledKey) }

    private(set) var settings: LabelPolicySettings = .graphFallback
    /// Short, content-free state for Settings / diagnostics.
    private(set) var status = "Graph label list (no policy SDK)"
    var provider: (any LabelPolicyProvider)?
    /// Resolves the provider when needed (the signed-in user may not be known when the coordinator is made).
    var providerFactory: (@MainActor () -> (any LabelPolicyProvider)?)?
    /// Seconds after queueing before the label change is committed to Purview (undo window + slack).
    static let commitDelay: UInt64 = 12
    /// Label hierarchy of the signed-in user (MailModel.compliance).
    var tree: () -> LabelTree = { LabelTree([]) }
    private var states: [UUID: ComposerLabelState] = [:]
    private var loading = false

    /// Per-composer label bookkeeping.
    @MainActor @Observable
    final class ComposerLabelState {
        /// The label the draft started with (default, reopened draft or reply floor): downgrades compare to it.
        var baseline: String?
        /// Applied by the policy default (Method=Standard) until the user picks one (Privileged).
        var isDefault = false
        var setAt = Date()
        var justificationChoice: JustificationChoice?
        var justificationText = ""
        /// Queued for the Purview commit; cleared by Undo.
        var pendingCommit = false
        init() {}
        var justification: String? {
            switch justificationChoice {
            case .none: nil
            case .other: justificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : justificationText
            case .some(let c): c.title
            }
        }
    }

    /// Outlook's downgrade reasons.
    enum JustificationChoice: String, CaseIterable, Identifiable {
        case noLongerApplies, wasIncorrect, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .noLongerApplies: "Previous label no longer applies"
            case .wasIncorrect: "Previous label was incorrect"
            case .other: "Other (explain)"
            }
        }
    }

    // MARK: Policy

    func load() {
        if provider == nil { provider = providerFactory?() }
        guard let provider, !loading, ProtectedContentCoordinator.isEnabled else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let s = try await provider.loadPolicy()
                settings = s
                status = "Purview policy (MIP SDK): default \(s.defaultLabelId == nil ? "none" : "set"), "
                    + "mandatory \(s.mandatory ? "yes" : "no"), justification \(s.justificationRequired ? "yes" : "no")"
                FileHandle.standardError.write(Data("[MIP] label policy loaded (\(status))\n".utf8))
            } catch {
                settings = .graphFallback
                status = "Graph label list (policy SDK unavailable: \((error as? MIPBridgeError)?.description ?? "error"))"
                FileHandle.standardError.write(Data("[MIP] label policy fallback: \(status)\n".utf8))
            }
        }
    }

    /// Sign-out / lock / decryption switched off (from `ProtectedContentCoordinator.reset`).
    func reset() {
        settings = .graphFallback; status = "Graph label list (no policy SDK)"
        states.removeAll(); provider = nil
    }

    // MARK: Composer hooks

    func state(_ c: ComposerState) -> ComposerLabelState {
        if let s = states[c.id] { return s }
        let s = ComposerLabelState(); states[c.id] = s; return s
    }

    /// PURVIEW-HOOK from ComposerState.init: the label to start with (reply floor, else the policy default).
    func initialLabel(floor: String?, composerId: UUID) -> String? {
        if settings.source == .graphFallback { load() }   // policy may have become available (toggle, sign-in)
        let pick = LabelGate.initialLabel(floorLabelId: floor, settings: settings, tree: tree())
        let s = ComposerLabelState(); s.baseline = pick.id; s.isDefault = pick.isDefault
        states[composerId] = s
        return pick.id
    }

    /// PURVIEW-HOOK from ComposerState.setLabel: the user picked a label (Privileged from now on).
    func labelPicked(_ c: ComposerState) {
        let s = state(c); s.isDefault = false; s.setAt = Date()
        if !needsJustification(c) { s.justificationChoice = nil; s.justificationText = "" }
    }

    /// PURVIEW-HOOK from MailModel (reopened draft): its saved label is the baseline, not a user change.
    func adoptBaseline(_ c: ComposerState) { let s = state(c); s.baseline = c.labelId; s.isDefault = false }

    func isDowngrade(_ c: ComposerState, tree: LabelTree? = nil) -> Bool {
        LabelGate.isDowngrade(from: state(c).baseline, to: c.labelId, tree: tree ?? self.tree())
    }
    func needsJustification(_ c: ComposerState, tree: LabelTree? = nil) -> Bool {
        settings.justificationRequired && isDowngrade(c, tree: tree)
    }

    /// PURVIEW-HOOK from MailModel.send: nil = may send. `tree` comes from the caller's compliance engine so the gate
    /// never runs against an empty tree. `originalProtected`: replying to / forwarding encrypted mail (incl.
    /// unlabelled Do Not Forward / Encrypt-Only) would go out in the clear → refused like an encrypting label.
    func sendBlock(_ c: ComposerState, tree: LabelTree, originalProtected: Bool) -> LabelSendBlock? {
        if originalProtected { return .encrypts(labelName: "The original message's protection") }
        return LabelGate.sendBlock(labelId: c.labelId, baseline: state(c).baseline, justification: state(c).justification,
                                   settings: settings, tree: tree)
    }

    /// PURVIEW-HOOK from ComposerState.draft(): the msip_labels value for the draft (nil = don't stamp).
    func header(for c: ComposerState) -> String? {
        guard let id = c.labelId, !Self.stampDisabled else { return nil }
        let s = state(c)
        return Self.header(labelId: id, privileged: !s.isDefault, setAt: s.setAt, settings: settings)
    }

    nonisolated static func header(labelId: String, privileged: Bool, setAt: Date, settings: LabelPolicySettings) -> String? {
        LabelMetadata.build(labelId: labelId, tenantId: MIPMetadata.homeTenantId ?? settings.tenantId,   // ACCOUNTS-HOOK: the open account's tenant
                            privileged: privileged, setDate: setAt)?.headerValue
    }

    /// PURVIEW-HOOK after the send is queued: record the label change in Purview (NotifyCommittedActions → audit,
    /// incl. the justification) when the policy SDK is in use. The justification never goes to our logs.
    /// Fired after the undo window: an undone send (`sendUndone`) is not audited. Send Later commits at this point
    /// too, before the message actually leaves (known gap, docs/MIP.md).
    func committed(_ c: ComposerState) {
        let s = state(c)
        s.pendingCommit = true
        guard let provider, settings.source == .mipPolicy else { return }
        let label = c.labelId, baseline = s.baseline, justification = needsJustification(c) ? s.justification : nil
        let privileged = !s.isDefault
        let old = baseline.flatMap { b in Self.header(labelId: b, privileged: true, setAt: Date(), settings: settings) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.commitDelay * 1_000_000_000)
            guard s.pendingCommit else { return }   // undone
            s.pendingCommit = false
            do {
                let p = try await provider.plan(labelId: label, existingHeader: old, privileged: privileged,
                                                justification: justification, contentId: "niivo mail",
                                                commit: true)
                FileHandle.standardError.write(Data("[MIP] label commit \(p.committed ? "audited" : "not audited")\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[MIP] label commit failed: \((error as? MIPBridgeError)?.description ?? "error")\n".utf8))
            }
        }
    }

    /// PURVIEW-HOOK from MailModel.undoSend: the composer is back, nothing is audited, its label state stays.
    func sendUndone(_ c: ComposerState) { state(c).pendingCommit = false }

    func discard(_ c: ComposerState) { states[c.id] = nil }

    // MARK: Meetings

    /// Default label for a new meeting (same "email" content format in the SDK; UNVERIFIED for calendar defaults).
    var defaultMeetingLabelId: String? {
        guard let d = settings.defaultLabelId, tree().isSelectable(d) else { return nil }
        return d
    }

    /// Gate for a new meeting with `labelId` (mandatory / encrypting labels). nil = may save.
    func meetingBlock(labelId: String?, tree: LabelTree) -> LabelSendBlock? {
        LabelGate.sendBlock(labelId: labelId, baseline: nil, justification: nil, settings: settings, tree: tree)
    }
}

// MARK: - Composer notices (mandatory / encrypts / justification)

struct PurviewComposerNotices: View {
    @Environment(\.skin) private var skin
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let policy = PurviewPolicy.shared
        let tree = app.mail.compliance.labelTree()
        let s = policy.state(composer)
        @Bindable var st = s
        VStack(alignment: .leading, spacing: 6) {
            if policy.settings.mandatory && composer.labelId == nil {
                NLabel("Your organisation requires a sensitivity label on mail.", systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
            if case .encrypts(let n)? = LabelGate.sendBlock(labelId: composer.labelId, baseline: nil, justification: nil,
                                                            settings: policy.settings, tree: tree) {
                NLabel("“\(n)” encrypts the message. niivo can't encrypt yet — send it from Outlook, or choose another label.",
                       systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(skin.danger)
            }
            if policy.needsJustification(composer, tree: tree) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Justify the label change").font(.callout.weight(.medium))
                    Text("Your organisation needs a reason to lower or remove a label. It's recorded with Microsoft Purview.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(PurviewPolicy.JustificationChoice.allCases) { c in
                        Button { st.justificationChoice = c } label: {
                            NLabel(c.title, systemImage: st.justificationChoice == c ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain).font(.caption)
                    }
                    if st.justificationChoice == .other {
                        TextField("Reason", text: $st.justificationText).textFieldStyle(.roundedBorder).font(.caption)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: skin.rounded)
            }
        }
    }
}

// MARK: - New meeting label row (event editor)

struct PurviewMeetingLabelRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var m = app
        let tree = app.compliance.labelTree()
        let policy = PurviewPolicy.shared
        VStack(alignment: .leading, spacing: 4) {
            SensitivityLabelPicker(tree: tree, currentId: m.editorDraft.labelId, floorLabelId: nil) { m.editorDraft.labelId = $0 }
            if let b = policy.meetingBlock(labelId: m.editorDraft.labelId, tree: tree) {
                NLabel(b.message, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
