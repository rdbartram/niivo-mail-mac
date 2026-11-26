import SwiftUI
import CalendarCore
import MailCore

// People window, contact cards, To Do pane and presence dots: app-side state. Graph work lives in MailCore
// (GraphPeopleService / GraphTodoService / GraphPresenceService). Everything here is memory only.
// Consent: each feature has its own incremental set (Auth.peopleScopes / todoScopes / presenceScopes), asked only
// from an explicit button. Passive UI (presence dots, card enrichment) uses silent tokens and goes quiet on failure.

@MainActor @Observable
final class PeopleHub {
    static let shared = PeopleHub()

    @ObservationIgnored private(set) var service: PeopleService?
    @ObservationIgnored var grant: (() async throws -> Void)?
    @ObservationIgnored weak var app: AppModel?

    var people: [PersonEntry] = []
    var contacts: [Contact] = []
    var folders: [ContactFolder] = []
    var query = ""
    var selectedId: String?
    var loading = false
    var needsConsent = false
    var notice: String?
    /// Other users whose contacts folder was opened (address). Addresses only, kept for the session.
    var sharedOwners: [String] = []
    var sharedOwnerDraft = ""
    var editor: ContactEditorModel?
    var card: PersonCardModel?

    @ObservationIgnored private var photos: [String: Data] = [:]      // directory id → bytes (memory only)
    @ObservationIgnored private var noPhoto: Set<String> = []
    @ObservationIgnored private let photoCap = 200

    var isConfigured: Bool { service != nil }

    func configure(service: PeopleService, grant: (() async throws -> Void)? = nil) {
        self.service = service; self.grant = grant
        people = []; contacts = []; folders = []; photos = [:]; noPhoto = []; card = nil
    }

    var filtered: [PersonEntry] { PeopleMerge.filter(people, query: query) }

    func load() async {
        guard let service else { notice = "People isn't available."; return }
        loading = true; defer { loading = false }
        do {
            async let f = service.contactFolders()
            async let c = service.contacts(folderId: nil, owner: nil)
            folders = (try? await f) ?? []
            var all = try await c
            for o in sharedOwners { all += (try? await service.contacts(folderId: nil, owner: o)) ?? [] }
            contacts = all
            let dir = (try? await service.relevantPeople(top: 50)) ?? []
            people = PeopleMerge.merge(contacts: all, directory: dir, correspondents: correspondents())
            needsConsent = false; notice = nil
        } catch {
            if case MailServiceError.offline = error { notice = "You're offline." } else { needsConsent = true }
            people = PeopleMerge.merge(contacts: [], directory: [], correspondents: correspondents())
        }
    }

    func grantAndLoad() async {
        do { try await grant?(); needsConsent = false; await load() }
        catch { notice = "Access to contacts wasn't granted." }
    }

    private func correspondents() -> [PersonNode] {
        let nodes = app?.mail.store?.graph?.people() ?? []
        return Array(nodes.sorted { $0.total.n > $1.total.n }.prefix(300))
    }

    func addSharedOwner() async {
        let a = sharedOwnerDraft.trimmingCharacters(in: .whitespaces).lowercased()
        guard a.contains("@"), !sharedOwners.contains(a) else { return }
        sharedOwners.append(a); sharedOwnerDraft = ""
        await load()
    }

    // MARK: Cards

    /// Opens the card for an address (from the reader, a list row or the People list).
    func show(address: String, name: String) {
        let key = address.lowercased()
        let entry = people.first { $0.id == key }
            ?? PersonEntry(id: key, displayName: name.isEmpty ? address : name, address: address, sources: [.correspondent],
                           isInternal: PresenceHub.shared.isInternal(key))
        selectedId = key
        let m = PersonCardModel(entry: entry)
        card = m
        Task { await enrich(m) }
    }

    func select(_ p: PersonEntry) {
        selectedId = p.id
        let m = PersonCardModel(entry: p)
        card = m
        Task { await enrich(m) }
    }

    private func enrich(_ m: PersonCardModel) async {
        m.contacts = contacts.filter { m.entry.contactIds.contains($0.id) || ($0.primaryAddress?.lowercased() == m.entry.id) }
        loadLocal(m)
        guard let service, let a = m.entry.address else { return }
        // Directory lookups only for internal people (or someone already known to the directory).
        guard m.entry.isInternal || m.entry.directoryId != nil else { return }
        do {
            guard let d = try await service.directoryUser(address: a) else { return }
            m.directory = d
            m.manager = try? await service.manager(userId: d.id)
            m.photo = await photo(userId: d.id)
        } catch { /* passive: no consent / offline → the card shows what's local */ }
    }

    func photo(userId: String) async -> Data? {   // ORG2-HOOK: internal (list avatars reuse this memory cache)
        if let p = photos[userId] { return p }
        if noPhoto.contains(userId) { return nil }
        guard let service else { return nil }
        let data = try? await service.photo(userId: userId)
        if let data {
            if photos.count >= photoCap { photos.removeAll() }
            photos[userId] = data
        } else { noPhoto.insert(userId) }
        return data
    }

    /// Recent mail and this week's meetings with the person, from the local store, through the same policy as rows.
    private func loadLocal(_ m: PersonCardModel) {
        guard let app, let a = m.entry.address?.lowercased() else { return }
        if let store = app.mail.store {
            let from = store.messages(matching: [.from(a)], mailbox: "me", limit: 8)
            let to = store.messages(matching: [.recipient(a)], mailbox: "me", limit: 8)
            let all = Array(Set(from + to)).sorted { $0.received > $1.received }.prefix(8)
            m.mail = all.map { msg in
                let p = app.mail.policy(for: msg, mailbox: "me")
                if p.preventScreenCapture { m.preventCapture = true }
                return .init(id: msg.id, title: p.redactDetails ? "Private message" : (msg.subject.isEmpty ? "(no subject)" : msg.subject),
                             date: msg.received, incoming: msg.from?.address.lowercased() == a)
            }
        }
        m.meetings = app.weekEvents
            .filter { e in e.organizer?.lowercased() == a || e.attendees.contains { $0.address.lowercased() == a } }
            .sorted { $0.start < $1.start }.prefix(6)
            .map { e in
                let p = app.policy(for: e)
                if p.preventScreenCapture { m.preventCapture = true }
                return PersonCardModel.Item(id: e.id, title: p.redactDetails ? "Private appointment" : e.subject, date: e.start, incoming: false)
            }
    }

    // MARK: Contacts CRUD (optimistic, online required)

    func newContact() { editor = ContactEditorModel(contact: Contact(), isNew: true) }
    func edit(_ c: Contact) { editor = ContactEditorModel(contact: c, isNew: false) }

    func save(_ e: ContactEditorModel) async {
        guard let service else { return }
        let c = e.built
        editor = nil
        if e.isNew {
            let tempId = "pending-\(UUID().uuidString)"
            var temp = c; temp.id = tempId
            contacts.append(temp); remerge()
            do {
                let made = try await service.createContact(c, folderId: nil)
                contacts.removeAll { $0.id == tempId }; contacts.append(made)
            } catch {
                contacts.removeAll { $0.id == tempId }; notice = failure("create the contact", error)
            }
        } else {
            guard let i = contacts.firstIndex(where: { $0.id == c.id }) else { return }
            let old = contacts[i]
            contacts[i] = c; remerge()
            do { let saved = try await service.updateContact(c); if let j = contacts.firstIndex(where: { $0.id == c.id }) { contacts[j] = saved } }
            catch { if let j = contacts.firstIndex(where: { $0.id == c.id }) { contacts[j] = old }; notice = failure("save the contact", error) }
        }
        remerge()
    }

    func delete(_ c: Contact) async {
        guard let service, c.owner == nil else { return }
        let old = contacts
        contacts.removeAll { $0.id == c.id }; remerge()
        if card?.contacts.contains(c) == true { card?.contacts.removeAll { $0.id == c.id } }
        do { try await service.deleteContact(id: c.id) }
        catch { contacts = old; remerge(); notice = failure("delete the contact", error) }
    }

    private func remerge() {
        let dir = people.compactMap { p -> DirectoryPerson? in
            guard let id = p.directoryId else { return nil }
            return DirectoryPerson(id: id, displayName: p.displayName, mail: p.address, jobTitle: p.jobTitle, department: p.department)
        }
        people = PeopleMerge.merge(contacts: contacts, directory: dir, correspondents: correspondents())
        if let card {   // keep the open card in step (else "Add to contacts" stays and makes duplicates)
            card.contacts = contacts.filter { $0.primaryAddress?.lowercased() == card.entry.id || card.entry.contactIds.contains($0.id) }
        }
    }

    private func failure(_ what: String, _ e: Error) -> String {
        if case MailServiceError.offline = e { return "Couldn't \(what): you're offline. Nothing was changed." }
        return "Couldn't \(what). Nothing was changed."
    }
}

@MainActor @Observable
final class PersonCardModel {
    struct Item: Identifiable, Hashable { var id: String; var title: String; var date: Date; var incoming: Bool }
    let entry: PersonEntry
    var directory: DirectoryPerson?
    var manager: DirectoryPerson?
    var photo: Data?
    var contacts: [Contact] = []
    var mail: [Item] = []
    var meetings: [Item] = []
    /// Any listed message / meeting forbids screen capture -> the People window is excluded from capture too.
    var preventCapture = false
    init(entry: PersonEntry) { self.entry = entry }
    var title: String? { directory?.jobTitle ?? entry.jobTitle ?? contacts.first?.jobTitle }
    var department: String? { directory?.department ?? entry.department ?? contacts.first?.department }
    var phones: [String] {
        var out = (directory?.businessPhones ?? []) + [directory?.mobilePhone].compactMap { $0 }
        for c in contacts { out += c.businessPhones + [c.mobilePhone].compactMap { $0 } }
        var seen = Set<String>(); return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

@MainActor @Observable
final class ContactEditorModel {
    let isNew: Bool
    let original: Contact
    var givenName: String
    var surname: String
    var email: String
    var phone: String
    var mobile: String
    var jobTitle: String
    var company: String
    var department: String
    init(contact c: Contact, isNew: Bool) {
        self.isNew = isNew; original = c
        givenName = c.givenName; surname = c.surname; email = c.primaryAddress ?? ""
        phone = c.businessPhones.first ?? ""; mobile = c.mobilePhone ?? ""; jobTitle = c.jobTitle ?? ""
        company = c.companyName ?? ""; department = c.department ?? ""
        if isNew == false && givenName.isEmpty && surname.isEmpty { givenName = c.displayName }
    }
    var canSave: Bool { !(givenName + surname + email).trimmingCharacters(in: .whitespaces).isEmpty }
    var built: Contact {
        var c = original
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        c.givenName = t(givenName); c.surname = t(surname)
        c.displayName = [c.givenName, c.surname].filter { !$0.isEmpty }.joined(separator: " ")
        let e = t(email)
        var emails = c.emails
        if e.isEmpty { if !emails.isEmpty { emails.removeFirst() } }
        else if emails.isEmpty { emails = [EmailAddress(name: c.displayName, address: e)] }
        else { emails[0].address = e }
        c.emails = emails
        var phones = c.businessPhones
        if t(phone).isEmpty { if !phones.isEmpty { phones.removeFirst() } } else if phones.isEmpty { phones = [t(phone)] } else { phones[0] = t(phone) }
        c.businessPhones = phones
        c.mobilePhone = t(mobile).isEmpty ? nil : t(mobile)
        c.jobTitle = t(jobTitle).isEmpty ? nil : t(jobTitle)
        c.companyName = t(company).isEmpty ? nil : t(company)
        c.department = t(department).isEmpty ? nil : t(department)
        return c
    }
}

// MARK: - Presence (visible people only)

@MainActor @Observable
final class PresenceHub {
    static let shared = PresenceHub()
    /// address (lowercased) → presence. Assigned once per batch, read only inside the small dot views.
    private(set) var values: [String: PresenceInfo] = [:]
    /// Off until configured; switched off when the silent token or a call is refused (never prompts).
    private(set) var enabled = false
    private(set) var needsGrant = false
    @ObservationIgnored private var cache: PresenceCache?
    @ObservationIgnored private var grant: (() async throws -> Void)?
    @ObservationIgnored private var visible: [String: Int] = [:]
    @ObservationIgnored private var internalCache: [String: Bool] = [:]
    /// nil = can't tell yet (store / settings not ready) -> not cached.
    @ObservationIgnored var internalCheck: (String) -> Bool? = { _ in nil }
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?

    var isConfigured: Bool { cache != nil }

    func configure(cache: PresenceCache, grant: (() async throws -> Void)? = nil, internalCheck: @escaping (String) -> Bool?) {
        self.cache = cache; self.grant = grant; self.internalCheck = internalCheck
        internalCache = [:]; values = [:]; enabled = true; needsGrant = false
        startLoop()
        if !visible.isEmpty { schedule() }   // rows already on screen get dots now
    }

    func isInternal(_ address: String) -> Bool {
        let k = address.lowercased()
        if let v = internalCache[k] { return v }
        guard let v = internalCheck(k) else { return false }
        internalCache[k] = v; return v
    }

    /// Tracked even while disabled, so a later configure / grant fills dots already on screen. Internal is decided at
    /// fetch time (the store may not be ready on first appearance).
    func appear(_ address: String) {
        let k = address.lowercased()
        visible[k, default: 0] += 1
        if enabled, values[k] == nil { schedule() }
    }

    func disappear(_ address: String) {
        let k = address.lowercased()
        guard let n = visible[k] else { return }
        if n <= 1 { visible.removeValue(forKey: k) } else { visible[k] = n - 1 }
    }

    func turnOn() async {
        do { try await grant?(); needsGrant = false; enabled = true; await cache?.reset(); schedule() }
        catch { needsGrant = true }
    }

    private func schedule(after ms: Int = 400) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        guard enabled, let cache else { return }
        let keys = visible.keys.filter { isInternal($0) }   // external senders never cause a directory call
        guard !keys.isEmpty else { return }
        do {
            let got = try await cache.lookup(keys)
            var next = values
            for (k, v) in got { next[k] = v }
            if next != values { values = next }
            // Rate-limited round (or new rows): ask again once the minimum interval has passed.
            if await cache.unanswered(keys) > 0 { schedule(after: Int(cache.minInterval * 1000) + 300) }
        } catch {
            if case MailServiceError.offline = error { return }
            enabled = false; needsGrant = true   // passive UI: go quiet, wait for an explicit grant
        }
    }
}

// MARK: - To Do

@MainActor @Observable
final class TasksHub {
    static let shared = TasksHub()
    @ObservationIgnored private(set) var service: TodoService?
    @ObservationIgnored var grant: (() async throws -> Void)?
    var lists: [TodoList] = []
    var selectedListId: String?
    var tasks: [TodoTask] = []
    var showCompleted = false
    var newTitle = ""
    var loading = false
    var needsConsent = false
    var notice: String?

    var isConfigured: Bool { service != nil }
    var selectedList: TodoList? { lists.first { $0.id == selectedListId } }
    var visibleTasks: [TodoTask] {
        tasks.filter { showCompleted || !$0.isCompleted }.sorted {
            ($0.isCompleted ? 1 : 0, $0.due ?? .distantFuture, $0.title) < ($1.isCompleted ? 1 : 0, $1.due ?? .distantFuture, $1.title)
        }
    }

    func configure(service: TodoService, grant: (() async throws -> Void)? = nil) {
        self.service = service; self.grant = grant; lists = []; tasks = []; selectedListId = nil
    }

    func load() async {
        guard let service else { notice = "To Do isn't available."; return }
        loading = true; defer { loading = false }
        do {
            lists = try await service.lists()
            if selectedListId == nil || selectedList == nil {
                selectedListId = (lists.first { $0.kind == .defaultList } ?? lists.first)?.id
            }
            needsConsent = false; notice = nil
            await loadTasks()
        } catch {
            if case MailServiceError.offline = error { notice = "You're offline." } else { needsConsent = true }
        }
    }

    func grantAndLoad() async {
        do { try await grant?(); needsConsent = false; await load() }
        catch { notice = "Access to To Do wasn't granted." }
    }

    func select(_ id: String) async { selectedListId = id; await loadTasks() }

    func loadTasks() async {
        guard let service, let id = selectedListId else { tasks = []; return }
        do { tasks = try await service.tasks(listId: id) } catch { notice = "Couldn't load tasks." }
    }

    func add() async {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let id = selectedListId else { return }
        newTitle = ""
        await create(TodoDraft(title: t), in: id)
    }

    /// Task from a message: label-aware title + link (no message content). Goes to the default Tasks list.
    /// Explicit click: may ask for To Do consent (interactive) the first time.
    func createFromMessage(_ m: MailMessage, policy: ContentPolicy) async -> (ok: Bool, text: String) {
        guard service != nil else { return (false, "To Do isn't available.") }
        if lists.isEmpty { await load() }
        if needsConsent { await grantAndLoad() }
        guard let list = lists.first(where: { $0.kind == .defaultList }) ?? lists.first else {
            return (false, needsConsent ? "Microsoft To Do access wasn't granted." : (notice ?? "No To Do list found."))
        }
        let ok = await create(TodoFromMail.draft(for: m, policy: policy), in: list.id)
        return ok ? (true, "Task added to \(list.displayName)") : (false, notice ?? "Couldn't add the task.")
    }

    @discardableResult
    private func create(_ d: TodoDraft, in listId: String) async -> Bool {
        guard let service else { return false }
        let temp = TodoTask(id: "pending-\(UUID().uuidString)", listId: listId, title: d.title, due: d.due)
        if listId == selectedListId { tasks.append(temp) }
        do {
            let made = try await service.create(listId: listId, d)
            if listId == selectedListId { tasks.removeAll { $0.id == temp.id }; tasks.append(made) }
            return true
        } catch {
            tasks.removeAll { $0.id == temp.id }
            notice = "Couldn't add the task. Nothing was changed."; return false
        }
    }

    func toggle(_ t: TodoTask) async { await patch(t, TodoPatch(status: t.isCompleted ? .notStarted : .completed)) }
    func setDue(_ t: TodoTask, _ d: Date?) async { await patch(t, TodoPatch(due: .some(d))) }
    func setReminder(_ t: TodoTask, _ d: Date?) async { await patch(t, TodoPatch(reminder: .some(d))) }

    private func patch(_ t: TodoTask, _ p: TodoPatch) async {
        guard let service, let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        let old = tasks[i]
        var opt = old
        if let s = p.status { opt.status = s }
        if let d = p.due { opt.due = d }
        if let r = p.reminder { opt.reminder = r; opt.isReminderOn = r != nil }
        tasks[i] = opt
        do {
            let saved = try await service.update(listId: t.listId, taskId: t.id, p)
            if let j = tasks.firstIndex(where: { $0.id == t.id }) { var s = saved; s.linked = old.linked; tasks[j] = s }
        } catch {
            if let j = tasks.firstIndex(where: { $0.id == t.id }) { tasks[j] = old }
            notice = "Couldn't update the task. Nothing was changed."
        }
    }

    func delete(_ t: TodoTask) async {
        guard let service else { return }
        let old = tasks
        tasks.removeAll { $0.id == t.id }
        do { try await service.delete(listId: t.listId, taskId: t.id) } catch { tasks = old; notice = "Couldn't delete the task." }
    }
}

// MARK: - Wiring (called from MailboxManager's configure*Extras, one line each)

extension MailModel {
    /// Idempotent: also called lazily from the People / Tasks windows and presence dots before Mail has started.
    func configurePeopleFixtures() {
        guard !PeopleHub.shared.isConfigured else { return }
        PeopleHub.shared.configure(service: FixturePeopleService())
        TasksHub.shared.configure(service: FixtureTodoService())
        // Synthetic ids for every address (fixture mail senders aren't all in the fixture directory).
        PresenceHub.shared.configure(cache: PresenceCache(service: FixturePresenceService(),
                                                          resolve: { a in Dictionary(a.map { ($0, "fx-" + $0) }, uniquingKeysWith: { x, _ in x }) }),
                                     internalCheck: { [weak self] a in self?.isInternalAddress(a) })
    }

    /// Internal domains from settings (same rule as the external-recipient warning), else CommGraph's view; nil when
    /// neither is known yet.
    func isInternalAddress(_ a: String) -> Bool? {
        if !settings.internalDomains.isEmpty { return RecipientCheck.isInternal(a, internalDomains: settings.internalDomains) }
        return store?.graph?.person(a)?.isInternal
    }

    func configurePeopleLive(auth: Auth) {
        // ACCOUNTS-HOOK: configured once per account; another account (switch) replaces the services, which clears
        // the previous account's people, contacts, tasks and presence.
        guard !PeopleHub.shared.isConfigured || PeopleHubAccount.current != auth.accountKey else { return }
        PeopleHubAccount.current = auth.accountKey
        let people = GraphPeopleService(token: { try await auth.peopleToken() })
        PeopleHub.shared.configure(service: people, grant: { try await auth.grantAccess(scopes: Auth.peopleScopes) })
        TasksHub.shared.configure(service: GraphTodoService(token: { try await auth.todoToken() }),
                                  grant: { try await auth.grantAccess(scopes: Auth.todoScopes) })
        let cache = PresenceCache(service: GraphPresenceService(token: { try await auth.presenceToken() }),
                                  resolve: { try await people.directoryIds(addresses: $0) })
        PresenceHub.shared.configure(cache: cache,
                                     grant: { try await auth.grantAccess(scopes: Auth.presenceScopes + Auth.peopleScopes) },
                                     internalCheck: { [weak self] a in self?.isInternalAddress(a) })
    }
}

extension AppModel {
    /// Lazy wiring for People / To Do / presence when Mail hasn't started yet (Calendar is the default section).
    func ensurePeopleHubs() {
        guard !PeopleHub.shared.isConfigured else { return }
        PeopleHub.shared.app = self
        if isFixtureMode { mail.configurePeopleFixtures() }
        else if mode == .live, let auth { mail.configurePeopleLive(auth: auth) }
    }
}

/// ACCOUNTS-HOOK: which account the People / Tasks / Presence hubs were configured for.
@MainActor enum PeopleHubAccount { static var current: String? }
