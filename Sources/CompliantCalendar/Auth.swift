import AppKit
import CalendarCore
@preconcurrency import MSAL

/// Tenant configuration. Lowest first: Info.plist defaults (`NiivoClientID` / `NiivoTenantID`, baked in by
/// scripts/bundle.sh; not secrets), then ~/Library/Application Support/CompliantCalendar/config.json, then env:
/// { "clientId": "...", "tenantId": "...", "delegatedMailboxes": ["boss@contoso.com"] }
struct AppConfig: Codable {
    var clientId: String?
    var tenantId: String?
    var delegatedMailboxes: [String]?
    /// Shared mailboxes (e.g. support@) opened in Mail. Graph can't enumerate them, so they're configured.
    var sharedMailboxes: [String]?

    static let bundleId = Bundle.main.bundleIdentifier ?? "ai.niivo.mail"
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CompliantCalendar", directoryHint: .isDirectory)
    }

    static func load() -> AppConfig {
        let file = try? JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: supportDir.appending(path: "config.json")))
        return merged(bundle: Bundle.main.infoDictionary ?? [:], file: file, env: ProcessInfo.processInfo.environment)
    }

    /// An absent or empty value at one level leaves the lower level's value in place.
    static func merged(bundle: [String: Any], file: AppConfig?, env: [String: String]) -> AppConfig {
        func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }
        var c = file ?? AppConfig()
        c.clientId = nonEmpty(env["CC_CLIENT_ID"]) ?? nonEmpty(file?.clientId) ?? nonEmpty(bundle["NiivoClientID"] as? String)
        c.tenantId = nonEmpty(env["CC_TENANT_ID"]) ?? nonEmpty(file?.tenantId) ?? nonEmpty(bundle["NiivoTenantID"] as? String)
        return c
    }

    var isConfigured: Bool { !(clientId ?? "").isEmpty }
}

/// MSAL wrapper. Graph scopes only; MIP SDK tokens (RMS + sync service resources) are a separate
/// acquireTokenSilent per resource once the MIP shim lands.
@MainActor
final class Auth {
    /// What the calendar's silent token requests (unchanged, so an existing calendar session keeps refreshing even
    /// before the mail scopes below are consented).
    static let calendarScopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/Calendars.ReadWrite.Shared",   // own + shared + delegated calendars
        "https://graph.microsoft.com/InformationProtectionPolicy.Read", // Purview label definitions
    ]
    /// Mail. CONSENT NEEDED: these delegated permissions must be added to the Entra app registration (API permissions)
    /// and consented (user or admin, per tenant consent settings) before mail works against a real tenant. Until
    /// then the mail silent token fails and Mail shows a "needs consent" state; the calendar is unaffected.
    static let mailScopes = [
        "https://graph.microsoft.com/Mail.ReadWrite",
        "https://graph.microsoft.com/Mail.ReadWrite.Shared",        // shared + delegated mailboxes
        "https://graph.microsoft.com/Mail.Send",
        "https://graph.microsoft.com/Mail.Send.Shared",             // send as / on behalf
        "https://graph.microsoft.com/MailboxSettings.ReadWrite",    // automatic replies, regional settings
    ]
    /// Directory lookup for "Add mailbox…" (People.Read, User.ReadBasic.All; user-consentable in most tenants). Kept
    /// out of `mailScopes` on purpose: one unconsented scope in a set fails that set's silent token, and lookup is
    /// optional (typing the address works without it).
    static let directoryScopes = [
        "https://graph.microsoft.com/People.Read",
        "https://graph.microsoft.com/User.ReadBasic.All",
    ]
    /// Microsoft 365 Groups, read: memberships + conversations/threads/posts. User.Read alone lists /me/memberOf but,
    /// without a group-read permission, groups come back with id only ("limited information", Learn), so
    /// GroupMember.Read.All is added (also the documented permission for GET /groups/{id} unseenCount).
    /// ADMIN CONSENT NEEDED (GroupMember.Read.All, Group-Conversation.Read.All). Separate from `mailScopes` so Mail keeps
    /// working in a tenant that hasn't consented them; asked when the Groups section is first opened.
    static let groupReadScopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/GroupMember.Read.All",
        "https://graph.microsoft.com/Group-Conversation.Read.All",
    ]
    /// Groups, write: reply to a thread / start a conversation. Graph documents Group.ReadWrite.All as the only
    /// delegated permission for both. ADMIN CONSENT NEEDED. Asked only when the user first posts.
    static let groupWriteScopes = [
        "https://graph.microsoft.com/Group.ReadWrite.All",
    ]
    /// Group calendars in the calendar: Learn lists Group.Read.All as least privileged for /groups/{id}/calendarView and
    /// Group.ReadWrite.All for create/update/delete. Group.ReadWrite.All is the one on the app registration (admin
    /// consent granted), so one set covers reads and writes. Never part of `calendarScopes`.
    static let groupCalendarScopes = groupWriteScopes
    /// Room finder: /places room lists + rooms (Place.Read.All, admin-consented). Free/busy for rooms uses getSchedule
    /// on the calendar token.
    static let placeScopes = ["https://graph.microsoft.com/Place.Read.All"]
    /// OneDrive cloud attachments: one incremental consent set, asked the first time the composer's OneDrive button is
    /// used, never part of `mailScopes`. Files.ReadWrite = least privilege for createLink / upload / download;
    /// Files.Read.All = least privilege for `extractSensitivityLabels` and needed for `sharedWithMe`. Both are on the
    /// app registration (delegated). Tenants that restrict user consent need ADMIN CONSENT. Sites.Read.All is NOT
    /// registered, so SharePoint document libraries aren't browsed.
    static let driveScopes = [
        "https://graph.microsoft.com/Files.ReadWrite",
        "https://graph.microsoft.com/Files.Read.All",
    ]
    /// People window + contact cards: Outlook contacts (own + shared folders), relevance and directory profiles/photos.
    /// Own incremental set (admin-consented on the registration), never part of `mailScopes`; asked on first use.
    static let peopleScopes = [
        "https://graph.microsoft.com/Contacts.ReadWrite",
        "https://graph.microsoft.com/Contacts.ReadWrite.Shared",
        "https://graph.microsoft.com/People.Read",
        "https://graph.microsoft.com/User.ReadBasic.All",
    ]
    /// Microsoft To Do (Tasks window, task from a message). Own incremental set.
    static let todoScopes = [
        "https://graph.microsoft.com/Tasks.ReadWrite",
    ]
    /// PEOPLE2-HOOK / NOTES-HOOK: "Log a note" on a person page writes a OneNote page (MailCore/PeopleNotes.swift).
    /// Own incremental set, never part of `mailScopes`; asked when the user presses "Connect OneNote". Notes.ReadWrite
    /// (find/create the "niivo" notebook + section, create pages). OWNER ACTION: the app registration must list
    /// Notes.ReadWrite (delegated) and the user consents once (UNVERIFIED: not checkable from code).
    static let notesScopes = [
        "https://graph.microsoft.com/Notes.ReadWrite",
    ]
    /// Teams presence dots. Own set; dots only ever use the silent token (passive UI never prompts).
    static let presenceScopes = [
        "https://graph.microsoft.com/Presence.Read.All",
    ]
    /// Requested at interactive sign-in so one consent covers calendar + mail.
    static let graphScopes = calendarScopes + mailScopes

    private let app: MSALPublicClientApplication
    private(set) var account: MSALAccount?
    private(set) var lastCacheError: String?

    /// ACCOUNTS-HOOK: which signed-in account this Auth serves. nil → the active account (persisted id), else the only
    /// cached account. Never an arbitrary `allAccounts().first` once several accounts are cached (docs/ACCOUNTS.md).
    init(config: AppConfig, accountId: String? = nil) throws {
        app = try Self.application(config: config)
        do {
            let all = try app.allAccounts()
            if let wanted = accountId ?? Self.activeAccountId, let a = all.first(where: { $0.homeAccountId?.identifier == wanted }) {
                account = a
            } else if accountId == nil {
                // First launch after the update (no active id yet): the pre-accounts behaviour. goLive then records
                // the id, so later launches pick the account by identifier.
                account = all.first
            }
        } catch {
            // Surface, don't swallow: an ad-hoc-signed build without a keychain-access-groups entitlement may
            // fail here (MSAL's default shared cache group). See FINDINGS §6.
            let ns = error as NSError
            FileHandle.standardError.write(Data("MSAL allAccounts failed: \(ns.domain) \(ns.code) \(ns.userInfo)\n".utf8))
            lastCacheError = "\(ns.domain) \(ns.code)"
        }
    }

    /// ACCOUNTS-HOOK: one MSAL application (one token cache) shared by every account's Auth.
    private static var sharedApp: MSALPublicClientApplication?
    private static var configuredTenant: String?
    private static func application(config: AppConfig) throws -> MSALPublicClientApplication {
        if let sharedApp { return sharedApp }
        configuredTenant = config.tenantId
        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(config.tenantId ?? "organizations")")!)
        let cfg = MSALPublicClientApplicationConfig(clientId: config.clientId!,
                                                    redirectUri: "msauth.\(AppConfig.bundleId)://auth",
                                                    authority: authority)
        // CP1 = this client handles Continuous Access Evaluation claims challenges, so Entra issues CAE tokens
        // (revocation reaches us in near real time). NOTE: nothing feeds a 401 claims challenge back into MSAL yet
        // (acquireToken with `claimsRequest`); until that lands, a CAE challenge surfaces as a sync error.
        // cfg.clientApplicationCapabilities = ["CP1"]  // OFF until claims challenges are handled (see NEXT.md):
        // declaring CP1 without handling the 401 challenge would leave calendar and mail calls unrecoverable.
        // LIFECYCLE-HOOK: Mail now handles the challenge (GraphMailService → MailSync status → `reauthenticateMail`).
        // The calendar service doesn't yet (its 401 shows "needs consent"), so CP1 stays opt-in:
        // `defaults write <bundle id> auth.caeCP1 -bool YES`. UNVERIFIED against a live CAE revocation.
        if UserDefaults.standard.bool(forKey: "auth.caeCP1") { cfg.clientApplicationCapabilities = ["CP1"] }
        // Signed builds: MSAL's cache group must be prefixed with our team ID to match the entitlement.
        if let team = Bundle.main.object(forInfoDictionaryKey: "CCTeamID") as? String, !team.isEmpty {
            cfg.cacheConfig.keychainSharingGroup = "\(team).com.microsoft.identity.universalstorage"
            KeychainCacheKey.accessGroup = "\(team).\(AppConfig.bundleId)"
        }
        let a = try MSALPublicClientApplication(configuration: cfg)
        sharedApp = a
        return a
    }

    /// The account the live session runs as (home-account identifier: no content, not secret). Plain defaults because
    /// it's needed before the keyring unlocks, to pick the right MSAL account.
    static var activeAccountId: String? {
        get { UserDefaults.standard.string(forKey: "accounts.activeId") }
        set { UserDefaults.standard.set(newValue, forKey: "accounts.activeId") }
    }

    /// The account's own tenant ("<oid>.<tid>" → tid).
    var tenantId: String? { (account?.homeAccountId?.identifier as String?).flatMap { Account.tenant(fromHomeAccountId: $0) } }

    /// Silent tokens go to the account's own tenant (docs/ACCOUNTS.md A10).
    private var accountAuthority: MSALAuthority? {
        // Account #1 (configured tenant): unchanged pre-accounts behaviour, the application's own authority.
        if let t = tenantId, t == Self.configuredTenant?.lowercased() { return nil }
        return tenantId.flatMap { URL(string: "https://login.microsoftonline.com/\($0)") }.flatMap { try? MSALAADAuthority(url: $0) }
    }

    /// ACCOUNTS-HOOK: config.json's shared/delegated mailboxes belong to the configured tenant's account only; another
    /// tenant's account never tries to open them or offers them as From. (No tenant configured: they apply to all.)
    var ownsConfiguredMailboxes: Bool {
        guard let c = Self.configuredTenant?.lowercased(), !c.isEmpty, c != "organizations", c != "common" else { return true }
        return tenantId == c
    }

    /// Every account in the MSAL cache.
    func cachedAccounts() -> [MSALAccount] { (try? app.allAccounts()) ?? [] }

    /// Add Account: browser PKCE via `organizations` with the account picker. Doesn't change this Auth's account.
    /// "Not this tenant (yet)" errors become `AddAccountError` (no retry, no workaround).
    func addAccount(clientId: String) async throws -> MSALAccount {
        guard let vc = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
        }
        let params = MSALInteractiveTokenParameters(scopes: Self.calendarScopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
        params.promptType = .selectAccount
        params.authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/organizations")!)
        do { return try await app.acquireToken(with: params).account }
        catch {
            let ns = error as NSError
            let text = [ns.localizedDescription, ns.userInfo[MSALErrorDescriptionKey] as? String,
                        ns.userInfo[MSALOAuthErrorKey] as? String].compactMap { $0 }.joined(separator: " ")
            let tenant = (ns.userInfo[MSALHomeAccountIdKey] as? String).flatMap(Account.tenant(fromHomeAccountId:))
            let kind = AccountAuthError.classify(text, tenant: tenant, clientId: clientId)
            if case .other = kind { throw error }
            throw AddAccountError(kind: kind)
        }
    }

    /// Removes one cached account (its refresh token) without touching the others.
    func removeCached(accountId: String) {
        if let a = cachedAccounts().first(where: { $0.homeAccountId?.identifier == accountId }) { try? app.remove(a) }
        if account?.homeAccountId?.identifier == accountId { account = nil }
    }

    var accountKey: String { account?.homeAccountId?.identifier ?? "anonymous" }

    func signIn() async throws {
        guard let vc = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
        }
        // Incremental consent: sign-in asks for calendar scopes only; Mail asks for its scopes when first opened.
        let params = MSALInteractiveTokenParameters(scopes: Self.calendarScopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
        params.promptType = .selectAccount
        // One sign-in covers Mail too (BACKLOG §17): its scopes are consented in the same sheet, so opening Mail
        // doesn't bounce the user through a second prompt. Tokens are still requested per scope set.
        params.extraScopesToConsent = Self.mailScopes.filter { !Self.calendarScopes.contains($0) }
        let result = try await app.acquireToken(with: params)
        account = result.account
    }

    /// Silent first; the token cache is the Keychain. Throws when interaction is required.
    func token() async throws -> String { try await token(scopes: Self.calendarScopes) }

    /// Mail's own silent token (fails with interaction-required until the mail scopes are consented).
    /// LIFECYCLE-HOOK: success / failure feeds the sync status ("Sign-in required" when MSAL needs interaction).
    func mailToken() async throws -> String {
        do { let t = try await token(scopes: Self.mailScopes); AppLifecycle.shared.mailTokenSucceeded(); return t }
        catch { AppLifecycle.shared.mailTokenFailed(error); throw error }
    }

    /// LIFECYCLE-HOOK: re-acquire the mail token, with a CAE / Conditional Access claims request when Graph sent one.
    /// Silent first (MSAL skips its access-token cache when claims are given, so the refresh token is redeemed with
    /// the claims); `interactive` then falls back to the sign-in sheet. Only ever interactive on a user click.
    func reauthenticateMail(claims: String?, interactive: Bool) async throws {
        guard let account else { throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]) }
        var claimsError: NSError?
        let request = claims.flatMap { MSALClaimsRequest(jsonString: $0, error: &claimsError) }
        if claims != nil, request == nil { throw claimsError ?? NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unreadable claims challenge"]) }
        do {
            let p = MSALSilentTokenParameters(scopes: Self.mailScopes, account: account)
            p.authority = accountAuthority   // ACCOUNTS-HOOK
            p.claimsRequest = request
            p.forceRefresh = claims == nil
            _ = try await app.acquireTokenSilent(with: p)
            return
        } catch where interactive {
            let main = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.isVisible }
            guard let vc = main?.contentViewController ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })?.contentViewController
                    ?? NSApp.keyWindow?.contentViewController else {
                throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
            }
            let params = MSALInteractiveTokenParameters(scopes: Self.mailScopes,
                                                        webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
            params.account = account
            params.claimsRequest = request
            let result = try await app.acquireToken(with: params)
            self.account = result.account
        }
    }

    /// Interactive consent for the mail scopes, asked the first time Mail is opened (not at calendar sign-in).
    func grantMailAccess() async throws {
        guard let vc = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
        }
        let params = MSALInteractiveTokenParameters(scopes: Self.mailScopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
        params.account = account
        let result = try await app.acquireToken(with: params)
        account = result.account
    }

    /// Optional scope sets (directory lookup, groups): silent token, and interactive consent when the user asks.
    func directoryToken() async throws -> String { try await token(scopes: Self.directoryScopes) }
    func groupToken(write: Bool) async throws -> String { try await token(scopes: write ? Self.groupWriteScopes : Self.groupReadScopes) }
    func driveToken() async throws -> String { try await token(scopes: Self.driveScopes) }
    func peopleToken() async throws -> String { try await token(scopes: Self.peopleScopes) }
    func todoToken() async throws -> String { try await token(scopes: Self.todoScopes) }
    func presenceToken() async throws -> String { try await token(scopes: Self.presenceScopes) }
    func notesToken() async throws -> String { try await token(scopes: Self.notesScopes) }   // PEOPLE2-HOOK

    /// The calendar service's per-request token (GraphCalendarService routes by path). Each set is its own silent token,
    /// so an unconsented optional set fails only its own requests.
    static func scopes(for scope: GraphScope) -> [String] {
        switch scope {
        case .calendar: calendarScopes
        case .groupMembership: groupReadScopes
        case .groupCalendar: groupCalendarScopes
        case .places: placeScopes
        case .mailboxSettings: mailScopes
        }
    }
    func token(for scope: GraphScope) async throws -> String { try await token(scopes: Self.scopes(for: scope)) }

    func grantAccess(scopes: [String]) async throws {
        guard let vc = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
        }
        let params = MSALInteractiveTokenParameters(scopes: scopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
        params.account = account
        let result = try await app.acquireToken(with: params)
        account = result.account
    }

    /// Silent token for non-Graph resources the MIP SDK asks for (RMS `https://aadrm.com/user_impersonation`, MIP sync
    /// `https://syncservice.o365syncservice.com/UnifiedPolicy.User.Read`); both are admin-consented on the app
    /// registration. Used by `ProtectedContentCoordinator` (docs/MIP.md).
    func silentToken(scopes: [String]) async throws -> String { try await token(scopes: scopes) }

    /// Azure Rights Management (RMS) delegated scope the MIP SDK needs to fetch a use licence. Admin-consented on the
    /// app registration (docs/MIP.md), so the silent call normally succeeds off the existing refresh token. Asked
    /// for on its own: MSAL can't mix resources (Graph + RMS) in one request.
    static let rmsScopes = ["https://aadrm.com/user_impersonation"]

    /// Incremental consent / interactive sign-in for RMS ("Grant access…" on a protected message), when the silent
    /// RMS token fails (interaction required, consent missing, MFA step-up). Same account; tenant unchanged.
    func grantProtectionAccess() async throws {
        guard let vc = NSApp.keyWindow?.contentViewController ?? NSApp.windows.first?.contentViewController else {
            throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window to present sign-in"])
        }
        let params = MSALInteractiveTokenParameters(scopes: Self.rmsScopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: vc))
        params.account = account
        let result = try await app.acquireToken(with: params)
        account = result.account
    }

    /// Signed-in UPN (the MIP engine identity).
    var username: String? { account?.username }

    private func token(scopes: [String]) async throws -> String {
        guard let account else { throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]) }
        let p = MSALSilentTokenParameters(scopes: scopes, account: account)
        p.authority = accountAuthority   // ACCOUNTS-HOOK: the account's own tenant
        let result = try await app.acquireTokenSilent(with: p)
        return result.accessToken
    }

    func signOut() {
        if let account { try? app.remove(account) }
        account = nil
    }
}

/// ACCOUNTS-HOOK: Add Account failed for a reason retrying won't fix (docs/ACCOUNTS.md §5).
struct AddAccountError: LocalizedError {
    let kind: AccountAuthError
    var errorDescription: String? { kind.message }
    var adminConsentURL: URL? { if case .adminConsentRequired(_, let u) = kind { u } else { nil } }
}
