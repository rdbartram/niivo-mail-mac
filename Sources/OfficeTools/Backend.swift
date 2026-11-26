import Foundation
import CryptoKit
import CalendarCore
import MailCore
import TrustCore

// MARK: - Configuration (argv)

public struct ServerConfig: Sendable {
    public init() {}
    public enum Mode: Sendable, Equatable { case fixtures, graph(tokenFile: String) }
    public var mode: Mode = .fixtures
    public var allowTriage = true
    public var allowDrafts = true
    /// `--ai-access`. Fixtures: sets the level outright (tests). Graph: can only tighten the loaded TrustPolicy.
    public var aiAccessOverride: TrustAIAccess?
    /// `--ai-max-priority`. Graph: can only tighten (lower) the default.
    public var aiMaxPriorityOverride: Int?
    /// Extra shared/delegated mailboxes to open (graph mode; fixtures always open their three mailboxes).
    public var extraMailboxes: [String] = []
    public var auditLogPath: String?
    /// ACCOUNTS-HOOK: the one account this server serves (docs/ACCOUNTS.md §4). Tool results are tagged with it; a
    /// call naming another account is refused. Default: the default account.
    public var accountId: String = AccountScope.defaultId

    public static let usage = """
    usage: OfficeMCP [--fixtures | --token-file <path>] [--allow-triage[=true|false]] [--read-only]
                     [--ai-access off|metadata|labels] [--ai-max-priority <n>] [--mailbox <address>]...
                     [--audit-log <path>] [--account <id>]
      --fixtures            synthetic mailboxes + calendars (default)
      --token-file <path>   Microsoft Graph with a delegated access token read from <path> on every call (UNVERIFIED)
      --allow-triage=false  remove mail_flag / mail_mark_read / mail_snooze
      --read-only           remove triage tools AND mail_create_draft
      --ai-access           off | metadata | labels (fixtures: sets it; Graph: may only tighten the org policy)
    """

    public static func parse(_ args: [String]) throws -> ServerConfig {
        var c = ServerConfig()
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < args.count else { throw ConfigError("\(name) needs a value") }
            return args[i]
        }
        func bool(_ s: String) throws -> Bool {
            switch s.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: throw ConfigError("expected true|false, got \(s)")
            }
        }
        while i < args.count {
            let a = args[i]
            let (name, inline): (String, String?) = {
                if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                    return (String(a[..<eq]), String(a[a.index(after: eq)...]))
                }
                return (a, nil)
            }()
            switch name {
            case "--fixtures": c.mode = .fixtures
            case "--token-file": c.mode = .graph(tokenFile: try inline ?? value(name))
            case "--allow-triage": c.allowTriage = try inline.map(bool) ?? true
            case "--read-only": c.allowTriage = false; c.allowDrafts = false
            case "--ai-access":
                switch (try inline ?? value(name)).lowercased() {
                case "off": c.aiAccessOverride = .off
                case "metadata", "metadataonly", "metadata-only": c.aiAccessOverride = .metadataOnly
                case "labels", "followlabels", "follow-labels": c.aiAccessOverride = .followLabels
                default: throw ConfigError("--ai-access must be off|metadata|labels")
                }
            case "--ai-max-priority":
                guard let n = Int(try inline ?? value(name)) else { throw ConfigError("--ai-max-priority needs an integer") }
                c.aiMaxPriorityOverride = n
            case "--mailbox": c.extraMailboxes.append(try inline ?? value(name))
            case "--audit-log": c.auditLogPath = try inline ?? value(name)
            case "--account": c.accountId = try inline ?? value(name)   // ACCOUNTS-HOOK
            case "-h", "--help": throw ConfigError("help")
            default: throw ConfigError("unknown argument \(a)")
            }
            i += 1
        }
        return c
    }
}

public struct ConfigError: Error { public let message: String; init(_ m: String) { message = m } }

// MARK: - Backend (mail sync + calendar service + policy)

/// Everything a tool needs. The MailStore is ALWAYS in-memory, also in Graph mode: the server must never open the
/// app's on-disk store, because `MailSync.syncNow()` flushes the outbox and would deliver queued sends.
public final class Backend: Sendable {
    let sync: MailSync
    let store: MailStore
    let calendar: CalendarService
    let engine: CachedLabelPolicyEngine
    let calendars: [CalendarInfo]
    let me: EmailAddress
    let internalDomains: Set<String>
    let identities: [SendIdentity]
    public let trust: TrustAIAccess
    public let aiMaxPriority: Int
    public let policySources: [String]
    /// Fixtures only: lets main() report the sent count (must stay 0) on shutdown.
    public let fixtureMail: FixtureMailService?
    public let isFixtures: Bool
    /// ACCOUNTS-HOOK: the account this backend's store, engine and tokens belong to.
    public let accountId: String

    init(sync: MailSync, store: MailStore, calendar: CalendarService, engine: CachedLabelPolicyEngine,
                 calendars: [CalendarInfo], me: EmailAddress, identities: [SendIdentity], trust: TrustAIAccess,
                 aiMaxPriority: Int, policySources: [String], fixtureMail: FixtureMailService?,
                 accountId: String = AccountScope.defaultId) {
        self.accountId = accountId
        self.sync = sync; self.store = store; self.calendar = calendar; self.engine = engine
        self.calendars = calendars; self.me = me; self.identities = identities; self.trust = trust
        self.aiMaxPriority = aiMaxPriority; self.policySources = policySources; self.fixtureMail = fixtureMail
        self.isFixtures = fixtureMail != nil
        let domain = me.address.split(separator: "@").last.map { String($0).lowercased() }
        self.internalDomains = domain.map { [$0] } ?? []
    }

    public static func make(_ c: ServerConfig) async throws -> Backend {
        let mailService: MailService
        let calService: CalendarService
        var fixture: FixtureMailService?
        var mailboxes: [String]
        var identities: [SendIdentity] = []
        var trust: TrustAIAccess
        var maxPriority = 2
        var sources: [String]

        switch c.mode {
        case .fixtures:
            let f = FixtureMailService()
            fixture = f
            mailService = f
            calService = FixtureCalendarService()
            mailboxes = FixtureMailService.mailboxes
            identities = [
                SendIdentity(address: FixtureMailService.sharedMailbox, name: "Support",
                             mailbox: FixtureMailService.sharedMailbox, mode: .sendAs),
                SendIdentity(address: FixtureMailService.principal, name: "Sam Rivera", mailbox: "me", mode: .sendOnBehalf),
            ]
            // Fixtures stand in for a managed Mac; the flag sets the level outright so tests can cover every value.
            trust = c.aiAccessOverride ?? TrustPolicy.managedDefault.aiAccess
            if let p = c.aiMaxPriorityOverride { maxPriority = p }
            sources = ["fixtures"]
        case .graph(let path):
            // UNVERIFIED end to end: coded against the same Graph clients the app uses, never run against a tenant.
            let token: @Sendable () async throws -> String = {
                try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Our tenant decides which msip_labels count (other organisations' labels are ignored, as in the app).
            if let t = try? String(contentsOfFile: path, encoding: .utf8) {
                MIPMetadata.homeTenantId = MIPMetadata.tenantId(fromAccessToken: t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            mailService = GraphMailService(token: token)
            calService = GraphCalendarService(token: token, delegatedMailboxes: c.extraMailboxes)
            mailboxes = ["me"] + c.extraMailboxes
            identities = c.extraMailboxes.map { SendIdentity(address: $0, name: "", mailbox: $0, mode: .sendAs) }
            // Organisation policy (managed prefs → BYOD/managed defaults). No tenant-signed file is fetched here
            // (UNVERIFIED: the app owns that download). argv can only tighten.
            let loaded = PolicyLoader(prefs: CFManagedPreferences(), pinnedKeys: PinnedPolicyKeys(keys: [:]))
                .load(tenantJSON: nil, tenantSignature: nil)
            trust = loaded.policy.aiAccess
            if let o = c.aiAccessOverride { trust = min(trust, o) }
            if let p = c.aiMaxPriorityOverride { maxPriority = min(maxPriority, p) }
            sources = loaded.sources.filter(\.applied).map(\.source.rawValue)
        }

        // Labels unavailable → engine empty and every labelled item becomes "unknown" → hidden (fail closed).
        let labels = try? await calService.sensitivityLabels()
        let engine = CachedLabelPolicyEngine(labels: labels ?? [], synced: labels != nil)

        let store = try MailStore(url: nil, key: SymmetricKey(size: .bits256))
        // SEARCH: graph + semantic index are maintained by the store's write paths, so attach them before the sync.
        let meEarly = (try? await mailService.me()) ?? EmailAddress(name: "", address: "")
        let meDomain = MailDomains.domain(of: meEarly.address)
        try store.enableCommGraph(owners: Set([meEarly.address] + mailboxes.filter { $0 != "me" }).subtracting([""]),
                                  internalDomains: meDomain.isEmpty ? [] : [meDomain])
        let org = AIOrgAccess(trustRawValue: trust.rawValue)
        let embedGate = AIGatePolicy(engine: engine, cloudAccess: org, onDeviceAccess: org, aiMaxPriority: maxPriority)
        let semantic = store.enableSemanticIndex(embedder: AppleSentenceEmbedder(), windowDays: 30,
                                                 policy: { m, mb in embedGate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        // STORIES: related-message clustering under the same on-device content rule (metadata only otherwise).
        let stories = try store.enableStories(gate: { m, mb in embedGate.exposure(m, mailbox: mb, tier: .onDevice) == .content })
        var settings = MailSettings(defaultWindow: .days(30), sharedDefaultWindow: .days(30), identities: identities)
        settings.pinnedMailboxes = Set(mailboxes.filter { $0 != "me" })
        let sync = MailSync(service: mailService, store: store, compliance: engine, mailboxes: mailboxes,
                            settings: settings, onChange: { _ in })
        await sync.syncNow()
        for mb in mailboxes where mb != "me" { await sync.openMailbox(mb) }
        if fixture != nil {
            while (try? semantic.catchUp(maxItems: 512)) ?? 0 > 0 {}
            while (try? stories.catchUp(maxItems: 512)) ?? 0 > 0 {}
        } else {
            Task.detached(priority: .background) {
                while (try? semantic.catchUp(maxItems: 128)) ?? 0 > 0 {}
                while (try? stories.catchUp(maxItems: 128)) ?? 0 > 0 {}
            }
        }

        let me = (try? await mailService.me()) ?? EmailAddress(name: "", address: "")
        let calendars = (try? await calService.listCalendars()) ?? []
        return Backend(sync: sync, store: store, calendar: calService, engine: engine, calendars: calendars, me: me,
                       identities: identities, trust: trust, aiMaxPriority: maxPriority, policySources: sources,
                       fixtureMail: fixture, accountId: c.accountId)
    }

    var mailboxes: [String] { get async { await sync.mailboxes } }
}
