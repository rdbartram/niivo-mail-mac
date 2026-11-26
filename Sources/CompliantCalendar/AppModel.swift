import SwiftUI
import CryptoKit
import CalendarCore
import ProtectedContent

@MainActor @Observable
final class AppModel {
    enum Mode { case loading, fixtures, live, needsSignIn, unconfigured }

    private(set) var mode: Mode = .loading
    private(set) var calendars: [CalendarInfo] = []
    var enabledCalendars: Set<String> = []
    private(set) var weekEvents: [CalendarEvent] = []
    private(set) var status: SyncEngine.Status = .idle(lastSync: nil)
    private(set) var pending = 0
    private(set) var conflictCount = 0
    var weekStart: Date = Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start

    /// Vertical position of the time grid (kept here: the @State macro isn't available under CLT).
    var gridScroll = ScrollPosition(edge: .top)

    // MARK: View mode
    enum ViewMode: String, CaseIterable, Identifiable {
        case grid, schedule, month, agenda
        var id: String { rawValue }
        var title: String {
            switch self { case .grid: "Calendar"; case .schedule: "Schedule"; case .month: "Month"; case .agenda: "Agenda" }
        }
        var symbol: String {
            switch self { case .grid: "calendar"; case .schedule: "chart.bar.doc.horizontal"; case .month: "calendar.badge.clock"; case .agenda: "list.bullet.rectangle" }
        }
        /// Month and agenda aren't time grids: the day-count tabs and overlap toggle don't apply.
        var isTimeGrid: Bool { self == .grid || self == .schedule }
    }
    /// Schedule is a single-day view; entering it remembers the grid's day count and restores it on exit.
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .grid {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
            guard oldValue != viewMode else { return }
            if viewMode == .schedule { gridDayCount = dayCount; dayCount = 1 }
            else if oldValue == .schedule { dayCount = gridDayCount }
            else { weekStart = Self.rangeStart(containing: anchor, days: dayCount); reload() }
        }
    }
    /// Agenda length in days.
    static let agendaDays = 14
    /// What's on screen (and therefore what `weekEvents` holds, so `screenPolicy` and selection cover it).
    var visibleRange: DateInterval {
        switch viewMode {
        case .month: return CalendarRanges.monthGridInterval(containing: anchor)
        case .agenda: return CalendarRanges.agendaInterval(from: anchor, days: Self.agendaDays)
        case .grid, .schedule:
            return DateInterval(start: weekStart, end: Calendar.current.date(byAdding: .day, value: dayCount, to: weekStart)!)
        }
    }
    /// The date the user is on (month view title, agenda start).
    var anchorDate: Date { anchor }
    private var gridDayCount: Int = UserDefaults.standard.integer(forKey: "gridDayCount").clamped(1, 7, default: 7) {
        didSet { UserDefaults.standard.set(gridDayCount, forKey: "gridDayCount") }
    }

    // MARK: Theme
    /// niivo is the default. A choice saved before niivo existed is moved to niivo once (`themeNiivoDefault`);
    /// any choice made after that is kept.
    var theme: Theme = AppModel.initialTheme() {
        didSet { if !ThemePreview.isRunning { UserDefaults.standard.set(theme.id, forKey: "theme") } }
    }
    private static func initialTheme() -> Theme {
        let d = UserDefaults.standard
        if ThemePreview.isRunning { return .niivo }
        if !d.bool(forKey: "themeNiivoDefault") {
            d.set(true, forKey: "themeNiivoDefault")
            d.set(Theme.niivo.id, forKey: "theme")
            return .niivo
        }
        return Theme.all.first { $0.id == d.string(forKey: "theme") } ?? .niivo
    }
    var skin: Skin { Skin(theme: theme) }

    // MARK: Layout
    enum GridLayout: String, CaseIterable, Identifiable {
        case overlay, split
        var id: String { rawValue }
        var title: String { self == .overlay ? "Overlay" : "Side by side" }
        var symbol: String { self == .overlay ? "square.stack" : "rectangle.split.3x1" }
    }
    /// Overlay = all calendars mixed per day. Side by side = one lane per visible calendar inside each day,
    /// so calendars never overlap each other and everything fits without horizontal scrolling.
    var layout: GridLayout = GridLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .overlay {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") }
    }
    enum Grouping: String, CaseIterable, Identifiable {
        case byDay, byCalendar
        var id: String { rawValue }
        var title: String { self == .byDay ? "Group by Day" : "Group by Calendar" }
        var symbol: String { self == .byDay ? "calendar.day.timeline.left" : "person.2" }
    }
    /// Only meaningful side by side: day → calendars (compare calendars on the same day) or
    /// calendar → days (read one person's week at a time).
    var grouping: Grouping = Grouping(rawValue: UserDefaults.standard.string(forKey: "grouping") ?? "") ?? .byDay {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "grouping") }
    }
    var overlap: Bool {
        get { layout == .overlay }
        set { layout = newValue ? .overlay : .split }
    }
    /// 1, 3, 5 (work week) or 7.
    var dayCount: Int = { let n = UserDefaults.standard.integer(forKey: "dayCount"); return [1, 3, 5, 7].contains(n) ? n : 7 }() {
        didSet {
            UserDefaults.standard.set(dayCount, forKey: "dayCount")
            if viewMode == .schedule && dayCount != 1 { gridDayCount = dayCount; viewMode = .grid; return }
            if !viewMode.isTimeGrid { gridDayCount = dayCount; viewMode = .grid; return }   // picking a day count leaves month/agenda
            weekStart = Self.rangeStart(containing: anchor, days: dayCount); reload()
        }
    }
    /// The date the user is "on"; the visible range is derived from it.
    private var anchor: Date = .now

    static func rangeStart(containing d: Date, days: Int) -> Date {
        let cal = Calendar.current
        if days >= 5 {
            let ws = cal.dateInterval(of: .weekOfYear, for: d)!.start
            // Work week starts Monday even in locales whose week starts on Sunday.
            if days == 5, cal.component(.weekday, from: ws) == 1 { return cal.date(byAdding: .day, value: 1, to: ws)! }
            return ws
        }
        return cal.startOfDay(for: d)
    }

    init() { weekStart = Self.rangeStart(containing: .now, days: dayCount) }

    var visibleDays: [Date] {
        (0..<dayCount).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }
    // MARK: Colours
    private(set) var tints: [String: Color] = [:]
    private var colorOverrides: [String: String] = UserDefaults.standard.dictionary(forKey: "calendarColors") as? [String: String] ?? [:]
    func tint(_ cal: CalendarInfo?) -> Color { cal.flatMap { tints[$0.id] } ?? .gray }
    func tint(for e: CalendarEvent) -> Color { tints[e.calendarId] ?? .gray }
    func setColor(_ hex: String?, for cal: CalendarInfo) {
        colorOverrides[cal.id] = hex
        UserDefaults.standard.set(colorOverrides, forKey: "calendarColors")
        tints = CalendarPalette.resolve(calendars, overrides: colorOverrides)
    }
    /// More than one owner on screen → show owner badges on every block.
    var showsOwnerBadges: Bool { Set(visibleCalendars.map(\.ownerAddress)).count > 1 }

    var visibleCalendars: [CalendarInfo] {
        let v = calendars.filter { enabledCalendars.contains($0.id) }
        // Assistant: the people I support lead; my own calendars come last.
        return persona == .assistant ? v.filter { $0.access != .own } + v.filter { $0.access == .own } : v
    }
    var selectedEventId: String?
    var lastError: String?
    private(set) var queryMillis: Double = 0

    /// Per-item licence rights (MIP decrypt, docs/MIP.md) win over the label's Graph rights once an item is decrypted.
    let compliance = CachedLabelPolicyEngine(itemRights: LicenceRightsStore.shared)

    // MARK: Protected content (MIP SDK decryption, off by default)
    /// Live only; created in `goLive`, reset on sign-out / lock / switch-off.
    private(set) var protectedContent: ProtectedContentCoordinator?
    /// The user's switch (Settings → Mail → Protected messages). Backed by `ProtectedContentDecryptEnabled`.
    var protectedDecryptEnabled = ProtectedContentCoordinator.isEnabled {
        didSet {
            guard oldValue != protectedDecryptEnabled else { return }
            UserDefaults.standard.set(protectedDecryptEnabled, forKey: ProtectedContentCoordinator.enabledKey)
            ProtectedContentCoordinator.log("decryption \(protectedDecryptEnabled ? "enabled" : "disabled") by the user")
            resetProtectedContent()
        }
    }
    /// Bumped on every reset: part of the readers' `.task` id, so a view still on screen (e.g. a message window across
    /// a lock) asks again instead of waiting on a state that was dropped.
    private(set) var protectedEpoch = 0

    /// Drops decrypted bodies + licence rights and puts the open readers back on label policy.
    func resetProtectedContent() {
        protectedContent?.reset()
        protectedEpoch += 1
        mail.refreshProtectedPolicies()
        MessageWindows.shared.refreshPolicies(mail: mail)
    }
    /// Loads the bridge (dlopen) — only asked for while the switch is on.
    var protectedBridgeStatus: String {
        switch ProtectedContentService.bridgeStatus() {
        case .success(let s): "Loaded (SDK \(s.sdkVersion))"
        case .failure(let e): "Not available in this build (\(e)) — protected mail stays Outlook-only"
        }
    }

    private func makeProtectedContent(auth: Auth, config: AppConfig) {
        guard protectedContent == nil, let clientId = config.clientId, !clientId.isEmpty else { return }
        let pc = ProtectedContentCoordinator(clientId: clientId,
                                             graphToken: { try await auth.mailToken() },
                                             mipToken: { scopes in try await auth.silentToken(scopes: scopes) },
                                             userEmail: { auth.username })
        pc.onRightsChanged = { [weak self] id in
            guard let self else { return }
            self.mail.refreshPolicy(itemId: id)
            MessageWindows.shared.refreshPolicy(itemId: id, mail: self.mail)
        }
        pc.grantAccess = { try await auth.grantProtectionAccess() }
        protectedContent = pc
        PurviewPolicy.shared.tree = { [weak self] in self?.compliance.labelTree() ?? LabelTree([]) }   // PURVIEW-HOOK
        LabelStampGuard.onRejected = { [weak self] _ in
            Task { @MainActor in self?.mail.toast(MailToast(text: "Label couldn't be written by niivo — sent with Exchange's own labelling", symbol: "tag.slash")) }
        }
        PurviewPolicy.shared.providerFactory = { [weak pc] in pc?.labelPolicyProvider() }
        PurviewPolicy.shared.load()
    }

    // MARK: Sections (Mail / Calendar) + trust
    enum AppSection: String, CaseIterable, Identifiable {
        case mail, calendar
        var id: String { rawValue }
        var title: String { self == .mail ? "Mail" : "Calendar" }
        var symbol: String { self == .mail ? "envelope" : "calendar" }
    }
    /// Defaults to Calendar so existing behaviour is unchanged until Mail is picked.
    var section: AppSection = AppModel.launchSection {
        didSet {
            UserDefaults.standard.set(section.rawValue, forKey: "section")
            if section == .mail { Task { await startMailIfNeeded() }; mail.focusListToken += 1 }
        }
    }
    let mail = MailModel()
    /// Posture "restricted" banner, hidden for this session once dismissed.
    var postureBannerDismissed = false
    let trust = TrustModel()
    let accounts = AccountsModel()   // ACCOUNTS-HOOK (AccountsModel.swift)
    /// Mail starts lazily (first switch to Mail), after the calendar sync loaded label definitions into `compliance`:
    /// MailStore applies the persist rule at write time, so labelled mail cached before labels are known stays stripped.
    /// Set after the first calendar sync returned (label definitions are in `compliance`).
    private var calendarReady = false
    /// `--section mail|calendar` wins over the saved choice (the preview bundle shares the defaults domain).
    static var launchSection: AppSection {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count, let s = AppSection(rawValue: args[i + 1]) { return s }
        return AppSection(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .calendar
    }

    func startMailIfNeeded() async {
        guard calendarReady, !mail.started else { return }
        let days = trust.policy.cacheWindowMaxDays
        switch mode {
        case .fixtures:
            mail.configureFixtureExtras()   // MAILBOXES-HOOK / GROUPS-HOOK (MailboxManager.swift)
            await mail.startFixtures(compliance: compliance, maxWindowDays: days)
        case .live:
            guard let auth else { return }
            let config = AppConfig.load()
            guard let keyring = trust.keyring, await trust.ensureKeys() else { return }
            let account = auth.accountKey
            guard !trust.wipeLayout.isTombstoned(account: account) else { return }   // TRUST-WIRING
            // Before startLive: it awaits the first full sync pass, and the sidebar needs these meanwhile.
            await mail.configureLiveExtras(auth: auth)   // MAILBOXES-HOOK / GROUPS-HOOK (MailboxManager.swift)
            await mail.startLive(compliance: compliance, token: { try await auth.mailToken() }, account: account,
                                 keys: { try keyring.mailKeys(account: account) },
                                 shared: auth.ownsConfiguredMailboxes ? config.sharedMailboxes ?? [] : [],   // ACCOUNTS-HOOK
                                 delegated: auth.ownsConfiguredMailboxes ? config.delegatedMailboxes ?? [] : [],
                                 maxWindowDays: days, tenant: auth.tenantId)
        default: break
        }
    }

    /// Fixtures only: the in-memory executor wipes the in-memory calendar + mail stores, never real directories.
    private var wipeExecutor: InMemoryWipeExecutor?
    func simulateRemoteWipe() {
        guard mode == .fixtures, let calStore = store else { return }
        var targets: [@Sendable () throws -> Void] = [{ try calStore.wipe() }]
        if let m = mail.wipeTarget() { targets.append(m) }
        let ex = InMemoryWipeExecutor(targets: targets)
        wipeExecutor = ex
        trust.simulateRemoteWipe(executor: ex)
        guard trust.isWiped else { return }
        mail.clearAfterWipe()
        sync = nil; store = nil; service = nil; calendarReady = false
        calendars = []; weekEvents = []; searchResults = []; selectedEventId = nil
        showEditor = false; removal = nil
    }

    /// Fixtures only: re-seed synthetic data after a simulated wipe.
    func resetWipeSimulation() async {
        guard mode == .fixtures, let ex = wipeExecutor else { return }
        trust.resetWipeSimulation(executor: ex)
        wipeExecutor = nil
        let svc = FixtureCalendarService()
        fixtures = svc
        open(service: svc, key: SymmetricKey(size: .bits256), url: nil)
        await syncNow()
        calendarReady = true
        if section == .mail || AppLifecycle.shared.startsMailInBackground { await startMailIfNeeded() }   // LIFECYCLE-HOOK
    }
    // TRUST-WIRING state (TrustWiring.swift).
    @ObservationIgnored var sessionClientId = ""
    @ObservationIgnored var lastEnforced: Date?
    @ObservationIgnored var lastInactiveProbe: Date?
    @ObservationIgnored var enforcementTickInFlight = false
    @ObservationIgnored var wipingAccounts: Set<String> = []

    /// Per-account wipe of the active account: close the live session like a lock, drop everything rendered.
    func tearDownSessionForWipe() {
        suspendForLock()
        resetProtectedContent(); protectedContent = nil
        mail.signOut()   // in-memory state; the store file itself is deleted by the executor
        sync = nil; store = nil; service = nil; calendarReady = false
        calendars = []; weekEvents = []; searchResults = []; selectedEventId = nil
        showEditor = false; removal = nil
        compliance.update(labels: [], synced: false)
        PurviewPolicy.shared.reset()
    }

    /// After the executor ran: the account is gone from MSAL, so the window shows the wiped notice, then sign-in.
    func finishWipedSession() {
        mode = .needsSignIn
    }

    private(set) var store: LocalStore?   // read by the invite card's conflict check (ReaderActions2.swift)
    private var sync: SyncEngine?
    private var fixtures: FixtureCalendarService?
    private(set) var auth: Auth?
    private var calendarById: [String: CalendarInfo] = [:]

    var simulateOffline = false {
        didSet { fixtures?.simulateOffline = simulateOffline; Task { await syncNow() } }
    }
    var isFixtureMode: Bool { mode == .fixtures }

    // MARK: Boot

    func start() async {
        guard !started else { return }   // called from App init (menu bar) and the window's .task
        started = true
        let config = AppConfig.load()
        // --theme-preview always runs on synthetic fixtures: it never signs in or reads a real mailbox.
        // Release builds never show sample data: no --fixtures, and a missing configuration lands on the sign-in
        // screen's "not configured" state instead of silently opening fixtures (BACKLOG §17).
        #if DEBUG
        let forceFixtures = CommandLine.arguments.contains("--fixtures") || ThemePreview.isRunning
        let useFixtures = forceFixtures || !config.isConfigured
        #else
        let forceFixtures = ThemePreview.isRunning
        let useFixtures = forceFixtures
        #endif
        // Live: the file-backed stores exist only while unlocked (their ciphers hold the cache keys).
        trust.onLocked = { [weak self] in self?.suspendForLock() }
        mail.ai.app = self   // AI-HOOK
        trust.onUnlocked = { [weak self] in await self?.resumeAfterUnlock() }
        trust.onEnforcementTick = { [weak self] in await self?.enforcementTick() }   // TRUST-WIRING
        // Unconfigured (release, no client ID): nothing to protect yet, so no vault and no Keychain either.
        trust.start(fixtures: useFixtures || !config.isConfigured)
        // DEV ONLY: a Graph token obtained outside the app (scripts/devtoken.py, device-code flow). Lets us test
        // against a real tenant before the bundle is signed with keychain entitlements. In-memory cache, no Keychain.
        if !forceFixtures, let path = ProcessInfo.processInfo.environment["CC_TOKEN_FILE"],
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let svc = GraphCalendarService(token: { token }, delegatedMailboxes: config.delegatedMailboxes ?? [])
            open(service: svc, key: SymmetricKey(size: .bits256), url: nil)
            mode = .live
            await syncNow()
            alerts.start(self)
            return
        }
        if !useFixtures, !config.isConfigured {
            mode = .unconfigured   // release build without a client ID: SignInView explains, never sample data
            return
        }
        if useFixtures {
            let svc = FixtureCalendarService()
            fixtures = svc
            // Fixtures: ephemeral key + in-memory store. Never touches the Keychain (ad-hoc re-signs would
            // re-prompt for Keychain access on every build) and never persists synthetic data.
            open(service: svc, key: SymmetricKey(size: .bits256), url: nil)
            mode = .fixtures
            AppModelBox.isFixture = true
        } else {
            do {
                let auth = try Auth(config: config)
                self.auth = auth
                // TRUST-WIRING: before any store opens. Interrupted wipes finish; the active account refreshes once
                // (bounded) so its grace clock is current; then its decision runs (lock / wipe / prompt).
                sessionClientId = config.clientId ?? ""
                wireSession(auth)
                if trust.keyring == nil { trust.keyring = CacheKeyring.system() }  // after Auth set KeychainCacheKey.accessGroup
                resumePendingWipes()
                guard let active = auth.account?.homeAccountId?.identifier else {
                    mode = .needsSignIn
                    Task { await self.probeInactiveAccounts() }
                    return
                }
                await probe(auth)
                enforce(account: active)
                guard auth.account != nil, !trust.isWiped else { return }   // wiped at launch: notice, then sign-in
                await goLive(auth: auth, config: config)
                Task { await self.probeInactiveAccounts() }
            } catch { lastError = "MSAL: \(error.localizedDescription)"; mode = .unconfigured }
        }
        await syncNow()
        // Fixture-only demo aid: open the inspector on a protected item.
        if mode == .fixtures, ProcessInfo.processInfo.environment["CC_DEMO_SELECT_PROTECTED"] == "1" {
            selectedEventId = weekEvents.first { policy(for: $0).bodyIsProtected }?.id
        }
        if mode == .fixtures, let q = ProcessInfo.processInfo.environment["CC_DEMO_SEARCH"] { searchText = q }
        alerts.start(self)
        if mode == .fixtures, ProcessInfo.processInfo.environment["CC_DEMO_ALERT"] == "1" { alerts.tick(force: true) }
        calendarReady = store != nil   // live + locked: set after unlock
        if section == .mail || AppLifecycle.shared.startsMailInBackground { await startMailIfNeeded() }   // LIFECYCLE-HOOK
    }

    /// Sign-in screen state (SignInViews.swift): busy while MSAL's sheet is up, and the classified failure.
    var signingIn = false
    var signInError: AccountAuthError?

    func signIn() async {
        guard let auth, !signingIn else { return }
        signingIn = true; signInError = nil; lastError = nil
        defer { signingIn = false }
        do {
            try await auth.signIn()
            // TRUST-WIRING: a wiped account comes back only once the server confirms it isn't revoked.
            sessionClientId = AppConfig.load().clientId ?? ""
            wireSession(auth)
            trust.dismissWipeNotice()
            guard await confirmAccessAfterSignIn(auth) else {
                lastError = "Your organisation couldn't confirm your access yet, so this account's data stays removed. Try again later."
                auth.signOut()
                return
            }
            await goLive(auth: auth, config: AppConfig.load())
            await syncNow()
            calendarReady = store != nil
            if section == .mail || AppLifecycle.shared.startsMailInBackground { await startMailIfNeeded() }   // LIFECYCLE-HOOK
        } catch {
            let ns = error as NSError
            if ns.domain == "MSALErrorDomain", ns.code == -50005 { return }   // MSALErrorUserCanceled: closed the sheet
            // TRUST-WIRING: an interactive failure for an account MSAL can name is authoritative (disabled / deleted /
            // unassigned on a tenant + client seen before → that account's data is wiped; 50173 only locks).
            recordInteractiveSignInFailure(error)
            let text = ([ns.localizedDescription] + ns.userInfo.values.compactMap { $0 as? String }).joined(separator: " ")
            signInError = AccountAuthError.classify(text, tenant: AppConfig.load().tenantId,
                                                    clientId: AppConfig.load().clientId ?? "")
            lastError = signInError?.message
        }
    }

    private func goLive(auth: Auth, config: AppConfig) async {
        // Home account id is "<oid>.<tid>": the tenant decides which msip_labels are ours.
        // ACCOUNTS-HOOK: one live session at a time, so the shim follows the active account; the services also carry
        // the tenant explicitly (docs/ACCOUNTS.md A9).
        MIPMetadata.homeTenantId = auth.tenantId
        if let id = auth.account?.homeAccountId?.identifier { Auth.activeAccountId = id }
        let svc = GraphCalendarService(token: { try await auth.token() },
                                       delegatedMailboxes: auth.ownsConfiguredMailboxes ? config.delegatedMailboxes ?? [] : [],
                                       scopedToken: { scope in try await auth.token(for: scope) },
                                       accountTenant: auth.tenantId)
        if trust.keyring == nil { trust.keyring = CacheKeyring.system() }  // after Auth set KeychainCacheKey.accessGroup
        service = svc
        mode = .live
        makeProtectedContent(auth: auth, config: config)
        await openLiveStore()
    }

    /// Live calendar store, keyed from the SE vault. Locked → stays closed; `resumeAfterUnlock` opens it.
    private var openingLive = false
    private func openLiveStore() async {
        guard mode == .live, store == nil, !openingLive, let auth, let service, let keyring = trust.keyring else { return }
        openingLive = true
        defer { openingLive = false }
        guard await trust.ensureKeys(), !trust.isLocked else { return }
        guard !trust.wipeLayout.isTombstoned(account: auth.accountKey) else { return }   // TRUST-WIRING: wiped, awaiting sign-in
        do {
            let (key, fresh) = try keyring.calendarKey(account: auth.accountKey)
            let url = AppConfig.supportDir.appending(path: "\(CacheKeyring.safeName(auth.accountKey)).sqlite")
            if fresh { CacheKeyring.discardStaleCache(at: url) }  // sealed with a lost key: unreadable, resync
            open(service: service, key: key, url: url)
            let layout = trust.wipeLayout
            accounts.load(keyring: keyring, auth: auth, isTombstoned: { layout.isTombstoned(account: $0) })   // ACCOUNTS-HOOK: registry needs the unlocked keyring
        } catch { lastError = "Cache key: \(error)" }
    }

    /// Lock (live): drop the stores, and with them the ciphers holding the keys, plus everything rendered from them.
    /// Fixtures keep their in-memory stores (ephemeral keys, synthetic data) so the demo continues after unlock; the
    /// lock screen hides the content.
    func suspendForLock() {
        AttachmentPreviewStore.shared.clear()   // PREVIEW-HOOK: preview bytes + scratch files, fixtures too
        guard mode == .live else { return }
        resetProtectedContent()   // decrypted bodies + licence rights don't survive a lock
        sync = nil; store = nil; calendarReady = false
        calendars = []; weekEvents = []; searchResults = []; selectedEventId = nil
        showEditor = false; removal = nil
        mail.suspendForLock()
    }

    func resumeAfterUnlock() async {
        // TRUST-WIRING: grace may have run out while locked; a lock / wipe decided here keeps the stores closed.
        if mode == .live, let a = auth?.account?.homeAccountId?.identifier { enforce(account: a) }
        guard mode == .live, store == nil, !trust.hidesContent else { return }
        await openLiveStore()
        guard store != nil else { return }
        // Usable straight away from the encrypted cache: `open` already painted it. Sync and mail start in the
        // background instead of gating the UI on a full network round-trip of every calendar.
        calendarReady = true
        if section == .mail || AppLifecycle.shared.startsMailInBackground { Task { await self.startMailIfNeeded() } }   // LIFECYCLE-HOOK
        Task { await self.syncNow() }
    }

    private func open(service: CalendarService, key: SymmetricKey, url: URL?) {
        do {
            let store = try LocalStore(url: url, cipher: AESGCMCipher(key: key))
            self.store = store
            self.service = service
            service.setSources(store.calendarSources())   // before the first sync: added + group calendars
            if teammates.isEmpty, service is FixtureCalendarService { teammates = FixtureCalendarService.teammates }
            sync = SyncEngine(service: service, store: store, compliance: compliance) { [weak self] s in
                Task { @MainActor in
                    self?.status = s; self?.reload()
                    // A created event got its real id from Exchange: keep it selected.
                    if let id = self?.selectedEventId, id.hasPrefix("local-"), let new = await self?.sync?.remappedIds[id] {
                        self?.selectedEventId = new
                    }
                }
            }
            reload() // paint from cache immediately — offline launch is the same code path
        } catch { lastError = "Cache: \(error)" }
    }

    func signOut() async {
        guard let auth else { return }
        let key = auth.accountKey
        try? await sync?.wipe()
        resetProtectedContent(); protectedContent = nil
        mail.signOut()
        // Crypto-shred: the wrapped keys go (and any legacy plain keys), so a lingering file stays unreadable.
        trust.keyring?.remove(account: key)
        sync = nil; store = nil
        auth.signOut()
        calendars = []; weekEvents = []; mode = .needsSignIn
        accounts.forget(key)   // ACCOUNTS-HOOK
    }

    /// ACCOUNTS-HOOK: switch the live session to another signed-in account. The current session is closed as on a
    /// lock (stores, ciphers, decrypted content dropped; nothing wiped), then the other account opens its own stores,
    /// keys, label engine and tenant. Nothing carries over between the two.
    func switchAccount(to id: String) async {
        guard mode == .live || mode == .needsSignIn, let config = Optional(AppConfig.load()), config.isConfigured else { return }
        suspendForLock()
        resetProtectedContent(); protectedContent = nil
        service = nil
        // The label tree is the previous tenant's: empty + unsynced (fail closed) until this account's own tree loads
        // from its store or syncs. Never evaluate one tenant's labels against another's tree.
        compliance.update(labels: [], synced: false)
        PurviewPolicy.shared.reset()   // previous tenant's label policy settings
        Auth.activeAccountId = id
        do {
            let next = try Auth(config: config, accountId: id)
            guard next.account != nil else { mode = .needsSignIn; auth = next; return }
            auth = next
            sessionClientId = config.clientId ?? ""   // TRUST-WIRING
            wireSession(next)
            trust.sessionLock = nil   // the previous account's lock doesn't follow the switch
            await probe(next)
            enforce(account: id)
            guard next.account != nil, !trust.isWiped else { return }
            await goLive(auth: next, config: config)
            await syncNow()
            calendarReady = store != nil
            if section == .mail || AppLifecycle.shared.startsMailInBackground { await startMailIfNeeded() }
        } catch { lastError = "MSAL: \(error.localizedDescription)" }
    }

    // MARK: Data

    var labelSyncIssue: String?

    func syncNow() async {
        await sync?.syncNow()
        pending = (try? await sync?.pendingCount()) ?? 0
        conflictCount = await sync?.conflicts.count ?? 0
        labelSyncIssue = await sync?.labelSyncIssue
        reload()
    }

    func reload() {
        guard let store else { return }
        let cals = (try? store.calendars()) ?? []
        if cals.map(\.id) != calendars.map(\.id) {
            let newIds = Set(cals.map(\.id)).subtracting(calendars.map(\.id))
            enabledCalendars.formUnion(newIds)
        }
        calendars = cals
        tints = CalendarPalette.resolve(cals, overrides: colorOverrides)
        calendarById = Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0) })
        let t = Date()
        let range = visibleRange
        weekEvents = (try? store.events(from: range.start, to: range.end, calendarIds: enabledCalendars)) ?? []
        queryMillis = Date().timeIntervalSince(t) * 1000
        refreshFreeBusy()
    }

    func calendar(for e: CalendarEvent) -> CalendarInfo? { calendarById[e.calendarId] }

    func policy(for e: CalendarEvent) -> ContentPolicy {
        compliance.policy(for: e, context: .init(calendarAccess: calendar(for: e)?.access ?? .shared))
    }

    var selectedEvent: CalendarEvent? {
        weekEvents.first { $0.id == selectedEventId } ?? searchResults.first { $0.id == selectedEventId }
    }

    private var started = false

    // MARK: Persona
    /// Two ways people use this app. "My calendar": my own time plus a glance at teammates' availability.
    /// "Assistant": the people I look after are the primary objects; my own calendar is secondary.
    enum Persona: String, CaseIterable, Identifiable {
        case personal, assistant
        var id: String { rawValue }
        var title: String { self == .personal ? "My Calendar" : "Assistant" }
        var symbol: String { self == .personal ? "person.crop.circle" : "person.2.crop.square.stack" }
    }
    var persona: Persona = Persona(rawValue: UserDefaults.standard.string(forKey: "persona") ?? "") ?? .personal {
        didSet {
            UserDefaults.standard.set(persona.rawValue, forKey: "persona")
            guard oldValue != persona else { return }
            // Switching mode applies sensible defaults; the user can still change any of them afterwards.
            switch persona {
            case .personal:
                enabledCalendars = Set(calendars.filter { $0.access == .own }.map(\.id))
                layout = .overlay
            case .assistant:
                enabledCalendars = Set(calendars.map(\.id))
                layout = .split; grouping = .byDay
            }
            reload()
        }
    }
    /// Calendars of the people I support (delegate or shared), in sidebar order.
    var principals: [CalendarInfo] { calendars.filter { $0.access != .own } }

    // MARK: Teammates (free/busy only)
    var teammates: [Teammate] = (UserDefaults.standard.data(forKey: "teammates")).flatMap { try? JSONDecoder().decode([Teammate].self, from: $0) } ?? [] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(teammates), forKey: "teammates")
            freeBusyKey = ""; refreshFreeBusy()
        }
    }
    var teammateDraft = ""
    private(set) var freeBusy: [String: [FreeBusySlot]] = [:]
    private var freeBusyKey = ""
    private var freeBusyAt = Date.distantPast
    private var service: (any CalendarService)?
    var showsTeammates: Bool { persona == .personal && !teammates.isEmpty }

    func addTeammate(_ text: String) {
        // Accepts "Name <addr>" or a bare address.
        let t = text.trimmingCharacters(in: .whitespaces)
        var name = t, addr = t
        if let lt = t.firstIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
            addr = String(t[t.index(after: lt)..<gt]); name = String(t[..<lt]).trimmingCharacters(in: .whitespaces)
        }
        guard addr.contains("@"), !teammates.contains(where: { $0.id == addr.lowercased() }) else { return }
        if name == addr { name = addr.split(separator: "@").first.map { $0.split(separator: ".").map(\.capitalized).joined(separator: " ") } ?? addr }
        teammates.append(Teammate(name: name, address: addr))
    }
    func removeTeammate(_ t: Teammate) { teammates.removeAll { $0.id == t.id } }

    /// Fetch free/busy for the visible range. Not cached on disk; refetched when the range changes or after 5 min.
    func refreshFreeBusy() {
        guard showsTeammates, let service else { return }
        let end = Calendar.current.date(byAdding: .day, value: dayCount, to: weekStart)!
        let key = "\(weekStart.timeIntervalSince1970)-\(dayCount)"
        guard key != freeBusyKey || Date().timeIntervalSince(freeBusyAt) > 300 else { return }
        freeBusyKey = key; freeBusyAt = Date()
        let addrs = teammates.map(\.address)
        Task {
            if let r = try? await service.freeBusy(for: addrs, window: DateInterval(start: weekStart, end: end)) { freeBusy = r }
        }
    }
    func slots(for t: Teammate) -> [FreeBusySlot] { freeBusy[t.id] ?? [] }

    /// "Busy until 11:00", "Free until 14:00", "Out of office" — for the sidebar glance.
    func availabilityNow(_ t: Teammate, now: Date = .now) -> (text: String, busy: Bool)? {
        guard let s = freeBusy[t.id] else { return nil }
        let today = s.filter { Calendar.current.isDate($0.start, inSameDayAs: now) || ($0.start <= now && $0.end > now) }
            .filter { $0.status != .free }.sorted { $0.start < $1.start }
        if let cur = today.first(where: { $0.start <= now && $0.end > now }) {
            if cur.status == .oof { return ("Out of office", true) }
            var end = cur.end
            for n in today where n.start <= end && n.end > end { end = n.end }
            return ("\(cur.status == .tentative ? "Tentative" : "Busy") until \(end.formatted(date: .omitted, time: .shortened))", true)
        }
        if let next = today.first(where: { $0.start > now }) { return ("Free until \(next.start.formatted(date: .omitted, time: .shortened))", false) }
        return ("Free for the rest of today", false)
    }

    /// Next meeting today on a principal's calendar, for the assistant sidebar. Policy-redacted.
    func nextUp(_ c: CalendarInfo, now: Date = .now) -> (title: String, start: Date)? {
        guard let store else { return nil }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        let e = ((try? store.events(from: now, to: end, calendarIds: [c.id])) ?? [])
            .filter { !$0.isAllDay && !$0.isCancelled && $0.end > now }.min { $0.start < $1.start }
        return e.map { (policy(for: $0).redactDetails ? "Private appointment" : $0.subject, $0.start) }
    }
    func meetingsToday(_ c: CalendarInfo, now: Date = .now) -> Int {
        guard let store else { return 0 }
        let d = Calendar.current.startOfDay(for: now)
        return ((try? store.events(from: d, to: Calendar.current.date(byAdding: .day, value: 1, to: d)!, calendarIds: [c.id])) ?? [])
            .filter { !$0.isAllDay && !$0.isCancelled }.count
    }

    // MARK: Alerts
    let alerts = AlertCenter()
    /// Own and delegated calendars alert by default (an assistant needs the boss's reminders); shared view-only
    /// calendars don't. Per-calendar override persisted.
    private var alertOverrides: [String: Bool] = UserDefaults.standard.dictionary(forKey: "alertCalendars") as? [String: Bool] ?? [:]
    func alertsOn(_ c: CalendarInfo) -> Bool { alertOverrides[c.id] ?? (c.access != .shared) }
    func setAlerts(_ on: Bool, for c: CalendarInfo) {
        alertOverrides[c.id] = on
        UserDefaults.standard.set(alertOverrides, forKey: "alertCalendars")
    }
    /// AI-HOOK: calendar service for the in-app agent's read-only calendar tools (OfficeTools).
    var aiCalendarService: (any CalendarService)? { service }
    /// AI-HOOK: busy blocks on the user's own calendars (Propose a time). Times only; nothing leaves the Mac.
    func aiOwnBusyEvents(from: Date, to: Date) -> [CalendarEvent] {
        guard let store else { return [] }
        let ids = Set(calendars.filter { $0.access == .own }.map(\.id))
        return (try? store.events(from: from, to: to, calendarIds: ids)) ?? []
    }

    func alertCandidates(from: Date, to: Date) -> [CalendarEvent] {
        guard let store else { return [] }
        let ids = Set(calendars.filter(alertsOn).map(\.id))
        return ((try? store.events(from: from, to: to, calendarIds: ids)) ?? [])
            .filter { !$0.isAllDay && !$0.isCancelled && $0.showAs != .free && $0.start >= from && $0.start <= to }
            .sorted { $0.start < $1.start }
    }

    /// Menu-bar label: time/countdown only — it is visible over every app and in screen shares, so never a subject.
    private(set) var menuBarTitle = ""
    private(set) var menuBarSymbol = "calendar"
    func refreshMenuBar(now: Date = .now) {
        guard let e = upcomingToday(now: now).first else { menuBarTitle = ""; menuBarSymbol = "calendar"; return }
        let m = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        menuBarTitle = m <= 0 ? "Now" : (m < 60 ? "in \(m) min" : e.start.formatted(date: .omitted, time: .shortened))
        menuBarSymbol = e.onlineMeetingURL != nil ? "video.fill" : "calendar"
    }

    /// Rest of today (incl. in-progress) on alerting calendars — own + people I support by default.
    func upcomingToday(now: Date = .now) -> [CalendarEvent] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return alertCandidates(from: Calendar.current.startOfDay(for: now), to: end).filter { $0.end > now }
    }

    // MARK: Calendar extras (CALENDAR-HOOK: CalendarExtras.swift)
    /// Store / engine / service for the extras model (added calendars, responses, rooms, categories, ICS import).
    var extrasStore: LocalStore? { store }
    var extrasSync: SyncEngine? { sync }
    func refreshAfterExtras() async { await afterWrite() }
    /// Open a day in the day grid (month view double-click).
    func openDay(_ d: Date) {
        anchor = d
        if viewMode != .grid { gridDayCount = 1; viewMode = .grid }
        dayCount = 1
        weekStart = Self.rangeStart(containing: anchor, days: dayCount)
        reload()
    }

    // MARK: Search
    var searchText = "" { didSet { runSearch() } }
    private(set) var searchResults: [CalendarEvent] = []
    /// Bumped by ⌘F; the root view moves keyboard focus into the toolbar search field.
    var focusSearchToken = 0
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func runSearch() {
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty, let store else { searchResults = []; return }
        let w = SyncEngine.syncWindow()
        let all = (try? store.events(from: w.start, to: w.end, calendarIds: enabledCalendars)) ?? []
        searchResults = all.filter { e in
            let p = policy(for: e)
            guard !p.redactDetails else { return false }   // private/unknown-label items: not findable by content
            let hay = ([e.subject, e.location, e.organizer,
                        e.onlineMeetingURL.map { MeetingProvider(url: $0).displayName }]
                       + e.attendees.map(\.name)).compactMap { $0 }.joined(separator: " ").lowercased()
            if terms.allSatisfy(hay.contains) { return true }
            // Whole query names a calendar/owner ("sam rivera") → that calendar's meetings.
            let cal = calendar(for: e)
            let who = [cal?.ownerDisplay, cal?.name].compactMap { $0?.lowercased() }
            return who.contains { $0 == searchText.lowercased().trimmingCharacters(in: .whitespaces) }
        }
        .prefix(500).map { $0 }
    }

    /// Jump the grid to an event and select it (from search, alerts…).
    func reveal(_ e: CalendarEvent) {
        anchor = e.start
        weekStart = Self.rangeStart(containing: anchor, days: dayCount)
        searchText = ""
        reload()
        selectedEventId = e.id
    }

    /// Strictest policy across everything on screen — drives window-level controls (screen capture).
    var screenPolicy: ContentPolicy {
        // Everything that can be on screen: the visible range AND search results (which span months).
        // …and the alert banner, which can show an event that isn't in the visible range.
        (weekEvents + searchResults).reduce(alerts.banner?.policy ?? .open) { $0.merged(with: policy(for: $1)) }
    }

    // MARK: Writes

    /// I own this item's content: organiser of a meeting, or an appointment with no attendees.
    func isOrganizer(_ e: CalendarEvent) -> Bool {
        if let o = e.isOrganizer { return o }
        guard let cal = calendar(for: e) else { return false }
        return e.attendees.isEmpty || e.organizer == nil || e.organizer == cal.ownerName
    }
    /// May change time/details: write access to the calendar, not hidden as private, and it's ours to change
    /// (an attendee's copy of someone else's meeting can only be declined).
    func canEdit(_ e: CalendarEvent) -> Bool {
        (calendar(for: e)?.canEdit ?? false) && !policy(for: e).redactDetails && isOrganizer(e)
    }
    func canRemove(_ e: CalendarEvent) -> Bool { (calendar(for: e)?.canEdit ?? false) && !policy(for: e).redactDetails }
    func removeMode(for e: CalendarEvent) -> RemoveMode {
        e.attendees.isEmpty ? .delete : (isOrganizer(e) ? .cancel : .decline)
    }
    var writableCalendars: [CalendarInfo] { calendars.filter(\.canEdit) }
    /// Where a new event goes when the click didn't say (overlay column): Assistant → first visible principal
    /// I can edit; otherwise my default calendar.
    var defaultWriteCalendar: CalendarInfo? {
        if persona == .assistant, let p = visibleCalendars.first(where: { $0.access != .own && $0.canEdit }) { return p }
        return visibleCalendars.first { $0.access == .own && $0.canEdit } ?? writableCalendars.first
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case SyncEngine.SeriesError.offline, ServiceError.offline: "offline"
        case ServiceError.conflict: "it was changed by someone else"
        case ServiceError.unauthorized: "sign-in expired"
        case ServiceError.http(let c, _): "HTTP \(c)"
        default: "error"
        }
    }

    /// Write trace for debugging: kinds, ids and times only — never subjects (same rule as the probes).
    func wlog(_ s: String) { FileHandle.standardError.write(Data("[Write] \(s)\n".utf8)) }

    private func afterWrite() async {
        pending = (try? await sync?.pendingCount()) ?? 0
        wlog("queue=\(pending)")
        reload()
    }

    func move(_ e: CalendarEvent, byMinutes m: Int) { move(e, dayOffset: 0, byMinutes: m, to: nil) }

    /// Drag result: shift by whole days and minutes, optionally onto another calendar (lane).
    func move(_ e: CalendarEvent, dayOffset: Int, byMinutes m: Int, to target: CalendarInfo?) {
        guard canEdit(e) else { return }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: dayOffset, to: e.start)!.addingTimeInterval(Double(m * 60))
        let end = start.addingTimeInterval(e.end.timeIntervalSince(e.start))
        if let target, target.id != e.calendarId {
            calendarMove = CalendarMove(event: e, target: target, start: start, end: end)
            wlog("calendar-move asked \(e.id) → \(target.id) blocked=\(calendarMove!.blocked)")
            return
        }
        guard start != e.start else { return }
        wlog("move \(e.id) → \(start.formatted(.iso8601))")
        Task { try? await sync?.move(eventId: e.id, to: start, end: end); await afterWrite() }
    }

    func resize(_ e: CalendarEvent, byMinutes m: Int) {
        guard m != 0, canEdit(e) else { return }
        let end = max(e.end.addingTimeInterval(Double(m * 60)), e.start.addingTimeInterval(15 * 60))
        wlog("resize \(e.id) end → \(end.formatted(.iso8601))")
        Task { try? await sync?.move(eventId: e.id, to: e.start, end: end); await afterWrite() }
    }

    /// Moving between calendars = create in the target + delete the original (Exchange has no cross-mailbox
    /// move). Only for items without attendees: a meeting would send a cancellation and a new invite.
    struct CalendarMove: Identifiable {
        var id: String { event.id }; var event: CalendarEvent; var target: CalendarInfo; var start: Date; var end: Date
        /// Meetings can't hop mailboxes without re-inviting everyone.
        var blocked: Bool { !event.attendees.isEmpty }
    }
    var calendarMove: CalendarMove?
    func confirmCalendarMove() {
        guard let m = calendarMove else { return }
        calendarMove = nil
        guard !m.blocked else { return }
        var d = EventDraft(m.event); d.calendarId = m.target.id; d.start = m.start; d.end = m.end
        d.notes = m.event.bodyPreview ?? ""
        Task {
            if let id = try? await sync?.create(d) {
                try? await sync?.remove(eventId: m.event.id, mode: .delete)
                selectedEventId = id
            }
            await afterWrite()
        }
    }

    /// Drag-to-create preview (lane index in the current grid, minutes from midnight).
    struct CreateGhost: Equatable { var column: Int; var startMinute: Int; var endMinute: Int }
    var createGhost: CreateGhost?
    /// Lane index for a grid column — set by WeekView each layout so CreateLane can report its ghost.
    var gridColumns: [GridColumn] = []
    func gridColumnIndex(_ c: GridColumn) -> Int { gridColumns.firstIndex(of: c) ?? 0 }

    enum SeriesScope: String { case occurrence, series }
    var editorScope: SeriesScope = .occurrence
    var removalScope: SeriesScope = .occurrence
    /// Shown as an alert: something a write couldn't do (series offline, series to another day…). Never a subject.
    var writeError: String?

    /// Attendee availability for the editor's day (free/busy only; held in memory, never stored).
    var editorFreeBusy: [String: [FreeBusySlot]] = [:]
    private var editorFreeBusyKey = ""
    func refreshEditorFreeBusy() {
        guard showEditor, let service else { return }
        let addrs = editorDraft.attendees.map(\.address)
        let day = Calendar.current.startOfDay(for: editorDraft.start)
        let key = "\(day.timeIntervalSince1970)|\(addrs.joined(separator: ","))"
        guard !addrs.isEmpty, key != editorFreeBusyKey else { if addrs.isEmpty { editorFreeBusy = [:] }; return }
        editorFreeBusyKey = key
        let window = DateInterval(start: day, duration: 86400)
        Task {
            let fb = (try? await service.freeBusy(for: addrs, window: window)) ?? [:]
            if editorFreeBusyKey == key { editorFreeBusy = fb }
        }
    }
    /// Who's busy at the drafted time (by address).
    var editorConflicts: Set<String> {
        let s = editorDraft.start, e = editorDraft.end
        return Set(editorFreeBusy.compactMap { addr, slots in
            slots.contains { $0.status != .free && $0.start < e && $0.end > s } ? addr : nil
        })
    }

    // Editor
    var editorDraft = EventDraft(calendarId: "", start: .now, end: .now)
    var editorOriginal: CalendarEvent?
    var showEditor = false
    var attendeeDraft = ""

    func newEvent(start: Date? = nil, end: Date? = nil, calendar: CalendarInfo? = nil, allDay: Bool = false) {
        let cal = Calendar.current
        let s = start ?? {
            let now = Date(), m = cal.component(.minute, from: now)
            return cal.date(byAdding: .minute, value: (m < 30 ? 30 : 60) - m, to: now).map { cal.date(bySetting: .second, value: 0, of: $0)! }!
        }()
        guard let target = calendar.flatMap({ $0.canEdit ? $0 : nil }) ?? defaultWriteCalendar else { return }
        editorDraft = EventDraft(calendarId: target.id, start: s, end: end ?? s.addingTimeInterval(1800), isAllDay: allDay)
        editorDraft.labelId = PurviewPolicy.shared.defaultMeetingLabelId   // PURVIEW-HOOK
        wlog("editor new in \(target.id) \(s.formatted(.iso8601))–\(editorDraft.end.formatted(.iso8601))")
        editorOriginal = nil
        attendeeDraft = ""
        editorScope = .occurrence
        editorFreeBusy = [:]; editorFreeBusyKey = ""
        showEditor = true
    }

    func editSelected() { if let e = selectedEvent, canEdit(e) { edit(e) } }
    func edit(_ e: CalendarEvent) {
        editorDraft = EventDraft(e); editorOriginal = e; attendeeDraft = ""; editorScope = .occurrence
        editorFreeBusy = [:]; editorFreeBusyKey = ""; showEditor = true
        refreshEditorFreeBusy()
    }

    /// What Save will do, so the button can say it ("Send", "Send Update", "Save").
    var editorSendsMail: Bool {
        guard !editorDraft.attendees.isEmpty else { return false }
        guard let o = editorOriginal else { return true }
        let before = EventDraft(o)
        return before.start != editorDraft.start || before.end != editorDraft.end || before.subject != editorDraft.subject
            || before.location != editorDraft.location || before.attendees != editorDraft.attendees || before.isAllDay != editorDraft.isAllDay
    }

    func saveEditor() {
        var d = editorDraft
        if d.isAllDay {
            let c = Calendar.current
            d.start = c.startOfDay(for: d.start)
            d.end = max(c.startOfDay(for: d.end), c.date(byAdding: .day, value: 1, to: d.start)!)
            if c.isDate(d.end, inSameDayAs: d.start) { d.end = c.date(byAdding: .day, value: 1, to: d.start)! }
        }
        if d.end <= d.start { d.end = d.start.addingTimeInterval(1800) }
        if editorOriginal == nil {   // PURVIEW-HOOK: new meeting label gate + msip_labels stamp
            if let b = PurviewPolicy.shared.meetingBlock(labelId: d.labelId, tree: compliance.labelTree()) { writeError = b.message; return }
            d.labelHeader = d.labelId.flatMap { PurviewPolicy.header(labelId: $0, privileged: true, setAt: Date(),
                                                                     settings: PurviewPolicy.shared.settings) }
            if PurviewPolicy.stampDisabled { d.labelHeader = nil }
        }
        let original = editorOriginal, scope = editorScope
        showEditor = false
        Task {
            if let o = original, scope == .series, o.seriesMasterId != nil {
                do { try await sync?.editSeries(occurrenceId: o.id, to: d); wlog("edit series of \(o.id)") }
                catch SyncEngine.SeriesError.changesDay { writeError = "A whole series can’t move to another day here — that changes its repeat pattern. Use Outlook, or edit just this occurrence." }
                catch SyncEngine.SeriesError.offline, ServiceError.offline { writeError = "Editing every occurrence needs a connection. Nothing was changed." }
                catch { writeError = "The series couldn’t be updated (\(Self.describe(error)))." }
            } else if let o = original { try? await sync?.edit(eventId: o.id, to: d); wlog("edit \(o.id)") }
            else if let id = try? await sync?.create(d) {
                wlog("create \(id) in \(d.calendarId) attendees=\(d.attendees.count)"); selectedEventId = id; anchor = d.start; weekStart = Self.rangeStart(containing: anchor, days: dayCount) }
            await afterWrite()
        }
    }

    func addAttendee() {
        let t = attendeeDraft.trimmingCharacters(in: .whitespaces)
        var name = t, addr = t
        if let lt = t.firstIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
            addr = String(t[t.index(after: lt)..<gt]); name = String(t[..<lt]).trimmingCharacters(in: .whitespaces)
        }
        guard addr.contains("@"), !editorDraft.attendees.contains(where: { $0.address.lowercased() == addr.lowercased() }) else { return }
        editorDraft.attendees.append(Attendee(name: name == addr ? "" : name, address: addr, response: "none"))
        attendeeDraft = ""
        refreshEditorFreeBusy()
    }

    // Delete / cancel / decline
    var removal: CalendarEvent?
    var removalComment = ""
    func askRemoveSelected() { if let e = selectedEvent, canRemove(e) { askRemove(e) } }
    func askRemove(_ e: CalendarEvent) { removal = e; removalComment = ""; removalScope = .occurrence }
    func confirmRemove() {
        guard let e = removal else { return }
        removal = nil
        let mode = removeMode(for: e), comment = removalComment, scope = removalScope
        if selectedEventId == e.id { selectedEventId = nil }
        wlog("remove \(e.id) mode=\(mode.rawValue) scope=\(scope.rawValue)")
        Task {
            if scope == .series, e.seriesMasterId != nil {
                do { try await sync?.removeSeries(occurrenceId: e.id, mode: mode, comment: comment) }
                catch { writeError = "The series couldn’t be removed (\(Self.describe(error))). Nothing was changed." }
            } else {
                try? await sync?.remove(eventId: e.id, mode: mode, comment: comment)
            }
            await afterWrite()
        }
    }

    /// Moves by the visible range: a week for 5/7-day views, otherwise by the number of days shown.
    func shiftWeek(_ n: Int) {
        let cal = Calendar.current
        if viewMode == .month {
            anchor = cal.date(byAdding: .month, value: n, to: cal.dateInterval(of: .month, for: anchor)!.start)!
            reload(); return
        }
        if viewMode == .agenda {
            anchor = cal.date(byAdding: .day, value: n * Self.agendaDays, to: cal.startOfDay(for: anchor))!
            reload(); return
        }
        anchor = dayCount >= 5 ? cal.date(byAdding: .weekOfYear, value: n, to: weekStart)!
                               : cal.date(byAdding: .day, value: n * dayCount, to: weekStart)!
        weekStart = Self.rangeStart(containing: anchor, days: dayCount)
        reload()
    }

    /// PEOPLE2-HOOK: open a meeting from the People history (Calendar, its week, selected).
    func reveal(eventId: String, at start: Date) {
        section = .calendar
        anchor = start
        weekStart = Self.rangeStart(containing: anchor, days: dayCount)
        reload()
        selectedEventId = eventId
    }

    func goToday() {
        anchor = .now
        weekStart = Self.rangeStart(containing: anchor, days: dayCount)
        reload()
    }

    func showOnly(_ cal: CalendarInfo?) {
        enabledCalendars = cal.map { [$0.id] } ?? Set(calendars.map(\.id))
        reload()
    }

    func toggle(_ cal: CalendarInfo) {
        if enabledCalendars.contains(cal.id) { enabledCalendars.remove(cal.id) } else { enabledCalendars.insert(cal.id) }
        reload()
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int, default d: Int) -> Int { (lo...hi).contains(self) ? self : d }
}

// WHEN-HOOK (WhenDeepViews.swift): the owner's busy times and the confirm-gated focus-block write. Same file so the
// private `sync` / `store` / `afterWrite` stay private.
extension AppModel {
    /// The owner's own default calendar (never a principal's in the assistant persona, never a group).
    var focusCalendar: CalendarInfo? { FocusBlockPlan.ownCalendar(calendars) }
    /// Busy intervals on the owner's own calendars (all of them, enabled or not); `excluding` drops event ids.
    func ownBusy(from: Date, to: Date, excluding: Set<String> = []) -> [DateInterval] {
        guard let store else { return [] }
        let ids = Set(calendars.filter { $0.access == .own && !$0.isGroup }.map(\.id))
        guard !ids.isEmpty else { return [] }
        let evs = (try? store.events(from: from, to: to, calendarIds: ids)) ?? []
        return SlotFinder.busy(from: evs, excluding: excluding, calendar: .current)
    }
    var focusWriter: FocusBlockWriter? {
        guard let sync, let store else { return nil }
        return SyncFocusWriter(sync: sync, store: store)
    }
    /// Purview: the same default label + stamp as a new meeting in the event editor. Returns a message when blocked.
    func stampFocusLabel(_ plan: inout FocusBlockPlan) -> String? {
        plan.labelId = PurviewPolicy.shared.defaultMeetingLabelId
        if let b = PurviewPolicy.shared.meetingBlock(labelId: plan.labelId, tree: compliance.labelTree()) { return b.message }
        plan.labelHeader = plan.labelId.flatMap { PurviewPolicy.header(labelId: $0, privileged: true, setAt: Date(), settings: PurviewPolicy.shared.settings) }
        if PurviewPolicy.stampDisabled { plan.labelHeader = nil }
        return nil
    }
    /// An earlier focus block's current id: Exchange's id for a local one, else the own-calendar block at that exact time.
    func resolveFocusEvent(_ id: String, slot: DateInterval) async -> String? {
        if let store, (try? store.event(id: id)) != nil { return id }
        if id.hasPrefix("local-"), let real = await sync?.remappedIds[id] { return real }
        guard let store else { return nil }
        let ids = Set(calendars.filter { $0.access == .own && !$0.isGroup }.map(\.id))
        let evs = (try? store.events(from: slot.start, to: slot.end, calendarIds: ids)) ?? []
        return evs.first { $0.start == slot.start && $0.end == slot.end && $0.attendees.isEmpty && $0.subject.hasPrefix("Focus") }?.id
    }
    func afterFocusWrite() async { await afterWrite() }
    /// Exchange's id for an event created offline (nil while it's still queued).
    func remappedEventId(_ local: String) async -> String? { await sync?.remappedIds[local] }
}

/// The real write path: SyncEngine outbox → Graph POST /calendars/{id}/events (own calendar, no attendees, tentative).
struct SyncFocusWriter: FocusBlockWriter {
    let sync: SyncEngine
    let store: LocalStore
    func createFocusBlock(_ draft: EventDraft) async throws -> String { try await sync.create(draft) }
    func removeFocusBlock(eventId: String) async throws {
        guard let e = try store.event(id: eventId) else { throw FocusBlockError.notFound }
        guard e.attendees.isEmpty else { throw FocusBlockError.notFound }   // never delete (= cancel) a meeting
        try await sync.remove(eventId: eventId, mode: .delete)
    }
}
