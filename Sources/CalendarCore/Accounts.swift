import Foundation

// MARK: - Accounts (docs/ACCOUNTS.md)
//
// Several signed-in accounts, any tenant. UI-free: the app's Settings/sidebar and the tests call the same code.
// Account #1 is the pre-multi-account sign-in: its id is the MSAL home-account identifier, byte-identical to the old
// `auth.accountKey`, so its store files and keyring slots are reused unchanged (ACCOUNTS.md A8).

/// Which service an account signs in to. Only `.microsoft365` is built (phase 1); the rest are declared so the model,
/// persistence and capability checks are ready for them (ACCOUNTS.md §3).
public enum AccountProvider: String, Codable, Sendable, CaseIterable {
    case microsoft365, outlookCom, gmail, icloud, imap, jmap

    public var isAvailable: Bool { self == .microsoft365 }

    public var capabilities: ProviderCapabilities {
        switch self {
        case .microsoft365: .microsoft365
        case .outlookCom: [.mail, .calendar, .contacts, .tasks, .serverSearch, .push, .categories, .serverRules]
        case .gmail: [.mail, .calendar, .contacts, .serverSearch, .push, .sendAs]
        case .icloud: [.mail, .calendar, .contacts, .push]
        case .imap: [.mail, .push]
        case .jmap: [.mail, .calendar, .contacts, .serverSearch, .push]
        }
    }

    public var displayName: String {
        switch self {
        case .microsoft365: "Microsoft 365"
        case .outlookCom: "Outlook.com"
        case .gmail: "Gmail"
        case .icloud: "iCloud"
        case .imap: "IMAP / SMTP"
        case .jmap: "JMAP"
        }
    }
}

/// What a provider can do. Surfaces check capabilities, never the provider (the label picker needs
/// `.sensitivityLabels`, the shared-mailbox menu `.sharedMailboxes`, …).
public struct ProviderCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let mail = Self(rawValue: 1 << 0)
    public static let calendar = Self(rawValue: 1 << 1)
    public static let contacts = Self(rawValue: 1 << 2)
    public static let tasks = Self(rawValue: 1 << 3)
    public static let sensitivityLabels = Self(rawValue: 1 << 4)
    public static let rightsManagement = Self(rawValue: 1 << 5)
    public static let sharedMailboxes = Self(rawValue: 1 << 6)
    public static let serverSearch = Self(rawValue: 1 << 7)
    public static let push = Self(rawValue: 1 << 8)
    public static let categories = Self(rawValue: 1 << 9)
    public static let serverRules = Self(rawValue: 1 << 10)
    public static let sendAs = Self(rawValue: 1 << 11)
    public static let microsoft365: Self = [.mail, .calendar, .contacts, .tasks, .sensitivityLabels, .rightsManagement,
                                            .sharedMailboxes, .serverSearch, .push, .categories, .serverRules, .sendAs]
}

/// The colours an account can take (sidebar dot, row stripe). Names map to NiivoUI tokens in the app.
public enum AccountColour: String, Codable, Sendable, CaseIterable {
    case teal, blue, violet, rose, amber, green, slate
    /// The next colour not yet used (cycles once all are taken).
    public static func next(after used: [AccountColour]) -> AccountColour {
        allCases.first { !used.contains($0) } ?? allCases[used.count % allCases.count]
    }
}

public struct Account: Codable, Sendable, Hashable, Identifiable {
    /// Microsoft 365: MSAL `homeAccountId.identifier` ("<oid>.<tid>"). Stable across launches; keys the stores.
    public var id: String
    public var provider: AccountProvider
    /// Entra tenant id (lower-cased GUID). Decides which `msip_labels` are this account's own (ACCOUNTS.md A9).
    public var tenantId: String?
    /// UPN / sign-in address.
    public var username: String
    public var displayName: String
    public var colour: AccountColour
    public var addedAt: Date

    public init(id: String, provider: AccountProvider = .microsoft365, tenantId: String?, username: String,
                displayName: String = "", colour: AccountColour = .teal, addedAt: Date = Date()) {
        self.id = id; self.provider = provider; self.tenantId = tenantId?.lowercased()
        self.username = username; self.displayName = displayName; self.colour = colour; self.addedAt = addedAt
    }

    /// "<oid>.<tid>" → tid (lower-cased); nil when the identifier has no tenant part.
    public static func tenant(fromHomeAccountId id: String) -> String? {
        let parts = id.split(separator: ".")
        return parts.count >= 2 ? parts.last.map { String($0).lowercased() } : nil
    }

    public var capabilities: ProviderCapabilities { provider.capabilities }
    /// File/slot-safe form of `id` (identical to the pre-accounts `CacheKeyring.safeName(accountKey)`).
    public var storeKey: String { AccountStoreNaming.safeName(id) }
    public var title: String { displayName.isEmpty ? username : displayName }
    /// MSAL authority for silent tokens: the account's own tenant (`organizations` only if the tenant is unknown).
    public var authority: String { "https://login.microsoftonline.com/\(tenantId ?? "organizations")" }

    /// Two accounts in the same organisation (same-tenant forwarding isn't "cross-tenant").
    public func sameTenant(as other: Account) -> Bool {
        guard let a = tenantId, let b = other.tenantId else { return false }
        return a == b
    }
}

/// Store file and keyring slot names. One function, used by the app's CacheKeyring and the tests, so account #1's
/// files can't drift (a different name would make the keyring report `fresh` and the cache be discarded).
public enum AccountStoreNaming {
    public static func safeName(_ account: String) -> String {
        account.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
    }
    public static func calendarFile(_ accountId: String) -> String { "\(safeName(accountId)).sqlite" }
    public static func mailFile(_ accountId: String) -> String { "\(safeName(accountId))-mail.sqlite" }
    /// Every file that belongs to the account (removal wipes these + sidecars).
    public static func files(_ accountId: String) -> [String] { [calendarFile(accountId), mailFile(accountId)] }
    /// The registry's own sealed file and keyring slot owner: no single account, so removing #1 keeps it readable.
    public static let registryFile = "accounts.sealed"
    public static let registryKeyOwner = "accounts-registry"
}

// MARK: - Registry

public struct AccountRegistry: Codable, Sendable, Equatable {
    public private(set) var accounts: [Account]
    public private(set) var defaultAccountId: String?
    public var version: Int = 1

    public init(accounts: [Account] = [], defaultAccountId: String? = nil) {
        self.accounts = accounts
        self.defaultAccountId = defaultAccountId ?? accounts.first?.id
    }

    public var defaultAccount: Account? { accounts.first { $0.id == defaultAccountId } ?? accounts.first }
    public func account(_ id: String?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }
    public var isMultiAccount: Bool { accounts.count > 1 }

    /// Adds (or refreshes name/tenant of) an account. Re-adding the same id never duplicates it or changes its colour.
    @discardableResult
    public mutating func add(_ a: Account) -> Account {
        if let i = accounts.firstIndex(where: { $0.id == a.id }) {
            accounts[i].username = a.username
            if !a.displayName.isEmpty { accounts[i].displayName = a.displayName }
            if a.tenantId != nil { accounts[i].tenantId = a.tenantId }
            return accounts[i]
        }
        var a = a
        if accounts.contains(where: { $0.colour == a.colour }) { a.colour = AccountColour.next(after: accounts.map(\.colour)) }
        accounts.append(a)
        if defaultAccountId == nil { defaultAccountId = a.id }
        return a
    }

    /// Removes the account; the default moves to the first remaining one. Returns the removed account (to wipe).
    @discardableResult
    public mutating func remove(_ id: String) -> Account? {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = accounts.remove(at: i)
        if defaultAccountId == id { defaultAccountId = accounts.first?.id }
        return removed
    }

    public mutating func move(_ id: String, by offset: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(accounts.count - 1, i + offset))
        guard i != j else { return }
        accounts.insert(accounts.remove(at: i), at: j)
    }

    public mutating func setColour(_ c: AccountColour, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].colour = c
    }

    public mutating func makeDefault(_ id: String) {
        if accounts.contains(where: { $0.id == id }) { defaultAccountId = id }
    }

    // Sealed persistence: the JSON never touches disk in the clear.
    public func sealed(with cipher: PayloadCipher) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys   // default date strategy: exact round-trip
        return try cipher.seal(enc.encode(self))
    }

    public static func open(_ data: Data, with cipher: PayloadCipher) throws -> AccountRegistry {
        let dec = JSONDecoder()
        return try dec.decode(AccountRegistry.self, from: cipher.open(data))
    }
}

// MARK: - Migration from the single-account build

public enum AccountMigration {
    /// What to do with the registry at launch.
    public enum Plan: Equatable, Sendable {
        /// A registry exists and opened: use it.
        case use(AccountRegistry)
        /// No registry yet, an MSAL account is signed in: it becomes account #1 (same id → same store + keys).
        case migrate(AccountRegistry)
        /// No registry and nobody signed in: start empty.
        case empty
        /// The registry file exists but can't be opened (locked / key unavailable). Don't migrate, don't overwrite;
        /// run as the legacy single account until it opens.
        case unreadable
    }

    /// - Parameters:
    ///   - sealedFile: the registry file's bytes, nil when the file doesn't exist.
    ///   - open: opens the bytes (throws when locked or the key is wrong).
    ///   - legacy: the signed-in MSAL account of the single-account build (home-account identifier + UPN).
    public static func plan(sealedFile: Data?, open: (Data) throws -> AccountRegistry,
                            legacy: (homeAccountId: String, username: String)?) -> Plan {
        if let sealedFile {
            guard let reg = try? open(sealedFile) else { return .unreadable }
            // A registry saved while signed out gains the legacy account (nothing to lose, nothing to resync).
            if reg.accounts.isEmpty, let legacy { return .migrate(migrated(legacy)) }
            return .use(reg)
        }
        guard let legacy else { return .empty }
        return .migrate(migrated(legacy))
    }

    static func migrated(_ legacy: (homeAccountId: String, username: String)) -> AccountRegistry {
        let a = Account(id: legacy.homeAccountId, tenantId: Account.tenant(fromHomeAccountId: legacy.homeAccountId),
                        username: legacy.username, colour: .teal)
        return AccountRegistry(accounts: [a], defaultAccountId: a.id)
    }
}

// MARK: - Sign-in errors that mean "not this tenant (yet)"

public enum AccountAuthError: Equatable, Sendable {
    /// Registration is single-tenant (AzureADMyOrg): other organisations can't sign in until the owner changes it.
    case appNotEnabledForOrganisation
    /// The tenant requires an administrator to consent to the app.
    case adminConsentRequired(tenant: String, url: URL)
    case other(String)

    public static let notEnabledMessage = "This app isn't enabled for other organisations yet."

    /// Maps an MSAL / Entra error text to what the user should see. Pure: no retry, no workaround (ACCOUNTS.md §5).
    public static func classify(_ text: String, tenant: String?, clientId: String) -> AccountAuthError {
        let codes = Set(text.matches(of: /AADSTS(\d+)/).map { String($0.1) })
        if !codes.isDisjoint(with: ["50020", "700016", "50194"]) { return .appNotEnabledForOrganisation }
        if !codes.isDisjoint(with: ["65001", "90094", "90095"]) {
            let t = tenant ?? "organizations"
            return .adminConsentRequired(tenant: t, url: adminConsentURL(tenant: t, clientId: clientId))
        }
        return .other(text)
    }

    public static func adminConsentURL(tenant: String, clientId: String) -> URL {
        var c = URLComponents(string: "https://login.microsoftonline.com/")!
        c.path = "/\(tenant)/adminconsent"
        c.queryItems = [URLQueryItem(name: "client_id", value: clientId)]
        return c.url!
    }

    public var message: String {
        switch self {
        case .appNotEnabledForOrganisation:
            Self.notEnabledMessage + " Its administrator has to allow sign-ins from other organisations first."
        case .adminConsentRequired(_, let url):
            "An administrator of this organisation needs to approve niivo mail before you can add this account. "
                + "Send them this link: \(url.absoluteString)"
        case .other(let s): s
        }
    }
}

// MARK: - Per-account label tenant (ACCOUNTS.md A9)

extension MIPMetadata {
    /// The tenant a service parses labels against: the account's own tenant when the service belongs to an account,
    /// otherwise the default account's (the compatibility shim). A non-default account must always pass its tenant.
    public static func tenant(forAccount accountTenant: String?) -> String? {
        accountTenant?.lowercased() ?? homeTenantId
    }
}
