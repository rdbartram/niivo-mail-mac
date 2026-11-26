import SwiftUI
import AppKit
import MailCore

// Message-list organisation state: filters, smart views, search scope + memory, master categories, keymap.
// Decisions live in MailCore (MailOrganise.swift, MailCategories.swift, MailScopedSearch.swift, MailUndo.swift) so
// CoreSelfTest covers them; views are in MailOrganiseViews.swift.

enum KeymapStyle: String, CaseIterable, Identifiable {
    case niivo, outlook, gmail   // THREAD-HOOK: gmail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .niivo: "niivo (single keys)"
        case .outlook: "Outlook compatible (⌘R, ⇧⌘R, ⌘J, ⇧⌘V)"
        case .gmail: "Gmail shortcuts (j/k threads, n/p messages, o, x, u)"
        }
    }
}

@MainActor @Observable final class MailListUI {
    static let shared = MailListUI()

    /// Filter bar over the current list (nil = all).
    var filter: SmartView? {
        didSet { if filter == .mentions, oldValue != .mentions, let mail { Task { await loadMentions(mail: mail) } } }
    }
    /// Server-reported ids that mention the user, per mailbox (beta, read-only; empty when unavailable).
    private(set) var mentioned: [String: Set<String>] = [:]
    private(set) var mentionsNote: String?

    /// Smart views pinned in the sidebar (local).
    var sidebarSmart: [SmartView] = (UserDefaults.standard.stringArray(forKey: "mail.smartViews") ?? ["unread", "flagged"])
        .compactMap(SmartView.init(rawValue:)) {
        didSet { UserDefaults.standard.set(sidebarSmart.map(\.rawValue), forKey: "mail.smartViews") }
    }
    var showUnifiedInbox: Bool = UserDefaults.standard.object(forKey: "mail.unifiedInbox") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showUnifiedInbox, forKey: "mail.unifiedInbox") }
    }
    var keymap: KeymapStyle = KeymapStyle(rawValue: UserDefaults.standard.string(forKey: "mail.keymap") ?? "") ?? .niivo {
        didSet { UserDefaults.standard.set(keymap.rawValue, forKey: "mail.keymap") }
    }

    // Search
    var searchScope: MailSearchScope = .mailbox { didSet { if oldValue != searchScope { mail?.rerunSearch() } } }
    var includeGroups = false { didSet { if oldValue != includeGroups { mail?.rerunSearch() } } }
    var memory = SearchMemory()
    private(set) var groupHits: [GroupHit] = []
    private(set) var unattributed = 0
    var savingSearch = false
    var savedSearchName = ""

    // Sheets
    var moving: [String]?            // ids for "Move to…"
    var sweep: SweepDraft?

    // Master categories
    private(set) var categories: [OutlookCategory] = []
    private(set) var categoriesLoaded = false
    var categoryError: String?
    var newCategoryName = ""
    var newCategoryColor = CategoryColor("preset7")
    var renaming: OutlookCategory?
    var renameText = ""

    @ObservationIgnored weak var mail: MailModel?
    @ObservationIgnored private var memoryLoaded = false
    @ObservationIgnored private var groupTask: Task<Void, Never>?

    struct GroupHit: Identifiable { var group: M365Group; var conversation: GroupConversation; var id: String { group.id + "/" + conversation.id } }

    func attach(_ m: MailModel) {
        guard mail !== m else { return }
        mail = m
        memoryLoaded = false; categoriesLoaded = false
    }

    // MARK: Filter

    func meSet(_ mail: MailModel) -> Set<String> {
        var s = Set<String>()
        if let a = mail.me?.address.lowercased() { s.insert(a) }
        if mail.selectedMailbox != "me" { s.insert(mail.selectedMailbox.lowercased()) }
        for i in mail.settings.identities { s.insert(i.address.lowercased()) }
        return s
    }

    func filtered(_ msgs: [MailMessage], mail: MailModel) -> [MailMessage] {
        guard let f = filter else { return msgs }
        let me = meSet(mail)
        let mentions = mentioned.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let now = Date()
        return msgs.filter { f.matches($0, me: me, mentioned: mentions, now: now) }
    }

    func loadMentions(mail: MailModel) async {
        guard let lookup = mail.sync?.mentionLookup else { mentionsNote = "Mentions aren't available here"; return }
        var out: [String: Set<String>] = [:]
        var failed = false
        for mb in Set([mail.selectedMailbox, "me"]) {
            do { out[mb] = Set(try await lookup.mentionedMessageIds(mailbox: mb, top: 200)) } catch { failed = true }
        }
        mentioned = out
        mentionsNote = failed ? "Mentions use a Microsoft Graph beta filter that this tenant refused" : nil
        mail.reloadList()
    }

    // MARK: Search memory (sealed in the mail store, never UserDefaults)

    func ensureMemory(_ mail: MailModel) {
        guard !memoryLoaded, let store = mail.store else { return }
        memory = SearchMemory.load(store); memoryLoaded = true
    }

    func searchFinished(_ q: String, result: ScopedSearchResult, mail: MailModel, remember: Bool = true) {   // SEARCHBOX-HOOK: remember on ↩ only
        if self.mail == nil { self.mail = mail }
        unattributed = result.unattributed
        ensureMemory(mail)
        if remember, let store = mail.store { memory.remember(q); memory.persist(store) }
        groupTask?.cancel(); groupHits = []
        guard includeGroups, let svc = mail.groups.searchService else { return }
        let groups = Array(mail.groups.groups.prefix(20))
        groupTask = Task { @MainActor in
            var hits: [GroupHit] = []
            for g in groups {
                guard !Task.isCancelled else { return }
                let convs = (try? await svc.conversations(groupId: g.id, top: 50)) ?? []
                hits += GroupSearch.match(convs, query: q).map { GroupHit(group: g, conversation: $0) }
            }
            guard !Task.isCancelled else { return }
            groupHits = hits
        }
    }

    func saveCurrentSearch(_ mail: MailModel) {
        let q = mail.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let store = mail.store else { return }
        ensureMemory(mail)
        let name = savedSearchName.trimmingCharacters(in: .whitespaces)
        memory.save(.init(name: name.isEmpty ? q : name, query: q, scope: searchScope, includeGroups: includeGroups))
        memory.persist(store)
        savedSearchName = ""; savingSearch = false
    }

    func run(_ s: SearchMemory.Saved, mail: MailModel) {
        searchScope = s.scope; includeGroups = s.includeGroups
        mail.searchText = s.query
    }

    func removeSaved(_ id: UUID, mail: MailModel) {
        guard let store = mail.store else { return }
        memory.removeSaved(id); memory.persist(store)
    }

    func clearRecent(mail: MailModel) {
        guard let store = mail.store else { return }
        memory.recent = []; memory.persist(store)
    }

    // MARK: Master categories

    func loadCategories(_ mail: MailModel, force: Bool = false) async {
        guard force || !categoriesLoaded, let svc = mail.sync?.masterCategoryService else { return }
        do {
            categories = try await svc.masterCategories(mailbox: "me")
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            categoriesLoaded = true; categoryError = nil
        } catch { categoryError = "Couldn't load your categories" }
    }

    func createCategory(_ mail: MailModel) async {
        guard let svc = mail.sync?.masterCategoryService else { return }
        do {
            let name = try MasterCategories.validate(name: newCategoryName, existing: categories)
            _ = try await svc.createCategory(displayName: name, color: newCategoryColor, mailbox: "me")
            newCategoryName = ""
            await loadCategories(mail, force: true)
        } catch MasterCategoryError.duplicateName { categoryError = "A category with that name already exists" }
        catch MasterCategoryError.emptyName { categoryError = "Enter a name" }
        catch { categoryError = "Couldn't create the category" }
    }

    func recolour(_ c: OutlookCategory, _ color: CategoryColor, mail: MailModel) async {
        guard let svc = mail.sync?.masterCategoryService else { return }
        do { _ = try await svc.setCategoryColor(id: c.id, color: color, mailbox: "me"); await loadCategories(mail, force: true) }
        catch { categoryError = "Couldn't change the colour" }
    }

    func delete(_ c: OutlookCategory, mail: MailModel) async {
        guard let svc = mail.sync?.masterCategoryService else { return }
        do { try await svc.deleteCategory(id: c.id, mailbox: "me"); await loadCategories(mail, force: true) }
        catch { categoryError = "Couldn't delete the category" }
    }

    /// Graph can't rename (displayName is fixed): create the new name with the same colour, re-tag the cached
    /// messages carrying the old one, then delete the old entry. Messages not cached on this Mac keep the old name.
    func rename(_ c: OutlookCategory, to newName: String, mail: MailModel) async {
        guard let svc = mail.sync?.masterCategoryService, let sync = mail.sync, let store = mail.store else { return }
        do {
            let name = try MasterCategories.validate(name: newName, existing: categories.filter { $0.id != c.id })
            _ = try await svc.createCategory(displayName: name, color: c.color, mailbox: "me")
            let tagged = store.messages(matching: [.category(c.displayName)], mailbox: nil, limit: 5_000)
            let r = await sync.apply(MasterCategories.retag(tagged, from: c.displayName, to: name))
            try await svc.deleteCategory(id: c.id, mailbox: "me")
            await loadCategories(mail, force: true)
            renaming = nil
            categoryError = r.failed > 0 ? "Renamed; \(r.failed) message(s) couldn't be re-tagged" : nil
            mail.reloadList()
        } catch MasterCategoryError.duplicateName { categoryError = "A category with that name already exists" }
        catch { categoryError = "Couldn't rename the category" }
    }

    /// Row colour for a category: the master list's preset when known.
    func color(for name: String) -> Color? { MasterCategories.hex(for: name, in: categories).map { Color(hex: $0) } }
}

struct SweepDraft: Identifiable {
    let id = UUID()
    var sender: EmailAddress
    var folderId: String
    var mailbox: String
    var mode: SweepModeChoice = .all
    var days = 10
    var moveTo: String?          // nil = delete
    var always = false
}

enum SweepModeChoice: String, CaseIterable, Identifiable {
    case all, keepLatest, older
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All messages from this sender"; case .keepLatest: "All but the latest one"; case .older: "Messages older than…" }
    }
}

// MARK: - Virtual lists (unified inbox, smart views)

extension MailModel {
    /// A page of a virtual list (keyset: strictly older than `before`).
    func virtualPage(_ v: VirtualFolder, store: MailStore, before: MailCursor?, limit: Int) -> [MailMessage] {
        switch v {
        case .today:   // TODAY-HOOK: one snapshot, no paging (TodayViews.swift)
            return before == nil ? TodayModel.shared.rows(mail: self) : []
        case .unifiedInbox:
            return UnifiedInbox.page(store: store, folderIds: UnifiedInbox.inboxes(store: store, mailboxes: mailboxes),
                                     before: before, limit: limit)
        case .smart(let view, let mb):
            let ui = MailListUI.shared
            let all = SmartViewQuery.rows(store: store, view: view, mailbox: mb, me: ui.meSet(self), mentioned: ui.mentioned[mb] ?? [])
            guard let before else { return Array(all.prefix(limit)) }
            let k = (Int64(before.received.timeIntervalSince1970), before.id)
            return Array(all.filter { (Int64($0.received.timeIntervalSince1970), $0.id) < k }.prefix(limit))
        case .promises: return []   // PROMISES-HOOK: PromisesListView replaces the message list
        case .list(let l):   // ORG2-HOOK: person / category / VIP / tray (MailOrg2.swift)
            let vips = MailOrg2.shared.vips
            let all = l.rows(store: store, vips: { vips.contains($0) })
            guard let before else { return Array(all.prefix(limit)) }
            let k = (Int64(before.received.timeIntervalSince1970), before.id)
            return Array(all.filter { (Int64($0.received.timeIntervalSince1970), $0.id) < k }.prefix(limit))
        }
    }

    var virtualFolder: VirtualFolder? { selectedFolderId.flatMap(VirtualFolder.init(id:)) }
    var listTitle: String { selectedFolder?.displayName ?? virtualFolder?.title ?? "Mail" }

    func openVirtual(_ v: VirtualFolder) {
        if case .smart(.mentions, _) = v { Task { await MailListUI.shared.loadMentions(mail: self) } }
        selectedFolderId = v.id
    }
}

// MARK: - Drag

enum BulkDrag {
    /// Newline-separated ids: the whole multi-selection when dragging one of its rows.
    static func payload(row: MailRow, rows: [MailRow], marked: Set<String>) -> String {
        marked.contains(row.id) && marked.count > 1 ? rows.filter { marked.contains($0.id) }.map(\.id).joined(separator: "\n") : row.id
    }
    static func title(row: MailRow, marked: Set<String>) -> String {
        marked.contains(row.id) && marked.count > 1 ? "\(marked.count) messages" : (row.policy.redactDetails ? "Private message" : row.message.subject)
    }
}
