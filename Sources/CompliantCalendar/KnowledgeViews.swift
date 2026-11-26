import SwiftUI
import AppKit
import CalendarCore
import MailCore

// PEOPLE: app side of the local knowledge layer (docs/INBOX-INTELLIGENCE-PLAN.md Phase 2; MailCore/Knowledge*.swift).
// * Ask: on ↩ in the main search box (and ⌘K "Ask: …"), a knowledge question ("mails from my lawyer", "that project in
//   Feb for that architect", "what did I agree with Franci about the offer") is answered locally; the cited card sits
//   above the results, which come from the existing search via the hand-off (from/to the resolved person, soft window).
// * Person page / matter page (window "knowledge"): timeline of threads, files and meetings, inferred role with an
//   edit / correct control (stored as a user fact), voice notes (existing voice editor), matters as chips.
// * State lives here (no @State: the toolchain can't expand SwiftUI macros). Lock / wipe drop it
//   (SearchBoxState.reset). Logs are counts only.

@MainActor @Observable
final class KnowledgeHub {
    static let shared = KnowledgeHub()
    enum Page: Hashable { case person(String), matter(person: String, matter: String) }

    /// The answer card above the search results (nil = none).
    var answer: KnowledgeAnswer?
    var summary: String?
    var summaryBusy = false
    var page: Page?
    var revision = 0
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var configKey = ""
    @ObservationIgnored private var lastLog = ""

    func reset() { answer = nil; summary = nil; summaryBusy = false; page = nil; configKey = ""; PeopleSurfaceModel.shared.reset() }   // PEOPLE2-HOOK

    // MARK: Engine (per account)

    func engine(_ mail: MailModel) -> KnowledgeEngine? {
        guard mail.started, let store = mail.store else { return nil }
        let t = mail.ai.trustPolicy
        var od = AIOrgAccess(trustRawValue: t.effectiveOnDeviceAIAccess.rawValue)
        // Interpretation (triage precedent): these are local rules, not a model. With on-device AI off they still use
        // metadata (addresses, domains, counts) but never read text.
        if od == .off { od = .metadataOnly }
        let gate = AIGatePolicy(engine: mail.compliance, cloudAccess: .off, onDeviceAccess: od)
        let me = mail.me?.address.lowercased() ?? ""
        let owners = Set([me] + mail.settings.identities.map { $0.address.lowercased() }
                         + mail.mailboxes.filter { $0 != "me" }.map { $0.lowercased() }).subtracting([""])
        let account = mail.ai.app?.auth?.accountKey ?? "default"
        var dir: [String: VoiceDirectoryFacts] = [:]
        for p in PeopleHub.shared.people {
            guard let a = p.address?.lowercased(), !a.isEmpty else { continue }
            dir[a] = VoiceDirectoryFacts(title: p.jobTitle, department: p.department, company: p.company)
        }
        let key = [account, "\(od)", "\(mail.compliance.availableLabels().count)", owners.sorted().joined(separator: ","), "\(dir.count)"].joined(separator: "|")
        if let k = store.knowledge, key == configKey { return k }
        let directory = dir
        let k = store.enableKnowledge(KnowledgeEngine.Config(account: account, owners: owners, internalDomains: mail.settings.internalDomains,
                                                             gate: gate, directory: { directory[$0] }))
        configKey = key
        return k
    }

    /// Answers `text` if it's a knowledge question. Returns the hand-off results (nil = not a knowledge question).
    func ask(_ text: String, mail: MailModel) async -> [MailMessage]? {
        guard let k = engine(mail), let store = mail.store else { return nil }
        let mailbox = mail.selectedMailbox
        let res = await Task.detached(priority: .userInitiated) { () -> (KnowledgeAnswer, [MailMessage], String)? in
            k.refresh()
            guard let a = KnowledgeAsk.answer(text, engine: k) else { return nil }
            return (a, KnowledgeAsk.search(a, store: store, mailbox: mailbox), KnowledgeAsk.diagnostic(k))
        }.value
        guard let (a, hits, diag) = res else { answer = nil; return nil }
        answer = a; summary = nil
        if diag != lastLog { lastLog = diag; FileHandle.standardError.write(Data((diag + "\n").utf8)) }
        return hits
    }

    // MARK: Summary (AI tier, gated, cited; optional)

    func summarise(mail: MailModel) {
        guard let a = answer, let assistant = mail.ai.assistant, mail.ai.available(.ask), let store = mail.store else { return }
        let ids = Array(a.citations.suffix(8))
        let items: [(MailMessage, String)] = ids.compactMap { id in
            (try? store.message(id: id)).flatMap { $0 }.map { ($0, store.mailbox(forFolder: $0.folderId)) }
        }
        guard !items.isEmpty else { return }
        summaryBusy = true
        Task { @MainActor in
            defer { summaryBusy = false }
            let q = "In at most two lines, what happened here (\(a.headline))? Cite the mails as [n]."
            if let r = try? await assistant.ask(q, retrieved: items) { summary = r.text }
        }
    }

    // MARK: Pages

    /// PEOPLE2-HOOK: opens the People surface on this person straight away. Before, this returned silently when the
    /// engine didn't exist yet (mail not started: hover card / answer card from Calendar), waited for a full rebuild
    /// before showing anything, and a miss was only a toast. Now the surface loads itself (`.task`) and says why a
    /// page is empty (`PeopleEmptyReason`, also in the `[People]` log line).
    func open(person address: String, mail: MailModel, openWindow: OpenWindowAction) {
        page = nil; revision += 1
        PeopleSurfaceModel.shared.select(address: address)
        DeskModel.shared.present(.people) { openWindow(id: "knowledge") }   // DESK-HOOK: the People tile when the Desk shows
    }

    /// PEOPLE2-HOOK: the People destination (menu / toolbar), without a person picked.
    func openDirectory(openWindow: OpenWindowAction) {
        page = nil; revision += 1
        PeopleSurfaceModel.shared.reloadToken += 1
        DeskModel.shared.present(.people) { openWindow(id: "knowledge") }   // DESK-HOOK: the People tile when the Desk shows
    }

    func open(matter: KnowledgeMatter, person: String, openWindow: OpenWindowAction) {
        // PEOPLE2-HOOK: the surface's side column / actions follow the matter's person (key = first address).
        if PeopleSurfaceModel.shared.selected != person.lowercased() { PeopleSurfaceModel.shared.select(address: person) }
        page = .matter(person: person, matter: matter.id); revision += 1
        DeskModel.shared.present(.people) { openWindow(id: "knowledge") }   // DESK-HOOK: the People tile when the Desk shows
    }

    func correct(_ role: KnowledgeRole, address: String, isRole: Bool, mail: MailModel) {
        engine(mail)?.setRole(role, for: address, isRole: isRole)
        revision += 1
        if let a = answer, a.person?.addresses.contains(address) == true, !mail.searchText.isEmpty { mail.submitSearch() }
    }

    func undoCorrection(_ role: KnowledgeRole, address: String, mail: MailModel) {
        engine(mail)?.clearRole(role, for: address)
        revision += 1
    }
}

// MARK: - Ask card (above the search results)

struct KnowledgeAnswerCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let hub = KnowledgeHub.shared
        if let a = hub.answer {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: a.kind == .matter ? "folder" : a.kind == .person ? "person.text.rectangle" : "questionmark.circle")
                        .accessibilityHidden(true)
                    Text(a.headline).font(skin.sans(NV.Size.body).weight(.semibold)).lineLimit(2)
                    Spacer()
                    if let p = a.person {
                        NButton(L("Open person"), kind: .quiet) { hub.open(person: p.addresses.first ?? p.key, mail: app.mail, openWindow: openWindow) }
                    }
                    if let m = a.matter, let p = a.person {
                        NButton(L("Open matter"), kind: .quiet) { hub.open(matter: m, person: p.key, openWindow: openWindow) }
                    }
                    NIconButton("xmark", label: L("Close the answer")) { hub.answer = nil }
                }
                if !a.why.isEmpty {
                    Text(L("Why: ") + a.why.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let f = a.first, let l = a.last, a.kind != .none {
                    Text(Self.range(f, l)).font(.caption).foregroundStyle(.secondary)
                }
                if a.kind == .none {
                    Text(L("Nothing on this Mac answers that for sure. The closest matches are listed below."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let m = a.matter, !m.keys.isEmpty {
                    KnowledgeChips(items: m.keys.map { ($0, $0) }) { _ in }
                }
                KnowledgeThreadLines(threads: Array(a.threads.prefix(4)))
                if !a.alsoInPeriod.isEmpty {
                    Text(L("Also in that period")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    KnowledgeThreadLines(threads: Array(a.alsoInPeriod.prefix(3)))
                }
                if !a.files.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").accessibilityHidden(true)
                        Text(a.files.prefix(4).map(\.name).joined(separator: " · ")).font(.caption).lineLimit(1)
                    }
                }
                if !a.otherMatters.isEmpty, let p = a.person {
                    HStack(spacing: 6) {
                        Text(L("Other matters:")).font(.caption).foregroundStyle(.secondary)
                        ForEach(a.otherMatters) { m in
                            Button(m.title) { hub.open(matter: m, person: p.key, openWindow: openWindow) }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                if !a.candidates.isEmpty {
                    HStack(spacing: 6) {
                        Text(a.kind == .none ? L("Closest:") : L("Or did you mean:")).font(.caption).foregroundStyle(.secondary)
                        ForEach(a.candidates) { c in
                            Button(c.name) { pick(c) }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                if let s = hub.summary {
                    Text(s).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if a.kind != .none, app.mail.ai.enabled, app.mail.ai.available(.ask) {
                    HStack {
                        if hub.summaryBusy { ProgressView().controlSize(.small) }
                        else { NButton(L("Summarise (AI)"), kind: .ghost) { hub.summarise(mail: app.mail) }.help(L("Only mail your labels allow AI to see is used")) }
                    }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(skin.brand ? AnyShapeStyle(skin.soft) : AnyShapeStyle(.quaternary.opacity(0.4)), in: RoundedRectangle(cornerRadius: skin.brand ? 0 : 8))
            .overlay(alignment: .leading) { if skin.brand { Rectangle().fill(skin.ink).frame(width: 3) } }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Answer"))
        }
    }

    /// A chip opens that person's page (where "This is my …" makes the choice stick).
    private func pick(_ c: KnowledgeCandidate) { KnowledgeHub.shared.open(person: c.key, mail: app.mail, openWindow: openWindow) }

    static func range(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        let x = f.string(from: a), y = f.string(from: b)
        return x == y ? x : x + " – " + y
    }
}

/// Thread lines: subject (or a neutral placeholder when the subject isn't visible), count, last date. ↩/click reveals.
struct KnowledgeThreadLines: View {
    @Environment(AppModel.self) private var app
    var threads: [KnowledgeThread]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(threads) { t in
                Button { app.mail.reveal(messageId: t.latestId) } label: {
                    HStack(spacing: 6) {
                        Text(t.subject.isEmpty ? L("(subject hidden by its label)") : t.subject).lineLimit(1)
                        if t.count > 1 { Text("\(t.count)").foregroundStyle(.secondary) }
                        Spacer()
                        Text(t.last, style: .date).foregroundStyle(.secondary)
                    }
                    .font(.caption).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Show this conversation"))
            }
        }
    }
}

struct KnowledgeChips: View {
    var items: [(id: String, title: String)]
    var tap: (String) -> Void
    var body: some View {
        HStack(spacing: 4) { ForEach(items, id: \.id) { i in NChip(i.title, tone: .muted).onTapGesture { tap(i.id) } } }
    }
}

// MARK: - Person / matter window

/// PEOPLE2-HOOK: the window is now the People surface (PeopleSurfaceViews.swift), inside SecondaryWindow like every
/// other secondary window. Before it wasn't: no skin (the default niivo skin whatever the theme), no ground / title
/// bar handling and no screen-capture guard, and its person page read the engine in `body` with no refresh, so a
/// window opened before a build showed a misleading "not visible with the current label policy".
struct KnowledgePageRoot: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        SecondaryWindow(captureBlocked: app.mail.screenPolicy.preventScreenCapture || PeopleSurfaceModel.shared.preventCapture) {
            PeopleSurfaceView()
        }
        .frame(minWidth: 1000, minHeight: 600)
    }
}

// PEOPLE2-HOOK: KnowledgePersonPage was replaced by the People surface's person column (PeopleSurfaceViews.swift),
// which keeps its sections (role + correction, files, open promises, voice notes) and adds the wireframe's.

/// Inferred role(s) with why, and the edit / correct control (stored as a user fact).
struct KnowledgeRoleSection: View {
    @Environment(AppModel.self) private var app
    var person: KnowledgePerson
    var body: some View {
        let hub = KnowledgeHub.shared
        let mail = app.mail
        let address = person.addresses.first ?? person.key
        NSectionHeader(L("Role"))
        VStack(alignment: .leading, spacing: 4) {
            let shown = person.roles.filter { $0.asserted || $0.userAsserted }
            if shown.isEmpty { Text(L("No role known yet.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(shown, id: \.role) { r in
                HStack(spacing: 6) {
                    NChip(r.role.title, tone: r.userAsserted ? .accent : .ink)
                    Text(KnowledgeAsk.whyLines(person, role: r.role).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if r.userAsserted {
                        Button(L("Undo")) { hub.undoCorrection(r.role, address: address, mail: mail) }.buttonStyle(.link).font(.caption)
                    } else {
                        Button(L("Not my %@", r.role.title.lowercased())) { hub.correct(r.role, address: address, isRole: false, mail: mail) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            NMenuButton(label: L("This is my…"), symbol: "person.badge.plus",
                        items: KnowledgeRole.builtIn.map { r in NMenuItem(title: r.title) { hub.correct(r, address: address, isRole: true, mail: mail) } })
                .fixedSize()
                .help(L("Correct the role; your choice wins over what was inferred"))
        }
    }
}

struct KnowledgeVoiceNotes: View {
    @Environment(AppModel.self) private var app
    var person: KnowledgePerson
    var body: some View {
        let m = VoiceEditorModel.shared
        @Bindable var model = m
        let a = EmailAddress(name: person.name, address: person.addresses.first ?? person.key)
        let notes = app.mail.voiceProfile.contact(address: a.address)?.notes ?? ""
        HStack(alignment: .top) {
            Text(notes.isEmpty ? L("No voice notes yet.") : notes).font(.caption).foregroundStyle(notes.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            NButton(L("Edit voice"), kind: .quiet) { m.editContact(a, in: app.mail.voiceProfile); m.showReaderEditor = true }
                .background(Color.clear.popover(isPresented: $model.showReaderEditor) { VoiceQuickEditor { m.showReaderEditor = false } })
        }
    }
}

struct KnowledgeFileLines: View {
    @Environment(AppModel.self) private var app
    var files: [KnowledgeFile]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(files) { f in
                Button { app.mail.reveal(messageId: f.messageId) } label: {
                    HStack { Image(systemName: "doc").accessibilityHidden(true); Text(f.name).lineLimit(1); Spacer(); Text(f.date, style: .date).foregroundStyle(.secondary) }
                        .font(.caption).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("Show the mail with this file"))
            }
        }
    }
}

/// Meetings with these people from the local calendar store (subjects only where the event's label allows).
struct KnowledgeMeetingLines: View {
    @Environment(AppModel.self) private var app
    var addresses: [String]
    var from: Date?
    var to: Date?
    var body: some View {
        let set = Set(addresses.map { $0.lowercased() })
        let start = (from ?? Date()).addingTimeInterval(-30 * 86_400), end = max(to ?? Date(), Date()).addingTimeInterval(60 * 86_400)
        let evs = app.aiOwnBusyEvents(from: start, to: end).filter { e in e.attendees.contains { set.contains($0.address.lowercased()) } }
            .sorted { $0.start > $1.start }.prefix(10)
        if !evs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(evs), id: \.id) { e in
                    let p = app.policy(for: e)
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").accessibilityHidden(true)
                        Text(p.redactDetails ? L("Meeting") : e.subject).lineLimit(1)
                        Spacer()
                        Text(e.start, style: .date).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }
    }
}

struct KnowledgeMatterPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var engine: KnowledgeEngine
    var personKey: String
    var matterId: String
    var body: some View {
        let _ = KnowledgeHub.shared.revision
        let v = engine.view(.user)
        if let p = v.people[personKey], let m = KnowledgeAsk.allMatters(for: p, engine: engine, tier: .user).first(where: { $0.id == matterId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(m.title).font(skin.sans(18))
                    Text(L("With %@ · %@", p.name, KnowledgeAnswerCard.range(m.first, m.last))).font(.caption).foregroundStyle(.secondary)
                    if !m.keys.isEmpty { KnowledgeChips(items: m.keys.map { ($0, $0) }) { _ in } }
                    NSectionHeader(L("Timeline"))
                    KnowledgeMeetingLines(addresses: p.addresses, from: m.first, to: m.last)
                    KnowledgeThreadLines(threads: m.threads)
                    if !m.files.isEmpty { NSectionHeader(L("Files")); KnowledgeFileLines(files: m.files) }
                    Text(L("Grouped because these conversations share an anchor (reference number, project name, file or subject); never by similarity alone."))
                        .font(.caption2).foregroundStyle(.secondary)
                    NSectionHeader(L("Open promises"))
                    KnowledgePromises(conversations: Set(m.threads.map(\.id)))
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(L("This matter isn't visible with the current label policy.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Open promises in these conversations, read through `PromiseSource` (TodayModel.promises). PEOPLE-HOOK: the
/// protocol exists on main but nothing implements it yet, so this shows the placeholder until the ledger lands.
struct KnowledgePromises: View {
    var conversations: Set<String>
    var body: some View {
        let ps = (TodayModel.shared.promises?.promisesDue(before: Date().addingTimeInterval(365 * 86_400)) ?? [])
            .filter { $0.conversationId.map(conversations.contains) ?? false }
        if TodayModel.shared.promises == nil {
            Text(L("The promises ledger isn't available yet.")).font(.caption).foregroundStyle(.secondary)
        } else if ps.isEmpty {
            Text(L("No open promises.")).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ps) { pr in
                    HStack { Image(systemName: "checkmark.circle").accessibilityHidden(true); Text(pr.title).lineLimit(1); Spacer()
                        if let d = pr.due { Text(d, style: .date).foregroundStyle(.secondary) } }.font(.caption)
                }
            }
        }
    }
}
