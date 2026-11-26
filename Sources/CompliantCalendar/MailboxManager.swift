import Foundation
import Observation
import MailCore

/// "Add mailbox…" and the per-mailbox sidebar controls (collapse, reorder, remove). State lives here, not in views
/// (no `@State` under CLT). The mailbox list itself stays on `MailModel.mailboxes`; changes go through
/// `MailModel.applyMailboxes` so the sync set, settings and sidebar move together.
@MainActor @Observable
final class MailboxManager {
    @ObservationIgnored weak var mail: MailModel?
    @ObservationIgnored private var directory: MailboxDirectory?
    /// Live only: interactive consent for directory lookup (People.Read, User.ReadBasic.All).
    @ObservationIgnored var grantDirectory: (() async throws -> Void)?

    var showAdd = false
    var query = "" { didSet { if oldValue != query { scheduleSearch() } } }
    var kind: MailboxAccessKind = .shared
    private(set) var suggestions: [EmailAddress] = []
    private(set) var validating = false
    private(set) var error: String?
    private(set) var directoryAvailable = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func configure(directory: MailboxDirectory, lookup: Bool, grant: (() async throws -> Void)? = nil) {
        self.directory = directory
        directoryAvailable = lookup
        grantDirectory = grant
    }

    func beginAdd() {
        query = ""; suggestions = []; error = nil; kind = .shared; validating = false
        showAdd = true
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        error = nil
        let q = query
        guard let directory, q.trimmingCharacters(in: .whitespaces).count >= 2 else { suggestions = []; return }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await directory.search(q)) ?? []
            guard !Task.isCancelled, self?.query == q else { return }
            let open = Set(self?.mail?.mailboxes ?? [])
            self?.suggestions = found.filter { !open.contains($0.address.lowercased()) }
        }
    }

    func pick(_ a: EmailAddress) { query = a.address; suggestions = [] }

    func allowDirectoryLookup() async {
        guard let grantDirectory else { return }
        do { try await grantDirectory(); scheduleSearch() }
        catch { self.error = "Directory lookup wasn't allowed. You can still type the full address." }
    }

    /// Validate access (`GET /users/{address}/mailFolders/inbox`) before anything is added, then persist + open.
    @discardableResult
    func add() async -> Bool {
        guard let mail, let sync = mail.sync, let directory else { error = "Mail isn't ready yet. Try again in a moment."; return false }
        guard let addr = MailboxAddress.normalise(query) else { error = MailboxAccessError.invalidAddress.message; return false }
        if mail.mailboxes.contains(where: { $0.lowercased() == addr }) { error = "That mailbox is already in the sidebar."; return false }
        if addr == mail.me?.address.lowercased() { error = "That's your own mailbox."; return false }
        validating = true; error = nil
        defer { validating = false }
        let v: MailboxValidation
        do { v = try await directory.validate(mailbox: addr) }
        catch { self.error = MailboxAccessError(error).message; return false }
        let name = v.displayName.isEmpty ? MailboxDisplay.title(v.address) : v.displayName
        await mail.refreshSettingsInfo()
        await mail.update { $0.addMailbox(v.address, identity: self.kind.identity(address: v.address, name: name)) }
        let list = MailboxList.compose(configured: mail.configuredMailboxes, settings: mail.settings)
        await sync.addMailbox(v.address)
        await sync.reorder(mailboxes: list)
        mail.applyMailboxes(list)
        showAdd = false
        await mail.openMailbox(v.address)
        return true
    }

    /// Remove from the sidebar, the sync set and the From picker; the local cache for it is purged.
    func remove(_ mailbox: String) async {
        guard let mail, let sync = mail.sync, mailbox != "me" else { return }
        let viewing = mail.selectedFolder?.mailbox == mailbox || mail.reader?.mailbox == mailbox
        try? await sync.removeMailbox(mailbox)
        await mail.refreshSettingsInfo()
        let configured = mail.configuredMailboxes.contains(mailbox)
        await mail.update { $0.removeMailbox(mailbox, configured: configured) }
        mail.applyMailboxes(MailboxList.compose(configured: mail.configuredMailboxes, settings: mail.settings), resetSelection: viewing)
    }

    func move(_ mailbox: String, by delta: Int) async {
        guard let mail, let sync = mail.sync else { return }
        let current = mail.mailboxes
        await mail.update { $0.moveMailbox(mailbox, by: delta, current: current) }
        let list = MailboxList.compose(configured: mail.configuredMailboxes, settings: mail.settings)
        await sync.reorder(mailboxes: list)
        mail.applyMailboxes(list)
    }

    func canMove(_ mailbox: String, by delta: Int) -> Bool {
        guard let mail, mailbox != "me", let i = mail.mailboxes.firstIndex(of: mailbox) else { return false }
        let j = i + delta
        return j >= 1 && j < mail.mailboxes.count
    }

    /// Optimistic collapse state: flips at once on click, persisted to the sealed settings in the background.
    private var collapsedOverride: [String: Bool] = [:]

    func isCollapsed(_ mailbox: String) -> Bool {
        collapsedOverride[mailbox] ?? mail?.settings.isCollapsed(mailbox) ?? false
    }

    func toggleCollapsed(_ mailbox: String) {
        guard let mail else { return }
        let on = !isCollapsed(mailbox)
        collapsedOverride[mailbox] = on
        Task { await mail.update { $0.setCollapsed(mailbox, on) } }
    }

    /// Per-mailbox sync error (403 / 404 …) from the last pass, shown under its sidebar header.
    func error(for mailbox: String) -> String? { mail?.status.mailboxErrors[mailbox] }
}

// MAILBOXES-HOOK / GROUPS-HOOK: wiring called from AppModel.startMailIfNeeded.
extension MailModel {
    /// Fixtures: synthetic directory + groups (never the network).
    func configureFixtureExtras() {
        mailboxManager.configure(directory: FixtureMailboxDirectory(), lookup: true)
        groups.configure(service: FixtureGroupsService())
        DriveHub.shared.configure(service: FixtureDriveService())   // ONEDRIVE-HOOK (DrivePicker.swift)
        configureComposeFixtures()   // COMPOSE-HOOK (ComposerAssistModel.swift)
        configurePeopleFixtures()   // PEOPLE-HOOK (PeopleHub.swift)
    }

    /// Live: the access check uses the mail token; directory lookup and Groups each have their own incremental
    /// consent (Auth.directoryScopes / groupReadScopes / groupWriteScopes), so a missing consent never breaks Mail.
    func configureLiveExtras(auth: Auth) async {
        let lookup = (try? await auth.directoryToken()) != nil
        mailboxManager.configure(
            directory: GraphMailboxDirectory(mailToken: { try await auth.mailToken() },
                                             directoryToken: { try await auth.directoryToken() }),
            lookup: lookup, grant: { try await auth.grantAccess(scopes: Auth.directoryScopes) })
        groups.configure(
            service: GraphGroupsService(readToken: { try await auth.groupToken(write: false) },
                                        writeToken: { try await auth.groupToken(write: true) }),
            grant: { write in try await auth.grantAccess(scopes: write ? Auth.groupWriteScopes : Auth.groupReadScopes) })
        configureComposeLive(auth: auth)   // COMPOSE-HOOK: autocomplete + MailTips + draft attachments
        GroupManage.shared.filesToken = { try await auth.driveToken() }   // ORG2-HOOK: group files link
        FindTimeHub.shared.configure(auth: auth)   // ORG2-HOOK: Find a time
        // ONEDRIVE-HOOK: own incremental consent set (Auth.driveScopes), asked on first use.
        DriveHub.shared.configure(
            service: GraphDriveService(token: { try await auth.driveToken() }, labelToken: { try await auth.driveToken() }),
            grant: { try await auth.grantAccess(scopes: Auth.driveScopes) })
        configurePeopleLive(auth: auth)   // PEOPLE-HOOK (PeopleHub.swift): own consent sets, silent tokens
    }
}
