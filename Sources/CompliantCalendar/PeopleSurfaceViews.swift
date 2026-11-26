import SwiftUI
import AppKit
import CalendarCore
import MailCore

// PEOPLE2: the People surface (wireframe "Workspace suite v0-6", People). Window id "knowledge" (it replaces the old
// person-only page; the matter page still opens in its centre column):
//   directory column (People / Organisations / Places, search, sorted by recent contact, open counts)
//   | person page (header, status chips, loops, history) | organisation + place panels and the action strip.
// Pure logic lives in MailCore/PeopleSurface.swift + PeopleNotes.swift (tested in CoreSelfTest).
// State lives in PeopleSurfaceModel (no @State: the toolchain can't expand SwiftUI macros). Lock / wipe drop it via
// KnowledgeHub.reset(). The `[People]` log line is counts only.

@MainActor @Observable
final class PeopleSurfaceModel {
    static let shared = PeopleSurfaceModel()
    enum Tab: String, CaseIterable, Hashable { case people, organisations, places }

    struct Page: Sendable {
        var person: KnowledgePerson
        var history: [PeopleHistoryItem]
        var owes: PeopleOwes
        var loops: [LoopSummary]
        var suggested: [KnowledgeMatter]
        var since: (year: Int, atWindowEdge: Bool)?
        var org: PeopleOrgRow?
        var orgKind: OrgKind
        var place: PeoplePlaceRow?
        var next: CalendarEvent?
        var nextRedacted: Bool
        var files: [KnowledgeFile]
        /// A listed message / meeting forbids screen capture → the window is excluded from capture (People window precedent).
        var preventCapture: Bool
    }
    enum OrgKind: Sendable { case client, supplier, internalOrg, external }

    var tab: Tab = .people
    var query = ""
    /// Selected person (lowercased address). nil → the first directory row once loaded.
    var selected: String?
    var selectedOrg: String?
    var selectedPlace: String?
    var directory = PeopleDirectory()
    var page: Page?
    var reason: PeopleEmptyReason?
    var loading = false
    var loaded = false
    var reloadToken = 0
    var preventCapture = false
    // Log a note (NOTES-HOOK)
    var noteOpen = false
    var noteDraft = ""
    var noteBusy = false
    var noteNeedsConsent = false
    var notice: String?
    /// LOOPS-HOOK: the loops engine plugs in here; nil → open triage conversations + suggested matters.
    @ObservationIgnored var loopSource: (any LoopSource)?
    /// Office locations seen in directory profiles this session (address → place). Memory only.
    @ObservationIgnored private var places: [String: String] = [:]
    @ObservationIgnored private var lastLog = ""
    @ObservationIgnored private var generation = 0

    func reset() {
        selected = nil; selectedOrg = nil; selectedPlace = nil; directory = PeopleDirectory(); page = nil; reason = nil
        loading = false; loaded = false; noteOpen = false; noteDraft = ""; noteBusy = false; noteNeedsConsent = false
        notice = nil; places = [:]; query = ""; lastLog = ""; preventCapture = false
        reloadToken += 1   // an open window reloads (shows the locked / empty reason) instead of spinning
    }

    func select(address: String) {
        selected = address.lowercased(); tab = .people; page = nil; reloadToken += 1
    }

    // MARK: Load

    func refresh(_ app: AppModel) async {
        generation += 1
        let gen = generation
        let mail = app.mail
        if !app.trust.hidesContent, !mail.started { await app.startMailIfNeeded() }
        guard gen == generation else { return }
        if app.trust.hidesContent { finish(nil, reason: .locked); return }
        guard mail.started, let k = KnowledgeHub.shared.engine(mail) else { finish(nil, reason: .mailNotStarted); return }
        notePlaces()
        loading = true
        let triage = mail.ai.inbox.engine
        let loopBox = LoopBox(source: loopSource)
        let q = query, placeMap = places
        let (dir, byConv, acct) = await Task.detached(priority: .userInitiated) { () -> (PeopleDirectory, [String: [PeopleConversation]], String) in
            let loops = loopBox.source
            k.refresh()
            let v = k.view(.user)
            var byConv: [String: [PeopleConversation]] = [:]
            let acct = triage?.account ?? k.account
            if let t = triage {
                for f in t.allFacts() {
                    let d = t.decide(f)
                    byConv[f.conversationId, default: []].append(PeopleConversation(
                        conversationId: f.conversationId, account: f.account, state: d.state, senderAddress: f.senderAddress,
                        lastFromMe: f.lastFromMe, latestMessageId: f.latestMessageId, since: d.since))
                }
            }
            let dir = PeopleSurface.directory(view: v, open: { p in
                if let loops { return PeopleOpenCount(count: PeopleSurface.loops(loops, addresses: p.addresses, account: k.account).count, fromLoops: true) }
                let o = PeopleSurface.owes(addresses: Set(p.addresses), conversations: p.conversations, account: acct,
                                           states: p.conversations.flatMap { byConv[$0] ?? [] })
                return PeopleOpenCount(count: o.youOwe + o.theyOwe, fromLoops: false)
            }, place: { p in p.addresses.lazy.compactMap { placeMap[$0] }.first }, query: q)
            return (dir, byConv, acct)
        }.value
        guard gen == generation else { return }
        directory = dir
        if selected == nil { selected = dir.people.first?.address }
        guard let sel = selected else { finish(nil, reason: .noSelection); return }
        // Page data (off the main thread, except the calendar read and its label policy).
        let now = Date()
        let events = app.aiOwnBusyEvents(from: now.addingTimeInterval(-365 * 86_400), to: now.addingTimeInterval(90 * 86_400))
        let redacted = Set(events.filter { app.policy(for: $0).redactDetails }.map(\.id))
        let noCaptureEvents = Set(events.filter { app.policy(for: $0).preventScreenCapture }.map(\.id))
        let compliance = mail.compliance
        let started = mail.started, locked = app.trust.hidesContent
        let built: (Page?, PeopleEmptyReason?) = await Task.detached(priority: .userInitiated) { () -> (Page?, PeopleEmptyReason?) in
            let loops = loopBox.source
            let v = k.view(.user)
            let p = v.person(address: sel)
            if let r = PeopleSurface.emptyReason(address: sel, locked: locked, mailStarted: started, owners: k.owners,
                                                 known: k.knows(address: sel), visible: p != nil) { return (nil, r) }
            guard let p else { return (nil, .noMailInWindow) }
            let addrs = Set(p.addresses)
            let hist = PeopleSurface.history(PeopleSurface.mailInputs(p, engine: k)
                                             + PeopleSurface.meetingInputs(events, addresses: addrs, redact: { redacted.contains($0.id) })
                                             + PeopleSurface.noteInputs(p.addresses.flatMap { k.notes(address: $0) }))
            let owes = PeopleSurface.owes(addresses: addrs, conversations: p.conversations, account: acct,
                                          states: p.conversations.flatMap { byConv[$0] ?? [] })
            let ls = loops.map { PeopleSurface.loops($0, addresses: p.addresses, account: k.account) } ?? []
            let sug = loops == nil ? Array(KnowledgeAsk.allMatters(for: p, engine: k, tier: .user).prefix(4)) : []
            let org = p.org.flatMap { o in dir.orgs.first { $0.id == o } }
            var kind = OrgKind.external
            if p.isInternal { kind = .internalOrg }
            else if let o = p.org, let members = v.orgs[o]?.people {
                let roles = members.compactMap { v.people[$0] }.flatMap(\.roles).filter(\.asserted).map(\.role)
                if roles.contains(.customer) { kind = .client } else if roles.contains(.supplier) { kind = .supplier }
            }
            let place = p.addresses.lazy.compactMap { placeMap[$0] }.first.flatMap { n in dir.places.first { $0.name == n } }
            let next = PeopleSurface.nextMeeting(events, addresses: addrs, now: now)
            let shownMail = hist.filter { $0.kind == .mail }.map(\.ref)
            let capture = hist.contains { $0.kind == .meeting && noCaptureEvents.contains($0.ref) }
                || shownMail.contains { id in
                    guard let x = k.message(id, tier: .user) else { return false }
                    return MailContentPolicy.policy(for: x.m, mailbox: x.mailbox, engine: compliance).preventScreenCapture
                }
            let threads = KnowledgeAsk.threads(of: p, window: nil, hints: [], engine: k, tier: .user)
            let files = Array(KnowledgeAsk.files(in: threads.prefix(40).flatMap(\.messageIds), engine: k, tier: .user).prefix(12))
            return (Page(person: p, history: hist, owes: owes, loops: ls, suggested: sug,
                         since: PeopleSurface.since(first: p.first, now: now, windowDays: k.windowDays), org: org, orgKind: kind,
                         place: place, next: next, nextRedacted: next.map { redacted.contains($0.id) } ?? false,
                         files: files, preventCapture: capture), nil)
        }.value
        guard gen == generation else { return }
        finish(built.0, reason: built.1)
    }

    private func finish(_ p: Page?, reason r: PeopleEmptyReason?) {
        page = p; reason = r; loading = false; loaded = true; preventCapture = p?.preventCapture ?? false
        let line = PeopleSurface.diagnostic(directory: directory.people.count, open: directory.openTotal, page: r, pageShown: true)
        if line != lastLog { lastLog = line; FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    /// Office locations from directory profiles already in memory (hover card, contact card). Never fetched for this.
    private func notePlaces() {
        for d in [HoverCardModel.shared.person, PeopleHub.shared.card?.directory].compactMap({ $0 }) {
            if let a = d.address?.lowercased(), let o = d.officeLocation?.trimmingCharacters(in: .whitespaces), !o.isEmpty { places[a] = o }
        }
    }

    // MARK: Actions

    /// 1: Reply all to my last message in the Waiting conversation, drafted in my voice where the gate allows. Never sends.
    func nudge(_ app: AppModel) {
        guard let id = page?.owes.nudgeMessageId else { return }
        let mail = app.mail
        AppLifecycle.shared.ensureMainWindow()
        app.section = .mail
        mail.reveal(messageId: id)
        mail.reply(.replyAll, to: id)
        guard mail.composer?.original?.id == id, mail.ai.enabled, let a = mail.ai.assistant, let route = a.route(.draftReply),
              let store = mail.store, let m = try? store.message(id: id, includeBody: false),
              a.gate.exposure(m, mailbox: store.mailbox(forFolder: m.folderId), tier: route.tier) == .content else { return }
        mail.ai.draft()
    }

    /// 3: the event editor with this person invited, then Find a time.
    func findTime(_ app: AppModel) {
        guard let p = page?.person else { return }
        app.newEvent()
        guard app.showEditor else { return }
        app.editorDraft.attendees = [Attendee(name: p.name, address: p.addresses.first ?? p.key, response: "none")]
        app.section = .calendar
        AppLifecycle.shared.ensureMainWindow()
        FindTimeHub.shared.find(app)
    }

    /// 2: a OneNote page (NOTES-HOOK). Consent missing / refused → "Connect OneNote" instead of an error.
    func saveNote(_ app: AppModel) {
        guard let p = page?.person, let auth = app.auth, let k = KnowledgeHub.shared.engine(app.mail) else {
            notice = L("OneNote isn't available in this session."); return
        }
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let service = GraphOneNoteService(token: { try await auth.notesToken() })
        let org = page?.org?.name
        noteBusy = true; notice = nil
        Task { @MainActor in
            defer { noteBusy = false }
            do {
                let r = try await PeopleNotes.log(service, person: p.name, address: p.addresses.first ?? p.key, org: org, text: text)
                k.putNote(r)
                noteDraft = ""; noteOpen = false; noteNeedsConsent = false
                app.mail.toast(MailToast(text: L("Note saved to OneNote"), symbol: "note.text"))
                reloadToken += 1
            } catch MailServiceError.offline {
                notice = L("You're offline. The note is still here; try again when connected.")
            } catch let e as MailServiceError {
                switch e {
                case .forbidden, .http(401, _): noteNeedsConsent = true; notice = L("OneNote needs your permission once.")
                default: notice = L("OneNote didn't save the note. The text is still here; try again.")
                }
            } catch {
                // Token errors (no consent yet / interaction required) come from MSAL, not Graph.
                noteNeedsConsent = true
                notice = L("OneNote needs your permission once.")
            }
        }
    }

    func connectOneNote(_ app: AppModel) {
        guard let auth = app.auth else { return }
        Task { @MainActor in
            do { try await auth.grantAccess(scopes: Auth.notesScopes); noteNeedsConsent = false; notice = nil }
            catch { notice = L("OneNote wasn't connected.") }
        }
    }
}

/// The loop source crosses into the detached build (implementations are expected to be thread-safe reads).
struct LoopBox: @unchecked Sendable { let source: (any LoopSource)? }

// MARK: - Surface

struct PeopleSurfaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = PeopleSurfaceModel.shared
        let hub = KnowledgeHub.shared
        HStack(spacing: 0) {
            PeopleDirectoryColumn(model: m).frame(width: 270)
            Rectangle().fill(skin.hair).frame(width: 1)
            Group {
                if case .matter(let pk, let mid)? = hub.page, let k = hub.engine(app.mail) {
                    VStack(alignment: .leading, spacing: 0) {
                        NButton(L("Back to person"), systemImage: "chevron.left", kind: .quiet) { hub.page = nil }.fixedSize().padding(10)
                        KnowledgeMatterPage(engine: k, personKey: pk, matterId: mid)
                    }
                } else {
                    PeoplePersonColumn(model: m)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(skin.hair).frame(width: 1)
            PeopleSideColumn(model: m).frame(width: 290)
        }
        .background(skin.ground)
        // Always-present container: the load runs on open, on selection, after a note and when Mail starts or the
        // lock changes (never on an empty Group).
        .task(id: "\(m.reloadToken)|\(app.mail.started)|\(app.trust.hidesContent)") { await m.refresh(app) }
    }
}

// MARK: Directory column

struct PeopleDirectoryColumn: View {
    @Bindable var model: PeopleSurfaceModel
    @Environment(\.skin) private var skin
    var body: some View {
        let d = model.directory
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel(L("Directory"), color: skin.muted)
                Spacer()
                MonoLabel("\(d.people.count)", color: skin.muted)
                NIconButton("arrow.clockwise", label: L("Refresh"), size: 22) { model.reloadToken += 1 }
            }
            Picker(L("Directory"), selection: $model.tab) {
                Text(L("People")).tag(PeopleSurfaceModel.Tab.people)
                Text(L("Organisations")).tag(PeopleSurfaceModel.Tab.organisations)
                Text(L("Places")).tag(PeopleSurfaceModel.Tab.places)
            }
            .pickerStyle(.segmented).labelsHidden()
            NField(L("Search people"), text: $model.query, style: .bordered, symbol: "magnifyingglass") { model.reloadToken += 1 }
                .onChange(of: model.query) { _, _ in model.reloadToken += 1 }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch model.tab {
                    case .people:
                        if d.people.isEmpty && model.loaded { empty(model.query.isEmpty ? L("No people with visible mail yet.") : L("No match.")) }
                        ForEach(d.people) { r in
                            row(r.name, sub: r.orgName, count: r.open, selected: model.selected.map { r.address == $0 } ?? false) {
                                model.select(address: r.address)
                            }
                        }
                    case .organisations:
                        if d.orgs.isEmpty && model.loaded { empty(L("No organisations yet.")) }
                        ForEach(d.orgs) { o in
                            row(o.name, sub: L("%lld people", o.people), count: PeopleOpenCount(count: o.open, fromLoops: model.loopSource != nil),
                                selected: model.selectedOrg == o.id) { model.selectedOrg = o.id }
                        }
                    case .places:
                        if d.places.isEmpty && model.loaded {
                            empty(L("Places come from office locations in directory profiles you've opened (hover card or contact card). None seen yet."))
                        }
                        ForEach(d.places) { p in
                            row(p.name, sub: L("%lld people", p.people), count: PeopleOpenCount(count: p.open, fromLoops: model.loopSource != nil),
                                selected: model.selectedPlace == p.name) { model.selectedPlace = p.name }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }

    private func row(_ title: String, sub: String?, count: PeopleOpenCount, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(skin.sans(NV.Size.body).weight(selected ? .semibold : .regular)).lineLimit(1)
                    if let sub, !sub.isEmpty { Text(sub).font(.caption2).foregroundStyle(skin.muted).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if count.count > 0 {
                    Text(count.fromLoops ? (count.count == 1 ? L("1 loop") : L("%lld loops", count.count))
                                         : (count.count == 1 ? L("1 open") : L("%lld open", count.count)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(skin.muted)
                        .help(count.fromLoops ? L("Open loops") : L("Open conversations: needs your reply or waiting on them"))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(skin.soft) : AnyShapeStyle(Color.clear))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(skin.ink).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Person column

struct PeoplePersonColumn: View {
    @Bindable var model: PeopleSurfaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let p = model.page {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(p)
                    chips(p)
                    loops(p)
                    history(p)
                    more(p)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                if model.loading || !model.loaded { ProgressView().controlSize(.small) }
                Text(model.loading || !model.loaded ? L("Reading your mail on this Mac…") : Self.text(model.reason))
                    .font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func text(_ r: PeopleEmptyReason?) -> String {
        switch r {
        case .locked?: L("Unlock to see people.")
        case .mailNotStarted?: L("Mail hasn't started yet. Open Mail once; people come from the mail on this Mac.")
        case .noSelection?: L("Pick a person in the directory, or click a sender in Mail.")
        case .ownAddress?: L("That's one of your own addresses.")
        case .noMailInWindow?: L("No mail with this person on this Mac in the last two years.")
        case .hiddenByLabels?: L("There is mail with this person, but its labels keep it out of this view.")
        case nil: L("Nothing to show.")
        }
    }

    private func header(_ p: PeopleSurfaceModel.Page) -> some View {
        let person = p.person
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel(L("Person"), color: skin.muted)
                Spacer()
                if let s = p.since {
                    let lead = p.orgKind == .client ? L("client since") : L("in contact since")
                    MonoLabel(s.atWindowEdge ? lead + " " + L("before %@", String(s.year)) : lead + " " + String(s.year), color: skin.muted)
                        .help(s.atWindowEdge ? L("First contact on this Mac; older mail isn't read") : L("First contact on this Mac"))
                }
            }
            HStack(spacing: 12) {
                SenderAvatar(who: EmailAddress(name: person.name, address: person.addresses.first ?? person.key), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(skin.sans(20).weight(.semibold)).lineLimit(1)
                    if let r = person.primaryRole, r.asserted || r.userAsserted {
                        Text(([r.role.title] + KnowledgeAsk.whyLines(person, role: r.role).prefix(1)).joined(separator: " · "))
                            .font(.caption).foregroundStyle(skin.muted).lineLimit(1)
                    } else {
                        Text(person.addresses.first ?? "").font(.caption).foregroundStyle(skin.muted).textSelection(.enabled)
                    }
                }
                Spacer()
                NButton(L("Contact card"), kind: .ghost) {
                    let ph = PeopleHub.shared; ph.app = app
                    ph.show(address: person.addresses.first ?? person.key, name: person.name); openWindow(id: "people")
                }.fixedSize()
            }
            HStack(spacing: 6) {
                if let o = p.org { NChip(o.name, tone: .muted) }
                if let pl = p.place { NChip(pl.name, tone: .muted) }
            }
            DisclosureGroup(L("Role and corrections")) { KnowledgeRoleSection(person: person) }
                .font(.caption)
        }
    }

    private func chips(_ p: PeopleSurfaceModel.Page) -> some View {
        HStack(spacing: 6) {
            if let l = p.person.last { NChip(L("Last contact %@", Self.relative(l)), tone: .muted) }
            if p.owes.youOwe > 0 { NChip(L("You owe them a reply"), tone: .warning) }
            if p.owes.theyOwe > 0 { NChip(L("They owe you a reply"), tone: .accent) }
            if let n = p.next {
                NChip(L("Next: %@", (p.nextRedacted ? L("meeting") : n.subject) + " " + n.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())), tone: .ink)
            }
        }
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder private func loops(_ p: PeopleSurfaceModel.Page) -> some View {
        if model.loopSource != nil {
            NSectionHeader(L("Loops · %lld open", p.loops.count))
            if p.loops.isEmpty { Text(L("No open loops.")).font(.caption).foregroundStyle(skin.muted) }
            ForEach(p.loops) { l in
                HStack {
                    Image(systemName: l.waitingOn == .me ? "circle.lefthalf.filled" : "circle").accessibilityHidden(true)
                    Text(l.title ?? L("Loop")).font(skin.sans(NV.Size.body)).lineLimit(1)   // LOOPS-HOOK: title is nil when its source is gated
                    if !l.confirmed { NChip(L("suggested"), tone: .muted) }   // LOOPS-HOOK: seeded, not yet confirmed
                    Spacer()
                    if let due = l.due { Text(L("due %@", due.formatted(.dateTime.weekday(.abbreviated)))).font(.caption).foregroundStyle(skin.muted) }
                    else if l.waitingOn == .them { Text(L("waiting on them")).font(.caption).foregroundStyle(skin.muted) }
                }
                .padding(8).background(skin.card)
            }
        } else {
            NSectionHeader(L("Loops · suggested"))
            Text(L("Loops aren't tracked yet; these matters are suggested from your mail.")).font(.caption2).foregroundStyle(skin.muted)
            if p.suggested.isEmpty { Text(L("No matters found with this person.")).font(.caption).foregroundStyle(skin.muted) }
            ForEach(p.suggested) { m in
                Button { KnowledgeHub.shared.page = .matter(person: p.person.key, matter: m.id); KnowledgeHub.shared.revision += 1 } label: {
                    HStack {
                        Image(systemName: "circle.dashed").accessibilityHidden(true)
                        Text(m.title).lineLimit(1)
                        Spacer()
                        Text(m.last, style: .date).font(.caption).foregroundStyle(skin.muted)
                    }
                    .padding(8).background(skin.card).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("Open matter"))
            }
        }
    }

    @ViewBuilder private func history(_ p: PeopleSurfaceModel.Page) -> some View {
        NSectionHeader(L("History"))
        if p.history.isEmpty { Text(L("Nothing yet.")).font(.caption).foregroundStyle(skin.muted) }
        ForEach(p.history) { h in
            Button { open(h) } label: {
                HStack(spacing: 10) {
                    MonoLabel(L(h.kind.rawValue), color: skin.muted).frame(width: 66, alignment: .leading)
                    Text(h.title.map { $0.isEmpty ? L("(no subject)") : $0 } ?? L("(details hidden by its label)"))
                        .font(skin.sans(NV.Size.body)).foregroundStyle(h.title == nil ? skin.muted : skin.ink).lineLimit(1)
                    Spacer()
                    Text(h.date, style: .date).font(.caption).foregroundStyle(skin.muted)
                }
                .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(h.kind == .note ? L("Open in OneNote") : L("Open"))
        }
    }

    /// Kept from the earlier person page (RETHINK §4: files, open promises and voice notes belong to a person).
    @ViewBuilder private func more(_ p: PeopleSurfaceModel.Page) -> some View {
        if !p.files.isEmpty {
            NSectionHeader(L("Files"))
            KnowledgeFileLines(files: p.files)
        }
        NSectionHeader(L("Open promises"))
        KnowledgePromises(conversations: p.person.conversations)
        NSectionHeader(L("Voice notes"))
        KnowledgeVoiceNotes(person: p.person)
    }

    private func open(_ h: PeopleHistoryItem) {
        AppLifecycle.shared.ensureMainWindow()
        switch h.kind {
        case .mail: app.section = .mail; app.mail.reveal(messageId: h.ref)
        case .meeting: app.reveal(eventId: h.ref, at: h.date)
        case .note, .teams: if let u = h.link { NSWorkspace.shared.open(u) }
        }
    }
}

// MARK: Side column: organisation, place, action strip

struct PeopleSideColumn: View {
    @Bindable var model: PeopleSurfaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = orgRow {
                panel {
                    HStack { MonoLabel(L("Organisation"), color: skin.muted); Spacer(); MonoLabel(L("%lld people", o.people), color: skin.muted) }
                    Text(o.name).font(skin.sans(15).weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let k = kind(o) { NChip(k, tone: .muted) }
                        if o.open > 0 { NChip(model.loopSource != nil ? L("%lld loops", o.open) : L("%lld open", o.open), tone: .muted) }
                    }
                }
            }
            if let pl = placeRow {
                panel {
                    HStack { MonoLabel(L("Place"), color: skin.muted); Spacer(); MonoLabel(L("%lld people", pl.people), color: skin.muted) }
                    Text(pl.name).font(skin.sans(15).weight(.semibold)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.page != nil { actions }
        }
        .padding(12)
    }

    private var orgRow: PeopleOrgRow? {
        if model.tab == .organisations, let id = model.selectedOrg { return model.directory.orgs.first { $0.id == id } }
        return model.page?.org
    }
    private var placeRow: PeoplePlaceRow? {
        if model.tab == .places, let n = model.selectedPlace { return model.directory.places.first { $0.name == n } }
        return model.page?.place
    }
    private func kind(_ o: PeopleOrgRow) -> String? {
        if o.isInternal { return L("Internal") }
        guard model.page?.org?.id == o.id, let k = model.page?.orgKind else { return nil }
        switch k { case .client: return L("Client"); case .supplier: return L("Supplier"); case .internalOrg: return L("Internal"); case .external: return nil }
    }

    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6, content: c)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(skin.card)
    }

    private var actions: some View {
        let canNudge = (model.page?.owes.theyOwe ?? 0) > 0 && model.page?.owes.nudgeMessageId != nil
        return VStack(alignment: .leading, spacing: 8) {
            if model.noteOpen {
                Text(L("Log a note")).font(.caption.weight(.semibold))
                TextEditor(text: $model.noteDraft).font(skin.sans(NV.Size.body)).frame(minHeight: 90).scrollContentBackground(.hidden)
                    .background(skin.ground).overlay(Rectangle().strokeBorder(skin.hair))
                Text(L("Saved as a page in your OneNote notebook \"niivo\". Notes follow that notebook's location policy; pages carry no label of their own."))
                    .font(.caption2).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.noteNeedsConsent {
                        NButton(L("Connect OneNote"), kind: .ghost) { model.connectOneNote(app) }.fixedSize()
                    }
                    Spacer()
                    NButton(L("Cancel"), kind: .quiet) { model.noteOpen = false }.fixedSize()
                    NButton(L("Save note"), kind: .primary) { model.saveNote(app) }.fixedSize()
                        .disabled(model.noteBusy || model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let n = model.notice { Text(n).font(.caption2).foregroundStyle(skin.muted) }
            }
            // GLASS: the action strip 1 / 2 / 3 uses glass keys (NiivoGlass.swift); "1" is the primary key.
            Button { model.nudge(app) } label: { strip(L("Send the drafted nudge"), key: "1") }
                .buttonStyle(NiivoGlassKeyStyle(primary: true)).disabled(!canNudge)
                .help(canNudge ? L("Opens a follow-up draft to your last message. Nothing is sent until you send it.") : L("Only when they owe you a reply"))
            HStack(spacing: 8) {
                Button { model.noteOpen.toggle() } label: { strip(L("Log a note"), key: "2") }.buttonStyle(NiivoGlassKeyStyle())
                Button { model.findTime(app) } label: { strip(L("Find time"), key: "3") }.buttonStyle(NiivoGlassKeyStyle())
            }
        }
        .padding(10).background(skin.soft)
    }

    private func strip(_ title: String, key: String) -> some View {
        HStack {
            Text(title).font(skin.sans(NV.Size.body)).lineLimit(1)
            Spacer(minLength: 6)
            NiivoKeyCap(key: key)
        }
        .frame(maxWidth: .infinity)
    }
}
