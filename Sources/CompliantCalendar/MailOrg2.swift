import SwiftUI
import AppKit
import MailCore

// Organisation, part 2 (app side): Favourites, Ignore conversation, Reply Later / Set Aside trays, VIPs, Quick Steps.
// Decisions + persistence live in MailCore/MailOrganise2.swift (sealed in the mail store, covered by CoreSelfTest).
// Views are in MailOrg2Views.swift. Hooks into shared files are one line each, marked `// ORG2-HOOK`.

@MainActor @Observable final class MailOrg2 {
    static let shared = MailOrg2()

    var favourites = FavouritesList() { didSet { if let store, favourites != oldValue { favourites.persist(store) } } }
    private(set) var ignored = IgnoredConversations()
    var quickSteps = QuickStepLibrary() { didSet { if let store, quickSteps != oldValue { quickSteps.persist(store) } } }
    /// The shared VIP list (MailCore `VIPStore.shared(for:)`; memory-only before the store opens).
    @ObservationIgnored private(set) var vips: VIPStore = VIPStore.current
    /// Bumped on every VIP change (VIPStore isn't observable).
    private(set) var vipVersion = 0
    var showAvatars: Bool = UserDefaults.standard.object(forKey: "mail.avatars") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAvatars, forKey: "mail.avatars") }
    }
    /// Quick Step editor sheet.
    var editingStep: QuickStep?
    /// Favourite row a drag is hovering (reorder indicator).
    var dropBefore: String?

    @ObservationIgnored private weak var store: MailStore?
    @ObservationIgnored private weak var mail: MailModel?
    @ObservationIgnored private var sweeping: Set<String> = []

    // MARK: Lifecycle

    func attach(_ mail: MailModel, store: MailStore) {
        self.mail = mail
        self.store = nil   // no persist while loading
        let legacy = UserDefaults.standard.stringArray(forKey: "mail.folders.favourites") ?? []
        let byId = Dictionary(mail.mailboxes.flatMap { mb in ((try? store.folders(mailbox: mb)) ?? []).map { ($0.id, mb) } },
                              uniquingKeysWith: { a, _ in a })
        let loaded = FavouritesList.load(store, legacyFolders: legacy.compactMap { id in byId[id].map { (id, $0) } })
        favourites = loaded.list
        migrateLegacy(byId)
        ignored = IgnoredConversations.load(store)
        quickSteps = QuickStepLibrary.load(store)
        vips = VIPStore.shared(for: store)
        MailNotifier.shared.vipLookup = vips   // ORG2-HOOK: VIP notifications use the same store
        vipVersion += 1
        self.store = store
    }

    func detach() {
        store = nil; mail = nil
        favourites = FavouritesList(); ignored = IgnoredConversations(); quickSteps = QuickStepLibrary()
        VIPStore.reset(); vips = VIPStore.current; vipVersion += 1
        MailNotifier.shared.vipLookup = nil   // ORG2-HOOK
        editingStep = nil; sweeping = []
        AvatarCache.shared.reset(); HoverCardModel.shared.shown = nil
    }

    // MARK: Favourites

    func isFavouriteFolder(_ id: String) -> Bool { favourites.items.contains { if case .folder(let f, _) = $0 { f == id } else { false } } }
    func setFavouriteFolder(_ id: String, _ on: Bool) {
        guard let f = mail?.folder(id: id) else { if !on { favourites.items.removeAll { $0.id == "folder:" + id } }; return }
        favourites.set(.folder(id: id, mailbox: f.mailbox), on)
    }
    /// Old UserDefaults folder pins whose mailbox wasn't cached yet stay there until their folder is known.
    private func migrateLegacy(_ byId: [String: String]) {
        let legacy = UserDefaults.standard.stringArray(forKey: "mail.folders.favourites") ?? []
        guard !legacy.isEmpty else { return }
        for id in legacy { if let mb = byId[id] { favourites.add(.folder(id: id, mailbox: mb)) } }
        let rest = legacy.filter { byId[$0] == nil }
        if rest.isEmpty { UserDefaults.standard.removeObject(forKey: "mail.folders.favourites") }
        else { UserDefaults.standard.set(rest, forKey: "mail.folders.favourites") }
    }

    func pruneFolders(known: Set<String>, loadedMailboxes: Set<String>) {
        if let mail { migrateLegacy(Dictionary(mail.folders.flatMap { mb, fs in fs.map { ($0.id, mb) } }, uniquingKeysWith: { a, _ in a })) }
        var f = favourites; f.prune(knownFolders: known, loadedMailboxes: loadedMailboxes)
        if f != favourites { favourites = f }
    }
    func toggle(_ item: FavouriteItem) { favourites.set(item, !favourites.contains(item)) }

    /// Reorder drop: payload `niivo-fav:<id>` onto the row `before`. nil = the payload isn't a favourite.
    static let dragPrefix = "niivo-fav:"
    func handleDrop(_ items: [String], before: String?) -> Bool? {
        guard let p = items.first, p.hasPrefix(Self.dragPrefix) else { return nil }
        favourites.move(String(p.dropFirst(Self.dragPrefix.count)), before: before)
        dropBefore = nil
        return true
    }

    func open(_ item: FavouriteItem, mail: MailModel) {
        switch item {
        case .folder(let id, _): mail.selectedFolderId = id
        case .group(let id, let name):
            mail.groups.select(mail.groups.groups.first { $0.id == id } ?? M365Group(id: id, displayName: name, mail: nil))
        default: if let sid = selectionId(item), let v = VirtualFolder(id: sid) { mail.openVirtual(v) }
        }
    }

    func selectionId(_ item: FavouriteItem) -> String? {
        switch item {
        case .folder(let id, _): id
        case .group: nil
        case .person(let a, _): VirtualFolder.list(.person(address: a, mailbox: "me")).id
        case .category(let c): VirtualFolder.list(.category(c, mailbox: "me")).id
        case .smart(let s): VirtualFolder.smart(s, mailbox: "me").id
        case .vip: VirtualFolder.list(.vip(mailbox: "me")).id
        case .tray(let t): VirtualFolder.list(.tray(t, mailbox: "me")).id
        }
    }

    func title(_ item: FavouriteItem, mail: MailModel) -> String {
        switch item {
        case .folder(let id, _): mail.folder(id: id)?.displayName ?? "Folder"
        case .group(let id, let name): mail.groups.groups.first { $0.id == id }?.displayName ?? name
        case .person(let a, let n): n.isEmpty ? a : n
        case .category(let c): c
        case .smart(let s): s.title
        case .vip: "VIPs"
        case .tray(let t): t.title
        }
    }

    func symbol(_ item: FavouriteItem, mail: MailModel) -> String {
        switch item {
        case .folder(let id, _): mail.folder(id: id).map(MailboxDisplay.folderSymbol) ?? "folder"
        case .group: "person.3"
        case .person: "person.crop.circle"
        case .category: "tag"
        case .smart(let s): s.symbol
        case .vip: "star"
        case .tray(let t): t.symbol
        }
    }

    // MARK: VIPs

    func isVIP(_ address: String?) -> Bool { _ = vipVersion; return address.map { vips.contains($0) } ?? false }
    func setVIP(_ address: String, _ on: Bool) {
        vips.set(address, on); vipVersion += 1
        mail?.toast(MailToast(text: on ? "Added to VIPs" : "Removed from VIPs", symbol: on ? "star.fill" : "star"))
        if case .list(.vip)? = mail?.virtualFolder { mail?.reloadList() }
    }

    // MARK: Ignore conversation

    func isIgnored(_ row: MailRow) -> Bool { ignored.contains(row.message.conversationId, mailbox: row.mailbox) }

    /// Remember the conversation (sealed), move what's listed to Deleted Items (one ⌘Z), sweep later arrivals.
    func ignore(_ row: MailRow, mail: MailModel) {
        guard let store, !row.message.conversationId.isEmpty else { return }
        ignored.ignore(row.message.conversationId, mailbox: row.mailbox)
        ignored.persist(store)
        // Every cached message of the thread in this mailbox (collapsed conversation members included), except
        // Deleted Items / Sent / Drafts / Outbox / Junk. ⌘Z restores them; the sweep only takes later arrivals.
        let all = ((try? store.conversation(id: row.message.conversationId)) ?? [row.message]).filter { mail.folder(id: $0.folderId)?.mailbox == row.mailbox }
        let wk: (WellKnownFolder) -> String? = { ((try? store.folder(wellKnown: $0, mailbox: row.mailbox)) ?? nil)?.id }
        let keep = Set(IgnoredConversations.untouched.compactMap(wk))
        let msgs = all.filter { !keep.contains($0.folderId) && !$0.isDraft }
        let rows = msgs.map { m in mail.visibleRows.first { $0.id == m.id } ?? MailRow(message: m, mailbox: row.mailbox, count: 1, policy: row.policy) }
        applySteps(msgs.map { BulkStep(messageId: $0.id, action: .delete) }, rows: rows,
                   label: "Ignored conversation — new messages go to Deleted Items while niivo runs", mail: mail)
    }

    func stopIgnoring(_ row: MailRow, mail: MailModel) {
        guard let store else { return }
        ignored.stop(row.message.conversationId, mailbox: row.mailbox)
        ignored.persist(store)
        mail.toast(MailToast(text: "Stopped ignoring this conversation", symbol: "speaker.wave.2"))
    }

    /// NOTIFY-HOOK filter: changed messages of ignored conversations go to Deleted Items before anything notifies.
    /// Returns the change minus the swept ids.
    func sweepIgnored(_ change: MailChange, mail: MailModel) -> MailChange {
        guard case .messages(let ids) = change, !ignored.keys.isEmpty, let store, let sync = mail.sync else { return change }
        let targets: [BulkTarget] = ids.compactMap { id in
            guard !sweeping.contains(id), let m = try? store.message(id: id, includeBody: false),
                  let f = mail.folder(id: m.folderId) else { return nil }
            return BulkTarget(message: m, mailbox: f.mailbox)
        }
        let steps = ignored.sweep(targets) { w, mb in ((try? store.folder(wellKnown: w, mailbox: mb)) ?? nil)?.id }
        guard !steps.isEmpty else { return change }
        let gone = Set(steps.map(\.messageId))
        sweeping.formUnion(gone)
        mail.dropRows(gone)
        Task { @MainActor [weak self] in
            _ = await sync.apply(steps)
            self?.sweeping.subtract(gone)
        }
        return .messages(ids: ids.filter { !gone.contains($0) })
    }

    // MARK: Trays

    func setTray(_ t: MailTray, on: Bool, rows: [MailRow], mail: MailModel) {
        let steps = rows.flatMap { r in MailTray.plan(t, message: r.message, on: on).map { BulkStep(messageId: r.id, action: $0) } }
        let n = rows.count == 1 ? "1 message" : "\(rows.count) messages"
        applySteps(steps, rows: rows, label: on ? "\(t.title): \(n)" : "Removed \(n) from \(t.title)", mail: mail)
        if on { Task { await ensureCategory(t.category, colour: t.colour, mail: mail) } }
    }

    /// One-key toggle over the selection: into the tray unless every target is already in it.
    func toggleTray(_ t: MailTray, mail: MailModel) {
        let rows = currentRows(mail)
        guard !rows.isEmpty else { return }
        setTray(t, on: !rows.allSatisfy { t.holds($0.message) }, rows: rows, mail: mail)
    }

    /// Outlook shows unknown categories grey; create the master category once so it has a colour everywhere.
    private func ensureCategory(_ name: String, colour: CategoryColor, mail: MailModel) async {
        let ui = MailListUI.shared
        await ui.loadCategories(mail)
        guard ui.categoriesLoaded, !ui.categories.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }),
              let svc = mail.sync?.masterCategoryService else { return }
        _ = try? await svc.createCategory(displayName: name, color: colour, mailbox: "me")
        await ui.loadCategories(mail, force: true)
    }

    // MARK: Quick Steps

    func run(_ s: QuickStep, rows: [MailRow], mail: MailModel) {
        guard let store, !rows.isEmpty else { return }
        let targets = rows.map { BulkTarget(message: $0.message, mailbox: $0.mailbox) }
        let plan = QuickStepPlanner.plan(s, targets: targets) { w, mb in ((try? store.folder(wellKnown: w, mailbox: mb)) ?? nil)?.id }
        if let r = plan.reply, let row = rows.first(where: { $0.id == r.messageId }) {
            if MailActionRights.allows(.reply, policy: row.policy),
               let t = (store.sealed(TemplateLibrary.self, for: TemplateLibrary.storeKey) ?? TemplateLibrary()).templates.first(where: { $0.id == r.templateId }) {
                mail.reply(.reply, to: row.id)
                if let c = mail.composer { mail.insertTemplate(t, in: c) }
            } else {
                mail.toast(MailToast(text: "Reply skipped — not allowed for this message, or the template is gone", symbol: "info.circle"))
            }
        }
        for a in s.actions { if case .tray(let t) = a { Task { await ensureCategory(t.category, colour: t.colour, mail: mail) } } }
        if !plan.steps.isEmpty || plan.reply == nil {
            applySteps(plan.steps, rows: rows, label: "\(s.name): \(rows.count == 1 ? "1 message" : "\(rows.count) messages")", mail: mail)
        }
        if plan.skippedReply { mail.toast(MailToast(text: "Reply skipped — Quick Step replies need a single message", symbol: "info.circle")) }
    }

    func runShortcut(_ n: Int, mail: MailModel) {
        guard let s = quickSteps.step(shortcut: n) else { return }
        run(s, rows: currentRows(mail), mail: mail)
    }

    func currentRows(_ mail: MailModel) -> [MailRow] {
        let ids = Set(MailChrome.shared.targets(mail))
        return mail.visibleRows.filter { ids.contains($0.id) }
    }

    /// Ordered steps as one action: optimistic list removal for moves, one toast, one ⌘Z (inverses in reverse order).
    func applySteps(_ steps: [BulkStep], rows: [MailRow], label: String, mail: MailModel) {
        let (steps, rows) = mail.expandThreadSteps(steps, rows: rows)   // THREAD-HOOK: a thread row = all its members
        guard !steps.isEmpty, let sync = mail.sync else {
            mail.toast(MailToast(text: "Nothing to change", symbol: "checkmark")); return
        }
        var current = Dictionary(rows.map { ($0.id, $0.message) }, uniquingKeysWith: { a, _ in a })
        var inverses: [BulkStep] = [], moveBacks: [BulkStep] = []
        for s in steps {
            guard let before = current[s.messageId] else { continue }
            if let inv = TriageUndo.inverse(of: s.action, before: before) {
                switch s.action {
                case .move, .delete, .snooze: moveBacks.append(BulkStep(messageId: s.messageId, action: inv))
                default: inverses.append(BulkStep(messageId: s.messageId, action: inv))
                }
            }
            var after = before
            switch s.action {
            case .categorize(let c): after.categories = c
            case .flag(let f): after.flag = f
            case .markRead(let b): after.isRead = b
            default: break
            }
            current[s.messageId] = after
        }
        let gone = Set(steps.filter { switch $0.action { case .move, .delete, .snooze: true; default: false } }.map(\.messageId))
        if !gone.isEmpty {
            if let sel = mail.selectedMessageId, gone.contains(sel) {
                let v = mail.visibleRows
                if let i = v.firstIndex(where: { $0.id == sel }) {
                    mail.selectedMessageId = v[i...].first { !gone.contains($0.id) }?.id ?? v[..<i].last { !gone.contains($0.id) }?.id
                }
            }
            mail.dropRows(gone)
        }
        // Undo: state changes first (newest first; MailSync.undo follows the one move's id remap), the move back last.
        mail.pushUndo(MailModel.UndoEntry(steps: QuickStepPlanner.undoOrder(state: inverses, moves: moveBacks), text: label))
        mail.toast(MailToast(text: label, symbol: "checkmark", action: .undoTriage))
        MailChrome.shared.marked = []
        Task { @MainActor in
            let r = await sync.apply(steps)
            if r.failed > 0 { mail.toast(MailToast(text: "Couldn't apply \(r.failed) of \(steps.count) changes", symbol: "exclamationmark.triangle", isError: true)) }
            mail.reloadList()
        }
    }

    // MARK: Palette + keys

    func paletteItems(_ mail: MailModel) -> [MailModel.PaletteItem] {
        var out: [MailModel.PaletteItem] = quickSteps.steps.map { s in
            .init(id: "org2:qs:" + s.id.uuidString, title: "Quick Step: \(s.name)", subtitle: s.shortcut.map { "⌃⇧\($0)" } ?? "",
                  symbol: "bolt", kind: .section("org2:qs:" + s.id.uuidString))
        }
        for t in MailTray.allCases {
            out.append(.init(id: "org2:tray:" + t.rawValue, title: "\(t.title) (toggle)", subtitle: t == .replyLater ? "⇧L" : "⇧A",
                             symbol: t.symbol, kind: .section("org2:tray:" + t.rawValue)))
            out.append(.init(id: "org2:open:" + t.rawValue, title: "Go to \(t.title)", subtitle: "Tray", symbol: t.symbol,
                             kind: .section("org2:open:" + t.rawValue)))
        }
        out.append(.init(id: "org2:vip", title: "Go to VIPs", subtitle: "Smart view", symbol: "star", kind: .section("org2:vip")))
        out.append(.init(id: "org2:ignore", title: "Ignore conversation", subtitle: "", symbol: "speaker.slash", kind: .section("org2:ignore")))
        for f in favourites.items {
            out.append(.init(id: "org2:fav:" + f.id, title: "Go to \(title(f, mail: mail))", subtitle: "Favourite",
                             symbol: symbol(f, mail: mail), kind: .section("org2:fav:" + f.id)))
        }
        return out
    }

    func runPalette(_ id: String, mail: MailModel) {
        let rest = String(id.dropFirst("org2:".count))
        if rest.hasPrefix("qs:"), let u = UUID(uuidString: String(rest.dropFirst(3))), let s = quickSteps.steps.first(where: { $0.id == u }) {
            run(s, rows: currentRows(mail), mail: mail)
        } else if rest.hasPrefix("tray:"), let t = MailTray(rawValue: String(rest.dropFirst(5))) {
            toggleTray(t, mail: mail)
        } else if rest.hasPrefix("open:"), let t = MailTray(rawValue: String(rest.dropFirst(5))) {
            open(.tray(t), mail: mail)
        } else if rest == "vip" {
            open(.vip, mail: mail)
        } else if rest == "ignore", let r = mail.selectedRow {
            ignore(r, mail: mail)
        } else if rest.hasPrefix("fav:"), let f = favourites.items.first(where: { $0.id == String(rest.dropFirst(4)) }) {
            open(f, mail: mail)
        }
    }

    /// Bare keys (list focus): ⇧L Reply Later, ⇧A Set Aside, ⇧V VIP sender. true = handled.
    func handleKey(_ characters: String, mail: MailModel) -> Bool {
        switch characters {
        case "L": toggleTray(.replyLater, mail: mail); return true
        case "A": toggleTray(.setAside, mail: mail); return true
        case "V":
            guard let r = mail.selectedRow, !r.policy.redactDetails, let a = r.message.from?.address, !a.isEmpty else { return false }
            setVIP(a, !isVIP(a)); return true
        default: return false
        }
    }
}
