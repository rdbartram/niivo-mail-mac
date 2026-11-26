import SwiftUI
import CalendarCore
import MailCore

// Stories UI: the reader's "Related" strip and the message list's "Stories" grouping mode. Engine: MailCore
// StoryEngine (on-device, sealed). Wired in by `// STORY-HOOK` lines only: SearchViews (attach / close),
// MailReader (strip), MailViews (list switch), MailShell (niivo toggle), MailModel (screenPolicy).
// No @State: all state lives in the @Observable `StoryHub`.

@MainActor @Observable
final class StoryHub {
    static let shared = StoryHub()

    struct Strip {
        var storyId: String
        var title: String
        var size: Int
        var members: [StoryMember]
        /// Merged policy of everything the strip shows (title words included): fed into MailModel.screenPolicy.
        var policy: ContentPolicy
    }

    /// List mode: group by story instead of by conversation.
    var active: Bool = UserDefaults.standard.bool(forKey: "mail.groupStories") {
        didSet { UserDefaults.standard.set(active, forKey: "mail.groupStories") }
    }
    @ObservationIgnored private(set) var store: MailStore?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var compliance: CachedLabelPolicyEngine?
    @ObservationIgnored private var onDeviceTitles = false
    @ObservationIgnored private var titleRequests: Set<String> = []
    /// Bumped (throttled) while the background linker makes progress, so open strips / lists refresh.
    private(set) var generation = 0
    private(set) var related: [String: Strip] = [:]
    /// message id → story id (stories with ≥ 2 members), story id → size.
    private(set) var keys: [String: String] = [:]
    private(set) var sizes: [String: Int] = [:]
    /// On-device (FoundationModels) titles, memory only.
    private(set) var titles: [String: String] = [:]
    /// Listed rows whose content the on-device rule allows (computed off the main thread in refreshKeys).
    @ObservationIgnored private var allowedIds: Set<String> = []

    /// STORY-HOOK target (SearchHub.attach): attach the engine with the on-device content rule and link in the background.
    func attach(store: MailStore, gate: AIGatePolicy, compliance: CachedLabelPolicyEngine) {
        close()
        self.store = store
        self.compliance = compliance
        onDeviceTitles = gate.allows(.onDevice)
        _ = try? store.enableStories(gate: { m, mb in gate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        maintenance = Task.detached(priority: .background) { [weak self] in
            var last = Date.distantPast, progressed = false, loggedOnce = false
            while !Task.isCancelled {
                let n = (try? store.stories?.catchUp(maxItems: 64)) ?? 0
                if n > 0 { progressed = true }
                if n == 0 && !loggedOnce { loggedOnce = true; progressed = true }   // shape log once per launch, even when already caught up
                if progressed && (n == 0 || Date().timeIntervalSince(last) > 3) {
                    progressed = false; last = Date()
                    if n == 0, let sh = store.stories?.debugShape() {   // content-free shape, once caught up
                        FileHandle.standardError.write(Data("[Story] rows=\(sh.rows) stories=\(sh.stories) largest=\(sh.largest) inStories=\(Int(sh.inStories * 100))% sizes=\(store.stories?.debugSizeBuckets() ?? [:]) \(store.stories?.debugLinks() ?? "")\n".utf8))
                    }
                    await MainActor.run { self?.generation += 1 }
                }
                try? await Task.sleep(for: n > 0 ? .milliseconds(30) : .seconds(4))
            }
        }
    }

    /// STORY-HOOK target (SearchHub.close: lock / sign-out): stop and drop every decrypted result.
    func close() {
        maintenance?.cancel(); maintenance = nil
        store?.stories?.dropMemory()
        store = nil; compliance = nil; related = [:]; keys = [:]; sizes = [:]; titles = [:]; titleRequests = []
    }

    private func policy(_ m: MailMessage, _ mb: String) -> ContentPolicy {
        compliance.map { MailContentPolicy.policy(for: m, mailbox: mb, engine: $0) } ?? MailContentPolicy.failClosed(for: m)
    }

    /// STORY-HOOK target (MailModel.screenPolicy): what the Related strip of the open message shows.
    func screenPolicy(readerId: String?) -> ContentPolicy {
        guard let id = readerId, let s = related[id] else { return .open }
        return s.policy
    }

    func loadRelated(_ id: String) async {
        guard let st = store?.stories else { return }
        let snap = await Task.detached(priority: .userInitiated) { st.story(messageId: id, limit: 9) }.value
        guard let snap, snap.size > 1 else { related.removeValue(forKey: id); return }
        let members = snap.members.filter { $0.id != id }
        let pol = members.reduce(ContentPolicy.open) { $0.merged(with: policy($1.message, $1.mailbox)) }
        if related.count > 40 { related = [:] }
        let key = titleKey(snap.id, snap.titleSubjects)
        related[id] = Strip(storyId: snap.id, title: titles[key] ?? snap.fallbackTitle, size: snap.size, members: members, policy: pol)
        requestTitle(key, subjects: snap.titleSubjects) { [weak self] t in self?.related[id]?.title = t }
    }

    func refreshKeys(for rows: [MailRow]) async {
        guard let st = store?.stories, !rows.isEmpty else { keys = [:]; return }
        let ids = rows.map(\.id), pairs = rows.map { ($0.message, $0.mailbox) }
        let (k, allowed) = await Task.detached(priority: .userInitiated) {
            let k = st.storyKeys(messageIds: ids)
            return (k, Set(pairs.filter { k[$0.0.id] != nil && st.contentAllowed($0.0, mailbox: $0.1) }.map(\.0.id)))
        }.value
        allowedIds = allowed
        keys = k.mapValues(\.id)
        sizes = Dictionary(k.values.map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    /// Title for a list group: on-device title if one was made from these (content-allowed) subjects, else fallback.
    func listTitle(storyId: String, rows: [MailRow]) -> String {
        let subs = allowedSubjects(rows)
        if let t = titles[titleKey(storyId, subs)] { return t }
        let shown = rows.filter { !$0.policy.redactDetails }.map(\.message.subject)
        return StoryTitles.fallback(subjects: shown) ?? "Related messages"
    }

    func requestListTitle(storyId: String, rows: [MailRow]) {
        let subs = allowedSubjects(rows)
        requestTitle(titleKey(storyId, subs), subjects: subs) { _ in }
    }

    private func allowedSubjects(_ rows: [MailRow]) -> [String] {
        rows.filter { !$0.policy.redactDetails && allowedIds.contains($0.id) }.map(\.message.subject)
    }

    private func titleKey(_ id: String, _ subjects: [String]) -> String { id + "|" + subjects.sorted().joined(separator: "\u{1F}") }

    private func requestTitle(_ key: String, subjects: [String], then: @escaping (String) -> Void) {
        guard onDeviceTitles, subjects.count >= 2, titles[key] == nil, !titleRequests.contains(key) else { return }
        titleRequests.insert(key)
        Task { [weak self] in
            guard let t = await StoryTitles.onDeviceTitle(subjects: subjects), let self, self.store != nil else { return }
            self.titles[key] = t
            then(t)
        }
    }
}

// MARK: - Reader: Related strip

struct RelatedStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var reader: ReaderState

    var body: some View {
        let hub = StoryHub.shared
        // Only in the reading pane: MailModel.screenPolicy covers the pane's strip (message windows decide capture
        // blocking from their own message alone, so they don't show related subjects).
        let inPane = app.mail.reader?.header.id == reader.header.id
        let strip = reader.policy.redactDetails || !inPane ? nil : hub.related[reader.header.id]
        VStack(alignment: .leading, spacing: 0) {
            if let s = strip, !s.members.isEmpty {
                HStack(spacing: 6) {
                    NSymbol("point.3.connected.trianglepath.dotted", size: 10, label: "Related").foregroundStyle(.secondary)
                    Text(app.skin.caps("Related · " + s.title))
                        .font(app.theme.brand ? app.skin.mono(NV.Size.labelSm, .medium) : .caption.weight(.semibold))
                        .tracking(app.skin.track(NV.Size.labelSm))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if s.size - 1 > s.members.count {
                        Text("\(s.size - 1) in this story").font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 4)
                .help("Related across conversations, folders and mailboxes. Worked out on this Mac.")
                ForEach(s.members) { m in row(m) }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .padding(.bottom, strip?.members.isEmpty == false ? 8 : 0)
        .task(id: "\(reader.header.id)#\(hub.generation)") { await hub.loadRelated(reader.header.id) }
    }

    private func row(_ m: StoryMember) -> some View {
        let p = app.mail.policy(for: m.message, mailbox: m.mailbox)
        let subject = m.message.subject.isEmpty ? "(no subject)" : m.message.subject
        return HStack(spacing: 8) {
            NSymbol("arrow.turn.down.right", size: 9).foregroundStyle(.secondary)
            Text(p.redactDetails ? "Private" : (m.message.from?.display ?? "")).font(.caption.weight(.medium)).lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Text(p.redactDetails ? "Private message" : subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if m.mailbox != reader.mailbox {
                if app.theme.brand { NChip(MailboxDisplay.title(m.mailbox), tone: .ink) }
                else { Text(MailboxDisplay.title(m.mailbox)).font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
            }
            Text(MessageRowView.time(m.message.received)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { app.mail.selectedMessageId = m.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(id: "message", value: m.id) })
        .help("Open · double-click for a window")
    }
}

// MARK: - List: Stories grouping mode

/// STORY-HOOK target (MessageListView): the stories list when the mode is on (and no search is showing), else the
/// normal list. Classic themes also get the Stories toggle in the toolbar from here.
struct StoryListSwitch<Content: View>: View {
    @Environment(AppModel.self) private var app
    let mail: MailModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if StoryHub.shared.active && mail.searchResults == nil { StoryListView(mail: mail) } else { content() }
        }
        .modifier(StoryToolbarToggle(enabled: !app.theme.brand))
    }
}

private struct StoryToolbarToggle: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: Bindable(StoryHub.shared).active) { Label("Stories", systemImage: "point.3.connected.trianglepath.dotted") }
                        .toggleStyle(.button).help("Group related mail into stories (worked out on this Mac)")
                }
            }
        } else { content }
    }
}

/// niivo header button (MailShell, next to Group by conversation).
struct StoryModeButton: View {
    var body: some View {
        NIconButton("point.3.connected.trianglepath.dotted", label: "Group by story",
                    help: "Group related mail into stories (worked out on this Mac)", isOn: StoryHub.shared.active) { StoryHub.shared.active.toggle() }
    }
}

struct StoryListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool
    let mail: MailModel

    struct Section: Identifiable {
        var id: String
        var storyId: String?
        var rows: [(index: Int, row: MailRow)]
    }

    var body: some View {
        let hub = StoryHub.shared
        let rows = mail.visibleRows
        let sections = Self.sections(rows, keys: hub.keys)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { sec in
                    if let sid = sec.storyId {
                        header(sid, sec.rows.map(\.row), size: hub.sizes[sid] ?? sec.rows.count)
                    }
                    ForEach(sec.rows, id: \.row.id) { item in rowView(item.index, item.row, grouped: sec.storyId != nil) }
                }
                if mail.isLoadingMore { ProgressView().controlSize(.small).padding() }
                else if rows.isEmpty { EmptyList() }
            }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { MailKeys.handle($0, mail: mail) }
        .onAppear { focused = true }
        .task(id: "\(rows.map(\.id).joined(separator: ",").hashValue)#\(hub.generation)") {
            await hub.refreshKeys(for: rows)
            for sec in Self.sections(rows, keys: hub.keys).prefix(12) {
                if let sid = sec.storyId { hub.requestListTitle(storyId: sid, rows: sec.rows.map(\.row)) }
            }
        }
    }

    /// Newest first; a story's rows are pulled up to its newest row. Rows without a story (here) stay single.
    static func sections(_ rows: [MailRow], keys: [String: String]) -> [Section] {
        var count: [String: Int] = [:]
        for r in rows { if let s = keys[r.id] { count[s, default: 0] += 1 } }
        var out: [Section] = [], at: [String: Int] = [:]
        for (i, r) in rows.enumerated() {
            if let s = keys[r.id], (count[s] ?? 0) >= 2 {
                if let k = at[s] { out[k].rows.append((i, r)) } else { at[s] = out.count; out.append(Section(id: "story:" + s, storyId: s, rows: [(i, r)])) }
            } else {
                out.append(Section(id: r.id, storyId: nil, rows: [(i, r)]))
            }
        }
        return out
    }

    private func header(_ sid: String, _ rows: [MailRow], size: Int) -> some View {
        let skin = app.skin
        let title = StoryHub.shared.listTitle(storyId: sid, rows: rows)
        return HStack(spacing: 6) {
            NSymbol("point.3.connected.trianglepath.dotted", size: 10, label: "Story").foregroundStyle(.secondary)
            if app.theme.brand { MonoLabel(title, size: NV.Size.labelSm, color: skin.ink, weight: .medium).lineLimit(1) }
            else { Text(title).font(.caption.weight(.semibold)).lineLimit(1) }
            Spacer()
            Text(size > rows.count ? "\(rows.count) here · \(size) in story" : "\(rows.count)")
                .font(app.theme.brand ? skin.mono(NV.Size.labelSm) : .caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder private func rowView(_ i: Int, _ row: MailRow, grouped: Bool) -> some View {
        let selected = row.id == mail.selectedMessageId
        let base = MessageRowView(row: row, selected: selected)
            .padding(.leading, grouped ? 10 : 0)
            .overlay(alignment: .leading) { if grouped { Rectangle().fill(app.theme.accent.opacity(0.5)).frame(width: 2).padding(.leading, 4) } }
            .id(row.id)
            .contentShape(Rectangle())
            .onTapGesture {
                mail.selectedMessageId = row.id; focused = true
                if row.message.isDraft { mail.openDraft(id: row.id) }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if row.message.isDraft { mail.openDraft(id: row.id) } else { openWindow(id: "message", value: row.id) }
            })
            .onAppear { mail.rowAppeared(index: i) }
            .contextMenu { RowMenu(row: row) }
        if app.theme.brand {
            base.nRow(selected: selected, hoverKey: AnyHashable("story:" + row.id), skin: app.skin)
        } else {
            base
        }
    }
}
