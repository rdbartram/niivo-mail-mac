import Foundation
import CalendarCore
import TrustCore
@preconcurrency import MSAL

// TRUST-WIRING: the app side of revocation / offline grace / wipe group / per-account wipe. All decisions are made by
// TrustCore (`SessionEnforcer`, `TrustEnforcement`, `AccountWipeLayout`, self-tested in CoreSelfTest); this file only
// feeds it MSAL/Graph results and carries out the returned action. Live mode only: fixtures never reach it.

// MARK: - MSAL error → TrustCore AuthFailure

extension AuthFailure {
    /// `AuthFailure(error:)` scans every string for AADSTS codes; this adds the fields from MSAL's own userInfo
    /// constants (MSALError.h: MSALOAuthErrorKey, MSALOAuthSubErrorKey, MSALHTTPResponseCodeKey, MSALSTSErrorCodesKey),
    /// so classification doesn't depend on guessed key strings. MSAL's interaction-required code (-50002) without an
    /// OAuth error becomes "interaction_required" (a prompt, never transient).
    init(msal error: Error) {
        self.init(error: error)
        let ns = error as NSError
        let info = ns.userInfo
        if let o = info[MSALOAuthErrorKey] as? String { oauthError = o }
        if let s = info[MSALOAuthSubErrorKey] as? String { subError = s }
        if let n = info[MSALHTTPResponseCodeKey] as? NSNumber { httpStatus = n.intValue }
        else if let t = info[MSALHTTPResponseCodeKey] as? String, let n = Int(t) { httpStatus = n }
        if let codes = info[MSALSTSErrorCodesKey] as? [Any] {
            for c in codes {
                if let n = (c as? NSNumber)?.intValue ?? (c as? String).flatMap({ Int($0) }), !aadstsCodes.contains(n) {
                    aadstsCodes.append(n)
                }
            }
        }
        if ns.domain == MSALErrorDomain, ns.code == -50002, oauthError == nil { oauthError = "interaction_required" }
        // MSAL replayed a cached server error (throttling cache) instead of asking Entra again: not an independent
        // signal, so it can't be a second revocation strike. Treated as transient.
        if (info[MSALThrottlingCacheHitKey] as? NSNumber)?.boolValue == true || (info[MSALThrottlingCacheHitKey] as? Bool) == true {
            aadstsCodes = []; oauthError = nil; subError = nil; httpStatus = nil; isNetworkError = true
        }
    }

    /// The user closed the sign-in sheet (MSALErrorUserCanceled): not a session signal.
    static func isUserCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == MSALErrorDomain && ns.code == -50005
    }
}

// MARK: - AppModel: feed + act

extension AppModel {
    /// Live (or between live sessions). `.loading` with an Auth = the launch probe, before any store opens.
    private var enforcing: Bool { mode == .live || mode == .needsSignIn || (mode == .loading && auth != nil) }

    /// Interactive sign-in failed for an account MSAL can name: that result is authoritative (disabled / deleted /
    /// unassigned on a tenant + client seen before → that account's data is wiped; 50173 only locks).
    func recordInteractiveSignInFailure(_ error: Error) {
        let ns = error as NSError
        guard !AuthFailure.isUserCancel(error), let id = ns.userInfo[MSALHomeAccountIdKey] as? String,
              let tenant = Account.tenant(fromHomeAccountId: id) else { return }
        sessionClientId = AppConfig.load().clientId ?? ""
        trust.enforcer.recordFailure(AuthFailure(msal: error), path: .interactive, account: id, tenantId: tenant,
                                     clientId: sessionClientId)
        enforce(account: id)
    }

    /// Every Auth that can refresh tokens reports here (the active one and the inactive-account probes).
    func wireSession(_ auth: Auth) {
        auth.onSession = { [weak self, weak auth] ev in
            guard let self, let auth else { return }
            self.handleSession(ev, auth: auth)
        }
    }

    func handleSession(_ ev: Auth.SessionEvent, auth: Auth) {
        guard enforcing, let tenant = auth.tenantId, !sessionClientId.isEmpty else { return }
        switch ev {
        case .success(let a):
            trust.enforcer.recordSuccess(account: a, tenantId: tenant, clientId: sessionClientId)
            // Successes arrive with every Graph request: only re-evaluate when something is pending, or once a minute.
            let due = lastEnforced.map { Date().timeIntervalSince($0) > 60 } ?? true
            if trust.sessionLock != nil || due { enforce(account: a) }
        case .failure(let a, let error, let path):
            let c = trust.enforcer.recordFailure(AuthFailure(msal: error), path: path, account: a, tenantId: tenant,
                                                 clientId: sessionClientId)
            FileHandle.standardError.write(Data("[Trust] session \(path == .interactive ? "interactive" : "silent") → \(c)\n".utf8))
            enforce(account: a)
        }
    }

    /// Evaluates one account and carries out the action. Inactive accounts can only be wiped (their lock / prompt
    /// applies when they become active).
    func enforce(account a: String) {
        guard enforcing else { return }
        lastEnforced = Date()
        let (_, action) = trust.enforcer.evaluate(account: a, policy: trust.policy,
                                                  tombstoned: trust.wipeLayout.isTombstoned(account: a))
        let active = a == auth?.account?.homeAccountId?.identifier
        switch action {
        case .wipe(.account(let id), let reason):
            wipeAccount(id, reason: reason)
        case .wipe(.device, let reason):
            // Not produced today (no device-level wipe trigger exists); kept total: every known account.
            for id in Set(trust.enforcer.knownAccounts + [a]) { wipeAccount(id, reason: reason) }
        case .lock(let reason):
            if active { enterSessionLock(reason) }
        case .reauthPrompt:
            if active { leaveSessionLock(); AppLifecycle.shared.sessionNeedsInteraction() }
        case .none:
            if active { leaveSessionLock() }
        }
    }

    private func enterSessionLock(_ reason: String) {
        guard trust.sessionLock != reason else { return }
        let wasHidden = trust.hidesContent
        trust.sessionLock = reason
        FileHandle.standardError.write(Data("[Trust] session locked: \(reason)\n".utf8))
        if !wasHidden { suspendForLock() }
        trust.keyring?.lock()   // keys leave memory; reopening needs user presence again
    }

    private func leaveSessionLock() {
        guard trust.sessionLock != nil else { return }
        trust.sessionLock = nil
        FileHandle.standardError.write(Data("[Trust] session unlocked\n".utf8))
        if !trust.hidesContent { Task { await self.resumeAfterUnlock() } }
    }

    // MARK: Probes

    /// One silent calendar-token refresh, bounded so an unreachable network doesn't hold up launch. The result reaches
    /// the enforcer through `onSession` (a late result is still recorded).
    func probe(_ auth: Auth, timeout: Duration = .seconds(10)) async {
        final class Once: @unchecked Sendable {
            private let lock = NSLock(); private var done = false
            func fire(_ c: CheckedContinuation<Void, Never>) {
                let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
                if first { c.resume() }
            }
        }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task { @MainActor in _ = try? await auth.token(); once.fire(c) }
            Task { try? await Task.sleep(for: timeout); once.fire(c) }
        }
    }

    /// Every other cached MSAL account refreshes silently, so its own grace clock (and any revocation of it) is known
    /// without opening its data. Then every known account is evaluated: past its offline deadline → wiped.
    func probeInactiveAccounts() async {
        guard mode == .live || mode == .needsSignIn, let auth else { return }
        lastInactiveProbe = Date()
        let config = AppConfig.load()
        let active = auth.account?.homeAccountId?.identifier
        let others = auth.cachedAccounts().compactMap { $0.homeAccountId?.identifier }.filter { $0 != active }
        for id in others {
            guard let other = try? Auth(config: config, accountId: id), other.account != nil else { continue }
            wireSession(other)
            await probe(other)
        }
        for id in Set(trust.enforcer.knownAccounts + others) where id != active { enforce(account: id) }
    }

    /// TrustModel's 60 s tick: second-strike / reconnect probe while session-locked, wipe-group cadence, grace.
    func enforcementTick() async {
        guard mode == .live, let auth, let a = auth.account?.homeAccountId?.identifier, !enforcementTickInFlight else { return }
        enforcementTickInFlight = true
        defer { enforcementTickInFlight = false }
        if let l = trust.sessionLock, l != "wipedAwaitingSignIn" { await probe(auth) }
        if trust.enforcer.isWipeGroupCheckDue(account: a, policy: trust.policy) { _ = await checkWipeGroup(auth) }
        enforce(account: a)
        if lastInactiveProbe.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true { await probeInactiveAccounts() }
    }

    // MARK: Wipe group

    /// Only what checkMemberGroups needs (delegated GroupMember.Read.All, admin consent), so a tenant that hasn't
    /// consented the Groups section's conversation scope still gets its wipe-group check.
    static let wipeGroupScopes = ["https://graph.microsoft.com/GroupMember.Read.All"]

    /// `POST /me/checkMemberGroups`. Any failure is "no decision" (never a wipe, never a session signal), logged.
    /// Returns the ids Graph returned.
    @discardableResult
    func checkWipeGroup(_ auth: Auth) async -> [String]? {
        guard let gid = trust.policy.wipeGroupId, !gid.isEmpty, let a = auth.account?.homeAccountId?.identifier else { return nil }
        var returned: [String]?
        do {
            let tok = try await auth.silentToken(scopes: Self.wipeGroupScopes)
            var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/checkMemberGroups")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = WipeGroupCheck.requestBody(wipeGroupId: gid)
            let (d, r) = try await URLSession.shared.data(for: req)
            if (r as? HTTPURLResponse)?.statusCode == 200 { returned = WipeGroupCheck.memberGroupIds(fromResponse: d) }
        } catch { returned = nil }
        if returned == nil {
            FileHandle.standardError.write(Data("[Trust] wipe-group check failed (no decision; needs GroupMember.Read.All consent?)\n".utf8))
        }
        trust.enforcer.recordWipeGroupCheck(account: a, returned: returned)
        return returned
    }

    // MARK: Tombstones

    /// At launch, before any store opens: finish interrupted wipes (accounts found from the tombstone file names; the
    /// registry is still sealed).
    func resumePendingWipes() {
        for safe in trust.wipeLayout.tombstonedAccounts {
            guard let ex = try? trust.accountWipeExecutor(safe, extra: [msalRemover(safeName: safe)]),
                  ex.tombstone?.completed == false else { continue }
            _ = try? ex.resumeIfNeeded()
        }
    }

    /// After an interactive sign-in of an account with a tombstone: clear it only when the server confirms the user is
    /// not revoked (a fresh Graph call succeeds and, if the policy sets one, the wipe-group check is negative).
    func confirmAccessAfterSignIn(_ auth: Auth) async -> Bool {
        guard let a = auth.account?.homeAccountId?.identifier, trust.wipeLayout.isTombstoned(account: a) else { return true }
        var graphOK = false
        if let tok = try? await auth.token() {
            var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id")!)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let (_, r) = try? await URLSession.shared.data(for: req) { graphOK = (r as? HTTPURLResponse)?.statusCode == 200 }
        }
        var groupOK = true
        if let gid = trust.policy.wipeGroupId, !gid.isEmpty {
            let m = await checkWipeGroup(auth)
            groupOK = m != nil && !WipeGroupCheck.shouldWipe(wipeGroupId: gid, returned: m)
        }
        guard graphOK, groupOK, let ex = try? trust.accountWipeExecutor(a, extra: [msalRemover(account: a)]) else { return false }
        if ex.tombstone?.completed == false { _ = try? ex.resumeIfNeeded() }   // never clear an unfinished wipe
        let cleared = ex.clearTombstone(freshSignInSucceeded: true, serverConfirmedNotRevoked: true)
        if cleared { FileHandle.standardError.write(Data("[Trust] tombstone cleared after sign-in\n".utf8)); enforce(account: a) }
        return cleared
    }

    /// "Sign in again" on the session-lock screen: interactive reauthentication, then (tombstone) confirmation.
    func signInAgainForSession() async {
        await AppLifecycle.shared.reauthenticate(interactive: true)
        guard let auth, let a = auth.account?.homeAccountId?.identifier else { return }
        if trust.wipeLayout.isTombstoned(account: a) { _ = await confirmAccessAfterSignIn(auth) }
        enforce(account: a)
    }

    // MARK: Wipe

    private func msalRemover(account id: String) -> CryptoShredding {
        ClosureShredder { [weak self] in
            MainActor.assumeIsolated {
                let a = self?.auth ?? (try? Auth(config: AppConfig.load()))
                a?.removeCached(accountId: id)
            }
        }
    }

    private func msalRemover(safeName: String) -> CryptoShredding {
        ClosureShredder { [weak self] in
            MainActor.assumeIsolated {
                guard let a = self?.auth ?? (try? Auth(config: AppConfig.load())) else { return }
                for c in a.cachedAccounts() {
                    if let id = c.homeAccountId?.identifier, AccountStoreNaming.safeName(id) == safeName { a.removeCached(accountId: id) }
                }
            }
        }
    }

    /// Per-account wipe. The active account's live session is torn down first; another account's data, keys and
    /// MSAL account stay. Tombstone first (inside the executor), so a crash mid-way resumes at the next launch.
    func wipeAccount(_ id: String, reason: String) {
        guard !wipingAccounts.contains(id) else { return }
        wipingAccounts.insert(id)
        defer { wipingAccounts.remove(id) }
        let isActive = id == auth?.account?.homeAccountId?.identifier || (id == Auth.activeAccountId && auth?.account == nil)
        let title = accounts.registry.account(id)?.title ?? (isActive ? auth?.username : nil)
        FileHandle.standardError.write(Data("[Trust] wipe (\(isActive ? "active" : "inactive") account): \(reason)\n".utf8))
        if isActive { tearDownSessionForWipe() }
        do {
            let r = try trust.accountWipeExecutor(id, extra: [msalRemover(account: id)]).wipe(reason: reason)
            FileHandle.standardError.write(Data("[Trust] wipe done: paths=\(r.removedPaths) keychain=\(r.removedKeychainItems) shredded=\(r.shreddedVaults) failures=\(r.failures.count)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[Trust] wipe: tombstone write failed (data deleted anyway)\n".utf8))
        }
        trust.keyring?.forget(account: id)
        trust.enforcer.forget(account: id)
        accounts.forget(id)   // registry entry; if the registry is still sealed, `load` drops it later
        if isActive {
            finishWipedSession()
            let next = accounts.accounts.first { $0.id != id && !trust.wipeLayout.isTombstoned(account: $0.id) }
            trust.showWipe(.init(reason: reason, at: Date(), account: title, nextAccountId: next?.id, nextAccountTitle: next?.title))
        } else if mail.started {
            mail.toast(MailToast(text: "Your organisation removed \(title ?? "another account")'s data from this Mac", symbol: "trash.slash"))
        }
    }

    /// Wiped screen → the sign-in screen (or the other account the user picked).
    func continueAfterWipe(with next: String?) async {
        trust.dismissWipeNotice()
        if let next { await switchAccount(to: next) }
    }
}

extension TrustModel {
    static func wipeReasonText(_ code: String, policy: TrustPolicy) -> String {
        switch code {
        case "userDisabled": "Your account was disabled by your organisation."
        case "userNotFound", "userDeleted": "Your account no longer exists in your organisation."
        case "appNotFound": "Your organisation removed niivo mail from its directory."
        case "userNotAssigned": "Your account is no longer assigned to niivo mail."
        case "wipeGroupMember": "Your organisation asked for its data to be removed from this Mac."
        case "offlineTooLong": "niivo mail couldn't confirm your access for longer than your organisation allows (\(policy.offlineWipeDays) days)."
        default: code
        }
    }

    static func sessionLockText(_ code: String, policy: TrustPolicy) -> String {
        switch code {
        case "reauth:grantRevoked": "Your sign-in was revoked, for example after a password change. Sign in again to continue."
        case "reauth:revocationUnconfirmed": "Your organisation may have revoked your access. Sign in again to continue."
        case "offlineGraceExceeded": "niivo mail hasn't been able to confirm your access for more than \(policy.offlineGraceDays) days. Connect to the internet and sign in again."
        case "wipedAwaitingSignIn": "This account's data was removed from this Mac. Sign in again so your organisation can confirm your access."
        default: "Sign in again to continue."
        }
    }
}
