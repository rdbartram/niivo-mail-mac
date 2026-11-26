import Foundation

// MARK: Error input

/// Plain-value description of an MSAL/Entra/Graph failure (TrustCore can't import MSAL). Build it with
/// `AuthFailure(error:)` or field by field. Never put server messages here verbatim into logs: they can contain the
/// user's address. Classification only uses codes.
public struct AuthFailure: Sendable, Equatable {
    public var domain: String?
    public var code: Int?
    /// OAuth `error` (e.g. "invalid_grant", "interaction_required").
    public var oauthError: String?
    public var subError: String?
    public var aadstsCodes: [Int]
    public var httpStatus: Int?
    /// Raw `WWW-Authenticate` header from a Graph 401 (CAE claims challenge).
    public var wwwAuthenticate: String?
    public var isNetworkError: Bool

    public init(domain: String? = nil, code: Int? = nil, oauthError: String? = nil, subError: String? = nil,
                aadstsCodes: [Int] = [], httpStatus: Int? = nil, wwwAuthenticate: String? = nil, isNetworkError: Bool = false) {
        self.domain = domain; self.code = code; self.oauthError = oauthError; self.subError = subError
        self.aadstsCodes = aadstsCodes; self.httpStatus = httpStatus; self.wwwAuthenticate = wwwAuthenticate
        self.isNetworkError = isNetworkError
    }

    /// Extracts codes from an `NSError` (MSAL puts the server description, which contains "AADSTSnnnnn:", in
    /// userInfo). The MSAL userInfo key names below ("MSALOAuthErrorKey", "MSALOAuthSubErrorKey",
    /// "MSALHTTPResponseCodeKey") are UNVERIFIED against the MSAL ObjC headers; every string value is scanned for
    /// AADSTS codes anyway, so classification doesn't depend on them.
    public init(error: Error) {
        let ns = error as NSError
        var strings: [String] = [ns.localizedDescription]
        func walk(_ v: Any) {
            if let s = v as? String { strings.append(s) }
            else if let e = v as? NSError { strings.append(e.localizedDescription); e.userInfo.values.forEach(walk) }
            else if let d = v as? [String: Any] { d.values.forEach(walk) }
        }
        ns.userInfo.values.forEach(walk)
        self.init(domain: ns.domain, code: ns.code,
                  oauthError: ns.userInfo["MSALOAuthErrorKey"] as? String,
                  subError: ns.userInfo["MSALOAuthSubErrorKey"] as? String,
                  aadstsCodes: Self.aadsts(in: strings.joined(separator: " ")),
                  httpStatus: (ns.userInfo["MSALHTTPResponseCodeKey"] as? NSNumber)?.intValue
                      ?? (ns.userInfo["MSALHTTPResponseCodeKey"] as? String).flatMap(Int.init),
                  isNetworkError: ns.domain == NSURLErrorDomain)
    }

    public static func aadsts(in s: String) -> [Int] {
        var out: [Int] = []
        var rest = Substring(s)
        while let r = rest.range(of: "AADSTS") {
            let digits = rest[r.upperBound...].prefix { $0.isNumber }
            if let n = Int(digits), !out.contains(n) { out.append(n) }
            rest = rest[r.upperBound...]
        }
        return out
    }
}

// MARK: Classification

public enum RevocationReason: String, Sendable, Codable, CaseIterable {
    case userDisabled, userNotFound, userDeleted, appNotFound, userNotAssigned
    case wipeGroupMember, offlineTooLong
}

public enum ReauthReason: String, Sendable, Codable {
    case mfaRequired, deviceNotCompliant, deviceNotManaged, conditionalAccess, claimsChallenge
    case signInFrequency, tokenExpired, interactionRequired, unauthorized
    /// 50173/50133: grant or session revoked — also a plain password change/reset. Lock and sign in again; a
    /// following interactive failure with disabled/deleted/unassigned is what wipes.
    case grantRevoked
    /// A "not found / not assigned" code on a tenant + client that has never signed in successfully: most likely a
    /// wrong tenant or client id, so never a wipe.
    case configuration
    /// First revoked result on the silent-refresh path; a wipe needs a second one ≥ 60 s later.
    case revocationUnconfirmed
}

public enum SessionErrorClass: Sendable, Equatable {
    case transient
    case reauth(ReauthReason)
    /// Tenant says this user/session must no longer have data → wipe.
    case revoked(RevocationReason)
}

public struct AADSTSEntry: Sendable {
    public let code: Int
    public let outcome: SessionErrorClass
    public let verified: Bool
    public let source: String
}

/// The explicit allowlist. Only codes listed here with a `.revoked` outcome ever trigger a wipe; anything unknown
/// falls to reauth/transient. Checked against Microsoft Learn on 2026-11-19.
public enum AADSTSCatalog {
    static let ref = "https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes"
    public static let entries: [AADSTSEntry] = [
        // "The provided grant has expired due to it being revoked… The user might have changed or reset their
        // password." Revoke-sessions alone just forces sign-in; admins pair it with disable for real incidents.
        .init(code: 50173, outcome: .reauth(.grantRevoked), verified: true,
              source: "https://learn.microsoft.com/troubleshoot/entra/entra-id/app-integration/error-code-aadsts50173-grant-expired-revoked"),
        .init(code: 50057, outcome: .revoked(.userDisabled), verified: true,
              source: "https://learn.microsoft.com/troubleshoot/entra/entra-id/app-integration/error-code-aadsts50057-user-account-is-disabled"),
        // 50034 / 500341 / 700016 / 50105 also fit a wrong tenant or client id: they only wipe once the same
        // tenant + client has signed in successfully before (see `misconfigurationGuarded`).
        .init(code: 50034, outcome: .revoked(.userNotFound), verified: true, source: ref),
        .init(code: 500341, outcome: .revoked(.userDeleted), verified: true,
              source: "https://learn.microsoft.com/viva/goals/integration-aad-errors"),
        // App not found in the tenant (enterprise app deleted). Also a client-id/tenant misconfiguration.
        .init(code: 700016, outcome: .revoked(.appNotFound), verified: true, source: ref),
        .init(code: 50105, outcome: .revoked(.userNotAssigned), verified: true, source: ref),
        .init(code: 53000, outcome: .reauth(.deviceNotCompliant), verified: true, source: ref),
        // "Your device is required to be compliant to access this resource" — product troubleshooting page only.
        .init(code: 530002, outcome: .reauth(.deviceNotCompliant), verified: true,
              source: "https://learn.microsoft.com/viva/goals/integration-aad-errors"),
        // Not in the main reference table; documented on product troubleshooting pages.
        .init(code: 530003, outcome: .reauth(.deviceNotManaged), verified: true,
              source: "https://learn.microsoft.com/viva/goals/integration-aad-errors"),
        .init(code: 53003, outcome: .reauth(.conditionalAccess), verified: true, source: ref),
        .init(code: 50076, outcome: .reauth(.mfaRequired), verified: true, source: ref),
        .init(code: 50079, outcome: .reauth(.mfaRequired), verified: true, source: ref),
        .init(code: 50078, outcome: .reauth(.mfaRequired), verified: true, source: ref),
        .init(code: 70043, outcome: .reauth(.signInFrequency), verified: true, source: ref),
        // Seen in the reference table (direct page read) but not returned by the Learn MCP search: UNVERIFIED.
        .init(code: 700082, outcome: .reauth(.tokenExpired), verified: false, source: ref),
        .init(code: 50133, outcome: .reauth(.grantRevoked), verified: true, source: ref),
    ]
    /// Codes that only count as revoked after a prior successful sign-in for the same tenant + client.
    public static let misconfigurationGuarded: Set<Int> = [50034, 700016, 50105, 500341]
    static let byCode: [Int: SessionErrorClass] = Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0.outcome) })
}

public enum SessionErrorClassifier {
    /// Revoked codes beat reauth codes beat claims challenge beat generic OAuth errors; network/5xx/429 are transient.
    /// `hadPriorSuccess`: this tenant + client has refreshed successfully before (defaults to false = never wipe on
    /// the misconfiguration-guarded codes).
    public static func classify(_ f: AuthFailure, hadPriorSuccess: Bool = false) -> SessionErrorClass {
        let known: [SessionErrorClass] = f.aadstsCodes.compactMap { code in
            guard let c = AADSTSCatalog.byCode[code] else { return nil }
            if !hadPriorSuccess, AADSTSCatalog.misconfigurationGuarded.contains(code) { return .reauth(.configuration) }
            return c
        }
        if let r = known.first(where: { if case .revoked = $0 { true } else { false } }) { return r }
        if let r = known.first { return r }
        if isClaimsChallenge(f) { return .reauth(.claimsChallenge) }
        if f.isNetworkError { return .transient }
        if let s = f.httpStatus, s == 429 || s >= 500 { return .transient }
        switch f.oauthError {
        case "invalid_grant", "interaction_required", "login_required", "consent_required": return .reauth(.interactionRequired)
        case "temporarily_unavailable", "server_error": return .transient
        default: break
        }
        if f.httpStatus == 401 { return .reauth(.unauthorized) }
        return .transient
    }

    /// CAE: Graph 401 with `WWW-Authenticate: Bearer … error="insufficient_claims", claims="…"`.
    /// (https://learn.microsoft.com/en-us/entra/identity-platform/claims-challenge)
    public static func isClaimsChallenge(_ f: AuthFailure) -> Bool {
        guard let h = f.wwwAuthenticate?.lowercased() else { return false }
        return h.contains("insufficient_claims")
    }

    /// The base64 claims request to hand back to MSAL (`claimsRequest`) for the interactive/silent retry.
    public static func claims(from wwwAuthenticate: String) -> String? {
        guard let r = wwwAuthenticate.range(of: "claims=\"") else { return nil }
        let rest = wwwAuthenticate[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

// MARK: Wipe group

/// Graph `POST /me/checkMemberGroups` with `{"groupIds":[wipeGroupId]}` (transitive; delegated permission
/// GroupMember.Read.All). TrustCore only builds the body and judges the response.
/// https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups?view=graph-rest-1.0
public enum WipeGroupCheck {
    public static func requestBody(wipeGroupId: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["groupIds": [wipeGroupId]])) ?? Data()
    }
    public static func memberGroupIds(fromResponse data: Data) -> [String]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o["value"] as? [String]
    }
    /// `returned` nil = the call failed or wasn't made → no decision (never wipe on a failed check).
    public static func shouldWipe(wipeGroupId: String?, returned: [String]?) -> Bool {
        guard let g = wipeGroupId?.lowercased(), !g.isEmpty, let returned else { return false }
        return returned.contains { $0.lowercased() == g }
    }
}

// MARK: Offline grace clock

public enum GraceStatus: Sendable, Equatable {
    case ok(offlineSeconds: TimeInterval)
    case locked
    case wipe
}

/// Persists the last successful token refresh and a high-water mark of the latest time seen, so winding the system
/// clock back doesn't extend the grace period.
public struct OfflineGraceClock: Sendable {
    static let lastKey = "trust.grace.lastSuccess", highKey = "trust.grace.highWater"
    public let store: TrustStateStore
    public let now: TrustNow
    public init(store: TrustStateStore, now: @escaping TrustNow = { Date() }) { self.store = store; self.now = now }

    private func load(_ k: String) -> Date? {
        store.data(forKey: k).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    }
    private func put(_ d: Date, _ k: String) { store.set(try? JSONEncoder().encode(d), forKey: k) }

    public var lastSuccess: Date? { load(Self.lastKey) }

    /// Tolerated backwards clock movement (NTP corrections) before the clock is treated as tampered.
    public static let backwardsTolerance: TimeInterval = 300

    /// A successful refresh proves we're online with a token the tenant accepted: re-anchor both marks to now, so a
    /// clock that was wound forward and then back can't freeze the grace period.
    public func recordSuccessfulRefresh() {
        let t = now()
        put(t, Self.lastKey)
        put(t, Self.highKey)
    }

    /// Successful refresh for a tenant + client: also remembers the pair (misconfiguration guard) and clears any
    /// pending revocation strike.
    public func recordSuccessfulRefresh(tenantId: String, clientId: String) {
        recordSuccessfulRefresh()
        store.set(Data("1".utf8), forKey: Self.seenKey(tenantId: tenantId, clientId: clientId))
        store.set(nil, forKey: RevocationGuard.strikeKey)
    }

    static func seenKey(tenantId: String, clientId: String) -> String {
        "trust.seen.\(tenantId.lowercased()).\(clientId.lowercased())"
    }

    public func hasPriorSuccess(tenantId: String, clientId: String) -> Bool {
        store.data(forKey: Self.seenKey(tenantId: tenantId, clientId: clientId)) != nil
    }

    /// No recorded success yet → locked (an online sign-in is needed before cached data is served; deleting the
    /// store therefore locks rather than resets the clock). Wipe is checked before lock.
    /// The clock running behind the latest time seen (beyond tolerance) → locked until the next successful refresh.
    public func status(policy: TrustPolicy) -> GraceStatus {
        let t = now()
        let high = load(Self.highKey) ?? .distantPast
        if t < high.addingTimeInterval(-Self.backwardsTolerance) { return .locked }
        if t > high { put(t, Self.highKey) }
        guard let last = lastSuccess else { return .locked }
        if t < last.addingTimeInterval(-Self.backwardsTolerance) { return .locked }
        let offline = t.timeIntervalSince(last)
        if offline > Double(policy.offlineWipeDays) * 86400 { return .wipe }
        if offline > Double(policy.offlineGraceDays) * 86400 { return .locked }
        return .ok(offlineSeconds: offline)
    }
}

// MARK: Revocation guard

public enum AuthPath: Sendable { case silentRefresh, interactive }

/// Stateful wrapper around the classifier:
/// - misconfiguration guard: guarded codes count as revoked only for a tenant + client seen succeeding before;
/// - two strikes on the silent-refresh path: a revoked result there must repeat, ≥ `minimumInterval` after the
///   first, before it is reported as `.revoked`; a single one returns `.reauth(.revocationUnconfirmed)` (locks).
///   A non-revoked, non-transient result (or a success) clears the strike; transient results are neutral.
/// - the interactive path is authoritative: one revoked result is enough.
/// Wipe-group hits and the offline wipe deadline bypass this and stay immediate (see `SessionHealth.decide`).
public struct RevocationGuard: Sendable {
    static let strikeKey = "trust.revocation.firstStrike"
    public let store: TrustStateStore
    public let now: TrustNow
    public let minimumInterval: TimeInterval
    public init(store: TrustStateStore, now: @escaping TrustNow = { Date() }, minimumInterval: TimeInterval = 60) {
        self.store = store; self.now = now; self.minimumInterval = minimumInterval
    }

    public func evaluate(_ f: AuthFailure, path: AuthPath, tenantId: String, clientId: String) -> SessionErrorClass {
        let prior = OfflineGraceClock(store: store, now: now).hasPriorSuccess(tenantId: tenantId, clientId: clientId)
        let c = SessionErrorClassifier.classify(f, hadPriorSuccess: prior)
        guard case .revoked = c else {
            if c != .transient { store.set(nil, forKey: Self.strikeKey) }
            return c
        }
        if path == .interactive { store.set(nil, forKey: Self.strikeKey); return c }
        let t = now()
        if let d = store.data(forKey: Self.strikeKey), let first = try? JSONDecoder().decode(Date.self, from: d) {
            if t.timeIntervalSince(first) >= minimumInterval { store.set(nil, forKey: Self.strikeKey); return c }
            return .reauth(.revocationUnconfirmed)
        }
        store.set(try? JSONEncoder().encode(t), forKey: Self.strikeKey)
        return .reauth(.revocationUnconfirmed)
    }
}

// MARK: Decision

public enum TrustDecision: Sendable, Equatable {
    case ok
    case restricted([String])
    case locked(String)
    case wipe(String)
}

/// Combines every signal into one decision. Precedence: wipe > locked > restricted > ok.
public enum SessionHealth {
    /// - Parameters:
    ///   - lastError: classification of the latest token/Graph failure since the last success (nil = none).
    ///   - wipeGroupMembers: checkMemberGroups result (nil = not checked / failed).
    ///   - tombstoned: a previous wipe hasn't been cleared by a fresh sign-in + server confirmation.
    public static func decide(policy: TrustPolicy, lastError: SessionErrorClass?, wipeGroupMembers: [String]?,
                              grace: GraceStatus, posture: PostureDecision, tombstoned: Bool) -> TrustDecision {
        if case .revoked(let r)? = lastError { return .wipe(r.rawValue) }
        if WipeGroupCheck.shouldWipe(wipeGroupId: policy.wipeGroupId, returned: wipeGroupMembers) {
            return .wipe(RevocationReason.wipeGroupMember.rawValue)
        }
        if grace == .wipe { return .wipe(RevocationReason.offlineTooLong.rawValue) }
        if tombstoned { return .locked("wipedAwaitingSignIn") }
        if case .block(let r) = posture { return .locked("posture:" + r.joined(separator: ",")) }
        if grace == .locked { return .locked("offlineGraceExceeded") }
        if case .reauth(let r)? = lastError { return .locked("reauth:\(r.rawValue)") }
        if case .restrict(let r) = posture { return .restricted(r) }
        return .ok
    }
}
