import Foundation
import CryptoKit
import CalendarCore
import TrustCore

/// The wiring layer the app calls (TrustCore/Enforcement.swift): per-account session state, decision → action, per-account
/// wipe, signed policy delivery. No network, no real Keychain, temp directories only.
@MainActor
func runTrustEnforcementTests() async {
    final class Clock: @unchecked Sendable {
        var t: Date
        init(_ t: Date) { self.t = t }
        var now: TrustNow { { [unowned self] in self.t } }
        func advance(days: Double) { t = t.addingTimeInterval(days * 86400) }
        func advance(seconds: Double) { t = t.addingTimeInterval(seconds) }
    }
    final class FakeKeychain: SecretDeleting, @unchecked Sendable {
        var deleted: [KeychainItemRef] = []
        func delete(_ item: KeychainItemRef) throws { deleted.append(item) }
    }
    final class Calls: @unchecked Sendable { var msalRemoved: [String] = [] }
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "trust-enforce-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    let t0 = ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z")!
    let tenant = "tid-a", client = "client-1"
    func fail(_ codes: [Int], oauth: String? = "invalid_grant", http: Int? = 400) -> AuthFailure {
        AuthFailure(oauthError: oauth, aadstsCodes: codes, httpStatus: http)
    }

    // MARK: Decision → action
    section("Trust enforcement: decision → action")
    do {
        typealias A = TrustAction
        let rows: [(TrustDecision, A, String)] = [
            (.ok, .none, "ok → nothing"),
            (.restricted(["x"]), .none, "restricted → nothing (posture handled by TrustModel)"),
            (.wipe("userDisabled"), .wipe(scope: .account("A"), reason: "userDisabled"), "revoked → wipe THIS account"),
            (.wipe("wipeGroupMember"), .wipe(scope: .account("A"), reason: "wipeGroupMember"), "wipe group → account wipe"),
            (.wipe("offlineTooLong"), .wipe(scope: .account("A"), reason: "offlineTooLong"), "offline deadline → account wipe"),
            (.locked("reauth:grantRevoked"), .lock("reauth:grantRevoked"), "50173/50133 → lock, not wipe"),
            (.locked("reauth:revocationUnconfirmed"), .lock("reauth:revocationUnconfirmed"), "first silent strike → lock"),
            (.locked("offlineGraceExceeded"), .lock("offlineGraceExceeded"), "grace exceeded → lock"),
            (.locked("wipedAwaitingSignIn"), .lock("wipedAwaitingSignIn"), "tombstone → lock (sign-in screen)"),
            (.locked("reauth:mfaRequired"), .reauthPrompt("mfaRequired"), "MFA → prompt, content stays"),
            (.locked("reauth:interactionRequired"), .reauthPrompt("interactionRequired"), "interaction required → prompt"),
            (.locked("reauth:configuration"), .reauthPrompt("configuration"), "misconfiguration → prompt, never wipe"),
            (.locked("reauth:claimsChallenge"), .reauthPrompt("claimsChallenge"), "CAE claims → prompt (silent retry path)"),
        ]
        for (d, want, msg) in rows { check(TrustEnforcement.action(for: d, account: "A") == want, msg) }
        // No account signal ever maps to a device-wide wipe.
        let all: [TrustDecision] = RevocationReason.allCases.map { .wipe($0.rawValue) } + rows.map(\.0)
        check(!all.contains { TrustEnforcement.action(for: $0, account: "A") == .wipe(scope: .device, reason: "x") }
              && all.allSatisfy { if case .wipe(.device, _) = TrustEnforcement.action(for: $0, account: "A") { false } else { true } },
              "account signals never yield a device-scope wipe")
        check(TrustAccountNaming.safeName("0a-b.c/d+e@f") == AccountStoreNaming.safeName("0a-b.c/d+e@f")
              && AccountWipeLayout.vaultSlots(account: "x@y.z").contains("\(AccountStoreNaming.safeName("x@y.z"))/mail-cache"),
              "TrustCore naming matches CalendarCore's store / keyring naming")
    }

    // MARK: 50173 / revocation through the enforcer
    section("Trust enforcement: revocation, 50173, two strikes, per account")
    do {
        let clk = Clock(t0)
        let e = SessionEnforcer(store: InMemoryTrustStore(), now: clk.now)
        e.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        e.recordSuccess(account: "B", tenantId: tenant, clientId: client)
        for path in [AuthPath.silentRefresh, .interactive] {
            let c = e.recordFailure(fail([50173]), path: path, account: "A", tenantId: tenant, clientId: client)
            let a = e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action
            check(c == .reauth(.grantRevoked) && a == .lock("reauth:grantRevoked"), "AADSTS50173 (\(path)) locks, never wipes")
            clk.advance(seconds: 120)
            _ = e.recordFailure(fail([50173]), path: path, account: "A", tenantId: tenant, clientId: client)
            check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:grantRevoked"),
                  "repeated 50173 (\(path)) still only locks")
        }
        check(e.recordFailure(fail([50133]), path: .interactive, account: "A", tenantId: tenant, clientId: client) == .reauth(.grantRevoked)
              && e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:grantRevoked"),
              "AADSTS50133 locks too")
        _ = e.recordFailure(fail([], oauth: "interaction_required"), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:grantRevoked"),
              "50173 then a plain interaction_required: still locked (never downgraded to a prompt)")
        e.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .none, "a fresh token clears the lock")
        _ = e.recordFailure(fail([50057]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        _ = e.recordFailure(fail([50076]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:revocationUnconfirmed"),
              "first revocation strike then MFA required: still locked")
        e.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        // Silent path: first strike locks, second ≥ 60 s later wipes A only.
        _ = e.recordFailure(fail([50057]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:revocationUnconfirmed"),
              "disabled user, first silent strike → lock")
        clk.advance(seconds: 30)
        _ = e.recordFailure(fail([50057]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("reauth:revocationUnconfirmed"),
              "second strike < 60 s later → still only lock")
        clk.advance(seconds: 40)
        _ = e.recordFailure(fail([50057]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .wipe(scope: .account("A"), reason: "userDisabled"),
              "second strike ≥ 60 s → wipe A")
        check(e.evaluate(account: "B", policy: .byodDefault, tombstoned: false).action == .none, "… B unaffected")
        _ = e.recordFailure(fail([50105]), path: .interactive, account: "B", tenantId: tenant, clientId: client)
        check(e.evaluate(account: "B", policy: .byodDefault, tombstoned: false).action == .wipe(scope: .account("B"), reason: "userNotAssigned"),
              "interactive unassigned (seen tenant + client) → wipe B at once")
        let cC = e.recordFailure(fail([50034]), path: .interactive, account: "C", tenantId: "other", clientId: client)
        let aC = e.evaluate(account: "C", policy: .byodDefault, tombstoned: false).action
        check(cC == .reauth(.configuration) && aC == .lock("offlineGraceExceeded"),
              "never-seen tenant + client: user-not-found is configuration (locked: never signed in), never a wipe")
        // Transient keeps the previous state; network-only failures never escalate.
        let e2 = SessionEnforcer(store: InMemoryTrustStore(), now: clk.now)
        e2.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        _ = e2.recordFailure(AuthFailure(isNetworkError: true), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e2.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .none, "network error → no action")
        _ = e2.recordFailure(fail([], oauth: "interaction_required"), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e2.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .reauthPrompt("interactionRequired"),
              "interaction_required → prompt (content stays)")
        _ = e2.recordFailure(AuthFailure(isNetworkError: true), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        check(e2.lastError(account: "A") == .reauth(.interactionRequired), "a later transient failure keeps the prompt")
        check(e2.evaluate(account: "A", policy: .byodDefault, tombstoned: true).action == .lock("wipedAwaitingSignIn"),
              "tombstoned account → locked until sign-in")
    }

    // MARK: Offline grace, per account
    section("Trust enforcement: offline grace → lock → wipe, per account")
    do {
        let clk = Clock(t0)
        let store = InMemoryTrustStore()
        let e = SessionEnforcer(store: store, now: clk.now)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("offlineGraceExceeded"),
              "no recorded refresh yet → locked (fail closed; the app refreshes before the first evaluation)")
        e.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        check(e.knownAccounts == ["A"], "a refreshed account is remembered for launch-time checks")
        clk.advance(days: 10)
        e.recordSuccess(account: "B", tenantId: tenant, clientId: client)
        clk.advance(days: 2)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .lock("offlineGraceExceeded"),
              "A: 12 days without a refresh (BYOD grace 3) → lock")
        check(e.evaluate(account: "B", policy: .byodDefault, tombstoned: false).action == .none, "B refreshed 2 days ago → fine")
        clk.advance(days: 2.5)
        check(e.evaluate(account: "A", policy: .byodDefault, tombstoned: false).action == .wipe(scope: .account("A"), reason: "offlineTooLong"),
              "A: past offlineWipeDays (14) → wipe A")
        check(e.evaluate(account: "B", policy: .byodDefault, tombstoned: false).action == .lock("offlineGraceExceeded"),
              "B: 4.5 days → lock only (its own clock)")
        check(e.evaluate(account: "A", policy: .managedDefault, tombstoned: false).action == .lock("offlineGraceExceeded"),
              "managed policy (14 / 60 days) on the same clock → lock, not wipe")
        e.forget(account: "A")
        check(e.knownAccounts == ["B"] && e.clock("A").lastSuccess == nil, "after A's wipe its grace anchor is gone, B stays known")
        // Persisted per account (a relaunch keeps the clock).
        let reopened = SessionEnforcer(store: store, now: clk.now)
        check(reopened.clock("B").lastSuccess != nil && reopened.clock("A").lastSuccess == nil, "grace clocks persist per account")
        // Clock wound back doesn't extend grace.
        clk.advance(days: -10)
        check(reopened.evaluate(account: "B", policy: .byodDefault, tombstoned: false).action == .lock("offlineGraceExceeded"),
              "system clock wound back → locked, not extended")
        // Success writes are throttled but never mask a pending error.
        let ws = InMemoryTrustStore(), wclk = Clock(t0)
        let w = SessionEnforcer(store: ws, now: wclk.now)
        w.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        wclk.advance(seconds: 100)
        w.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        check(w.clock("A").lastSuccess == t0, "successes within 5 min aren't re-written")
        _ = w.recordFailure(fail([50076]), path: .silentRefresh, account: "A", tenantId: tenant, clientId: client)
        wclk.advance(seconds: 10)
        w.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        check(w.clock("A").lastSuccess == t0.addingTimeInterval(110) && w.lastError(account: "A") == nil,
              "a success after an error is always recorded and clears it")
    }

    // MARK: Wipe group cadence
    section("Trust enforcement: wipe-group check cadence")
    do {
        let clk = Clock(t0)
        let e = SessionEnforcer(store: InMemoryTrustStore(), now: clk.now)
        var p = TrustPolicy.byodDefault
        check(!e.isWipeGroupCheckDue(account: "A", policy: p), "no wipe group → never due")
        p.wipeGroupId = "G-1"
        check(e.isWipeGroupCheckDue(account: "A", policy: p), "wipe group set, never checked → due")
        e.recordWipeGroupCheck(account: "A", returned: nil)
        check(e.isWipeGroupCheckDue(account: "A", policy: p), "a failed check doesn't count (retried)")
        e.recordSuccess(account: "A", tenantId: tenant, clientId: client)
        e.recordWipeGroupCheck(account: "A", returned: [])
        check(!e.isWipeGroupCheckDue(account: "A", policy: p) && e.evaluate(account: "A", policy: p, tombstoned: false).action == .none,
              "negative check → not due, no action")
        clk.advance(seconds: 61 * 60)
        check(e.isWipeGroupCheckDue(account: "A", policy: p), "default cadence 60 min → due again")
        p.wipeGroupCheckMinutes = 15
        e.recordWipeGroupCheck(account: "A", returned: [])
        clk.advance(seconds: 16 * 60)
        check(e.isWipeGroupCheckDue(account: "A", policy: p), "policy cadence 15 min honoured")
        e.recordWipeGroupCheck(account: "A", returned: ["g-1"])
        check(e.evaluate(account: "A", policy: p, tombstoned: false).action == .wipe(scope: .account("A"), reason: "wipeGroupMember")
              && e.evaluate(account: "B", policy: p, tombstoned: false).action != .wipe(scope: .account("B"), reason: "wipeGroupMember"),
              "member of the wipe group → wipe A only")
        var zero = TrustPolicy.byodDefault; zero.wipeGroupCheckMinutes = 0
        check(zero.effectiveWipeGroupCheckMinutes == TrustPolicy.minimumWipeGroupCheckMinutes, "cadence 0 means the minimum, never 'never'")
    }

    // MARK: Per-account wipe isolation
    section("Trust enforcement: per-account wipe (revoke A, B readable)")
    do {
        let fm = FileManager.default
        let root = tmpDir(), support = root.appending(path: "support"), tombs = root.appending(path: "trust/tombstones")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let mip = support.appending(path: "mip", directoryHint: .isDirectory)
        try fm.createDirectory(at: mip, withIntermediateDirectories: true)
        try Data("lic".utf8).write(to: mip.appending(path: "x.bin"))
        let vault = EnclaveVault(directory: support.appending(path: "vault"), backend: SoftwareKeyBackend())
        let a = "oid-a.tid-a", b = "oid-b.tid-b"
        var keyB = SymmetricKey(size: .bits256)
        for id in [a, b] {
            for p in [VaultPurpose.calendarCache, .mailCache, .mailIndex] {
                let k = try vault.createKey(name: "\(AccountStoreNaming.safeName(id))/\(p.rawValue)", purpose: p)
                if id == b, p == .calendarCache { keyB = k }
            }
            for f in AccountStoreNaming.files(id) {
                for s in ["", "-wal", "-shm"] { fm.createFile(atPath: support.appending(path: f).path + s, contents: Data("db".utf8)) }
            }
        }
        _ = try vault.createKey(name: "\(AccountStoreNaming.registryKeyOwner)/\(VaultPurpose.accountRegistry.rawValue)", purpose: .accountRegistry)
        try Data("sealed".utf8).write(to: support.appending(path: AccountStoreNaming.registryFile))
        let sealedB = try AESGCMCipher(key: keyB).seal(Data("B's calendar".utf8))
        let kc = FakeKeychain(), calls = Calls()
        let layout = AccountWipeLayout(supportDirectory: support, tombstoneDirectory: tombs)
        func items(_ id: String) -> [KeychainItemRef] {
            [.init(service: "ai.niivo.mail.cachekey", account: id), .init(service: "ai.niivo.mail.cachekey", account: id + ".mail")]
        }
        let ex = try layout.executor(account: a, storeFileNames: AccountStoreNaming.files(a), cacheDirectories: [mip],
                                     keychainItems: items(a), keychain: kc, vault: vault,
                                     extraShredders: [ClosureShredder { calls.msalRemoved.append(a) }], now: { t0 })
        let r = try ex.wipe(reason: "userDisabled")
        check(r.failures.isEmpty && r.shreddedVaults == 2, "wipe of A completes (vault slots + MSAL account shredded first)")
        check(AccountStoreNaming.files(a).allSatisfy { f in ["", "-wal", "-shm"].allSatisfy { !fm.fileExists(atPath: support.appending(path: f).path + $0) } },
              "A's calendar + mail stores and sidecars deleted")
        check(AccountStoreNaming.files(b).allSatisfy { fm.fileExists(atPath: support.appending(path: $0).path) }
              && fm.fileExists(atPath: support.appending(path: AccountStoreNaming.mailFile(b)).path + "-wal"),
              "B's stores untouched")
        let names = vault.wrappedNames
        check(!names.contains { $0.hasPrefix(AccountStoreNaming.safeName(a) + "/") }, "A's vault slots removed (crypto-shred of A only)")
        let wB = vault.wrapped(named: "\(AccountStoreNaming.safeName(b))/calendar-cache")
        let unwrappedB = wB.flatMap { try? vault.unwrapSync($0, context: nil) }
        check(unwrappedB.flatMap { try? AESGCMCipher(key: $0).open(sealedB) } == Data("B's calendar".utf8),
              "B's key still unwraps and B's sealed data still opens")
        check(names.contains("\(AccountStoreNaming.registryKeyOwner)/account-registry") && vault.hasKey
              && fm.fileExists(atPath: support.appending(path: AccountStoreNaming.registryFile).path),
              "vault key, registry slot and registry file kept")
        check(Set(kc.deleted) == Set(items(a)) && calls.msalRemoved == [a], "only A's keychain items and MSAL account removed")
        check(!fm.fileExists(atPath: mip.path), "shared MIP licence cache cleared (re-fetchable; may hold A's licences)")
        check(layout.isTombstoned(account: a) && !layout.isTombstoned(account: b) && layout.tombstonedAccounts == [AccountStoreNaming.safeName(a)],
              "tombstone for A only")
        let again = try layout.executor(account: a, storeFileNames: AccountStoreNaming.files(a), vault: vault)
        check(!again.canServeData && again.tombstone?.reason == "userDisabled" && again.tombstone?.completed == true,
              "after restart A stays blocked (tombstone outside wiped paths)")
        let exB = try layout.executor(account: b, storeFileNames: AccountStoreNaming.files(b), vault: vault)
        check(exB.canServeData, "B can still serve data")
        // Interrupted wipe of A resumes from the tombstone file name alone (registry sealed at launch).
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(WipeTombstone(reason: "offlineTooLong", wipedAt: t0, completed: false)).write(to: layout.tombstoneURL(account: a))
        fm.createFile(atPath: support.appending(path: AccountStoreNaming.calendarFile(a)).path, contents: Data("late".utf8))
        let safeA = layout.tombstonedAccounts[0]
        let resumed = try layout.executor(account: safeA, storeFileNames: AccountStoreNaming.files(safeA), vault: vault).resumeIfNeeded()
        check(resumed != nil && !fm.fileExists(atPath: support.appending(path: AccountStoreNaming.calendarFile(a)).path)
              && fm.fileExists(atPath: support.appending(path: AccountStoreNaming.calendarFile(b)).path),
              "interrupted wipe of A resumes by safe name, B still untouched")
        check(again.clearTombstone(freshSignInSucceeded: true, serverConfirmedNotRevoked: true) && !layout.isTombstoned(account: a),
              "fresh sign-in + server confirmation clears A's tombstone")
        try? fm.removeItem(at: root)
    } catch { failures += 1; print("  ✗ per-account wipe threw \(error)") }

    // MARK: Signed policy delivery: tighten only
    section("Trust enforcement: signed policy from managed prefs / file, tighten only")
    do {
        let signer = Curve25519.Signing.PrivateKey()
        let pin = "k1:" + signer.publicKey.rawRepresentation.base64EncodedString()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        func doc(version: Int, _ edit: (inout TrustPolicyOverlay) -> Void) throws -> (Data, Data) {
            var o = TrustPolicyOverlay(); edit(&o)
            let j = try enc.encode(SignedTenantPolicy(keyId: "k1", tenantId: "tid-a", version: version, issuedAt: t0,
                                                      expiresAt: t0.addingTimeInterval(30 * 86400), policy: o))
            return (j, try signer.signature(for: j))
        }
        let now: TrustNow = { t0.addingTimeInterval(3600) }
        // Tries to relax everything it can, and tightens two things.
        let (j, s) = try doc(version: 4) {
            $0.offlineGraceDays = 30; $0.offlineWipeDays = 90; $0.cacheWindowMaxDays = 365; $0.allowOfflineBodiesForLabelled = true
            $0.appLockRequireBiometric = false; $0.requireFileVault = false; $0.profile = .managed
            $0.allowPrint = false; $0.wipeGroupId = "G-9"; $0.wipeGroupCheckMinutes = 10
        }
        let forced = StaticManagedPreferences(values: [TenantPolicySource.pinnedKeysKey: [pin], TenantPolicySource.tenantKey: "tid-a",
                                                       TenantPolicySource.documentKey: String(decoding: j, as: UTF8.self),
                                                       TenantPolicySource.signatureKey: s.base64EncodedString()],
                                              forced: [TenantPolicySource.pinnedKeysKey, TenantPolicySource.tenantKey])
        let st = InMemoryTrustStore()
        let (l, origin) = TenantPolicySource.load(prefs: forced, directory: nil, store: st, now: now)
        let p = l.policy, d = TrustPolicy.byodDefault
        check(origin == "managedPreferences" && l.sources.contains { $0.source == .tenantSigned && $0.applied }, "signed document from managed prefs applied")
        check(p.offlineGraceDays == d.offlineGraceDays && p.offlineWipeDays == d.offlineWipeDays && p.cacheWindowMaxDays == d.cacheWindowMaxDays
              && !p.allowOfflineBodiesForLabelled && p.appLock.requireBiometric && p.requireFileVault && p.profile == .byod,
              "tenant document can't relax grace / wipe days, window, offline bodies, app lock, FileVault or profile")
        check(!p.allowPrint && p.wipeGroupId == "G-9" && p.effectiveWipeGroupCheckMinutes == 10 && p.version == 4,
              "… but tightens print, adds a wipe group and a shorter cadence")
        // Tightening offline grace works.
        let (j2, s2) = try doc(version: 5) { $0.offlineGraceDays = 1; $0.offlineWipeDays = 2 }
        let dir = tmpDir()
        try j2.write(to: dir.appending(path: TenantPolicySource.fileName))
        try s2.write(to: dir.appending(path: TenantPolicySource.signatureFileName))
        let keysOnly = StaticManagedPreferences(values: [TenantPolicySource.pinnedKeysKey: [pin]], forced: [TenantPolicySource.pinnedKeysKey])
        let (l2, o2) = TenantPolicySource.load(prefs: keysOnly, directory: dir, store: st, now: now)
        check(o2 == "file" && l2.policy.offlineGraceDays == 1 && l2.policy.offlineWipeDays == 2, "file next to config: tighter grace applied")
        // Anti-rollback across launches: version 4 after 5 was applied is rejected.
        let (l3, _) = TenantPolicySource.load(prefs: forced, directory: nil, store: st, now: now)
        check(!l3.sources.contains { $0.source == .tenantSigned && $0.applied }
              && l3.sources.contains { $0.notes.contains("rejected:rollback:4<5") }, "older version rejected after a newer one (persisted)")
        // Keys must be forced: a user's own `defaults write` key is ignored.
        let unforced = StaticManagedPreferences(values: [TenantPolicySource.pinnedKeysKey: [pin]])
        let (l4, _) = TenantPolicySource.load(prefs: unforced, directory: dir, store: InMemoryTrustStore(), now: now)
        check(!l4.sources.contains { $0.source == .tenantSigned && $0.applied } && l4.policy.offlineGraceDays == d.offlineGraceDays,
              "pinned keys from unforced prefs are ignored (document rejected)")
        // Tampered file.
        var bad = j2; bad.append(UInt8(ascii: " "))   // still valid JSON, signature no longer matches
        try bad.write(to: dir.appending(path: TenantPolicySource.fileName))
        let (l5, _) = TenantPolicySource.load(prefs: keysOnly, directory: dir, store: InMemoryTrustStore(), now: now)
        check(l5.sources.contains { $0.notes.contains("rejected:badSignature") } && l5.policy == TrustPolicy.byodDefault,
              "tampered document rejected → defaults")
        let (l6, o6) = TenantPolicySource.load(prefs: StaticManagedPreferences(), directory: tmpDir(), store: InMemoryTrustStore(), now: now)
        check(o6 == "none" && l6.policy == TrustPolicy.byodDefault, "no document → defaults")
        try? FileManager.default.removeItem(at: dir)
    } catch { failures += 1; print("  ✗ signed policy threw \(error)") }
}
