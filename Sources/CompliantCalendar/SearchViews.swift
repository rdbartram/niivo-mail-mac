import SwiftUI
import CalendarCore
import MailCore

// Search window: ranked results with a facet rail, and person / company / project pages from the communication
// graph. Built only from NiivoUI components (NField, NTabs, NChip, NButton, NMenuButton, NPicker, .nRow, NGlyph).
// Wired into the app by `// SEARCH-HOOK` lines only (CompliantCalendarApp: window + command; MailModel: hub).
// No @State: all state lives in the @Observable `SearchHub`.

// MARK: - Model

@MainActor @Observable
final class SearchHub {
    enum Page: Equatable {
        case results
        case person(PersonPage)
        case company(CompanyPage)
        case project(ProjectPage)
    }
    enum Scope: String, CaseIterable, Hashable { case all = "All", people = "People", companies = "Companies", projects = "Projects" }

    @ObservationIgnored private(set) var store: MailStore?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    var mailboxes: [String] = ["me"]
    var mailbox = "me"
    var query = "" { didSet { if oldValue != query { schedule() } } }
    var scope: Scope = .all { didSet { if scope != .all { refreshDirectory() } } }
    private(set) var result: SearchResult?
    /// Highlighted hit (single click / ↑↓); ↩ opens it in the main window's reader.
    var selectedHitId: String?
    private(set) var searching = false
    private(set) var page: Page = .results
    private(set) var back: [Page] = []
    private(set) var people: [PersonNode] = []
    private(set) var companies: [CompanyNode] = []
    private(set) var projects: [GraphProject] = []
    /// Background index status ("Building graph… 40%") for the footer.
    private(set) var status: String?
    var labelNames: [String: String] = [:]

    /// SEARCH-HOOK target (MailModel.afterOpen): attach graph + semantic index to the open store and keep them
    /// current in the background (graph backfill, BM25 reindex of rows from older builds, on-device embedding).
    func attach(store: MailStore, me: String, mailboxes: [String], internalDomains: Set<String>,
                compliance: CachedLabelPolicyEngine, onDeviceAccess: AIOrgAccess) {
        close()
        self.store = store
        self.mailboxes = mailboxes
        labelNames = Dictionary(compliance.availableLabels().map { ($0.id.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        _ = try? store.enableCommGraph(owners: Set([me] + mailboxes.filter { $0 != "me" }).subtracting([""]), internalDomains: internalDomains)
        let gate = AIGatePolicy(engine: compliance, cloudAccess: .off, onDeviceAccess: onDeviceAccess)
        store.enableSemanticIndex(embedder: onDeviceAccess == .off ? nil : AppleSentenceEmbedder(), windowDays: 90,
                                  policy: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        StoryHub.shared.attach(store: store, gate: gate, compliance: compliance)   // STORY-HOOK
        maintenance = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                var idle = true
                if !store.searchIndexCurrent { _ = try? store.reindexStep(maxRows: 2_000); idle = false }
                if !store.graphBackfillDone { _ = try? store.graphBackfillStep(maxRows: 2_000); idle = false }
                if let s = store.semantic, ((try? s.catchUp(maxItems: 64)) ?? 0) > 0 { idle = false }
                let st: String? = !store.graphBackfillDone ? "Building the people & projects graph…"
                    : (store.semantic?.pendingCount ?? 0) > 0 ? "Indexing for meaning on this Mac…" : nil
                await MainActor.run { self?.status = st }
                try? await Task.sleep(for: idle ? .seconds(20) : .milliseconds(50))
            }
        }
        refreshDirectory()
    }

    /// SEARCH-HOOK target (MailModel.suspendForLock / sign-out): drop the store and every decrypted result.
    func close() {
        maintenance?.cancel(); running?.cancel()
        store?.semantic?.dropMemory()
        StoryHub.shared.close()   // STORY-HOOK
        store = nil; result = nil; page = .results; back = []; people = []; companies = []; projects = []; status = nil
    }

    func refreshDirectory() {
        guard let g = store?.graph else { return }
        people = g.people().filter { $0.bulk == 0 || $0.total.n > 0 }.sorted { $0.total.weight(at: Int64(Date().timeIntervalSince1970)) > $1.total.weight(at: Int64(Date().timeIntervalSince1970)) }.prefix(200).map { $0 }
        companies = g.companies().sorted { ($0.total.n, $0.domain) > ($1.total.n, $1.domain) }.prefix(200).map { $0 }
        projects = g.projects(limit: 200)
    }

    private func schedule() {
        running?.cancel()
        let q = query, mb = mailbox, labels = labelNames
        guard let store, !q.trimmingCharacters(in: .whitespaces).isEmpty else { result = nil; searching = false; return }
        searching = true
        running = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let r = await Task.detached(priority: .userInitiated) {
                var o = SearchEngine.Options(mailbox: mb, limit: 100)
                o.match = .natural   // SEARCHQ-HOOK: relaxed matching + expansions (docs/SEARCH-QUALITY.md, "ask-typed")
                o.labelName = { labels[$0.lowercased()] }
                return SearchEngine(store: store).search(q, o)
            }.value
            guard !Task.isCancelled else { return }
            self?.result = r; self?.searching = false
            self?.selectedHitId = r.hits.first?.message.id
            if self?.page != .results { self?.back = []; self?.page = .results }
        }
    }

    func refine(_ op: String) {
        guard !query.contains(op) else { return }
        query = (query.trimmingCharacters(in: .whitespaces) + " " + op + " ")
    }

    /// ↑ / ↓ over the hits.
    func moveSelection(_ d: Int) {
        guard let hits = result?.hits, !hits.isEmpty else { return }
        let i = hits.firstIndex { $0.message.id == selectedHitId } ?? (d > 0 ? -1 : hits.count)
        selectedHitId = hits[max(0, min(hits.count - 1, i + d))].message.id
    }

    private func push(_ p: Page) { back.append(page); page = p }
    func goBack() { page = back.popLast() ?? .results }

    func openPerson(_ address: String) {
        guard let store else { return }
        push(.person(SearchPages.person(address, store: store, mailbox: mailbox)))
    }
    func openCompany(_ domain: String) {
        guard let store else { return }
        push(.company(SearchPages.company(domain, store: store, mailbox: mailbox)))
    }
    func openProject(_ id: String) {
        guard let store, let p = SearchPages.project(id, store: store, mailbox: mailbox) else { return }
        push(.project(p))
    }
}

// MARK: - Commands + window

struct SearchCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search People, Companies & Projects") {
                // TODAY-HOOK: ⌘⇧F in Today starts Flow; elsewhere it opens the search window.
                if let app = AppLifecycle.shared.model, app.section == .mail, TodayModel.shared.isActive(app.mail) {
                    TodayModel.shared.startFlow(app.mail)
                } else { openWindow(id: "search") }
            }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

struct SearchWindowRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        // ORG2-HOOK: one window-level shield, also covering the in-place reader (fail closed while it loads).
        SecondaryWindow(captureBlocked: model.mail.screenPolicy.preventScreenCapture || SearchReaderState.shared.blocksCapture) {
            SearchScreen(hub: model.mail.search)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Screen

struct SearchScreen: View {
    @Bindable var hub: SearchHub
    @Environment(\.skin) private var skin
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(skin.hair).frame(height: 1)
            if hub.store == nil {
                emptyState("Mail isn't open yet.", glyph: .search)
            } else {
                switch hub.page {
                case .results: resultsPage
                case .person(let p): PersonPageView(page: p, hub: hub)
                case .company(let c): CompanyPageView(page: c, hub: hub)
                case .project(let p): ProjectPageView(page: p, hub: hub)
                }
            }
            if let s = hub.status {
                HStack { Text(s).font(.caption).foregroundStyle(skin.muted); Spacer() }.padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .background(skin.ground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !hub.back.isEmpty { NButton("Back", systemImage: "chevron.left", kind: .ghost) { hub.goBack() } }
            NField("Search mail, people, companies, projects — from: company: project: has:attachment after:30d",
                   text: $hub.query, symbol: "magnifyingglass",
                   onSubmit: { if let id = hub.selectedHitId ?? hub.result?.hits.first?.message.id { hub.selectedHitId = id; SearchReaderState.shared.opened = id } })   // ORG2-HOOK: reader in place
                .onKeyPress(.downArrow) { hub.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { hub.moveSelection(-1); return .handled }
            if hub.mailboxes.count > 1 {
                NPicker("Mailbox", selection: $hub.mailbox, options: hub.mailboxes, label: { $0 == "me" ? "My mailbox" : $0 })
                    .frame(width: 200)
            }
            NMenuButton(label: "Browse", symbol: "line.3.horizontal.decrease", items: [
                NMenuItem(title: "People", action: { hub.query = ""; hub.scope = .people; hub.refreshDirectory() }),
                NMenuItem(title: "Companies", action: { hub.query = ""; hub.scope = .companies; hub.refreshDirectory() }),
                NMenuItem(title: "Projects", action: { hub.query = ""; hub.scope = .projects; hub.refreshDirectory() }),
            ])
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var resultsPage: some View {
        HStack(alignment: .top, spacing: 0) {
            FacetRail(hub: hub).frame(width: 240)
            Rectangle().fill(skin.hair).frame(width: 1)
            VStack(spacing: 0) {
                NTabs(title: "Scope", items: SearchHub.Scope.allCases, selection: $hub.scope, label: { $0.rawValue },
                      count: { s in count(s) }, divider: true, horizontalPadding: 16)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        switch hub.scope {
                        case .all: messageRows
                        case .people: ForEach(hub.people, id: \.address) { p in
                            EntityRow(glyph: .person, title: p.displayName, subtitle: p.address, detail: "\(p.total.n) messages") { hub.openPerson(p.address) }
                        }
                        case .companies: ForEach(hub.companies, id: \.domain) { c in
                            EntityRow(glyph: .company, title: c.displayName, subtitle: c.domain, detail: "\(c.people.count) people · \(c.total.n) messages") { hub.openCompany(c.domain) }
                        }
                        case .projects: ForEach(hub.projects) { p in
                            EntityRow(glyph: .project, title: p.name, subtitle: p.kind.rawValue.capitalized, detail: "\(p.conversations) conversations") { hub.openProject(p.id) }
                        }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { hub.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { hub.moveSelection(-1); return .handled }
                .onKeyPress(.return) {
                    guard let id = hub.selectedHitId else { return .ignored }
                    SearchReaderState.shared.opened = id; return .handled   // ORG2-HOOK: reader in place
                }
                .onChange(of: hub.selectedHitId) { _, id in if let id { proxy.scrollTo("hit:" + id) } }
                }
            }
            SearchReaderColumn()   // ORG2-HOOK: one click / ↩ opens the reader here (SearchReaderPane.swift)
        }
    }

    private func count(_ s: SearchHub.Scope) -> Int {
        switch s {
        case .all: hub.result?.total ?? 0
        case .people: hub.people.count
        case .companies: hub.companies.count
        case .projects: hub.projects.count
        }
    }

    @ViewBuilder private var messageRows: some View {
        if let r = hub.result {
            if r.hits.isEmpty { emptyState(hub.searching ? "Searching…" : "No matches in the local cache.", glyph: .search) }
            ForEach(r.hits) { h in ResultRow(hit: h, hub: hub).id("hit:" + h.message.id) }
        } else {
            emptyState("Type to search. Ranked by words and meaning, on this Mac.", glyph: .search)
        }
    }

    private func emptyState(_ text: String, glyph: NGlyphKind) -> some View {
        VStack(spacing: 10) {
            NGlyph(glyph, size: 28, label: "")
            Text(text).foregroundStyle(skin.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

// MARK: - Rows

struct ResultRow: View {
    let hit: SearchHit
    let hub: SearchHub
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = hit.message
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.from?.display ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink).lineLimit(1)
                    if m.hasAttachments { NGlyph(.archive, size: 11, label: "Attachment") }
                    if hit.semanticRank != nil && hit.keywordRank == nil { NChip("Similar", tone: .accent) }
                    ForEach(m.categories.prefix(2), id: \.self) { NChip($0, tone: .muted) }
                    Spacer()
                    Text(m.received, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(skin.muted)
                }
                Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(.system(size: 13)).foregroundStyle(skin.ink).lineLimit(1)
                if let p = m.preview, !p.isEmpty { Text(p).font(.caption).foregroundStyle(skin.muted).lineLimit(1) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .nRow(selected: hub.selectedHitId == m.id, hoverKey: "search:" + hit.id, skin: skin)
        .contentShape(Rectangle())
        // One click / ↩ opens it in the search window's reader column; double-click opens its own message window;
        // "Show in Mail" (reader header or context menu) reveals it in the main window.
        .onTapGesture { hub.selectedHitId = m.id; SearchReaderState.shared.opened = m.id }   // ORG2-HOOK: reader in place
        .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(id: "message", value: m.id) })
        .contextMenu {
            Button("Show in Mail") { app.openMailMessage(m.id, raise: true) }   // ORG2-HOOK
            if let a = m.from?.address { Button("Show person") { hub.openPerson(a) } }
            if let d = m.from.flatMap({ MailDomains.companyKey(for: $0.address) }) { Button("Show company") { hub.openCompany(d) } }
        }
    }
}

struct EntityRow: View {
    var glyph: NGlyphKind
    var title: String
    var subtitle: String
    var detail: String
    var action: () -> Void
    @Environment(\.skin) private var skin
    var body: some View {
        HStack(spacing: 10) {
            NGlyph(glyph, size: 16, label: "")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(skin.ink).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(skin.muted).lineLimit(1)
            }
            Spacer()
            Text(detail).font(.caption).foregroundStyle(skin.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .nRow(selected: false, hoverKey: "entity:" + glyph.rawValue + subtitle, skin: skin)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct ThreadRow: View {
    let t: ThreadSummary
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 8) {
            if t.awaitingMe { NChip("Awaiting you", tone: .warning) } else { NChip("Awaiting them", tone: .muted) }
            Text(t.latest.subject.isEmpty ? "(no subject)" : t.latest.subject).foregroundStyle(skin.ink).lineLimit(1)
            Spacer()
            Text("\(t.count)").font(.caption).foregroundStyle(skin.muted)
            Text(t.latest.received, format: .dateTime.day().month()).font(.caption).foregroundStyle(skin.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .nRow(selected: false, hoverKey: "thread:" + t.id, skin: skin)
        .contentShape(Rectangle())
        .onTapGesture { app.openMailMessage(t.latest.id, raise: false) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(id: "message", value: t.latest.id) })
    }
}

// MARK: - Facet rail

struct FacetRail: View {
    let hub: SearchHub
    @Environment(\.skin) private var skin
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let f = hub.result?.facets {
                    group("People", f.people, glyph: .person)
                    group("Companies", f.companies, glyph: .company)
                    group("Projects", f.projects, glyph: .project)
                    group("Date", f.dates, glyph: .calendar)
                    group("Attachments", f.attachments, glyph: .archive)
                    group("Labels", f.labels, glyph: .encrypted)
                    group("Folders", f.folders, glyph: .mail)
                    if f.mailboxes.count > 1 { group("Mailboxes", f.mailboxes, glyph: .mail) }
                } else {
                    Text("Facets appear with results.").font(.caption).foregroundStyle(skin.muted)
                }
            }.padding(14)
        }
        .background(skin.soft)
    }

    @ViewBuilder private func group(_ title: String, _ values: [FacetValue], glyph: NGlyphKind) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { NGlyph(glyph, size: 12, label: ""); Text(title.uppercased()).font(.caption2).foregroundStyle(skin.muted) }
                ForEach(values) { v in
                    HStack {
                        Text(v.label).font(.system(size: 12)).foregroundStyle(skin.ink).lineLimit(1)
                        Spacer()
                        NChip("\(v.count)", tone: .muted)
                    }
                    .padding(.vertical, 2)
                    .nRow(selected: false, hoverKey: "facet:" + title + v.key, divider: false, skin: skin)
                    .contentShape(Rectangle())
                    .onTapGesture { if let r = v.refinement { hub.refine(r) } }
                    .contextMenu {
                        if title == "People" { Button("Show person") { hub.openPerson(v.key) } }
                        if title == "Companies" { Button("Show company") { hub.openCompany(v.key) } }
                        if title == "Projects" { Button("Show project") { hub.openProject(v.key) } }
                    }
                }
            }
        }
    }
}

// MARK: - Entity pages

private struct PageHeader: View {
    var glyph: NGlyphKind
    var title: String
    var subtitle: String
    var chips: [String]
    @Environment(\.skin) private var skin
    var body: some View {
        HStack(spacing: 12) {
            NGlyph(glyph, size: 26, label: "")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(skin.ink)
                HStack(spacing: 6) {
                    Text(subtitle).font(.caption).foregroundStyle(skin.muted)
                    ForEach(chips, id: \.self) { NChip($0, tone: .muted) }
                }
            }
            Spacer()
        }.padding(16)
    }
}

private struct Section_<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.skin) private var skin
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.caption2).foregroundStyle(skin.muted).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            content()
        }
    }
}

struct PersonPageView: View {
    let page: PersonPage
    let hub: SearchHub
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(glyph: .person, title: page.name, subtitle: page.address,
                           chips: [page.isInternal ? "Internal" : "External", "\(page.received) received", "\(page.sent) sent"]
                               + (page.lastContact.map { ["Last " + $0.formatted(date: .abbreviated, time: .omitted)] } ?? []))
                if let c = page.company {
                    HStack { NButton(c.name, systemImage: "building.2", kind: .ghost) { hub.openCompany(c.domain) }; Spacer() }.padding(.horizontal, 16)
                }
                if !page.openThreads.isEmpty { Section_(title: "Open threads (30 days)") { ForEach(page.openThreads) { ThreadRow(t: $0) } } }
                Section_(title: "History") {
                    ForEach(page.months) { m in
                        HStack { Text(m.month).monospacedDigit(); Spacer(); NChip("↓ \(m.received)", tone: .muted); NChip("↑ \(m.sent)", tone: .muted) }
                            .padding(.horizontal, 16).padding(.vertical, 3)
                    }
                }
                if !page.projects.isEmpty {
                    Section_(title: "Related projects") {
                        ForEach(page.projects) { p in EntityRow(glyph: .project, title: p.name, subtitle: p.kind.rawValue.capitalized, detail: "\(p.conversations) threads") { hub.openProject(p.id) } }
                    }
                }
                if !page.relatedPeople.isEmpty {
                    Section_(title: "Often with") {
                        ForEach(page.relatedPeople) { r in EntityRow(glyph: .person, title: r.name, subtitle: r.address, detail: "\(r.count)") { hub.openPerson(r.address) } }
                    }
                }
            }
        }
    }
}

struct CompanyPageView: View {
    let page: CompanyPage
    let hub: SearchHub
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(glyph: .company, title: page.name, subtitle: page.domain,
                           chips: [page.isInternal ? "Internal" : "External", "\(page.people.count) people", "\(page.messageCount) messages"])
                if !page.openThreads.isEmpty { Section_(title: "Open threads (30 days)") { ForEach(page.openThreads.prefix(10)) { ThreadRow(t: $0) } } }
                Section_(title: "People") {
                    ForEach(page.people) { p in EntityRow(glyph: .person, title: p.name, subtitle: p.address, detail: "\(p.count)") { hub.openPerson(p.address) } }
                }
                if !page.projects.isEmpty {
                    Section_(title: "Projects") {
                        ForEach(page.projects) { p in EntityRow(glyph: .project, title: p.name, subtitle: p.kind.rawValue.capitalized, detail: "\(p.conversations) threads") { hub.openProject(p.id) } }
                    }
                }
                Section_(title: "Recent threads") { ForEach(page.threads) { ThreadRow(t: $0) } }
            }
        }
    }
}

struct ProjectPageView: View {
    let page: ProjectPage
    let hub: SearchHub
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(glyph: .project, title: page.project.name, subtitle: page.project.kind.rawValue.capitalized,
                           chips: ["\(page.messageCount) messages"] + (page.lastActivity.map { ["Last " + $0.formatted(date: .abbreviated, time: .omitted)] } ?? []))
                Section_(title: "Threads") { ForEach(page.threads) { ThreadRow(t: $0) } }
                Section_(title: "People") {
                    ForEach(page.people) { p in EntityRow(glyph: .person, title: p.name, subtitle: p.address, detail: "\(p.count)") { hub.openPerson(p.address) } }
                }
                if !page.companies.isEmpty {
                    Section_(title: "Companies") {
                        ForEach(page.companies) { c in EntityRow(glyph: .company, title: c.name, subtitle: c.domain, detail: "\(c.count)") { hub.openCompany(c.domain) } }
                    }
                }
            }
        }
    }
}
