import Foundation
import CalendarCore

// MARK: - Open one protected item: fetch rpmsg → decrypt → licence rights → outcome

/// Why a protected item couldn't be shown. Content-free (safe to log via `code`).
public enum ProtectedOpenFailure: Sendable, Equatable {
    /// The bridge dylib isn't built / bundled (or has the wrong ABI). Nothing was fetched.
    case bridgeUnavailable
    /// Network, timeout, Graph throttling / 5xx: worth a retry.
    case retryable(code: String)
    /// The RMS token couldn't be acquired silently (consent / interaction required) or RMS refused the token.
    case needsAccess(code: String)
    /// Conditional Access (incl. label-based CA) demands an extra sign-in; not wired yet → Outlook.
    case claimsChallenge
    /// The account can't use Rights Management at all (no licence / service off for the user).
    case accessDenied
    /// RTF body or another format we can't render.
    case unsupportedBody
    /// Graph returned no rpmsg (attachment list and MIME) for an item we believed protected.
    case notFound
    case other(code: String)

    public var code: String {
        switch self {
        case .bridgeUnavailable: "bridge-unavailable"
        case .retryable(let c): "retryable(\(c))"
        case .needsAccess(let c): "needs-access(\(c))"
        case .claimsChallenge: "claims-challenge"
        case .accessDenied: "access-denied"
        case .unsupportedBody: "unsupported-body"
        case .notFound: "no-rpmsg-found"
        case .other(let c): "other(\(c))"
        }
    }
}

public enum ProtectedOpenOutcome: Sendable, Equatable {
    /// `html` is NOT sanitised yet (callers run it through `HTMLSanitizer`). Memory only; never persist, index or log it.
    case decrypted(html: String, rights: UsageRights)
    /// The licence was evaluated but grants no VIEW (or the SDK said no-permission). `rights` is the explicit set,
    /// usually empty, recorded so policy doesn't fall back to the label's broader rights.
    case notPermitted(rights: UsageRights)
    case failed(ProtectedOpenFailure)

    /// Content-free one-liner for logs.
    public var logSummary: String {
        switch self {
        case .decrypted(let h, let r): "decrypt ok, html \(h.utf8.count) bytes, rights \(r.names.joined(separator: ","))"
        case .notPermitted(let r): "no VIEW right (rights \(r.names.isEmpty ? "none" : r.names.joined(separator: ",")))"
        case .failed(let f): "failed: \(f.code)"
        }
    }
}

/// The testable core of `ProtectedContentCoordinator` (app). The network and the MIP bridge are injected, so
/// CoreSelfTest drives it with a stub; `live(...)` wires the real `RPMSGFetcher` + `ProtectedContentService`.
/// Never touches disk; logs only lengths, rights names, rights source, token-call counts and error codes.
public struct ProtectedItemOpener: Sendable {
    public typealias Fetch = @Sendable (_ id: String, _ mailbox: String, _ kind: RPMSGFetcher.Kind) async throws
        -> (data: Data, path: RPMSGFetcher.Path)
    public typealias Decrypt = @Sendable (_ rpmsg: Data, _ userEmail: String) async throws -> DecryptedContent

    public var isAvailable: @Sendable () -> Bool
    public var fetch: Fetch
    public var decrypt: Decrypt

    public init(isAvailable: @escaping @Sendable () -> Bool, fetch: @escaping Fetch, decrypt: @escaping Decrypt) {
        self.isAvailable = isAvailable; self.fetch = fetch; self.decrypt = decrypt
    }

    public static func live(service: ProtectedContentService, fetcher: RPMSGFetcher,
                            tokens: @escaping MIPTokenProvider) -> ProtectedItemOpener {
        ProtectedItemOpener(
            isAvailable: { if case .success = ProtectedContentService.bridgeStatus() { true } else { false } },
            fetch: { id, mb, kind in try await fetcher.fetch(id: id, mailbox: mb, kind: kind) },
            decrypt: { data, user in try await service.decrypt(rpmsg: data, userEmail: user, tokens: tokens) })
    }

    /// Bridge check first (no Graph call when the SDK isn't there), then fetch, then decrypt.
    public func open(itemId: String, mailbox: String = "me", kind: RPMSGFetcher.Kind = .message, userEmail: String,
                     log: @Sendable (String) -> Void = { _ in }) async -> ProtectedOpenOutcome {
        guard isAvailable() else {
            log("bridge unavailable, nothing fetched")
            return .failed(.bridgeUnavailable)
        }
        let payload: Data
        do {
            let (data, path) = try await fetch(itemId, mailbox, kind)
            log("fetch ok via \(path.rawValue), rpmsg \(data.count) bytes")
            payload = data
        } catch {
            let f = Self.classify(error)
            log("fetch failed: \(f.code)")
            return .failed(f)
        }
        do {
            let c = try await decrypt(payload, userEmail)
            log("licence: rights \(c.rights.names.joined(separator: ",")), source \(c.rightsSource.rawValue), "
                + "body \(c.bodyByteCount) bytes, token calls \(c.tokenCalls)")
            return Self.outcome(for: c)
        } catch {
            if case .noPermission? = error as? MIPBridgeError { return .notPermitted(rights: []) }
            return .failed(Self.classify(error))
        }
    }

    /// VIEW (OWNER normalises to everything, so it includes VIEW) → show; otherwise not permitted.
    public static func outcome(for c: DecryptedContent) -> ProtectedOpenOutcome {
        let r = c.rights.normalized
        return r.contains(.view) ? .decrypted(html: c.html, rights: r) : .notPermitted(rights: r)
    }

    /// Records the licence rights an outcome established (the `ItemRightsProvider` the policy engine reads).
    /// Failures record nothing: the item stays on its label rights (protected → body hidden anyway).
    public static func record(_ outcome: ProtectedOpenOutcome, itemId: String, in store: LicenceRightsStore) {
        switch outcome {
        case .decrypted(_, let r), .notPermitted(let r): store.set(r, for: itemId)
        case .failed: break
        }
    }

    public static func classify(_ error: Error) -> ProtectedOpenFailure {
        if let e = error as? MIPBridgeError {
            switch e {
            case .bridgeUnavailable: return .bridgeUnavailable
            case .network, .timeout: return .retryable(code: e.description)
            case .auth, .consent: return .needsAccess(code: e.description)
            case .claimsChallenge: return .claimsChallenge
            case .accessDenied: return .accessDenied
            case .unsupportedBody: return .unsupportedBody
            case .noPermission: return .other(code: e.description)   // handled as notPermitted by `open`
            case .internalError: return .retryable(code: e.description)
            default: return .other(code: e.description)
            }
        }
        if let f = error as? RPMSGFetcher.FetchError {
            switch f {
            case .notFound: return .notFound
            case .http(let c, _) where c == 401: return .needsAccess(code: f.description)
            case .http(let c, _) where c == 0 || c == 408 || c == 429 || c >= 500: return .retryable(code: f.description)
            case .http: return .other(code: f.description)
            }
        }
        if error is URLError { return .retryable(code: "url-\((error as! URLError).code.rawValue)") }
        // Token provider errors (e.g. MSAL interaction required) surface here from the Graph fetch.
        return .needsAccess(code: "token")
    }
}

// MARK: - Unlabelled encrypted mail (Encrypt-only / Do Not Forward without a label)

public enum ProtectedPolicy {
    /// True when an item's attachment list carries the rpmsg payload (IRM / Purview Message Encryption).
    public static func hasRPMSG(_ attachments: [(name: String, contentType: String)]) -> Bool {
        attachments.contains { RPMSG.isRPMSGAttachment(name: $0.name, contentType: $0.contentType) }
    }

    /// Policy for an item we've detected as encrypted but whose licence isn't known yet: protected, VIEW only, not
    /// cacheable, capture blocked. Once decrypted, the engine's per-item licence rights replace this.
    public static func awaitingLicence(_ p: ContentPolicy) -> ContentPolicy {
        guard !p.bodyIsProtected else { return p }
        var q = p
        q.bodyIsProtected = true
        q.rights = .viewOnly
        q.rightsSource = .encryptedUnknown
        q.allowOfflineDetails = false
        q.preventScreenCapture = true
        return q
    }
}
