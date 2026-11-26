import SwiftUI
import AppKit
import CalendarCore
import MailCore

// LOOPS (docs/SUITE.md step 1): the app side of loops. One engine per store and account (MailCore LoopsEngine on top of
// the knowledge engine). Heavy work (knowledge refresh, seeding, proposals, the loop page) runs detached; views read
// published snapshots only. A chip shows on the reader header and the list row only for CONFIRMED memberships and
// never on redacted rows. Lock / wipe drop everything (SearchBoxState.reset). Logs: `[Loops] …` counts only.

@MainActor @Observable
final class LoopsModel {
    static let shared = LoopsModel()

    struct Chip: Hashable { var id: String; var title: String? }

    /// Conversation id → confirmed loop (for the row / reader chips).
    private(set) var confirmed: [String: Chip] = [:]
    var revision = 0
    /// The loop page (window "loop").
    private(set) var page: LoopDetail?
    var pageId: String?
    var pageBusy = false
    var renameDraft = ""
    @ObservationIgnored private var engineId: ObjectIdentifier?
    @ObservationIgnored private var seededGen = Int.min
    @ObservationIgnored private var lastDiag = ""
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var draftFor: String?

    func reset() {
        confirmed = [:]; page = nil; pageId = nil; pageBusy = false; renameDraft = ""; draftFor = nil; pending = false
        engineId = nil; seededGen = .min; lastRefresh = .distantPast
        PeopleSurfaceModel.shared.loopSource = nil   // LOOPS-HOOK
    }

    /// The current account's engine (rekeys the caches when the store or account changes).
    func engine(_ mail: MailModel) -> LoopsEngine? {
        guard mail.started, !(mail.ai.app?.trust.hidesContent ?? false), let store = mail.store,
              let k = KnowledgeHub.shared.engine(mail) else { return nil }
        let account = mail.ai.app?.auth?.accountKey ?? "default"
        let l: LoopsEngine
        if let cur = store.loops, cur.knowledge === k, cur.account == account { l = cur }
        else { l = store.enableLoops(LoopsEngine.Config(account: account, owners: k.owners), knowledge: k) }
        if engineId != ObjectIdentifier(l) {
            engineId = ObjectIdentifier(l); confirmed = [:]; page = nil; pageId = nil; seededGen = .min
        }
        PeopleSurfaceModel.shared.loopSource = l   // LOOPS-HOOK: the person page lists real loops
        return l
    }

    /// Chip map and diagnostic, off the main thread. `heavy` (Signal, the loop page) also refreshes the knowledge
    /// snapshot and seeds once per snapshot; the light pass (triage changes) only re-reads the loop rows. A forced
    /// refresh during one in flight runs again right after it.
    func refresh(_ mail: MailModel, force: Bool = false, heavy: Bool = false) async {
        guard let l = engine(mail) else { return }
        if refreshing { if force || heavy { pending = true }; return }
        if !force, !heavy, Date().timeIntervalSince(lastRefresh) < 5 { return }
        refreshing = true; lastRefresh = Date()
        let seeded = seededGen
        let id = ObjectIdentifier(l)
        let (map, gen, diag) = await Task.detached(priority: .utility) { () -> ([String: Chip], Int, String) in
            if heavy { l.knowledge.refresh() }
            let g = l.knowledge.snapshotGeneration
            if heavy, g != seeded { l.seed() }
            var titles: [String: String?] = [:]
            var map: [String: Chip] = [:]
            for (cid, lid) in l.confirmedMap() {
                if titles[lid] == nil { titles[lid] = .some(l.loop(id: lid)?.title) }
                map[cid] = Chip(id: lid, title: titles[lid] ?? nil)
            }
            return (map, g, l.diagnostic())
        }.value
        refreshing = false
        if pending { pending = false; Task { await refresh(mail, force: true) } }
        guard engineId == id else { return }
        if heavy { seededGen = gen }
        confirmed = map
        revision += 1
        if diag != lastDiag { lastDiag = diag; FileHandle.standardError.write(Data((diag + "\n").utf8)) }
        if let p = pageId { await loadPage(p, mail: mail) }
    }

    // MARK: Page

    func open(_ loopId: String, mail: MailModel, openWindow: OpenWindowAction) {
        pageId = loopId; page = nil
        DeskModel.shared.present(.loops) { openWindow(id: "loop") }   // DESK-HOOK: the Loops tile when the Desk shows
        Task { await refresh(mail, heavy: true); await loadPage(loopId, mail: mail) }
    }

    func loadPage(_ loopId: String, mail: MailModel) async {
        guard let l = engine(mail) else { return }
        pageBusy = true
        let promises = TodayModel.shared.promises.map(PromiseBox.init)
        let d = await Task.detached(priority: .userInitiated) { l.detail(loopId, tier: .user, promises: promises?.source) }.value
        pageBusy = false
        guard pageId == loopId else { return }
        page = d
        if draftFor != loopId { draftFor = loopId; renameDraft = d?.summary.title ?? "" }   // never overwrite while typing
    }

    /// Runs an edit off the main thread, then refreshes chips and the page.
    func edit(_ mail: MailModel, _ body: @escaping @Sendable (LoopsEngine) -> Void) {
        guard let l = engine(mail) else { return }
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) { body(l) }.value
            await refresh(mail, force: true)
        }
    }
}

/// The promise source crosses into detached work (the ledger is thread-safe).
struct PromiseBox: @unchecked Sendable { let source: PromiseSource }

// MARK: - Chip (reader header, list row)

struct LoopChip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    var chip: LoopsModel.Chip
    var compact = false
    var body: some View {
        Button { LoopsModel.shared.open(chip.id, mail: app.mail, openWindow: openWindow) } label: {
            HStack(spacing: 4) {
                Circle().strokeBorder(skin.ink, lineWidth: 1.2).frame(width: 7, height: 7)
                Text(chip.title ?? L("Loop")).font(skin.brand ? skin.mono(compact ? 9 : 10, .medium) : .caption2.weight(.medium))
                    .foregroundStyle(skin.ink).lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .modifier(LoopChipSurface(compact: compact))   // GLASS: reader-header chip only; list-row chips stay solid (rows are content)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(L("Open this loop"))
        .accessibilityLabel(L("Loop: %@", chip.title ?? L("Loop")))
    }
}

private struct LoopChipSurface: ViewModifier {
    @Environment(\.skin) private var skin
    var compact: Bool
    func body(content: Content) -> some View {
        if compact { content.background(Capsule().fill(skin.soft)) } else { content.niivoGlassCapsule(interactive: true) }
    }
}

/// LOOPS-HOOK: the reader header line (confirmed loops only, never on redacted messages).
struct LoopReaderChip: View {
    @Environment(AppModel.self) private var app
    var reader: ReaderState
    var body: some View {
        if !reader.policy.redactDetails, let c = LoopsModel.shared.confirmed[reader.header.conversationId] {
            HStack { LoopChip(chip: c); Spacer() }.padding(.horizontal, 18).padding(.bottom, 6)
        }
    }
}

// MARK: - Loop page (window "loop")

struct LoopPageRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = LoopsModel.shared
        let _ = m.revision
        VStack(spacing: 0) {
            if app.trust.hidesContent || !app.mail.started {
                Text(L("Unlock to see loops.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = m.page {
                LoopPage(detail: d)
            } else if m.pageBusy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(L("Click a loop chip to open it.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
    }
}

struct LoopPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var detail: LoopDetail
    var body: some View {
        let m = LoopsModel.shared
        @Bindable var model = m
        let s = detail.summary
        let mail = app.mail
        let id = s.id
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    MonoLabel(L("Loop"), wide: true)
                    if !s.confirmed { NChip(L("suggested"), tone: .muted) }
                    NChip(L(s.state.rawValue.capitalized), tone: s.state == .open ? .ink : .muted)
                    Spacer()
                    if let due = s.due { MonoLabel(L("due %@", due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), size: NV.Size.labelSm) }
                }
                HStack(spacing: 8) {
                    TextField(L("Loop title"), text: $model.renameDraft)
                        .textFieldStyle(.plain).font(skin.sans(NV.Size.title))
                        .onSubmit { let t = m.renameDraft; m.edit(mail) { $0.rename(id, to: t) } }
                        .accessibilityLabel(L("Loop title"))
                }
                HStack(spacing: 6) {
                    if !s.confirmed { NButton(L("Accept suggestion"), kind: .primary) { m.edit(mail) { $0.acceptSuggestion(id) } } }
                    if s.state != .done { NButton(L("Mark done"), kind: .ghost) { m.edit(mail) { $0.setState(id, .done) } } }
                    if s.state != .open { NButton(L("Reopen"), kind: .ghost) { m.edit(mail) { $0.setState(id, .open) } } }
                    if s.state != .archived { NButton(L("Archive"), kind: .quiet) { m.edit(mail) { $0.setState(id, .archived) } } }
                    if s.state == .open { LoopScheduleButton(loopId: id) }   // WHEN-HOOK: "Schedule" → When for this loop
                }
                LoopWorkSection(loopId: id)   // WHEN-HOOK / DEEP-HOOK: work items + suggestions (WhenDeepViews.swift)
                NSectionHeader(L("People"))
                if s.people.isEmpty { Text(L("No visible people.")).font(.caption).foregroundStyle(skin.muted) }
                else {
                    Text(s.people.prefix(12).joined(separator: " · ")).font(.caption).foregroundStyle(skin.muted).textSelection(.enabled)
                    if !s.organisations.isEmpty {
                        HStack(spacing: 4) { ForEach(s.organisations.prefix(6), id: \.self) { NChip(MailDomains.name(fromDomain: $0), tone: .muted) } }
                    }
                }
                NSectionHeader(L("Conversations · %lld", detail.members.count))
                ForEach(detail.members) { mem in LoopMemberRow(member: mem, loopId: id) }
                NSectionHeader(L("Promises"))
                if detail.promises.isEmpty { Text(L("No open promises.")).font(.caption).foregroundStyle(skin.muted) }
                ForEach(detail.promises) { p in
                    HStack { Image(systemName: "checkmark.circle").accessibilityHidden(true); Text(p.title).lineLimit(1); Spacer()
                        if let d = p.due { Text(d, style: .date).foregroundStyle(.secondary) } }.font(.caption)
                }
                NSectionHeader(L("Files"))
                if detail.files.isEmpty { Text(L("No files.")).font(.caption).foregroundStyle(skin.muted) }
                else { KnowledgeFileLines(files: Array(detail.files.prefix(30))) }
                NSectionHeader(L("Timeline"))
                ForEach(detail.timeline) { t in
                    HStack(spacing: 8) {
                        MonoLabel(L("Mail"), size: NV.Size.labelSm)
                        Text(t.subject.isEmpty ? L("Protected conversation") : t.subject).font(.caption).lineLimit(1)
                        Spacer()
                        Text(t.last, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L("Loops form only from shared anchors (reference numbers, project names, files, subjects) or from what you confirm; never from similarity alone."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

/// One member conversation of a loop (the loop page, Deep's drawer). `removable` shows "Not this loop".
struct LoopMemberRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var member: LoopMemberInfo
    var loopId: String
    var removable = true
    var body: some View {
        let mem = member
        let mail = app.mail
        let m = LoopsModel.shared
        HStack(spacing: 8) {
            Image(systemName: mem.origin.isConfirmed ? "circle.fill" : "circle").font(.system(size: 7)).accessibilityHidden(true)
            Button {
                if let t = mem.thread { mail.reveal(messageId: t.latestId) }
            } label: {
                Text(mem.thread.map { $0.subject.isEmpty ? L("Protected conversation") : $0.subject } ?? L("Not visible"))
                    .font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
            }
            .buttonStyle(.plain).disabled(mem.thread == nil).help(L("Show this conversation"))
            if mem.origin.isConfirmed { NChip(L("you added"), tone: .muted) }
            else if let r = mem.reason { NChip(LoopsText.reason(r), tone: .muted) }
            Spacer()
            if removable {
                Button(L("Not this loop")) { let c = mem.conversationId, l = loopId; m.edit(mail) { $0.notThisLoop(c, loopId: l) } }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

enum LoopsText {
    /// "Same reference 4500123456" / "Same project Seeblick" (anchor text only when the gate gave it).
    static func reason(_ r: LoopReason) -> String {
        let base: String
        switch r.kind {
        case .id: base = r.anchorText.map { L("Same reference %@", $0) } ?? L("Same reference")
        case .proj: base = r.anchorText.map { L("Same project %@", $0) } ?? L("Same project")
        case .att: base = r.anchorText.map { L("Same file %@", $0) } ?? L("Same file")
        case .stem: base = L("Same subject")
        }
        return r.samePeople ? L("%@, same people", base) : base
    }
}
