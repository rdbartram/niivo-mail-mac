import Foundation
import CalendarCore
import MailCore
import ProtectedContent

/// Drives Purview decryption for protected mail / calendar bodies and publishes the result into
/// `ProtectedBodyStore.shared`, which `ProtectedBodyView(state:)` renders. Not a view.
///
/// OFF by default (`ProtectedContentDecryptEnabled`, a UserDefaults key, so an MDM managed preference can set it
/// too). The user switches it on in Mail Settings → "Decrypt protected messages on this Mac (MIP SDK)" (docs/MIP.md).
/// When off, items show "unavailable — open in Outlook".
///
/// Rules:
///  * decrypted HTML goes through `HTMLSanitizer` and is held only in `ProtectedBodyStore` (memory); it is never
///    handed to `MailStore`, `ReaderState.body`, the search index or AI. On BYOD the MIP licence cache is in memory too.
///  * licence rights go to `LicenceRightsStore.shared`, which the compliance engine reads via `ItemRightsProvider`
///    (`AppModel.compliance = CachedLabelPolicyEngine(itemRights: LicenceRightsStore.shared)`). `onRightsChanged`
///    lets the readers re-derive their `ContentPolicy` BEFORE the body is published, so copy / print / reply /
///    forward / capture never run on the stale label policy.
///  * logs are content-free: lengths, rights names, rights source, token-call counts and error codes (`[MIP] …`).
///
/// Wiring: AppModel creates it in `goLive` and calls `reset()` on sign-out, lock, and when the setting goes off.
/// MailReader's `ReaderBody` (reading pane and message windows) calls `open(itemId:mailbox:)` where
/// `p.bodyIsProtected`.
@MainActor
final class ProtectedContentCoordinator {
    static let enabledKey = "ProtectedContentDecryptEnabled"
    /// Managed Macs only, and only if the admin allows it: encrypted on-disk licence cache for offline reading.
    static let encryptedCacheKey = "ProtectedContentAllowEncryptedLicenceCache"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let service: ProtectedContentService
    /// PURVIEW-HOOK: same MSAL silent path for the policy-sync token (UnifiedPolicy.User.Read, admin-consented).
    private let mipTokens: MIPTokenProvider
    /// PURVIEW-HOOK: rpmsg probe for unlabelled protected invites (lists /events/{id}/attachments).
    private let probeFetcher: RPMSGFetcher
    private let opener: ProtectedItemOpener
    private let userEmail: @MainActor () -> String?
    private let store: ProtectedBodyStore
    private let rights: LicenceRightsStore
    private var inFlight: Set<String> = []
    /// Bumped by `reset()`: a decrypt that finishes after a reset (sign-out / lock / switched off) is dropped.
    private var generation = 0
    /// Called with the item id once its licence rights are recorded, before its body state is published.
    var onRightsChanged: (@MainActor (String) -> Void)?
    /// Interactive RMS consent / sign-in ("Grant access…"); the item is retried afterwards.
    var grantAccess: (@MainActor () async throws -> Void)?

    init(clientId: String, isManagedDevice: Bool = false,
         graphToken: @escaping @Sendable () async throws -> String,
         mipToken: @escaping @Sendable ([String]) async throws -> String,
         userEmail: @escaping @MainActor () -> String?,
         store: ProtectedBodyStore = .shared, rights: LicenceRightsStore = .shared) {
        let cache = MIPCacheConfig.resolve(isManagedDevice: isManagedDevice,
                                           policyAllowsEncryptedCache: UserDefaults.standard.bool(forKey: Self.encryptedCacheKey))
        let persistent = cache.mode == .onDiskEncrypted
            ? AppConfig.supportDir.appending(path: "mip", directoryHint: .isDirectory) : nil
        let service = ProtectedContentService(configuration: .init(clientId: clientId, cache: cache,
                                                                   persistentStateDirectory: persistent))
        self.service = service
        opener = .live(service: service, fetcher: RPMSGFetcher(graphToken: graphToken),
                       tokens: { req in try await mipToken(req.msalScopes) })
        self.userEmail = userEmail
        mipTokens = { req in try await mipToken(req.msalScopes) }
        probeFetcher = RPMSGFetcher(graphToken: graphToken)
        self.store = store
        self.rights = rights
    }

    /// Fetch + decrypt one protected item and publish its state. Idempotent while in flight and once decided
    /// (decrypted / not permitted) for this session; failures are re-attempted on the next open.
    func open(itemId: String, mailbox: String = "me", kind: RPMSGFetcher.Kind = .message, force: Bool = false) {
        guard Self.isEnabled else {
            store.states[itemId] = .unavailable(reason: "Decrypting protected messages is turned off on this Mac "
                                                + "(Settings → Mail → Protected messages). Open it in Outlook.")
            return
        }
        if !force {
            switch store.states[itemId] {
            case .decrypted?, .notPermitted?: return
            default: break
            }
        }
        guard !inFlight.contains(itemId) else { return }
        guard let user = userEmail(), !user.isEmpty else {
            store.states[itemId] = .unavailable(reason: "Sign in again to open protected content.")
            return
        }
        inFlight.insert(itemId)
        store.states[itemId] = .decrypting
        let opener = opener, gen = generation, tag = Self.tag(itemId)
        Self.log("\(tag) open (\(kind.rawValue), \(mailbox == "me" ? "own" : "other") mailbox)")
        Task { [weak self] in
            let outcome = await opener.open(itemId: itemId, mailbox: mailbox, kind: kind, userEmail: user,
                                            log: { Self.log("\(tag) \($0)") })
            self?.finish(itemId, outcome, generation: gen)
        }
    }

    /// "Try again".
    func retry(itemId: String, mailbox: String = "me", kind: RPMSGFetcher.Kind = .message) {
        open(itemId: itemId, mailbox: mailbox, kind: kind, force: true)
    }

    /// "Grant access…": interactive RMS consent / sign-in, then retry.
    func requestAccess(itemId: String, mailbox: String = "me", kind: RPMSGFetcher.Kind = .message) {
        guard let grantAccess else { retry(itemId: itemId, mailbox: mailbox, kind: kind); return }
        Task { [weak self] in
            do { try await grantAccess() } catch {
                let ns = error as NSError
                Self.log("\(Self.tag(itemId)) interactive RMS sign-in failed: \(ns.domain) \(ns.code)")
            }
            self?.retry(itemId: itemId, mailbox: mailbox, kind: kind)
        }
    }

    private func finish(_ id: String, _ outcome: ProtectedOpenOutcome, generation gen: Int) {
        guard gen == generation else { Self.log("\(Self.tag(id)) dropped (reset while in flight)"); return }
        inFlight.remove(id)
        Self.log("\(Self.tag(id)) \(outcome.logSummary)")
        // Rights first, then the readers' policy, then the body: never shown under the stale label policy.
        ProtectedItemOpener.record(outcome, itemId: id, in: rights)
        onRightsChanged?(id)
        store.states[id] = Self.state(for: outcome)
    }

    static func state(for outcome: ProtectedOpenOutcome) -> ProtectedBodyState {
        switch outcome {
        case .decrypted(let html, _): return .decrypted(html: HTMLSanitizer.sanitize(html).html)
        case .notPermitted: return .notPermitted
        case .failed(let f): return state(for: f)
        }
    }

    static func state(for f: ProtectedOpenFailure) -> ProtectedBodyState {
        switch f {
        case .bridgeUnavailable:
            return .unavailable(reason: "Protected-message support (MIP SDK) isn't installed in this build. Open it in Outlook.")
        case .retryable:
            return .retryable(reason: "Couldn't reach Rights Management or download the protected content. Check your connection and try again.")
        case .needsAccess:
            return .needsAccess(reason: "niivo mail needs your permission to use Azure Rights Management.")
        case .claimsChallenge:
            return .unavailable(reason: "Your organisation requires an extra sign-in for this item. Open it in Outlook.")
        case .accessDenied:
            return .unavailable(reason: "Your account can't use Rights Management. Open it in Outlook.")
        case .unsupportedBody:
            return .unavailable(reason: "This protected message uses a format the app can't show yet. Open it in Outlook.")
        case .notFound:
            return .unavailable(reason: "The protected content wasn't found on the server. Open it in Outlook.")
        case .other(let code):
            return .retryable(reason: "Couldn't open this protected item here (\(code)).")
        }
    }

    /// Sign-out / lock / wipe / switched off: drop decrypted bodies, licence rights and the MIP context (and its
    /// state directory). In-flight results are discarded.
    func reset() {
        generation += 1
        inFlight.removeAll()
        store.states.removeAll()
        ProtectedAttachmentStore.shared.removeAll()   // PURVIEW-HOOK
        PurviewPolicy.shared.reset()   // PURVIEW-HOOK: policy settings go with the session
        rights.removeAll()
        let s = service
        Task.detached { s.shutdown() }
    }

    /// Short, non-reversible tag so the log lines of one item correlate without logging its Graph id.
    static func tag(_ id: String) -> String {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return "item#" + String(h, radix: 16)
    }

    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data("[MIP] \(line)\n".utf8))
    }

    /// Unlabelled encrypted mail (Encrypt-only, Do Not Forward): its label policy says "not protected", but Graph
    /// lists the rpmsg payload as an attachment. Treat it as protected, VIEW only, until the licence arrives.
    static func detectingRPMSG(_ p: ContentPolicy, attachments: [AttachmentInfo]) -> ContentPolicy {
        guard !p.bodyIsProtected, ProtectedPolicy.hasRPMSG(attachments.map { ($0.name, $0.contentType) }) else { return p }
        return ProtectedPolicy.awaitingLicence(p)
    }
}


// MARK: - PURVIEW-HOOK: label policy provider + protected-message attachments

extension ProtectedContentCoordinator {
    /// The Policy SDK seam for `PurviewPolicy` (nil without a signed-in user; the bridge is checked when loading).
    func labelPolicyProvider() -> (any LabelPolicyProvider)? {
        guard let user = userEmail(), !user.isEmpty else { return nil }
        return MIPLabelPolicyProvider(service: service, userEmail: user, tokens: mipTokens)
    }

    /// Second pass over the item's rpmsg for its attachments, on demand ("Show protected attachments"). Memory only.
    func openAttachments(itemId: String, mailbox: String = "me", kind: RPMSGFetcher.Kind = .message) {
        let store = ProtectedAttachmentStore.shared
        guard Self.isEnabled, let user = userEmail(), !user.isEmpty else { store.states[itemId] = .failed("turned-off"); return }
        if case .loading? = store.states[itemId] { return }
        store.states[itemId] = .loading
        let gen = generation, opener = opener, service = service, tokens = mipTokens, tag = Self.tag(itemId)
        Task {
            do {
                let (data, _) = try await opener.fetch(itemId, mailbox, kind)
                let a = try await service.decryptAttachments(rpmsg: data, userEmail: user, tokens: tokens)
                guard gen == generation else { return }
                FileHandle.standardError.write(Data("[MIP] item#\(tag) attachments \(a.items.count), rights \(a.rights.names.joined(separator: ","))\n".utf8))
                store.states[itemId] = .loaded(a)
            } catch {
                guard gen == generation else { return }
                let code = ProtectedItemOpener.classify(error).code
                FileHandle.standardError.write(Data("[MIP] item#\(tag) attachments failed: \(code)\n".utf8))
                store.states[itemId] = .failed(code)
            }
        }
    }

    /// Unlabelled meeting: does Graph list a message.rpmsg on it (Encrypt-Only / Do Not Forward invite)? One GET of
    /// attachment names/content types, only when decryption is on. Hit → `ProtectedAttachmentStore.rpmsgEvents`.
    func probeEvent(itemId: String, mailbox: String) async {
        let store = ProtectedAttachmentStore.shared
        guard Self.isEnabled, store.probedEvents.insert(itemId).inserted else { return }
        if (try? await probeFetcher.listsRPMSG(id: itemId, mailbox: mailbox, kind: .event)) == true {
            store.rpmsgEvents.insert(itemId)
        }
    }
}
