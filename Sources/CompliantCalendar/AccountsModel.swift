import AppKit
import CalendarCore
import MailCore
import TrustCore

/// ACCOUNTS-HOOK: the signed-in accounts (docs/ACCOUNTS.md). The pure rules (registry, migration, error mapping,
/// naming) live in CalendarCore/Accounts.swift and are self-tested; this file only persists and drives them.
///
/// Phase 1 runs **one live session at a time**: the active account's Auth, stores, label engine, MIP context and
/// policy. Switching tears that session down (as a lock does) and opens the other account's own stores, so nothing
/// from one tenant can reach another tenant's store, index, Stories or AI context. Concurrent sessions (a true
/// cross-account All Inboxes) are phase 1b, see BACKLOG.
@MainActor @Observable
final class AccountsModel {
    private(set) var registry = AccountRegistry()
    /// The registry file exists but couldn't be opened (locked): shown read-only, never overwritten.
    private(set) var unreadable = false
    private(set) var loaded = false
    var busy = false
    var errorText: String?
    /// Admin consent needed: the link to hand to that tenant's administrator.
    var consentURL: URL?
    var pendingRemoval: Account?

    var accounts: [Account] { registry.accounts }
    var activeId: String? { Auth.activeAccountId ?? registry.defaultAccount?.id }
    var active: Account? { registry.account(activeId) ?? registry.defaultAccount }

    private var fileURL: URL { AppConfig.supportDir.appending(path: AccountStoreNaming.registryFile) }

    /// Opens (or migrates) the registry. Needs the keyring unlocked; does nothing while locked.
    func load(keyring: CacheKeyring?, auth: Auth?) {
        guard let keyring, let k = try? keyring.registryKey() else { return }
        // A fresh key means a previous registry (if any) was sealed with a lost key: unreadable for good, so start over
        // from the signed-in account. Store files are keyed separately and aren't touched.
        if k.fresh { try? FileManager.default.removeItem(at: fileURL) }
        let cipher = AESGCMCipher(key: k.key)
        let legacy = auth?.account.flatMap { a -> (homeAccountId: String, username: String)? in
            guard let id = a.homeAccountId?.identifier else { return nil }
            return (id, a.username ?? "")
        }
        switch AccountMigration.plan(sealedFile: try? Data(contentsOf: fileURL),
                                     open: { try AccountRegistry.open($0, with: cipher) }, legacy: legacy) {
        case .use(let r): registry = r; unreadable = false
        case .migrate(let r): registry = r; unreadable = false; save(cipher)
        case .empty: registry = AccountRegistry(); unreadable = false
        case .unreadable: unreadable = true
        }
        // The cached MSAL account that runs the session must be in the list (signed in before the registry existed).
        if !unreadable, let legacy, registry.account(legacy.homeAccountId) == nil {
            registry.add(Account(id: legacy.homeAccountId, tenantId: Account.tenant(fromHomeAccountId: legacy.homeAccountId),
                                 username: legacy.username))
            save(cipher)
        }
        if Auth.activeAccountId == nil, let id = legacy?.homeAccountId ?? registry.defaultAccount?.id { Auth.activeAccountId = id }
        loaded = true
        self.cipher = cipher
    }

    private var cipher: AESGCMCipher?

    private func save(_ c: AESGCMCipher? = nil) {
        guard !unreadable, let c = c ?? cipher, let data = try? registry.sealed(with: c) else { return }
        try? FileManager.default.createDirectory(at: AppConfig.supportDir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: Settings actions

    func add(app: AppModel) async {
        guard let auth = app.auth, let clientId = AppConfig.load().clientId else { return }
        busy = true; errorText = nil; consentURL = nil
        defer { busy = false }
        do {
            let a = try await auth.addAccount(clientId: clientId)
            guard let id = a.homeAccountId?.identifier else { return }
            registry.add(Account(id: id, tenantId: Account.tenant(fromHomeAccountId: id), username: a.username ?? "",
                                 colour: AccountColour.next(after: registry.accounts.map(\.colour))))
            save()
        } catch let e as AddAccountError {
            errorText = e.errorDescription; consentURL = e.adminConsentURL
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Sign-out of the active account (its stores are already wiped by AppModel.signOut): drop it from the list.
    func forget(_ id: String) {
        guard registry.account(id) != nil else { return }
        registry.remove(id); save()
        if Auth.activeAccountId == id { Auth.activeAccountId = registry.defaultAccount?.id }
    }

    func move(_ id: String, by offset: Int) { registry.move(id, by: offset); save() }
    func setColour(_ c: AccountColour, for id: String) { registry.setColour(c, for: id); save() }
    func makeDefault(_ id: String) { registry.makeDefault(id); save() }

    /// Remove: wipes that account's stores and keys and its MSAL token, nothing else. Removing the active account
    /// switches to the next one (or signs out when it was the last).
    func remove(_ id: String, app: AppModel) async {
        guard registry.account(id) != nil else { return }
        let wasActive = id == activeId   // before signOut → forget() moves the active id
        if wasActive {
            await app.signOut()   // wipes the active session's stores + keys + MSAL account
        } else {
            for f in AccountStoreNaming.files(id) { CacheKeyring.discardStaleCache(at: AppConfig.supportDir.appending(path: f)) }
            app.trust.keyring?.remove(account: id)
            app.auth?.removeCached(accountId: id)
        }
        registry.remove(id)
        save()
        if wasActive || Auth.activeAccountId == id {
            Auth.activeAccountId = registry.defaultAccount?.id
            if wasActive, let next = registry.defaultAccount?.id { await app.switchAccount(to: next) }
        }
    }

    func switchTo(_ id: String, app: AppModel) async {
        guard id != activeId || app.auth?.account == nil, registry.account(id) != nil else { return }
        await app.switchAccount(to: id)
    }
}

extension AccountColour {
    /// NiivoUI-friendly swatches (muted, legible on light and dark grounds).
    var color: NSColor {
        switch self {
        case .teal: NSColor(srgbRed: 0.16, green: 0.55, blue: 0.55, alpha: 1)
        case .blue: NSColor(srgbRed: 0.22, green: 0.42, blue: 0.78, alpha: 1)
        case .violet: NSColor(srgbRed: 0.52, green: 0.36, blue: 0.78, alpha: 1)
        case .rose: NSColor(srgbRed: 0.80, green: 0.32, blue: 0.45, alpha: 1)
        case .amber: NSColor(srgbRed: 0.85, green: 0.58, blue: 0.16, alpha: 1)
        case .green: NSColor(srgbRed: 0.30, green: 0.62, blue: 0.32, alpha: 1)
        case .slate: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.53, alpha: 1)
        }
    }
    var title: String { rawValue.capitalized }
}
