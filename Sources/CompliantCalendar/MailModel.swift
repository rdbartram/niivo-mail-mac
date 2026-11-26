import SwiftUI
import CryptoKit
import CalendarCore
import MailCore
import ProtectedContent

/// One row in the message list: a message, or the newest message of a conversation (`count` > 1).
struct MailRow: Identifiable, Equatable {
    var message: MailMessage
    var mailbox: String
    var count: Int
    var policy: ContentPolicy
    /// THREAD-HOOK: the store-grouped conversation this row stands for (nil = a single message / client grouping).
    var thread: MailThreadSummary? = nil
    var id: String { message.id }
}

struct MailToast: Identifiable, Equatable {
    enum Action: Equatable { case none, undoTriage, undoSend(UUID), voiceNudge }   // VOICE2-HOOK: voiceNudge
    var id = UUID()
    var text: String
    var symbol: String
    var action: Action = .none
    var isError = false
    /// Undo-send toasts count down to this.
    var deadline: Date?
}

/// Reader pane state for the selected message.
struct ReaderState: Equatable {
    var header: MailMessage
    var mailbox: String
    var policy: ContentPolicy
    var body: String?
    var bodyIsHTML = false
    var loading = false
    var error: String?
    var thread: [MailMessage] = []
}

/// Composer sheet state (all view state lives in models: no `@State` under CLT).
@MainActor @Observable
final class ComposerState: Identifiable {
    let id = UUID()
    var kind: MailDraft.Kind
    var original: MailMessage?
    var from: SendIdentity?
    var to: [EmailAddress] = [] { didSet { edited() } }
    var cc: [EmailAddress] = [] { didSet { edited() } }
    var bcc: [EmailAddress] = [] { didSet { edited() } }
    var toText = "" { didSet { edited() } }   // typed-but-not-tokenised addresses still autosave
    var ccText = "" { didSet { edited() } }   // typed-but-not-tokenised addresses still autosave
    var bccText = "" { didSet { edited() } }   // typed-but-not-tokenised addresses still autosave
    var showCcBcc = false
    var subject = "" { didSet { edited() } }
    var body = "" { didSet { edited() } }
    var importance: Importance = .normal { didSet { edited() } }
    /// COMPOSE2: reply/forward without the quoted history (Mail Settings → Send As → Replying).
    var omitHistory = false
    private(set) var labelId: String?
    /// The original's label: a reply/forward can't go below it.
    let floorLabelId: String?
    var floorMessage: String?
    var showSendLater = false
    var customSendAt = Date().addingTimeInterval(3600)
    var error: String?
    // Autosave (COMPOSE2): one server draft per composer, PATCHed in place (MailCore DraftSession).
    @ObservationIgnored var session = DraftSession()
    var savedDraftId: String? { session.draftId }
    var savedAt: Date?
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    /// The user changed something since it opened (prefilled reply recipients don't count).
    @ObservationIgnored var touched = false
    /// Opened from Drafts: a draft the user already kept is never deleted by clicking away.
    @ObservationIgnored var reopened = false

    /// Worth keeping when the user clicks away (owner, 2026-11-20: "either delete or save depending on content").
    /// Prefilled reply recipients, the quoted history, a default signature and a forward's original attachments
    /// are not the user's content.
    var hasUserContent: Bool {
        if reopened || !editor.userTextIsEmpty { return true }
        switch kind {
        case .new: return !allRecipients.isEmpty || !subject.isEmpty
        case .forward: return !allRecipients.isEmpty
        default: return false
        }
    }
    var onEdit: (() -> Void)?
    /// Rich editor (MailEditorState.swift); `body` is its plain-text mirror.
    let editor = ComposerEditorState()

    init(kind: MailDraft.Kind, original: MailMessage?, from: SendIdentity?) {
        self.kind = kind; self.original = original; self.from = from
        floorLabelId = kind == .new ? nil : MailLabelFloor.inheritableLabel(original, tree: PurviewPolicy.shared.tree())
        labelId = floorLabelId
        labelId = PurviewPolicy.shared.initialLabel(floor: floorLabelId, composerId: id)   // PURVIEW-HOOK: default label
        editor.onText = { [weak self] s in self?.body = s }
        editor.onFormat = { [weak self] in self?.edited() }
    }

    private func edited() { onEdit?() }

    var allRecipients: [EmailAddress] { to + cc + bcc }

    func setLabel(_ id: String?, engine: CachedLabelPolicyEngine) {
        var d = draft()
        d.labelId = id
        let enforced = MailLabelFloor.enforce(d, original: original, engine: engine)
        labelId = enforced.labelId
        floorMessage = LabelFloorExplainer.message(requested: id, enforced: enforced.labelId, labels: engine.allLabels())
        PurviewPolicy.shared.labelPicked(self)   // PURVIEW-HOOK
        edited()
    }

    /// Pending text in the token fields becomes tokens (on send / field exit).
    func commitTokenText() {
        func take(_ text: inout String, into list: inout [EmailAddress]) {
            let (valid, _) = RecipientCheck.parse(text)
            for a in valid where !list.contains(where: { $0.address.lowercased() == a.address.lowercased() }) { list.append(a) }
            if !valid.isEmpty { text = "" }
        }
        take(&toText, into: &to); take(&ccText, into: &cc); take(&bccText, into: &bcc)
    }

    func draft(sendAt: Date? = nil) -> MailDraft {
        // Addresses still being typed (not yet turned into tokens) belong to the draft too, or autosave drops them.
        func merged(_ list: [EmailAddress], _ text: String) -> [EmailAddress] {
            list + RecipientCheck.parse(text).0.filter { a in !list.contains { $0.address.lowercased() == a.address.lowercased() } }
        }
        let to = merged(to, toText), cc = merged(cc, ccText), bcc = merged(bcc, bccText)
        var d = MailDraft(kind: kind, replyTo: kind == .new ? nil : original?.id, to: to, cc: cc, bcc: bcc, subject: subject,
                  bodyHTML: editor.html(reconciling: body), importance: importance, labelId: labelId, sendAt: sendAt,
                  from: from?.mode == .selfSend ? nil : from)
        d.attachments = editor.outgoing()
        if omitHistory && kind != .new { d.omitHistory = true }
        d.labelHeader = PurviewPolicy.shared.header(for: self)   // PURVIEW-HOOK: msip_labels stamp
        return d
    }

    var isEmpty: Bool { allRecipients.isEmpty && subject.isEmpty && editor.contentIsEmpty }
}

@MainActor @Observable
final class MailModel {
    enum Phase: Equatable { case notStarted, starting, fixtures, live, needsConsent(String), unavailable(String), wiped }

    private(set) var phase: Phase = .notStarted
    var started: Bool { phase != .notStarted && phase != .wiped }
    var isFixtures: Bool { fixtures != nil }
    private(set) var compliance = CachedLabelPolicyEngine()
    private(set) var sync: MailSync?
    private(set) var store: MailStore?
    private var fixtures: FixtureMailService?
    private(set) var me: EmailAddress?
    private(set) var mailboxes: [String] = ["me"]
    private(set) var folders: [String: [MailFolder]] = [:]
    private(set) var openedMailboxes: Set<String> = ["me"]
    private(set) var settings = MailSettings()
    private(set) var status = MailSyncStatus()
    private(set) var maxWindowDays = 3650

    // MARK: Selection + list

    var selectedFolderId: String? {
        didSet {
            guard oldValue != selectedFolderId else { return }
            searchText = ""
            if let c = composer {   // another folder: the pane composer goes (saved or deleted by content)
                if ai.composer.preview != nil { ai.acceptPreview() }
                closeComposer(c)
            }
            resetList()
            focusListToken += 1
            // Opening a folder always pulls its latest changes, then shows them. Virtual lists (unified inbox, smart
            // views — MailBulk.swift) have no server folder.
            if let id = selectedFolderId, VirtualFolder(id: id) == nil, let sync {
                Task { @MainActor [weak self] in
                    await sync.openFolder(id)
                    if self?.selectedFolderId == id { self?.refreshFolders(); self?.reloadList() }
                }
            }
        }
    }
    var selectedMessageId: String? {
        didSet {
            guard oldValue != selectedMessageId else { return }
            leavePaneComposerIfElsewhere()
            Task { await loadReader() }
        }
    }

    /// Clicking another conversation or folder while replying in the pane: keep the draft if it has content,
    /// otherwise delete it (with any autosaved server copy). Same conversation (thread view) keeps it open.
    func leavePaneComposerIfElsewhere() {
        guard let c = composer else { return }
        if let o = c.original {
            if selectedMessageId == o.id { return }
            if let sel = selectedMessageId, !o.conversationId.isEmpty,
               rows.first(where: { $0.id == sel })?.conversationId == o.conversationId { return }
        }
        if c.original == nil && selectedMessageId == nil { return }   // a new mail in the pane, nothing selected
        if ai.composer.preview != nil { ai.acceptPreview() }   // an AI draft not kept yet is still the user's draft
        closeComposer(c)
    }
    private(set) var rows: [MailMessage] = []
    private(set) var reachedEnd = false
    private(set) var isLoadingMore = false
    var splitTab: InboxBucket = .important {
        didSet { if oldValue != splitTab { selectedMessageId = nil; Task { await fillIfShort() } } }
    }
    var splitInboxEnabled: Bool = UserDefaults.standard.object(forKey: "mail.splitInbox") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitInboxEnabled, forKey: "mail.splitInbox") }
    }
    // THREAD-HOOK: default ON (MailThreadPreferences); the list re-pages from the store when it flips.
    var groupConversations: Bool = MailThreadPreferences.load().grouped {
        didSet {
            UserDefaults.standard.set(groupConversations, forKey: MailThreadPreferences.Key.grouped)
            if oldValue != groupConversations { threadSummaries = [:]; resetList() }
        }
    }
    /// THREAD-HOOK: store-grouped thread page for the current folder, by conversation id (MailModel+Threads.swift).
    var threadSummaries: [String: MailThreadSummary] = [:]
    var threadPolicies: [String: ContentPolicy] = [:]

    // MARK: Search

    var searchText = "" { didSet { if oldValue != searchText { scheduleSearch() } } }
    private(set) var searchResults: [MailMessage]?
    // AI-HOOK: AI assist (settings, triage cache, features). See AIAssistModel.swift.
    @ObservationIgnored private(set) lazy var ai: AIAssistModel = { let a = AIAssistModel(); a.mail = self; return a }()
    @ObservationIgnored let search = SearchHub()   // SEARCH-HOOK: graph + hybrid search (SearchViews.swift)
    /// AI-HOOK: natural-language search results (query ran locally over the blind index).
    func aiShowSearchResults(_ r: [MailMessage], summary: String?) {
        searchTask?.cancel(); searching = false
        SearchBoxState.shared.result = nil   // SEARCHBOX-HOOK: AI results have their own order (no sort toggle)
        searchResults = r
        selectedMessageId = r.first?.id
        if let summary { toast(MailToast(text: "AI search: \(summary)", symbol: "sparkle.magnifyingglass")) }
    }
    private(set) var searching = false
    var focusSearchToken = 0
    private var searchTask: Task<Void, Never>?

    // MARK: Reader, composer, UI flags

    private(set) var reader: ReaderState?
    /// Messages whose remote images the user allowed this session (never honoured for labelled mail).
    private(set) var imagesAllowed: Set<String> = []
    var composer: ComposerState?
    /// COMPOSE2: further open drafts, each in its own window (WindowGroup "composer-extra").
    private(set) var windowComposers: [ComposerState] = []
    /// Window opens the views still have to perform (ExtraComposerOpener, MailWindows.swift).
    var windowRequests: [UUID] = []
    private(set) var toasts: [MailToast] = []
    var showCheatSheet = false
    var showPalette = false
    var paletteQuery = "" { didSet { paletteIndex = 0 } }
    var paletteIndex = 0
    var showSnooze = false
    var snoozeCustom = Date().addingTimeInterval(3 * 3600)
    var showCategories = false
    var showSettings = false
    /// §17: size of the view that presents the Settings sheet, so the sheet (and the rule editor on top of it) is
    /// clamped to the window instead of a fixed 820×600 that runs past small windows / screens. Zero = unknown.
    var settingsHost: CGSize = .zero
    var settingsTab: SettingsTab = .mail
    enum SettingsTab: String, CaseIterable, Identifiable {
        case mail, layout, rules, autoReplies, identities, trust, ai, accounts   // AI-HOOK: .ai · A11Y-HOOK: .layout · ACCOUNTS-HOOK: .accounts
        var id: String { rawValue }
        var title: String {
            switch self { case .mail: L("Mail"); case .layout: L("Layout & Accessibility"); case .rules: L("Rules"); case .autoReplies: L("Automatic Replies"); case .identities: L("Send As"); case .trust: L("Device Trust"); case .ai: L("AI"); case .accounts: L("Accounts") }
        }
        var symbol: String {
            switch self { case .mail: "envelope"; case .layout: "accessibility"; case .rules: "line.3.horizontal.decrease.circle"; case .autoReplies: "airplane"; case .identities: "person.2"; case .trust: "lock.shield"; case .ai: "sparkles"; case .accounts: "person.crop.circle.badge.plus" }
        }
    }

    /// Asks the message list to take keyboard focus (after sheets close, section switches).
    var focusListToken = 0

    // MARK: Undo

    /// One ⌘Z step: a single triage or a whole bulk plan (MailBulk.swift). Ids are re-resolved at undo time.
    struct UndoEntry { var steps: [BulkStep]; var text: String; var after: (@MainActor () -> Void)? = nil }   // TODAY-HOOK: after   // ORG2-HOOK: internal (MailOrg2.applySteps)
    private var undoStack: [UndoEntry] = []
    private var pendingSendComposers: [UUID: ComposerState] = [:]

    // MARK: Rules / OOF / settings extras

    private(set) var rules: [MailRule] = []
    var ruleEditor: RuleEditorState?
    var newIdentity = SendIdentity(address: "", name: "", mailbox: "me", mode: .sendAs)
    var ruleError: String?
    var ruleWarnings: [String] = []
    private(set) var autoReplies: AutomaticReplies?
    var autoRepliesDraft = AutomaticReplies()
    var autoRepliesError: String?
    private(set) var oofActive = false
    private(set) var oofUntil: Date?
    private(set) var backfill: [String: BackfillInfo] = [:]
    struct BackfillInfo: Equatable { var oldest: Date?; var done: Bool }
    private(set) var bodyCacheUsed = 0
    private(set) var recentAddresses: [String: EmailAddress] = [:]

    // MARK: Boot

    /// Fixtures: synthetic mailboxes (me, shared support@, delegated Sam), in-memory store with an ephemeral key.
    func startFixtures(compliance: CachedLabelPolicyEngine, maxWindowDays: Int) async {
        guard phase == .notStarted || phase == .wiped else { return }
        phase = .starting
        self.compliance = compliance
        self.maxWindowDays = maxWindowDays
        let svc = FixtureMailService()
        fixtures = svc
        var s = MailSettings(pinnedMailboxes: [FixtureMailService.sharedMailbox], identities: [
            SendIdentity(address: FixtureMailService.me.address, name: FixtureMailService.me.name),
            SendIdentity(address: FixtureMailService.sharedMailbox, name: "Contoso Support",
                         mailbox: FixtureMailService.sharedMailbox, mode: .sendAs),
            SendIdentity(address: FixtureMailService.principal, name: "Sam Rivera",
                         mailbox: FixtureMailService.principal, mode: .sendOnBehalf),
        ])
        s.internalDomains = ["contoso.example"]
        capWindows(&s, maxDays: maxWindowDays)
        await open(service: svc, store: try? MailStore(url: nil, key: SymmetricKey(size: .bits256)),
                   mailboxes: FixtureMailService.mailboxes, settings: s)
        phase = sync == nil ? .unavailable("Couldn't open the mail cache") : .fixtures
        await afterOpen()
    }

    /// Live: Graph via the signed-in account's mail token. A token/consent failure stays inside Mail.
    /// `keys` comes from the SE-backed `CacheKeyring` (payload key + blind-index key; `fresh` → the old file is garbage).
    func startLive(compliance: CachedLabelPolicyEngine, token: @escaping GraphMailService.TokenProvider, account: String,
                   keys: () throws -> (cache: SymmetricKey, index: SymmetricKey, fresh: Bool),
                   shared: [String], delegated: [String], maxWindowDays: Int, tenant: String? = nil) async {
        guard phase == .notStarted else { return }
        phase = .starting
        self.compliance = compliance
        self.maxWindowDays = maxWindowDays
        let throttle = ThrottleMonitor()
        let svc = GraphMailService(token: token, throttle: throttle, accountTenant: tenant)   // ACCOUNTS-HOOK
        let meAddr: EmailAddress
        do { meAddr = try await svc.me() } catch {
            phase = .needsConsent("Mail couldn't get access to your mailbox. The app registration needs the Mail permissions "
                                  + "(Mail.ReadWrite, Mail.Send, MailboxSettings.ReadWrite and the .Shared variants) consented, "
                                  + "then sign in again.")
            return
        }
        do {
            let k = try keys()
            let url = AppConfig.supportDir.appending(path: "\(CacheKeyring.safeName(account))-mail.sqlite")
            if k.fresh { CacheKeyring.discardStaleCache(at: url) }  // sealed with a lost key: unreadable, resync
            let store = try MailStore(url: url, cipher: AESGCMCipher(key: k.cache), indexKey: k.index)
            var s = (try? store.settings()) ?? MailSettings()
            if s.identities.isEmpty {
                s.identities = [SendIdentity(address: meAddr.address, name: meAddr.name)]
                    + shared.map { SendIdentity(address: $0, name: MailboxDisplay.title($0), mailbox: $0, mode: .sendAs) }
                    + delegated.map { SendIdentity(address: $0, name: MailboxDisplay.title($0), mailbox: $0, mode: .sendOnBehalf) }
            }
            if s.internalDomains.isEmpty { s.internalDomains = [RecipientCheck.domain(of: meAddr.address)] }
            capWindows(&s, maxDays: maxWindowDays)
            await open(service: svc, store: store, mailboxes: ["me"] + shared + delegated, settings: s, throttle: throttle)
            me = meAddr
            phase = .live
            await afterOpen()
        } catch CacheKeyring.KeyringError.locked {
            phase = .notStarted   // locked while Graph answered: reopen after unlock
        } catch { phase = .unavailable("Mail cache unavailable") }
    }

    /// Trust policy caps how much history a BYOD Mac may keep.
    private func capWindows(_ s: inout MailSettings, maxDays: Int) {
        func cap(_ w: CacheWindow) -> CacheWindow { Self.window(w, cappedAt: maxDays) }
        s.defaultWindow = cap(s.defaultWindow); s.sharedDefaultWindow = cap(s.sharedDefaultWindow)
        s.windows = s.windows.mapValues(cap)
    }

    static func window(_ w: CacheWindow, cappedAt maxDays: Int, now: Date = .now) -> CacheWindow {
        guard let lim = Calendar.current.date(byAdding: .day, value: -maxDays, to: now) else { return w }
        guard let c = w.cutoff(now: now) else { return .days(maxDays) }
        return c < lim ? .days(maxDays) : w
    }

    /// May the user pick this window under the trust policy?
    func allows(_ w: CacheWindow) -> Bool { Self.window(w, cappedAt: maxWindowDays) == w }

    private func open(service: MailService, store: MailStore?, mailboxes: [String], settings s: MailSettings,
                      throttle: ThrottleMonitor? = nil) async {
        guard let store else { return }
        self.store = store
        // MAILBOXES-HOOK: config-declared + added in the app, minus removed, in the user's order (MailboxList).
        configuredMailboxes = mailboxes.filter { $0 != "me" }
        let mailboxes = MailboxList.compose(configured: configuredMailboxes, settings: s)
        self.mailboxes = mailboxes
        if fixtures != nil { me = FixtureMailService.me }
        sync = MailSync(service: service, store: store, compliance: compliance, mailboxes: mailboxes, settings: s,
                        throttle: throttle, pageSize: 100) { [weak self] change in
            Task { @MainActor in self?.handle(change) }
        }
        settings = s
    }

    private func afterOpen() async {
        guard let sync, let store else { return }
        // Label parsing v2 (foreign-tenant labels ignored): rows cached before it carry the wrong label, and delta
        // never re-sends unchanged items, so drop the header cache once. Skipped while offline actions are queued.
        // Rows stored as 1970 by the partial-delta bug: drop their cursors so the next pass fetches them whole.
        if fixtures == nil, (try? store.value(for: "epochFix")) ?? nil != "1", (try? store.outbox().isEmpty) == true {
            try? store.resetHeaders(); try? store.setValue("1", for: "epochFix"); try? store.setValue("2", for: "labelParse")
            FileHandle.standardError.write(Data("[Mail] epoch-date repair: header cache refreshed\n".utf8))
        }
        if fixtures == nil, (try? store.value(for: "labelParse")) ?? nil != "2", MIPMetadata.homeTenantId != nil,
           (try? store.outbox().isEmpty) == true {
            try? store.resetHeaders()
            try? store.setValue("2", for: "labelParse")
            FileHandle.standardError.write(Data("[Mail] label parsing v2: header cache refreshed\n".utf8))
        }
        MailOrg2.shared.attach(self, store: store)   // ORG2-HOOK: favourites, VIPs, ignored, quick steps
        search.attach(store: store, me: me?.address ?? "", mailboxes: mailboxes, internalDomains: settings.internalDomains, compliance: compliance, onDeviceAccess: AIOrgAccess(trustRawValue: ai.trustPolicy.effectiveOnDeviceAIAccess.rawValue))   // SEARCH-HOOK
        // Show what the cache already has before the first sync pass: a full pass on a large mailbox can take
        // minutes, and until the inbox is selected the list stays empty while the folder counts already show.
        refreshFolders()
        TodayModel.shared.launch(self)   // TODAY-HOOK: "Open Today at launch" (first folder selection)
        if selectedFolderId == nil { selectedFolderId = (try? store.folder(wellKnown: .inbox, mailbox: "me"))?.id }
        else { resetList() }
        focusListToken += 1
        await sync.syncNow()
        for mb in settings.pinnedMailboxes { openedMailboxes.insert(mb); await sync.openMailbox(mb) }
        refreshFolders()
        if selectedFolderId == nil { selectedFolderId = (try? store.folder(wellKnown: .inbox, mailbox: "me"))?.id }
        else { reloadList() }
        if let sent = try? store.folder(wellKnown: .sentitems, mailbox: "me") {
            collectAddresses((try? store.messages(folderId: sent.id, limit: 200)) ?? [])
        }
        await refreshAutoReplies()
        await sync.wakeSnoozed()
        focusListToken += 1
        MailNotifier.shared.arm(self)   // NOTIFY-HOOK: from here on, new Inbox mail may notify
        startTimers()
    }

    private var timerTask: Task<Void, Never>?

    /// Snooze wake-ups and client-side send-later both need a running clock: every minute wake snoozed mail and
    /// flush the outbox (due scheduled sends go out); every 5 minutes a sync pass.
    private func startTimers() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            // 30 s: Inbox delta. 60 s: snooze wake-ups + outbox. 5 min: full pass (all folders, shared, backfill).
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let sync = self.sync else { return }
                ticks += 1
                // LIFECYCLE-HOOK: with every window closed the Inbox delta drops to every 2 min (BackgroundSyncCadence);
                // nothing while throttled or while sign-in is needed. Snooze + outbox keep their 60 s clock.
                let lc = AppLifecycle.shared
                let visible = lc.windowsVisible
                // While sign-in is needed only the 5-min full pass runs (a probe: a clean pass clears the state).
                let work = lc.mailNeedsSignIn ? (ticks % 10 == 0 ? .full : .none)
                    : BackgroundSyncCadence.work(tick: ticks, windowsVisible: visible, throttledUntil: self.status.throttledUntil["me"])
                if work == .full { await self.syncNow(); continue }
                if work == .quick {
                    await sync.quickInbox()
                    // The open folder too (Sent, Drafts, a project folder…), not just the Inbox.
                    if visible, let id = self.selectedFolderId, id != (try? self.store?.folder(wellKnown: .inbox, mailbox: "me"))??.id {
                        await sync.openFolder(id)
                    }
                    self.refreshFolders(); self.reloadList()
                }
                if ticks % 2 == 0, !lc.mailNeedsSignIn { await sync.wakeSnoozed(); await sync.flush() }
            }
        }
    }

    /// "Needs consent" / unavailable → try again (after granting consent or coming back online).
    func resetForRetry() {
        switch phase { case .needsConsent, .unavailable: phase = .notStarted; default: break }
    }

    func syncNow() async {
        guard let sync else { return }
        await sync.syncNow()
        await sync.wakeSnoozed()
        refreshFolders()
        reloadList()
    }

    // MAILBOXES-HOOK: additional mailboxes (add / remove / reorder) live in MailboxManager.swift.
    @ObservationIgnored private(set) lazy var mailboxManager: MailboxManager = { let m = MailboxManager(); m.mail = self; return m }()
    // GROUPS-HOOK: Microsoft 365 Groups (GroupsModel.swift).
    @ObservationIgnored private(set) lazy var groups: GroupsModel = { let g = GroupsModel(); g.mail = self; return g }()
    private(set) var configuredMailboxes: [String] = []
    /// The sidebar's mailbox list changed (added / removed / reordered): drop what belongs to mailboxes that left.
    /// `resetSelection`: the removed mailbox was the one on screen (its folder rows may already be gone).
    func applyMailboxes(_ list: [String], resetSelection: Bool = false) {
        mailboxes = list
        for mb in Array(folders.keys) where !list.contains(mb) { folders[mb] = nil }
        openedMailboxes = openedMailboxes.filter { list.contains($0) }
        if resetSelection || selectedFolder.map({ !list.contains($0.mailbox) }) == true {
            selectedMessageId = nil
            selectedFolderId = (try? store?.folder(wellKnown: .inbox, mailbox: "me"))??.id
        }
        refreshFolders()
    }

    func openMailbox(_ mb: String) async {
        guard let sync else { return }
        openedMailboxes.insert(mb)
        await sync.openMailbox(mb)
        refreshFolders()
    }

    /// Fixture wipe target: the in-memory mail store only.
    func wipeTarget() -> (@Sendable () throws -> Void)? {
        guard isFixtures, let store else { return nil }
        return { try store.wipe() }
    }

    /// After a (simulated) wipe: drop everything held in memory too.
    func clearAfterWipe() {
        ai.wipe()   // AI-HOOK
        search.close()   // SEARCH-HOOK
        searchTask?.cancel(); searching = false; SearchBoxState.shared.reset()   // SEARCHBOX-HOOK: no decrypted box results kept
        ReaderExtras.dropAll()   // READER-HOOK: inline images, attachment temp files, notifications, badge
        for c in openComposers { c.autosaveTask?.cancel() }   // COMPOSE2
        timerTask?.cancel()
        MailOrg2.shared.detach()   // ORG2-HOOK
        sync = nil; store = nil; fixtures = nil
        rows = []; folders = [:]; reader = nil; composer = nil; windowComposers = []; windowRequests = []; searchResults = nil; toasts = []
        undoStack = []; pendingSendComposers = [:]; rules = []; recentAddresses = [:]; imagesAllowed = []
        openedMailboxes = ["me"]; selectedMessageId = nil; selectedFolderId = nil
        groups.reset()   // GROUPS-HOOK: in-memory group content goes with the mail cache
        phase = .wiped
    }

    /// App lock (live): close the file-backed store (its cipher holds the key) and drop everything rendered from it.
    /// `phase` returns to `.notStarted`, so the next `startMailIfNeeded` after unlock reopens it. An unsaved composer is
    /// discarded (its last autosave, if any, is a server draft).
    func suspendForLock() {
        ai.reset()   // AI-HOOK: drop in-memory AI results while locked
        guard !isFixtures, phase != .notStarted else { return }
        clearAfterWipe()
        phase = .notStarted
    }

    func signOut() {
        ai.wipe()   // AI-HOOK
        if let store { try? store.wipe() }
        clearAfterWipe()
        phase = .notStarted
    }

    // MARK: Changes from MailSync

    private var reloadPending = false

    private func handle(_ change: MailChange) {
        MailNotifier.shared.handle(MailOrg2.shared.sweepIgnored(change, mail: self), mail: self)   // NOTIFY-HOOK (ORG2-HOOK: ignored conversations swept first)
        switch change {
        case .status(let s):
            if status.phase == .syncing, s.phase == .idle { logLabelCensus() }   // [Labels] once per sync pass
            status = s; AppLifecycle.shared.statusChanged(s)   // LIFECYCLE-HOOK: CAE silent retry
        case .folders: refreshFolders()
        case .messages(let ids):
            scheduleReload()
            if let r = reader, ids.contains(r.header.id), let h = try? store?.message(id: r.header.id, includeBody: false) {
                reader?.header = h
            }
            if let t = refreshedReaderThread(changed: ids) { reader?.thread = t }   // THREAD-HOOK: your sent reply joins the open conversation
        case .sendQueued(let token, let at):
            toast(MailToast(text: L("Sending…"), symbol: "paperplane", action: .undoSend(token), deadline: at))
        case .sendScheduled(_, let at):
            dropSendToasts()
            toast(MailToast(text: "Scheduled for \(at.formatted(date: .abbreviated, time: .shortened)) — sent by this Mac when due",
                            symbol: "clock.badge.checkmark"))
        case .sendCancelled(let t):
            toasts.removeAll { $0.action == .undoSend(t) }
        case .sent:
            dropSendToasts()
            toast(MailToast(text: L("Sent"), symbol: "checkmark.circle"))
            refreshFolders()
            // Exchange files the copy in Sent Items a moment after sendMail returns: pull Sent then (and Drafts,
            // where the sent draft disappears).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let store = self.store, let sync = self.sync else { return }
                for w in [WellKnownFolder.sentitems, .drafts] {
                    if let f = try? store.folder(wellKnown: w, mailbox: "me") { await sync.openFolder(f.id) }
                }
                self.refreshFolders(); self.reloadList()
            }
        case .sendFailed(_, let reason):
            dropSendToasts()
            toast(MailToast(text: Self.sendFailureText(reason), symbol: "exclamationmark.triangle", isError: true))
        case .lateScheduledSends(let n):
            toast(MailToast(text: "\(n) scheduled message\(n == 1 ? "" : "s") went out late (the Mac was off or asleep)",
                            symbol: "clock.badge.exclamationmark"))
        }
    }

    static func sendFailureText(_ reason: String) -> String {
        if reason.contains("sendAsDenied") {
            let addr = reason.split(separator: "\"").dropFirst().first.map(String.init) ?? "that address"
            return "You can't send as \(addr). Ask your admin for Send As / Send on Behalf."
        }
        if reason.contains("offline") { return "Offline — the message is queued and sends when you're back online" }
        return "Couldn't send. The draft is in Drafts."
    }

    private func dropSendToasts() {
        toasts.removeAll { if case .undoSend = $0.action { true } else { false } }
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor in
            await Task.yield()
            reloadPending = false
            refreshFolders()
            reloadList()
        }
    }

    func refreshFolders() {
        guard let store else { return }
        var out: [String: [MailFolder]] = [:]
        for mb in mailboxes { out[mb] = ((try? store.folders(mailbox: mb)) ?? []).sorted { MailboxDisplay.sortKey($0) < MailboxDisplay.sortKey($1) } }
        folders = out
    }

    var selectedFolder: MailFolder? {
        guard let id = selectedFolderId else { return nil }
        return folders.values.lazy.flatMap { $0 }.first { $0.id == id }
    }
    var selectedMailbox: String { selectedFolder?.mailbox ?? "me" }
    var isInbox: Bool { selectedFolder?.wellKnown == .inbox }
    var showsSplitTabs: Bool { isInbox && splitInboxEnabled && searchResults == nil }

    // MARK: List paging (keyset, 50 per page)

    private func resetList() {
        rows = []; reachedEnd = false; selectedMessageId = nil; threadSummaries = [:]; threadPolicies = [:]
        reloadList(minimum: MailPaging.pageSize)
        Task { await fillIfShort() }
    }

    /// Re-query the loaded window from the top (same row count), e.g. after a sync change.
    func reloadList(minimum: Int? = nil) {
        guard let store, let fid = selectedFolderId else { rows = []; return }
        let n = max(minimum ?? MailPaging.pageSize, rows.count)
        let r: [MailMessage]
        if let v = VirtualFolder(id: fid) { r = virtualPage(v, store: store, before: nil, limit: n) }
        else if usesThreadPage { r = threadPage(store: store, folderId: fid, before: nil, limit: n, replace: true) }   // THREAD-HOOK
        else { do { r = try store.messages(folderId: fid, limit: n) }
        catch { FileHandle.standardError.write(Data("[Mail] list query failed: \(String(describing: error).prefix(160))\n".utf8)); r = [] } }
        FileHandle.standardError.write(Data("[Mail] list rows=\(r.count)\n".utf8))
        rows = r
        collectAddresses(r)
        // A thread message from another folder (e.g. your reply in Sent) stays selected while it exists.
        if let id = selectedMessageId, !r.contains(where: { $0.id == id }), searchResults == nil,
           (try? store.message(id: id, includeBody: false)) == nil { selectedMessageId = nil }
        repointThreadSelection()   // THREAD-HOOK: a new message in the open thread becomes its row id
    }

    /// Called from a row's onAppear.
    func rowAppeared(index: Int) {
        guard searchResults == nil,
              MailPaging.shouldLoadMore(appearedIndex: index, loadedCount: visibleRows.count, reachedEnd: reachedEnd,
                                        isLoading: isLoadingMore) else { return }
        Task { await loadMore() }
    }

    private func fillIfShort() async {
        if !reachedEnd && visibleRows.count < MailPaging.prefetchDistance * 2 { await loadMore() }
    }

    func loadMore() async {
        guard !isLoadingMore, !reachedEnd, let store, let fid = selectedFolderId else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var pages = 0
        var last = 0
        repeat {
            func localPage() -> [MailMessage] {
                let cursor = rows.last.map { MailCursor(received: $0.received, id: $0.id) }
                if let v = VirtualFolder(id: fid) { return virtualPage(v, store: store, before: cursor, limit: MailPaging.pageSize) }
                if usesThreadPage {   // THREAD-HOOK: keyset on (latest, conversation id)
                    return threadPage(store: store, folderId: fid, before: rows.last.map { MailThreadCursor(latest: $0.received, conversationId: $0.conversationId) },
                                      limit: MailPaging.pageSize, replace: false)
                }
                return (try? store.messages(folderId: fid, before: cursor, limit: MailPaging.pageSize)) ?? []
            }
            var page = localPage()
            if page.count < MailPaging.pageSize, VirtualFolder(id: fid) != nil { reachedEnd = page.isEmpty }
            else if page.count < MailPaging.pageSize, let sync {
                // Local cache exhausted: one server page older than the oldest cached header.
                let fetched = (try? await sync.loadOlder(folderId: fid, count: MailPaging.pageSize)) ?? []
                guard fid == selectedFolderId else { return }
                page = localPage()
                if fetched.isEmpty { reachedEnd = true }
            }
            guard fid == selectedFolderId else { return }
            let have = Set(rows.map(\.id))
            rows.append(contentsOf: page.filter { !have.contains($0.id) })
            collectAddresses(page)
            pages += 1
            last = page.count
            if page.isEmpty { reachedEnd = true }
        } while !reachedEnd && MailPaging.needsAnotherPage(visibleCount: visibleRows.count, pagesThisTrigger: pages, lastPageCount: last)
    }

    /// What the list shows: search results, or the folder (split-inbox tab + optional conversation grouping).
    var visibleRows: [MailRow] {
        var msgs = searchResults ?? rows
        if searchResults == nil, showsSplitTabs { msgs = msgs.filter { SplitInbox.bucket(for: $0) == splitTab } }
        msgs = MailListUI.shared.filtered(msgs, mail: self)   // SMART VIEWS: list filter bar (MailBulk.swift)
        if searchResults == nil, usesThreadPage { return threadRows(msgs) }   // THREAD-HOOK: store-grouped rows
        var mapped: [(MailMessage, Int)] = []
        if groupConversations && searchResults == nil {
            var seen: [String: Int] = [:]
            for m in msgs {
                if let i = seen[m.conversationId] { mapped[i].1 += 1 } else { seen[m.conversationId] = mapped.count; mapped.append((m, 1)) }
            }
        } else { mapped = msgs.map { ($0, 1) } }
        return mapped.map { pair in
            let mb = store?.mailbox(forFolder: pair.0.folderId) ?? "me"
            return MailRow(message: pair.0, mailbox: mb, count: pair.1, policy: policy(for: pair.0, mailbox: mb))
        }
    }

    func splitCount(_ b: InboxBucket) -> Int { rows.filter { SplitInbox.bucket(for: $0) == b && !$0.isRead }.count }

    // MARK: Policy (every decision goes through ContentPolicy)

    func policy(for m: MailMessage, mailbox: String) -> ContentPolicy {
        MailContentPolicy.policy(for: m, mailbox: mailbox, engine: compliance)
    }

    func labelPolicy(labelId: String?) -> ContentPolicy {
        compliance.policy(labelId: labelId, isPrivate: false, access: .own)
    }

    /// Everything that can be on screen in Mail: list rows, the reader + its thread, the composer.
    var screenPolicy: ContentPolicy {
        var p = visibleRows.prefix(80).reduce(ContentPolicy.open) { $0.merged(with: $1.policy) }
        if let r = reader {
            p = p.merged(with: r.policy)
            for t in r.thread { p = p.merged(with: policy(for: t, mailbox: store?.mailbox(forFolder: t.folderId) ?? r.mailbox)) }
            p = p.merged(with: ConversationHub.shared.livePolicy(mail: self))   // THREAD-HOOK: every expanded member's live policy
        }
        p = p.merged(with: StoryHub.shared.screenPolicy(readerId: reader?.header.id))   // STORY-HOOK: Related strip
        for c in openComposers {   // COMPOSE2: every open draft (pane + windows)
            p = p.merged(with: labelPolicy(labelId: c.labelId))
            if let o = c.original { p = p.merged(with: policy(for: o, mailbox: store?.mailbox(forFolder: o.folderId) ?? "me")) }
        }
        return p
    }

    /// One content-free `[Labels]` line per sync pass: how many cached rows carry our label, an ignored foreign one,
    /// a SiteId-less one, an id outside our tree, or another organisation's encrypting label. Counts only.
    private func logLabelCensus() {
        guard fixtures == nil, let store else { return }
        let known = Set(compliance.allLabels().map { $0.id.lowercased() })
        Task.detached(priority: .utility) {
            guard let c = try? store.labelCensus(known: known) else { return }
            FileHandle.standardError.write(Data((c.logLine + "\n").utf8))
        }
    }

    // MARK: Reader

    private func loadReader() async {
        guard let id = selectedMessageId, let store, let sync,
              let header = try? store.message(id: id, includeBody: false) else { reader = nil; return }
        let mb = store.mailbox(forFolder: header.folderId)
        let p = policy(for: header, mailbox: mb)
        let thread = readerThread(for: header)   // THREAD-HOOK: folder + Sent (MailModel+Threads.swift)
        reader = ReaderState(header: header, mailbox: mb, policy: p, loading: true, thread: thread)
        MarkReadScheduler.shared.opened(header, thread: usesThreadPage && searchResults == nil ? thread : [], mail: self)   // READER2-HOOK: 0 s / 5 s / never (ReaderActions3.swift) · THREAD-HOOK: whole thread
        // Fail closed: no body fetch for private-redacted, encrypted or unknown-label mail.
        var canShow = !p.redactDetails && !p.bodyIsProtected
        // An unknown id parsed before provenance existed (cached pre-v2) or while the tenant was unknown re-decides from the
        // full message; the body is still shown only if the fresh label allows it (stale foreign labels stuck here).
        if case .unknown = p.labelState, header.labelOrigin != nil, header.labelOrigin != .tenantUnknown { canShow = false }
        guard canShow else { reader?.loading = false; return }
        do {
            let full = try await sync.fetchBody(id: id)
            guard selectedMessageId == id else { return }
            // The full message carries the authoritative msip_labels: re-decide before showing anything.
            // Unlabelled encrypted mail carries message.rpmsg: protected until its licence is known (MIP-HOOK).
            let fp = ProtectedContentCoordinator.detectingRPMSG(policy(for: full, mailbox: mb), attachments: full.attachments)
            reader?.policy = fp
            reader?.header.adoptLabel(of: full)
            reader?.header.isPrivate = full.isPrivate
            if !full.attachments.isEmpty { reader?.header.attachments = full.attachments }
            var show = !fp.redactDetails && !fp.bodyIsProtected
            if case .unknown = fp.labelState { show = false }
            guard show else { reader?.loading = false; return }
            reader?.body = full.body
            reader?.bodyIsHTML = full.bodyIsHTML
            reader?.loading = false
        } catch {
            guard selectedMessageId == id else { return }
            reader?.loading = false
            reader?.error = (error as? MailServiceError) == .offline ? "Offline — the body isn't cached on this Mac yet." : "Couldn't load the message body."
        }
    }

    /// A reader for a message window (⌘O / double-click), independent of the reading pane. Same fail-closed rules as
    /// `loadReader`: no body for private-redacted, encrypted or unknown-label mail; the full message's label re-decides.
    func standaloneReader(id: String) async -> ReaderState? {
        guard let store, let sync, let header = try? store.message(id: id, includeBody: false) else { return nil }
        let mb = store.mailbox(forFolder: header.folderId)
        let p = policy(for: header, mailbox: mb)
        let thread = readerThread(for: header)   // THREAD-HOOK: folder + Sent (MailModel+Threads.swift)
        var r = ReaderState(header: header, mailbox: mb, policy: p, loading: false, thread: thread)
        var canShow = !p.redactDetails && !p.bodyIsProtected
        // An unknown id parsed before provenance existed (cached pre-v2) or while the tenant was unknown re-decides from the
        // full message; the body is still shown only if the fresh label allows it (stale foreign labels stuck here).
        if case .unknown = p.labelState, header.labelOrigin != nil, header.labelOrigin != .tenantUnknown { canShow = false }
        guard canShow else { return r }
        do {
            let full = try await sync.fetchBody(id: id)
            let fp = ProtectedContentCoordinator.detectingRPMSG(policy(for: full, mailbox: mb), attachments: full.attachments)
            r.policy = fp; r.header.adoptLabel(of: full); r.header.isPrivate = full.isPrivate
            if !full.attachments.isEmpty { r.header.attachments = full.attachments }
            var show = !fp.redactDetails && !fp.bodyIsProtected
            if case .unknown = fp.labelState { show = false }
            guard show else { return r }
            r.body = full.body; r.bodyIsHTML = full.bodyIsHTML
        } catch {
            r.error = (error as? MailServiceError) == .offline ? "Offline — the body isn't cached on this Mac yet." : "Couldn't load the message body."
        }
        return r
    }

    /// MIP-HOOK: licence rights for `itemId` were just recorded (or cleared): re-derive the reader's policy so copy,
    /// print, reply / forward, capture and AI follow the item's licence before its body is shown.
    func refreshPolicy(itemId: String) {
        ConversationHub.shared.refreshPolicy(itemId: itemId, mail: self)   // THREAD-HOOK
        guard let r = reader, r.header.id == itemId else { return }
        reader?.policy = reprotected(r)
    }

    /// Fresh policy for a reader; an item already treated as protected (incl. rpmsg-detected, unlabelled) stays so.
    func reprotected(_ r: ReaderState) -> ContentPolicy {
        let p = policy(for: r.header, mailbox: r.mailbox)
        return r.policy.bodyIsProtected && !p.bodyIsProtected ? ProtectedPolicy.awaitingLicence(p) : p
    }

    /// MIP-HOOK: the decryption switch changed (licence rights dropped): back to label policy for the open reader.
    func refreshProtectedPolicies() {
        ConversationHub.shared.refreshProtectedPolicies(mail: self)   // THREAD-HOOK
        guard let r = reader, r.policy.bodyIsProtected else { return }
        reader?.policy = reprotected(r)
    }

    /// Remote content only for unlabelled mail, only after the user asked, only for this message.
    func remoteAllowed(for r: ReaderState) -> Bool {
        (imagesAllowed.contains(r.header.id) || senderImagesAllowed(r)) && r.policy.labelState == .unlabeled
    }

    func allowImages() {
        guard let r = reader else { return }
        allowImages(for: r)
    }

    /// THREAD-HOOK: per message (conversation cards); same rule as the reader's.
    func allowImages(for r: ReaderState) {
        guard r.policy.labelState == .unlabeled else {
            toast(MailToast(text: L("Remote images stay blocked for labelled mail"), symbol: "photo.badge.exclamationmark"))
            return
        }
        imagesAllowed.insert(r.header.id)
    }

    /// Sanitised HTML + blocked remote-image count for the reader.
    func rendered(_ r: ReaderState) -> (html: String, blocked: Int)? {
        guard let body = r.body else { return nil }
        if !r.bodyIsHTML { return (MailHTML.fromPlainText(body), 0) }
        let s = HTMLSanitizer.sanitize(body, allowRemote: remoteAllowed(for: r))
        return (s.html, s.blockedRemoteCount)
    }

    // MARK: Commands

    func run(_ cmd: MailCommand) {
        if cmd.needsSelection && selectedRow == nil {
            if cmd == .open, let first = visibleRows.first { selectedMessageId = first.id }
            return
        }
        switch cmd {
        case .next: moveSelection(1)
        case .previous: moveSelection(-1)
        case .open:   // the reader follows the selection; a draft opens in the composer
            if let r = selectedRow, r.message.isDraft { openDraft(id: r.id) }
        case .archive: archiveSelected()
        case .delete: triage(.delete)
        case .reply: reply(defaultReplyKind())   // COMPOSE2-HOOK: default reply setting (ComposeScheduled.swift)
        case .replyAll: reply(.replyAll)
        case .forward: reply(.forward)
        case .compose: compose()
        case .flag:   // THREAD-HOOK: a thread flags if no member is flagged, reads if any member is unread
            if let r = selectedRow { triage(.flag(FollowUpFlag(status: (r.thread.map(\.flagged) ?? (r.message.flag.status == .flagged)) ? .notFlagged : .flagged))) }
        case .toggleRead:
            if let r = selectedRow { triage(.markRead(r.thread.map(\.hasUnread) ?? !r.message.isRead)) }
        case .snooze: snoozeCustom = TimePreset.tomorrowMorning.date(); showSnooze = true
        case .categorize: showCategories = true
        case .palette: paletteQuery = ""; showPalette = true
        case .search: focusSearchToken += 1
        case .undo: Task { await undo() }
        case .cheatSheet: showCheatSheet.toggle()
        case .loadImages: allowImages()
        case .settings: showSettings = true
        case .sync: Task { await syncNow() }
        case .toggleConversations: groupConversations.toggle()
        }
    }

    var selectedRow: MailRow? {
        guard let id = selectedMessageId else { return nil }
        return visibleRows.first { $0.id == id }
    }

    func moveSelection(_ delta: Int) {
        let v = visibleRows
        guard !v.isEmpty else { return }
        guard let id = selectedMessageId, let i = v.firstIndex(where: { $0.id == id }) else {
            selectedMessageId = (delta > 0 ? v.first : v.last)?.id; return
        }
        let j = min(max(i + delta, 0), v.count - 1)
        selectedMessageId = v[j].id
        rowAppeared(index: j)
    }

    private func archiveSelected() { if let id = selectedMessageId { archive(id: id) } }

    func archive(id: String) {
        guard let row = visibleRows.first(where: { $0.id == id }), let store else { return }
        guard let arch = try? store.folder(wellKnown: .archive, mailbox: row.mailbox) else {
            toast(MailToast(text: L("This mailbox has no Archive folder"), symbol: "archivebox", isError: true)); return
        }
        if row.message.folderId == arch.id { return }
        triage(.move(toFolderId: arch.id), id: id, text: L("Archived"))
    }

    func snooze(until date: Date) {
        showSnooze = false
        focusListToken += 1
        let ids = MailChrome.shared.targets(self)   // BULK: a multi-selection snoozes together (one undo)
        if ids.count > 1 { applyBulk(.snooze(date), ids: ids); MailChrome.shared.marked = []; return }
        triage(.snooze(until: date))
    }

    func setCategories(_ cats: [String]) { triage(.categorize(cats)) }

    var knownCategories: [String] {
        let fromRows = Set(rows.flatMap(\.categories))
        let master = MailListUI.shared.categories.map(\.displayName)   // Outlook master list (MailBulk.swift)
        return Array(fromRows.union(master.isEmpty ? ["Follow up", "Customer", "Finance", "Internal"] : master)).sorted()
    }

    /// Optimistic triage with undo. Moves advance the selection like Superhuman/HEY.
    func triage(_ action: MailAction, id: String? = nil, text: String? = nil) {
        if triageThread(action, id: id ?? selectedMessageId, text: text) { return }   // THREAD-HOOK: whole conversation, one ⌘Z
        guard let sync, let store, let id = id ?? selectedMessageId,
              let before = try? store.message(id: id, includeBody: false) else { return }
        let removes: Bool
        switch action { case .move, .delete, .snooze, .unsnooze: removes = true; default: removes = false }
        if removes {
            if selectedMessageId == id {
                let v = visibleRows
                if let i = v.firstIndex(where: { $0.id == id }) {
                    selectedMessageId = i + 1 < v.count ? v[i + 1].id : (i > 0 ? v[i - 1].id : nil)
                }
            }
            rows.removeAll { $0.id == id }
            searchResults?.removeAll { $0.id == id }
        }
        let label = text ?? TriageUndo.describe(action)
        if let inv = TriageUndo.inverse(of: action, before: before) {
            pushUndo(UndoEntry(steps: [BulkStep(messageId: id, action: inv)], text: label))
        }
        toast(MailToast(text: label, symbol: "checkmark", action: .undoTriage))
        Task {
            do { try await sync.perform(action, on: id) }
            catch { toast(MailToast(text: L("Couldn't apply that change"), symbol: "exclamationmark.triangle", isError: true)) }
        }
    }

    func undo() async {
        // The newest pending send wins over triage.
        if let t = toasts.last(where: { if case .undoSend = $0.action { true } else { false } }), case .undoSend(let token) = t.action {
            await undoSend(token); return
        }
        guard let sync, let e = undoStack.popLast() else { return }
        // MailSync.undo follows server-move id remaps (a moved message has a new id once the move has flushed).
        let r = await sync.undo(e.steps)
        toasts.removeAll { $0.action == .undoTriage }
        if r.failed == 0 {
            e.after?()   // TODAY-HOOK: Done's state mark goes with the move
            toast(MailToast(text: L("Undone: %@", e.text), symbol: "arrow.uturn.backward"))
        } else {
            toast(MailToast(text: r.done == 0 ? "Couldn't undo — the message changed on the server"
                                              : "Undone for \(r.done) of \(r.done + r.failed) — the rest changed on the server",
                            symbol: "exclamationmark.triangle", isError: true))
        }
        reloadList()
    }

    /// ORG2-HOOK: optimistic removal for Quick Steps / the ignore sweep (MailOrg2.swift).
    func dropRows(_ ids: Set<String>) { rows.removeAll { ids.contains($0.id) }; searchResults?.removeAll { ids.contains($0.id) } }

    func pushUndo(_ e: UndoEntry) {   // ORG2-HOOK: internal
        guard !e.steps.isEmpty || e.after != nil else { return }   // TODAY-HOOK: a state-only Done can be undone too
        undoStack.append(e)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// Bulk triage (MailBulk.swift builds the op): one optimistic update, one toast, one ⌘Z entry.
    /// Returns (applied, skipped).
    @discardableResult
    func applyBulk(_ op: BulkOp, ids: [String], folderName: String? = nil) -> (applied: Int, skipped: Int) {
        guard let sync, let store else { return (0, 0) }
        let idset = Set(ids)
        let targets = expandThreadTargets(visibleRows.filter { idset.contains($0.id) })   // THREAD-HOOK: every member in the folder
        let plan = BulkPlanner.plan(op, targets: targets) { w, mb in ((try? store.folder(wellKnown: w, mailbox: mb)) ?? nil)?.id }
        guard !plan.steps.isEmpty else { return (0, plan.skipped) }
        let before = Dictionary(targets.map { ($0.message.id, $0.message) }, uniquingKeysWith: { a, _ in a })
        if plan.removesFromList {
            let gone = Set(plan.steps.map(\.messageId))
            if let sel = selectedMessageId, gone.contains(sel) {
                let v = visibleRows
                if let i = v.firstIndex(where: { $0.id == sel }) {
                    selectedMessageId = v[i...].first { !gone.contains($0.id) }?.id ?? v[..<i].last { !gone.contains($0.id) }?.id
                }
            }
            rows.removeAll { gone.contains($0.id) }
            searchResults?.removeAll { gone.contains($0.id) }
        }
        let inverses = plan.steps.compactMap { s in
            before[s.messageId].flatMap { TriageUndo.inverse(of: s.action, before: $0) }.map { BulkStep(messageId: s.messageId, action: $0) }
        }
        var label = BulkPlanner.describe(op, count: plan.steps.count, folderName: folderName)
        if plan.skipped > 0 { label += " (\(plan.skipped) skipped)" }
        pushUndo(UndoEntry(steps: inverses, text: label))
        toast(MailToast(text: label, symbol: "checkmark", action: .undoTriage))
        let steps = plan.steps
        Task {
            let r = await sync.apply(steps)
            if r.failed > 0 { toast(MailToast(text: "Couldn't apply \(r.failed) of \(steps.count) changes", symbol: "exclamationmark.triangle", isError: true)) }
        }
        return (plan.steps.count, plan.skipped)
    }

    // MARK: Toasts

    func toast(_ t: MailToast) {
        if t.action == .undoTriage { toasts.removeAll { $0.action == .undoTriage } }
        toasts.append(t)
        if toasts.count > 4 { toasts.removeFirst() }
        let id = t.id
        let life: Double = t.deadline.map { max(1, $0.timeIntervalSinceNow) + 1 } ?? (t.action == .undoTriage ? 8 : t.action == .voiceNudge ? 14 : 5)   // VOICE2-HOOK
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(life))
            toasts.removeAll { $0.id == id }
        }
    }

    func dismissToast(_ t: MailToast) { toasts.removeAll { $0.id == t.id } }

    // MARK: Search

    // SEARCHBOX-HOOK: main search box — natural ranked matching as you type (120 ms debounce, no query embedding),
    // operators strict, scope respected; ↩ re-runs with the embedding and merges server `$search` hits, which also
    // join while typing when local hits are few (after a longer pause). MailSearchBox.swift / SearchBoxViews.swift.
    private func scheduleSearch(submitted: Bool = false) {
        searchTask?.cancel()
        let raw = searchText
        let q = raw.trimmingCharacters(in: .whitespaces)
        let box = SearchBoxState.shared
        box.textChanged(raw, mail: self)
        guard !q.isEmpty else { searchResults = nil; searching = false; box.result = nil; KnowledgeHub.shared.answer = nil; return }   // PEOPLE-HOOK
        searching = true
        // SEARCH SCOPE (MailBulk.swift): this folder / this mailbox / all mailboxes; groups matched separately.
        let ui = MailListUI.shared
        let labels = search.labelNames
        let req = MailSearchBox.Request(text: raw, scope: ui.searchScope,
                                        mailbox: selectedMailbox, folderId: selectedFolderId.flatMap { VirtualFolder(id: $0) == nil ? $0 : nil },
                                        allMailboxes: mailboxes, typing: !submitted, labelName: { labels[$0.lowercased()] })
        searchTask = Task { @MainActor in
            if !submitted { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let sync, let store else { return }
            // PEOPLE-HOOK: Ask — a knowledge question on ↩ gets the cited answer card and the hand-off results.
            if submitted, let hits = await KnowledgeHub.shared.ask(raw, mail: self) {
                guard !Task.isCancelled else { return }
                var kr = MailBoxResult(); kr.ranked = hits; kr.newest = hits.sorted { ($0.received, $0.id) > ($1.received, $1.id) }; kr.total = hits.count
                showBoxResult(kr, select: true)
                searching = false
                ui.searchFinished(q, result: ScopedSearchResult(messages: hits, unattributed: 0), mail: self, remember: true)
                return
            }
            if !submitted { KnowledgeHub.shared.answer = nil }
            var r = await Task.detached(priority: .userInitiated) { MailSearchBox.local(req, store: store) }.value
            guard !Task.isCancelled else { return }
            showBoxResult(r, select: true)
            if MailSearchBox.shouldAskServer(typing: !submitted, localCount: r.ranked.count), MailSearchBox.serverText(req.query) != nil {
                if !submitted { try? await Task.sleep(for: .milliseconds(600)) }
                guard !Task.isCancelled else { return }
                let srv = await sync.boxServerHits(req, excluding: Set(r.ranked.map(\.id)))
                guard !Task.isCancelled else { return }
                r = MailSearchBox.merge(r, server: srv.hits, unattributed: srv.unattributed, limit: req.limit)
                showBoxResult(r, select: r.ranked.first?.id != selectedMessageId && searchResults?.isEmpty != false)
            }
            searching = false
            ui.searchFinished(q, result: ScopedSearchResult(messages: r.ranked, unattributed: r.unattributed), mail: self, remember: submitted)
        }
    }

    /// SEARCHBOX-HOOK: ↩ in the main box (after a highlighted suggestion and the Ask-mode hook).
    func submitSearch() { if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { scheduleSearch(submitted: true) } }

    private func showBoxResult(_ r: MailBoxResult, select: Bool) {
        let box = SearchBoxState.shared
        box.result = r
        searchResults = r.messages(box.sort)
        if select { selectedMessageId = searchResults?.first?.id }
    }

    /// SEARCHBOX-HOOK: Best match / Newest toggle — re-orders the same result, never re-queries.
    func applySearchOrder() {
        guard let r = SearchBoxState.shared.result, searchResults != nil else { return }
        searchResults = r.messages(SearchBoxState.shared.sort)
    }

    /// Re-run the current search (scope changed).
    func rerunSearch() { if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { scheduleSearch() } }

    // MARK: Composer

    private var defaultIdentity: SendIdentity? { settings.identities.first { $0.mode == .selfSend } ?? settings.identities.first }

    func compose() {
        // Writing from a shared/delegated mailbox defaults to that mailbox's identity.
        let mb = selectedMailbox
        let from = settings.identities.first { $0.mailbox == mb && mb != "me" } ?? defaultIdentity
        present(ComposerState(kind: .new, original: nil, from: from))
    }

    /// Re-open a saved draft in the composer. Autosave PATCHes the same server draft (COMPOSE2 DraftSession), the
    /// draft's label is restored (never dropped by re-opening) and its quoted history is carried verbatim. A draft
    /// that is already open is brought forward instead of being opened twice.
    func openDraft(id: String) {
        if let open = openComposers.first(where: { $0.savedDraftId == id }) { focus(open); return }
        guard let store, let sync, let d = try? store.message(id: id, includeBody: false), d.isDraft else { return }
        let mb = store.mailbox(forFolder: d.folderId)
        let from = ReplyIdentity.pick(identities: settings.identities, mailbox: mb, addressedTo: [d.from].compactMap { $0 }) ?? defaultIdentity
        let c = ComposerState(kind: .new, original: nil, from: from)
        c.reopened = true
        c.session = DraftSession(draftId: id, loading: true)   // no save until the body is in (it would PATCH it empty)
        c.to = d.toRecipients; c.cc = d.ccRecipients; c.subject = d.subject; c.importance = d.importance
        c.showCcBcc = !d.ccRecipients.isEmpty
        if let l = d.labelId { c.setLabel(l, engine: compliance) }
        PurviewPolicy.shared.adoptBaseline(c)   // PURVIEW-HOOK: the saved label is the baseline
        present(c)
        loadDraftExtras(c, id: id, mailbox: mb)   // COMPOSE-HOOK: server attachments as chips
        Task { @MainActor [weak c] in
            guard let c else { return }
            guard let full = try? await sync.fetchBody(id: id), let b = full.body else {
                c.error = "Couldn't load the saved draft — it stays unchanged on the server until it loads."
                return
            }
            c.editor.load(html: b, isHTML: full.bodyIsHTML)
            c.session.markLoaded(c.draft())   // reopening and closing untouched writes nothing
        }
    }

    func reply(_ kind: MailDraft.Kind, to messageId: String? = nil) {
        // THREAD-HOOK: in a conversation, keys / header act on the focused card, else the latest message.
        guard let store, let id = messageId ?? ConversationHub.shared.replyTarget(mail: self) ?? selectedMessageId, let o = try? store.message(id: id, includeBody: false) else { return }
        let mb = store.mailbox(forFolder: o.folderId)
        // Usage rights (REPLY / REPLYALL / FORWARD): one gate behind the reader, row menu and triage keys r / a / f.
        guard MailActionRights.allows(kind, policy: policy(for: o, mailbox: mb)) else {
            toast(MailToast(text: MailActionRights.deniedReason, symbol: "lock.fill"))
            return
        }
        // COMPOSE-HOOK: the mailbox's own identity (case-insensitive, send as before on behalf; ComposeAssist.swift).
        let from = ReplyIdentity.pick(identities: settings.identities, mailbox: mb, addressedTo: o.toRecipients + o.ccRecipients) ?? defaultIdentity
        let c = ComposerState(kind: kind, original: o, from: from)
        c.omitHistory = kind != .forward && composerPrefs.replyHistory == .omit   // COMPOSE2: a forward always carries the message
        let mine = Set(settings.identities.map { $0.address.lowercased() } + [me?.address.lowercased() ?? ""])
        switch kind {
        case .reply:
            c.to = [o.from ?? o.sender].compactMap { $0 }.filter { !mine.contains($0.address.lowercased()) }
            if c.to.isEmpty, let f = o.from { c.to = [f] }
        case .replyAll:
            c.to = ([o.from].compactMap { $0 } + o.toRecipients).filter { !mine.contains($0.address.lowercased()) }
            c.cc = o.ccRecipients.filter { !mine.contains($0.address.lowercased()) }
            c.showCcBcc = !c.cc.isEmpty
        case .forward, .new: break
        }
        let p = policy(for: o, mailbox: mb)
        let subj = p.redactDetails ? "" : o.subject
        let prefix = kind == .forward ? "Fw: " : "Re: "
        c.subject = subj.lowercased().hasPrefix(prefix.lowercased()) ? subj : prefix + subj
        present(c)
    }

    /// Every open draft: the pane/sheet/"composer" window one, then the extra windows (COMPOSE2).
    var openComposers: [ComposerState] { (composer.map { [$0] } ?? []) + windowComposers }

    /// A new composer takes the pane (or the "composer" window); the one already there is MOVED (same object, its
    /// autosave and session) into its own window, never copied or dropped. An untouched empty one is just closed.
    private func present(_ c: ComposerState) {
        if let old = composer, old !== c {
            if (old.isEmpty || !old.touched) && old.savedDraftId == nil { old.autosaveTask?.cancel() } else { moveToWindow(old) }
        }
        if composer !== c {   // AI-HOOK: fresh AI state per composer (AI follows the primary one)
            ai.composer.cancel(); ai.composer = AIComposerState()
        }
        prepareEditor(c)   // before onEdit: a default signature alone must not schedule an autosave
        c.onEdit = { [weak self, weak c] in
            guard let self, let c else { return }
            c.touched = true
            self.scheduleAutosave(c)
        }
        windowComposers.removeAll { $0 === c }
        composer = c
    }

    /// Extra composer windows (WindowGroup "composer-extra", keyed by ComposerState.id).
    func moveToWindow(_ c: ComposerState) {
        if composer === c { composer = nil }
        if !windowComposers.contains(where: { $0 === c }) { windowComposers.append(c) }
        windowRequests.append(c.id)
    }

    func windowComposer(_ id: UUID) -> ComposerState? { windowComposers.first { $0.id == id } }

    /// Bring an open draft forward (window: re-opening the same value focuses it).
    func focus(_ c: ComposerState) {
        if windowComposers.contains(where: { $0 === c }) { windowRequests.append(c.id) }
    }

    /// Removes a composer from wherever it is shown.
    private func detach(_ c: ComposerState) {
        c.autosaveTask?.cancel()
        if composer === c {   // COMPOSE-LAYOUT: a suggestion never outlives its composer (it would lock the next editor)
            ai.composer.preview = nil; ai.composer.pendingSignature = nil
            composer = nil; focusListToken += 1
        }
        windowComposers.removeAll { $0 === c }
    }

    /// Back on screen after a failed send / undo: the pane if free, else a window.
    private func restore(_ c: ComposerState) {
        if composer == nil { composer = c } else { moveToWindow(c) }
    }

    /// Debounced autosave, per composer (several drafts can be open). Each save PATCHes the same server draft.
    private func scheduleAutosave(_ c: ComposerState) {
        c.autosaveTask?.cancel()
        c.autosaveTask = Task { @MainActor [weak self, weak c] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let c else { return }
            await self?.saveDraft(c)
        }
    }

    @discardableResult
    func saveDraft(_ c: ComposerState) async -> Bool {
        // Saves are serialised in an unstructured task (ComposerEditorState.serialSave): cancelling the autosave
        // debounce must not abort an attachment upload, and close/send wait for it instead of racing it.
        await c.editor.serialSave { [weak self] in await self?.saveDraftNow(c) ?? false }
    }

    private func saveDraftNow(_ c: ComposerState) async -> Bool {
        guard let sync, !c.isEmpty else { return false }
        do {
            guard try await c.session.save(c.draft(), sync: sync) else { return false }
            c.savedAt = c.session.savedAt
            refreshHistory(c)   // COMPOSE2: the reply's quoted history, now known
            return true
        } catch {
            c.error = Self.composeError(error)
            return false
        }
    }

    /// Fresh reply/forward: the history the service carries (from createReply). Reopened drafts set it on load.
    func refreshHistory(_ c: ComposerState) {
        guard c.kind != .new, let id = c.savedDraftId, let h = sync?.draftHistory?.draftHistory(id: id) else { return }
        if c.editor.historyHTML != h { c.editor.historyHTML = h }
    }

    static func composeError(_ e: Error) -> String {
        if let me = e as? MailServiceError {
            if case .sendAsDenied(let a) = me { return "You can't send as \(a)." }
            if me == .offline { return "Offline — couldn't save the draft to the server." }
        }
        return "Couldn't save the draft."
    }

    /// Close: keep a draft if there's anything in it.
    func closeComposer(_ c: ComposerState) {
        guard c.hasUserContent else {   // nothing of the user's: no stray "Re:" drafts left behind
            let hadServerCopy = c.savedDraftId != nil
            discardComposer(c)
            FileHandle.standardError.write(Data("[Compose] closed empty → discarded serverCopy=\(hadServerCopy)\n".utf8))
            return
        }
        detach(c)
        Task { if await saveDraft(c), c.session.draftId != nil { toast(MailToast(text: L("Draft saved"), symbol: "doc")) } }
    }

    func discardComposer(_ c: ComposerState) {
        detach(c)
        guard let sync else { return }
        Task { await c.editor.waitForSave(); await c.session.discard(sync: sync) }
    }

    /// Send after the 10 s undo window, or later (`at`).
    func send(_ c: ComposerState, at: Date? = nil) {
        // COMPOSE-LAYOUT: a pending AI suggestion isn't in the body yet — every send path (⌘↩, Send ▾, ⋯, Schedule) waits.
        if composer === c, !ComposeLayout.sendEnabled(suggestionPending: ai.composer.preview != nil) {
            c.error = L("Keep or discard the AI suggestion first."); return
        }
        if composer === c, ai.interceptSend(c, at: at) { return }   // AI-HOOK: pre-send check (⌘↩ again sends); primary composer only
        c.commitTokenText()
        guard !c.allRecipients.isEmpty else { c.error = "Add at least one recipient."; return }
        // Re-check at send: the label policy may have synced (or tightened) since the composer opened.
        if let o = c.original,
           !MailActionRights.allows(c.kind, policy: policy(for: o, mailbox: store?.mailbox(forFolder: o.folderId) ?? "me")) {
            c.error = MailActionRights.deniedReason; return
        }
        if !c.editor.outgoing().isEmpty, let why = attachGateReason(c) { c.error = why; return }   // label may have changed since attaching
        if DriveHub.shared.isUploading(for: c) { c.error = "Wait for the OneDrive upload to finish."; return }   // ONEDRIVE-HOOK
        if c.session.loading { c.error = "Wait for the saved draft to finish loading."; return }
        if let b = PurviewPolicy.shared.sendBlock(c, tree: compliance.labelTree(), originalProtected: c.original.map { policy(for: $0, mailbox: store?.mailbox(forFolder: $0.folderId) ?? "me").bodyIsProtected } ?? false) { c.error = b.message; return }   // PURVIEW-HOOK: mandatory / encrypts / justification
        guard let sync else { return }
        detach(c)
        Task {
            await c.editor.waitForSave()   // an autosave mid-upload finishes first (its draft is reused)
            // ONEDRIVE-HOOK: "Specific people" links → grant the recipients before the mail goes out.
            if let why = await DriveHub.shared.grantRecipients(c) { c.error = why; restore(c); return }
            do {
                let (draftId, mb) = try await c.session.prepareSend(c.draft(), sync: sync)
                let token = await sync.queueSend(draftId: draftId, mailbox: mb, sendAt: at, undoSeconds: 10)
                pendingSendComposers[token] = c
                VoiceLearnModel.shared.sent(c, mail: self)   // VOICE2-HOOK: compare with the accepted AI draft, maybe nudge
                PurviewPolicy.shared.committed(c)   // PURVIEW-HOOK: Purview audit of the label (incl. justification)
            } catch {
                c.error = Self.composeError(error)
                restore(c)
            }
        }
    }

    func undoSend(_ token: UUID) async {
        guard let sync else { return }
        if await sync.undoSend(token) {
            toasts.removeAll { $0.action == .undoSend(token) }
            if let c = pendingSendComposers.removeValue(forKey: token) { restore(c); PurviewPolicy.shared.sendUndone(c) }   // PURVIEW-HOOK
            toast(MailToast(text: L("Send cancelled — back in the composer"), symbol: "arrow.uturn.backward"))
        }
    }

    // MARK: Recipients

    private func collectAddresses(_ msgs: [MailMessage]) {
        for m in msgs {
            for a in [m.from].compactMap({ $0 }) + m.toRecipients + m.ccRecipients where !a.address.isEmpty {
                let k = a.address.lowercased()
                if recentAddresses[k] == nil || (recentAddresses[k]?.name.isEmpty == true && !a.name.isEmpty) { recentAddresses[k] = a }
            }
        }
    }

    func suggestions(for text: String, excluding: [EmailAddress]) -> [EmailAddress] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let ex = Set(excluding.map { $0.address.lowercased() })
        let hits = recentAddresses.values.filter { a in
            !ex.contains(a.address.lowercased()) && (a.address.lowercased().contains(q) || a.name.lowercased().contains(q))
        }
        return Array(hits.sorted { $0.display < $1.display }.prefix(6))
    }

    func externalWarning(_ c: ComposerState) -> RecipientCheck.Warning {
        let pending = RecipientCheck.parse(c.toText + "," + c.ccText + "," + c.bccText).valid
        return RecipientCheck.warning(recipients: c.allRecipients + pending, internalDomains: settings.internalDomains,
                                      label: labelPolicy(labelId: c.labelId).label)
    }

    // MARK: Settings

    func refreshSettingsInfo() async {
        guard let sync, let store else { return }
        settings = await sync.settings
        var b: [String: BackfillInfo] = [:]
        for mb in mailboxes {
            let p = await sync.backfillProgress(mailbox: mb)
            b[mb] = BackfillInfo(oldest: p.oldestCached, done: p.done)
        }
        backfill = b
        bodyCacheUsed = (try? store.bodyCacheBytes()) ?? 0
    }

    func setWindow(_ w: CacheWindow, for mailbox: String) async {
        guard let sync, allows(w) else { return }
        try? await sync.setWindow(w, for: mailbox)
        await refreshSettingsInfo()
        reloadList()
    }

    func backfillNow(_ mailbox: String) async {
        guard let sync else { return }
        _ = await sync.backfill(mailbox: mailbox, maxPages: 10)
        await refreshSettingsInfo()
    }

    func update(_ change: (inout MailSettings) -> Void) async {
        guard let sync else { return }
        var s = settings
        change(&s)
        try? await sync.update(settings: s)
        await refreshSettingsInfo()
    }

    func setPinned(_ mailbox: String, _ on: Bool) async {
        guard let sync else { return }
        try? await sync.pin(mailbox: mailbox, on)
        if on { await openMailbox(mailbox) }
        await refreshSettingsInfo()
    }

    // MARK: Rules

    func loadRules() async {
        guard let sync else { return }
        rules = ((try? await sync.rules()) ?? []).sorted { $0.sequence < $1.sequence }
    }

    func editRule(_ r: MailRule?) {
        ruleError = nil; ruleWarnings = []
        ruleEditor = RuleEditorState(rule: r ?? MailRule(displayName: "New rule", sequence: (rules.map(\.sequence).max() ?? 0) + 1))
    }

    /// "Always move messages from X" (reader ⋯ menu): opens the editor prefilled; nothing is saved until confirmed.
    func suggestRule(for m: MailMessage, folder: MailFolder) {
        guard let r = MailRule.suggested(from: m, toFolderId: folder.id, folderName: folder.displayName) else { return }
        settingsTab = .rules
        showSettings = true
        Task { await loadRules(); editRule(r) }
    }

    @discardableResult
    func saveRule(_ r: MailRule, confirmPermanentDelete: Bool = false) async -> Bool {
        guard let sync else { return false }
        do {
            let (_, warnings) = try await sync.saveRule(r, confirmPermanentDelete: confirmPermanentDelete)
            ruleWarnings = warnings
            ruleError = nil
            await loadRules()
            return true
        } catch let e as RulePolicyError {
            switch e {
            case .externalForwardBlocked(let addrs):
                ruleError = "Blocked by policy: this rule would forward mail outside your organisation (\(addrs.joined(separator: ", "))). Automatic external forwarding is a data-exfiltration path."
            case .permanentDeleteNotConfirmed: ruleError = "Permanent delete needs confirmation."
            case .readOnly: ruleError = "This rule is read-only (created by another client or your admin)."
            }
        } catch { ruleError = "Couldn't save the rule." }
        return false
    }

    func toggleRule(_ r: MailRule) async {
        var r = r
        r.isEnabled.toggle()
        await saveRule(r)
    }

    func deleteRule(_ r: MailRule) async {
        guard let sync, let id = r.id else { return }
        try? await sync.deleteRule(id: id)
        await loadRules()
    }

    func moveRules(from: IndexSet, to: Int) async {
        guard let sync else { return }
        var list = rules
        list.move(fromOffsets: from, toOffset: to)
        rules = list
        if let saved = try? await sync.reorderRules(ids: list.compactMap(\.id)) { rules = saved }
        else { await loadRules() }
    }

    // MARK: Automatic replies

    func refreshAutoReplies() async {
        guard let sync else { return }
        if let r = try? await sync.refreshAutomaticReplies() {
            autoReplies = r
            autoRepliesDraft = r
        }
        oofActive = await sync.oofActive
        oofUntil = await sync.oofUntil
    }

    func saveAutoReplies() async {
        guard let sync else { return }
        var d = autoRepliesDraft
        if d.status == .scheduled {
            let start = d.start ?? .now
            let end = d.end ?? Calendar.current.date(byAdding: .day, value: 1, to: start)!
            guard end > start else { autoRepliesError = "The end must be after the start."; return }
            d.start = start; d.end = end
        }
        do {
            let saved = try await sync.setAutomaticReplies(d)
            autoReplies = saved; autoRepliesDraft = saved; autoRepliesError = nil
            oofActive = await sync.oofActive
            oofUntil = await sync.oofUntil
        } catch { autoRepliesError = "Couldn't save automatic replies." }
    }

    func turnOffAutoReplies() async {
        autoRepliesDraft.status = .disabled
        await saveAutoReplies()
    }

    // MARK: Palette

    struct PaletteItem: Identifiable {
        enum Kind { case command(MailCommand), folder(MailFolder), section(String) }
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var kind: Kind
    }

    var paletteItems: [PaletteItem] {
        var items = MailCommand.allCases.filter { $0 != .palette }.map {
            PaletteItem(id: "cmd:" + $0.rawValue, title: $0.title, subtitle: $0.hint, symbol: $0.symbol, kind: .command($0))
        }
        for mb in mailboxes {
            for f in folders[mb] ?? [] {
                items.append(PaletteItem(id: "f:" + f.id, title: "Go to \(f.displayName)", subtitle: MailboxDisplay.title(mb),
                                         symbol: MailboxDisplay.folderSymbol(f), kind: .folder(f)))
            }
        }
        items.append(PaletteItem(id: "s:calendar", title: "Go to Calendar", subtitle: "⌃⌘2", symbol: "calendar", kind: .section("calendar")))
        items += MailOrg2.shared.paletteItems(self)   // ORG2-HOOK: quick steps, trays, favourites
        // PEOPLE-HOOK: ⌘K "Ask: …" — local, deterministic knowledge answers (no AI needed), for questions only.
        let pq = paletteQuery.trimmingCharacters(in: .whitespaces)
        let askItem: [PaletteItem] = !pq.isEmpty && KnowledgeQuery.interpret(pq).isKnowledge
            ? [PaletteItem(id: "ask:knowledge", title: "Ask: \(pq)", subtitle: "people and matters on this Mac", symbol: "person.text.rectangle", kind: .section("ask:knowledge"))] : []
        // AI-HOOK: Ask / Search / Do entries for the typed text first, then the fixed AI commands.
        if ai.enabled {
            items += AIAssistModel.fixedPalette
            // AI entries go after command/folder matches, so ↩ on a typed command still runs that command.
            return askItem + FuzzyMatch.rank(items, query: paletteQuery) { "\($0.title) \($0.subtitle)" } + ai.paletteItems(query: paletteQuery)
        }
        return askItem + FuzzyMatch.rank(items, query: paletteQuery) { "\($0.title) \($0.subtitle)" }
    }

    /// Returns a section id to switch to, if the item asked for one.
    func runPalette(_ item: PaletteItem) -> String? {
        showPalette = false
        focusListToken += 1
        switch item.kind {
        case .command(let c): run(c); return nil
        case .folder(let f): selectedFolderId = f.id; return nil
        case .section(let s) where s.hasPrefix("ai-"): ai.runPalette(s, query: paletteQuery); return nil   // AI-HOOK
        case .section("ask:knowledge"): searchText = paletteQuery.trimmingCharacters(in: .whitespaces); submitSearch(); return nil   // PEOPLE-HOOK
        case .section(let s) where s.hasPrefix("org2:"): MailOrg2.shared.runPalette(s, mail: self); return nil   // ORG2-HOOK
        case .section(let s): return s
        }
    }
}
