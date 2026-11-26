import Foundation
import CryptoKit
import CalendarCore
import TrustCore
import MailCore
import LocalAuthentication

@MainActor
func runTrustTests() async {
    final class TestClock: @unchecked Sendable {
        var t: Date
        init(_ t: Date) { self.t = t }
        var now: TrustNow { { [unowned self] in self.t } }
        func advance(days: Double) { t = t.addingTimeInterval(days * 86400) }
    }
    final class FakeKeychain: SecretDeleting, @unchecked Sendable {
        var items: Set<KeychainItemRef>
        var deleted: [KeychainItemRef] = []
        init(_ items: Set<KeychainItemRef>) { self.items = items }
        func delete(_ item: KeychainItemRef) throws { items.remove(item); deleted.append(item) }
    }
    final class FakeAuth: LocalAuthenticating, @unchecked Sendable {
        var succeed = true, calls = 0
        func authenticate(reason: String) async -> Bool { calls += 1; return succeed }
    }
    struct FakeRunner: CommandRunning {
        var outputs: [String: CommandOutput]
        func run(_ executable: String, _ arguments: [String]) -> CommandOutput? { outputs[executable] }
    }
    final class Capture: @unchecked Sendable { var lines: [Data] = [] }

    let t0 = ISO8601DateFormatter().date(from: "2026-11-19T08:00:00Z")!
    let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "trust-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Policy merge
    section("TrustPolicy merge strictness")
    do {
        let b = TrustPolicy.byodDefault, m = TrustPolicy.managedDefault
        check(b.allowAttachmentsDownload && b.allowPrint && b.allowCopyOut && b.allowScreenCapture && b.appLock.requireBiometric && b.offlineGraceDays < m.offlineGraceDays
              && b.cacheWindowMaxDays < m.cacheWindowMaxDays && b.aiAccess <= m.aiAccess, "byodDefault is stricter than managedDefault")
        var m16 = m; m16.minimumOSVersion = OSVersion("16.1")!
        m16.allowAttachmentsDownload = false; m16.approvedOpenInBundleIds = ["com.apple.Preview", "com.example.Other"]
        let s = b.stricter(m16)
        check(s.profile == .byod && !s.allowAttachmentsDownload && s.approvedOpenInBundleIds == ["com.apple.Preview"]
              && s.offlineGraceDays == 3 && s.offlineWipeDays == 14 && s.aiAccess == .followLabels && s.appLock.requireBiometric,
              "stricter(): allow-flags AND, limits min, require-flags OR, bundle ids intersect")
        check(s.minimumOSVersion == OSVersion(16, 1), "stricter(): minimum OS takes the higher version")
        check(m16.stricter(b) == s, "merge is order-independent")
        check(OSVersion("15.10")! > OSVersion("15.9")! && OSVersion("x.1") == nil, "OS versions compare numerically")
        var o = TrustPolicyOverlay(); o.appLockIdleMinutes = 0
        var p = b; p.apply(o, relax: false)
        check(p.appLock.idleMinutes == 5, "idleMinutes 0 (= no idle lock) doesn't loosen a 5-minute lock")
        o.appLockIdleMinutes = 2; p.apply(o, relax: false)
        check(p.appLock.idleMinutes == 2, "shorter idle lock wins")
        var g = TrustPolicyOverlay(); g.offlineWipeDays = 1
        p.apply(g, relax: false)
        check(p.offlineWipeDays >= p.offlineGraceDays, "wipe days never below grace days")
    }

    // MARK: Signed tenant policy
    section("Tenant-signed policy (Ed25519)")
    let signer = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let pinned = PinnedPolicyKeys(keys: ["k1": signer.publicKey], tenantId: "tenant-1")
    func doc(version: Int = 3, issued: Date = t0, expires: Date? = nil, keyId: String = "k1",
             _ edit: (inout TrustPolicyOverlay) -> Void) -> Data {
        var o = TrustPolicyOverlay(); edit(&o)
        let d = SignedTenantPolicy(keyId: keyId, tenantId: "tenant-1", version: version, issuedAt: issued,
                                   expiresAt: expires ?? issued.addingTimeInterval(30 * 86400), policy: o)
        return try! enc.encode(d)
    }
    let tight = doc { $0.cacheWindowMaxDays = 7; $0.aiAccess = .off; $0.allowAttachmentsDownload = true; $0.wipeGroupId = "G-1" }
    let tightSig = try! signer.signature(for: tight)
    do {
        let now = t0.addingTimeInterval(3600)
        if case .success(let d) = TenantPolicyVerifier.verify(json: tight, signature: tightSig, keys: pinned, now: now) {
            check(d.version == 3, "valid signature verifies")
        } else { check(false, "valid signature verifies") }
        check(TenantPolicyVerifier.verify(json: tight, signature: Data(tightSig.base64EncodedString().utf8), keys: pinned,
                                          now: now).isSuccess, "base64 detached signature accepted")
        var tampered = tight
        let i = tampered.firstRange(of: Data("\"cacheWindowMaxDays\":7".utf8))!.upperBound - 1
        tampered[i] = UInt8(ascii: "9")
        check(TenantPolicyVerifier.verify(json: tampered, signature: tightSig, keys: pinned, now: now).failure == .badSignature,
              "tampered JSON → badSignature")
        check(TenantPolicyVerifier.verify(json: tight, signature: try! other.signature(for: tight), keys: pinned, now: now)
              .failure == .badSignature, "signature by another key under a pinned keyId → badSignature")
        let unk = doc(keyId: "k9") { $0.allowPrint = false }
        check(TenantPolicyVerifier.verify(json: unk, signature: try! other.signature(for: unk), keys: pinned, now: now)
              .failure == .unknownKey("k9"), "unpinned keyId → unknownKey")
        check(TenantPolicyVerifier.verify(json: tight, signature: tightSig, keys: pinned, now: t0.addingTimeInterval(31 * 86400))
              .failure == .expired, "past expiresAt → expired")
        let longLived = doc(expires: t0.addingTimeInterval(400 * 86400)) { $0.allowPrint = false }
        check(TenantPolicyVerifier.verify(json: longLived, signature: try! signer.signature(for: longLived), keys: pinned,
                                          now: t0.addingTimeInterval(200 * 86400)).failure == .tooOld, "older than pinned maxAge → tooOld")
        check(TenantPolicyVerifier.verify(json: tight, signature: tightSig, keys: pinned, now: t0.addingTimeInterval(-86400))
              .failure == .notYetValid, "issuedAt in the future → notYetValid")
        check(TenantPolicyVerifier.verify(json: tight, signature: tightSig, keys: pinned, now: now, minimumVersion: 4)
              .failure == .rollback(seen: 4, got: 3), "older version than last applied → rollback")
        var wrongTenant = pinned; wrongTenant.tenantId = "tenant-2"
        check(TenantPolicyVerifier.verify(json: tight, signature: tightSig, keys: wrongTenant, now: now).failure == .wrongTenant,
              "other tenant → wrongTenant")
        check(TenantPolicyVerifier.verify(json: Data("{".utf8), signature: tightSig, keys: pinned, now: now).failure == .malformed,
              "garbage → malformed")
    }

    // MARK: Loader
    section("PolicyLoader sources and MDM-forced override")
    do {
        let clock: TrustNow = { t0.addingTimeInterval(3600) }
        let none = PolicyLoader(prefs: StaticManagedPreferences(), pinnedKeys: pinned, now: clock).load(tenantJSON: nil, tenantSignature: nil)
        check(none.policy == .byodDefault, "no MDM, no tenant file → byodDefault")

        let t = PolicyLoader(prefs: StaticManagedPreferences(), pinnedKeys: pinned, now: clock).load(tenantJSON: tight, tenantSignature: tightSig)
        check(t.policy.cacheWindowMaxDays == 7 && t.policy.aiAccess == .off && t.policy.wipeGroupId == "G-1" && t.policy.version == 3,
              "verified tenant file tightens")
        check(t.policy.appLock.requireBiometric && t.policy.offlineWipeDays <= TrustPolicy.byodDefault.offlineWipeDays,
              "tenant file cannot relax BYOD defaults")
        check(t.sources.first { $0.source == .tenantSigned }?.applied == true, "tenant source reported applied")

        var tampered = tight; tampered[tampered.count - 2] ^= 1
        let bad = PolicyLoader(prefs: StaticManagedPreferences(), pinnedKeys: pinned, now: clock).load(tenantJSON: tampered, tenantSignature: tightSig)
        let rep = bad.sources.first { $0.source == .tenantSigned }!
        check(bad.policy == .byodDefault && !rep.applied && rep.notes.first?.hasPrefix("rejected:") == true,
              "bad tenant file ignored, reason recorded (\(rep.notes))")
        let expired = PolicyLoader(prefs: StaticManagedPreferences(), pinnedKeys: pinned, now: { t0.addingTimeInterval(40 * 86400) })
            .load(tenantJSON: tight, tenantSignature: tightSig)
        check(expired.sources.first { $0.source == .tenantSigned }?.notes == ["rejected:expired"], "expired tenant file ignored with reason")

        let forced = StaticManagedPreferences(values: ["profile": "managed", "allowPrint": true, "offlineGraceDays": 30,
                                                       "appLockRequireBiometric": false],
                                              forced: ["profile", "allowPrint", "offlineGraceDays", "appLockRequireBiometric"])
        let f = PolicyLoader(prefs: forced, pinnedKeys: pinned, now: clock).load(tenantJSON: tight, tenantSignature: tightSig)
        check(f.policy.profile == .managed && f.policy.allowCopyOut, "forced profile=managed → managedDefault base")
        check(f.policy.allowPrint && f.policy.offlineGraceDays == 30 && !f.policy.appLock.requireBiometric,
              "MDM-forced keys relax, overriding the tenant file and defaults")
        check(f.policy.cacheWindowMaxDays == 7 && f.policy.aiAccess == .off, "keys MDM doesn't force still follow tenant tightening")

        let user = StaticManagedPreferences(values: ["profile": "managed", "allowAttachmentsDownload": true, "cacheWindowMaxDays": 5,
                                                     "offlineWipeDays": "lots"])
        let u = PolicyLoader(prefs: user, pinnedKeys: pinned, now: clock).load(tenantJSON: nil, tenantSignature: nil)
        check(u.policy.profile == .byod && u.policy.offlineGraceDays == TrustPolicy.byodDefault.offlineGraceDays, "unforced prefs (user `defaults write`) cannot relax or switch profile")
        check(u.policy.cacheWindowMaxDays == 5, "unforced prefs may tighten")
        check(u.sources.first { $0.source == .managedUnforced }?.notes.contains("invalid:offlineWipeDays") == true
              && u.policy.offlineWipeDays == 14, "wrongly typed pref key rejected individually")
    }

    // MARK: Posture
    section("Posture decisions")
    do {
        let good = PostureReport(fileVault: .yes, sip: .yes, screenLock: .yes, osVersion: OSVersion(27), codeSignature: .notarized)
        let b = TrustPolicy.byodDefault, m = TrustPolicy.managedDefault
        check(PostureChecker.decide(good, policy: b) == .allow, "all good + notarised → allow")
        var r = good; r.fileVault = .no
        check(PostureChecker.decide(r, policy: b) == .block(["fileVaultOff"]), "FileVault off → block")
        r = good; r.sip = .no
        check(PostureChecker.decide(r, policy: b) == .block(["sipOff"]), "SIP off → block")
        r = good; r.osVersion = OSVersion(14, 7)
        check(PostureChecker.decide(r, policy: b) == .block(["osBelowMinimum"]), "OS below minimum → block")
        r = good; r.screenLock = .unverified("screenLockUnparsed")
        check(PostureChecker.decide(r, policy: b) == .restrict(["screenLockUnverified:screenLockUnparsed"]), "unverifiable screen lock → restrict")
        check(PostureChecker.decide(r, policy: m) == .allow, "screen lock not required on managed → allow")
        r = good; r.codeSignature = .adhoc
        check(PostureChecker.decide(r, policy: b) == .restrict(["notNotarized"]), "ad-hoc build on BYOD → restrict")
        check(PostureChecker.decide(r, policy: m) == .allow, "ad-hoc build on managed Mac → allow")
        r = good; r.codeSignature = .invalid
        check(PostureChecker.decide(r, policy: m) == .block(["codeSignatureInvalid"]), "modified bundle → block")
        var noFV = b; noFV.requireFileVault = false
        r = good; r.fileVault = .no
        check(PostureChecker.decide(r, policy: noFV) == .allow, "FileVault off but not required → allow")
        let restricted = b.restrictedForPosture()
        check(!restricted.allowAttachmentsDownload && restricted.aiAccess <= .metadataOnly && !restricted.allowCopyOut,
              "restrict tightens the effective policy")

        check(SystemPostureProbes.parseFileVault("FileVault is On.\n") == .yes && SystemPostureProbes.parseFileVault("FileVault is Off.\n") == .no,
              "fdesetup output parsed")
        check(SystemPostureProbes.parseSIP("System Integrity Protection status: enabled.\n") == .yes
              && SystemPostureProbes.parseSIP("System Integrity Protection status: unknown (Custom Configuration).\n") == .no
              && SystemPostureProbes.parseSIP("System Integrity Protection status: disabled.\n") == .no, "csrutil output parsed (custom config = off)")
        check(SystemPostureProbes.parseScreenLock("2026-11-19 sysadminctl[1:2] screenLock delay is 900 seconds\n") == .yes
              && SystemPostureProbes.parseScreenLock("screenLock is off\n") == .no
              && SystemPostureProbes.parseScreenLock("whatever\n") == .unverified("screenLockUnparsed"), "sysadminctl screenLock parsed, unknown → UNVERIFIED")
        let fake = SystemPostureProbes(runner: FakeRunner(outputs: [
            "/usr/bin/fdesetup": .init(status: 0, stdout: "FileVault is On.\n", stderr: ""),
            "/usr/bin/csrutil": .init(status: 0, stdout: "System Integrity Protection status: enabled.\n", stderr: ""),
            "/usr/sbin/sysadminctl": .init(status: 0, stdout: "", stderr: "x screenLock is immediate\n"),
        ]))
        check(fake.fileVault() == .yes && fake.sip() == .yes && fake.screenLock() == .yes, "probes use the injected command runner")
        let dead = SystemPostureProbes(runner: FakeRunner(outputs: [:]))
        check(dead.fileVault() == .unverified("fdesetupUnavailable") && dead.screenLock() == .unverified("sysadminctlUnavailable"),
              "runner failure → UNVERIFIED, not pass")
        let live = SystemPostureProbes().codeSignature()
        check(live != .notarized, "live SecStaticCode: this swift-build binary is not notarised (\(live))")
    }

    // MARK: Error classification
    section("Session error classification")
    do {
        func c(_ codes: [Int], http: Int? = 400, oauth: String? = "invalid_grant", prior: Bool = true) -> SessionErrorClass {
            SessionErrorClassifier.classify(AuthFailure(oauthError: oauth, aadstsCodes: codes, httpStatus: http), hadPriorSuccess: prior)
        }
        check(c([50173]) == .reauth(.grantRevoked), "50173 grant/session revoked (incl. password reset) → reauth, not wipe")
        check(c([50133]) == .reauth(.grantRevoked), "50133 session revoked by password change → reauth")
        check(c([530002]) == .reauth(.deviceNotCompliant), "530002 device must be compliant → reauth")
        for code in [50034, 700016, 50105, 500341] {
            check(c([code], prior: false) == .reauth(.configuration), "\(code) without a prior sign-in → reauth(configuration), never wipe")
        }
        check(c([50057], prior: false) == .revoked(.userDisabled), "50057 is not misconfiguration-guarded")
        check(c([50057]) == .revoked(.userDisabled), "50057 user disabled → revoked")
        check(c([50034]) == .revoked(.userNotFound), "50034 user not found → revoked")
        check(c([500341]) == .revoked(.userDeleted), "500341 user deleted → revoked")
        check(c([700016]) == .revoked(.appNotFound), "700016 app not found in tenant → revoked")
        check(c([50105]) == .revoked(.userNotAssigned), "50105 user not assigned → revoked")
        check(c([53000]) == .reauth(.deviceNotCompliant), "53000 device not compliant → reauth, not wipe")
        check(c([530003]) == .reauth(.deviceNotManaged), "530003 device must be managed → reauth, not wipe")
        check(c([53003]) == .reauth(.conditionalAccess), "53003 blocked by CA → reauth")
        check(c([50076]) == .reauth(.mfaRequired) && c([50079]) == .reauth(.mfaRequired), "50076/50079 MFA → reauth")
        check(c([70043]) == .reauth(.signInFrequency) && c([700082]) == .reauth(.tokenExpired), "70043/700082 → reauth")
        check(c([50076, 50057]) == .revoked(.userDisabled), "a revoked code beats a reauth code")
        check(c([99999]) == .reauth(.interactionRequired), "unknown code + invalid_grant → reauth, never wipe")
        check(c([], http: 400, oauth: nil) == .transient, "unknown 400 → transient")
        check(c([], http: 503, oauth: nil) == .transient && c([], http: 429, oauth: nil) == .transient, "503/429 → transient")
        check(SessionErrorClassifier.classify(AuthFailure(isNetworkError: true)) == .transient, "network error → transient")
        let hdr = #"Bearer realm="", authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", error="insufficient_claims", claims="eyJhY2Nlc3NfdG9rZW4iOnsibmJmIjp7ImVzc2VudGlhbCI6dHJ1ZX19fQ==""#
        let cae = AuthFailure(httpStatus: 401, wwwAuthenticate: hdr)
        check(SessionErrorClassifier.classify(cae) == .reauth(.claimsChallenge), "CAE insufficient_claims → reauth")
        check(SessionErrorClassifier.claims(from: hdr) == "eyJhY2Nlc3NfdG9rZW4iOnsibmJmIjp7ImVzc2VudGlhbCI6dHJ1ZX19fQ==", "claims extracted for MSAL retry")
        check(SessionErrorClassifier.classify(AuthFailure(httpStatus: 401)) == .reauth(.unauthorized), "plain 401 → reauth")
        let ns = NSError(domain: "MSALErrorDomain", code: -50000, userInfo: [
            "MSALErrorDescriptionKey": "AADSTS50057: The user account is disabled. Trace ID: x", "MSALOAuthErrorKey": "invalid_grant"])
        let parsed = AuthFailure(error: ns)
        check(parsed.aadstsCodes == [50057] && SessionErrorClassifier.classify(parsed) == .revoked(.userDisabled), "NSError userInfo scanned for AADSTS codes")
        check(SessionErrorClassifier.classify(AuthFailure(error: URLError(.notConnectedToInternet))) == .transient, "URLError → transient")
        check(AADSTSCatalog.entries.allSatisfy { $0.source.hasPrefix("https://learn.microsoft.com/") }, "every catalog code has a Learn source")
        check(AADSTSCatalog.entries.filter { if case .revoked = $0.outcome { true } else { false } }.allSatisfy(\.verified),
              "every wipe-triggering code is verified")

        // CAE: reauth first; wipe only if the follow-up refresh says revoked.
        let ok = PostureDecision.allow, b = TrustPolicy.byodDefault, g = GraceStatus.ok(offlineSeconds: 0)
        check(SessionHealth.decide(policy: b, lastError: .reauth(.claimsChallenge), wipeGroupMembers: nil, grace: g, posture: ok, tombstoned: false)
              == .locked("reauth:claimsChallenge"), "CAE challenge → locked pending reauth (no wipe)")
        check(SessionHealth.decide(policy: b, lastError: c([50057]), wipeGroupMembers: nil, grace: g, posture: ok, tombstoned: false)
              == .wipe("userDisabled"), "CAE follow-up refresh revoked → wipe")
        check(SessionHealth.decide(policy: b, lastError: nil, wipeGroupMembers: nil, grace: g, posture: ok, tombstoned: false) == .ok,
              "CAE follow-up refresh succeeds → ok")
        check(SessionHealth.decide(policy: b, lastError: .transient, wipeGroupMembers: nil, grace: g, posture: .restrict(["notNotarized"]), tombstoned: false)
              == .restricted(["notNotarized"]), "transient + restricted posture → restricted")
        check(SessionHealth.decide(policy: b, lastError: nil, wipeGroupMembers: nil, grace: g, posture: .block(["sipOff"]), tombstoned: false)
              == .locked("posture:sipOff"), "blocked posture → locked")
    }

    // MARK: Revocation guard
    section("Revocation guard: misconfiguration guard, two strikes")
    do {
        let clk = TestClock(t0), store = InMemoryTrustStore()
        let rg = RevocationGuard(store: store, now: clk.now)
        let grace = OfflineGraceClock(store: store, now: clk.now)
        let disabled = AuthFailure(oauthError: "invalid_grant", aadstsCodes: [50057], httpStatus: 400)
        let notFound = AuthFailure(oauthError: "invalid_grant", aadstsCodes: [50034], httpStatus: 400)
        let unassigned = AuthFailure(oauthError: "invalid_grant", aadstsCodes: [50105], httpStatus: 400)
        let pwReset = AuthFailure(oauthError: "invalid_grant", aadstsCodes: [50173], httpStatus: 400)
        check(rg.evaluate(notFound, path: .interactive, tenantId: "T1", clientId: "C1") == .reauth(.configuration),
              "never-seen tenant+client: 50034 → configuration, even interactively")
        grace.recordSuccessfulRefresh(tenantId: "T1", clientId: "C1")
        check(grace.hasPriorSuccess(tenantId: "t1", clientId: "c1"), "successful pair recorded (case-insensitive)")
        check(rg.evaluate(notFound, path: .interactive, tenantId: "T1", clientId: "C2") == .reauth(.configuration),
              "same tenant, other client id → still guarded")
        check(rg.evaluate(notFound, path: .interactive, tenantId: "T1", clientId: "C1") == .revoked(.userNotFound),
              "seen pair: interactive 50034 → revoked immediately")
        let first = rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1")
        check(first == .reauth(.revocationUnconfirmed), "silent: first revoked → unconfirmed (locks only)")
        check(SessionHealth.decide(policy: .byodDefault, lastError: first, wipeGroupMembers: nil, grace: .ok(offlineSeconds: 0),
                                   posture: .allow, tombstoned: false) == .locked("reauth:revocationUnconfirmed"), "single strike → locked, not wiped")
        clk.t = t0.addingTimeInterval(30)
        check(rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1") == .reauth(.revocationUnconfirmed),
              "second strike < 60 s later → still unconfirmed")
        check(rg.evaluate(AuthFailure(isNetworkError: true), path: .silentRefresh, tenantId: "T1", clientId: "C1") == .transient,
              "network error in between is neutral")
        clk.t = t0.addingTimeInterval(61)
        check(rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1") == .revoked(.userDisabled),
              "second strike ≥ 60 s after the first → revoked")
        clk.t = t0.addingTimeInterval(200)
        _ = rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1")
        grace.recordSuccessfulRefresh(tenantId: "T1", clientId: "C1")
        clk.t = t0.addingTimeInterval(400)
        check(rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1") == .reauth(.revocationUnconfirmed),
              "a success in between resets the strikes")
        clk.t = t0.addingTimeInterval(500)
        _ = rg.evaluate(AuthFailure(oauthError: "invalid_grant", aadstsCodes: [50076], httpStatus: 400), path: .silentRefresh, tenantId: "T1", clientId: "C1")
        clk.t = t0.addingTimeInterval(600)
        check(rg.evaluate(disabled, path: .silentRefresh, tenantId: "T1", clientId: "C1") == .reauth(.revocationUnconfirmed),
              "a non-revoked error in between breaks the run")
        // Password reset / revoke-sessions: lock, sign in again; only a following hard failure wipes.
        let pr = rg.evaluate(pwReset, path: .silentRefresh, tenantId: "T1", clientId: "C1")
        check(pr == .reauth(.grantRevoked) && SessionHealth.decide(policy: .byodDefault, lastError: pr, wipeGroupMembers: nil,
              grace: .ok(offlineSeconds: 0), posture: .allow, tombstoned: false) == .locked("reauth:grantRevoked"), "50173 → locked")
        let after = rg.evaluate(unassigned, path: .interactive, tenantId: "T1", clientId: "C1")
        check(SessionHealth.decide(policy: .byodDefault, lastError: after, wipeGroupMembers: nil, grace: .ok(offlineSeconds: 0),
                                   posture: .allow, tombstoned: false) == .wipe("userNotAssigned"), "…then interactive 50105 → wipe")
        var p = TrustPolicy.byodDefault; p.wipeGroupId = "g"
        check(SessionHealth.decide(policy: p, lastError: first, wipeGroupMembers: ["g"], grace: .ok(offlineSeconds: 0), posture: .allow,
                                   tombstoned: false) == .wipe("wipeGroupMember")
              && SessionHealth.decide(policy: .byodDefault, lastError: first, wipeGroupMembers: nil, grace: .wipe, posture: .allow,
                                      tombstoned: false) == .wipe("offlineTooLong"), "wipe group and offline deadline stay immediate")
    }

    // MARK: Wipe group
    section("Wipe-group membership")
    do {
        let gid = "6f1c2b9e-0000-4000-8000-00000000abcd"
        check(WipeGroupCheck.shouldWipe(wipeGroupId: gid, returned: [gid.uppercased()]), "member of wipe group → wipe")
        check(!WipeGroupCheck.shouldWipe(wipeGroupId: gid, returned: []), "not a member → no wipe")
        check(!WipeGroupCheck.shouldWipe(wipeGroupId: gid, returned: nil), "check failed → no wipe")
        check(!WipeGroupCheck.shouldWipe(wipeGroupId: nil, returned: [gid]), "no wipe group configured → no wipe")
        let body = String(data: WipeGroupCheck.requestBody(wipeGroupId: gid), encoding: .utf8)!
        check(body.contains("\"groupIds\"") && body.contains(gid), "checkMemberGroups body built")
        let resp = Data(#"{"@odata.context":"x","value":["\#(gid)"]}"#.utf8)
        check(WipeGroupCheck.memberGroupIds(fromResponse: resp) == [gid], "checkMemberGroups response parsed")
        var p = TrustPolicy.byodDefault; p.wipeGroupId = gid
        check(SessionHealth.decide(policy: p, lastError: nil, wipeGroupMembers: [gid], grace: .ok(offlineSeconds: 0), posture: .allow,
                                   tombstoned: false) == .wipe("wipeGroupMember"), "decision: wipe-group member → wipe")
    }

    // MARK: Grace clock
    section("Offline grace: lock, then wipe")
    do {
        let clk = TestClock(t0), store = InMemoryTrustStore()
        let grace = OfflineGraceClock(store: store, now: clk.now)
        let p = TrustPolicy.byodDefault // 3 days lock, 14 days wipe
        check(grace.status(policy: p) == .locked, "no successful refresh yet → locked")
        grace.recordSuccessfulRefresh()
        clk.advance(days: 2)
        if case .ok = grace.status(policy: p) { check(true, "day 2 offline → ok") } else { check(false, "day 2 offline → ok") }
        clk.advance(days: 1.5)
        check(grace.status(policy: p) == .locked, "day 3.5 offline → locked")
        clk.t = t0.addingTimeInterval(86400) // user winds the clock back
        check(grace.status(policy: p) == .locked, "winding the clock back doesn't unlock (high-water mark)")
        clk.t = t0.addingTimeInterval(14.5 * 86400)
        check(grace.status(policy: p) == .wipe, "day 14.5 offline → wipe")
        check(SessionHealth.decide(policy: p, lastError: .transient, wipeGroupMembers: nil, grace: .wipe, posture: .allow, tombstoned: false)
              == .wipe("offlineTooLong"), "decision: grace wipe → wipe")
        grace.recordSuccessfulRefresh()
        if case .ok = grace.status(policy: p) { check(true, "successful refresh resets the clock") } else { check(false, "refresh resets") }
        // Forward-then-back clock trick: refresh at +400 days, return to real time.
        let real = clk.t
        clk.t = real.addingTimeInterval(400 * 86400); grace.recordSuccessfulRefresh()
        clk.t = real
        check(grace.status(policy: p) == .locked, "clock wound back after a future-dated refresh → locked")
        clk.advance(days: 20)
        check(grace.status(policy: p) != .ok(offlineSeconds: 0) && grace.status(policy: p) == .locked, "…and stays locked (no frozen grace)")
        grace.recordSuccessfulRefresh()
        if case .ok = grace.status(policy: p) { check(true, "real refresh re-anchors the clock") } else { check(false, "re-anchor") }
        let reopened = OfflineGraceClock(store: store, now: clk.now)
        check(reopened.lastSuccess != nil, "last refresh persisted in the store")
        let dir = tmpDir()
        let fileStore = try FileTrustStore(directory: dir)
        OfflineGraceClock(store: fileStore, now: clk.now).recordSuccessfulRefresh()
        check(OfflineGraceClock(store: try FileTrustStore(directory: dir), now: clk.now).lastSuccess == clk.t, "file store survives restart")
        try? FileManager.default.removeItem(at: dir)
    } catch { failures += 1; print("  ✗ grace threw \(error)") }

    // MARK: Wipe executor
    section("Wipe executor: idempotent, tombstone blocks data")
    do {
        let root = tmpDir()
        let cache = root.appending(path: "cache"), mail = root.appending(path: "mail.sqlite")
        let tomb = root.appending(path: "state/wipe.tombstone")
        try FileManager.default.createDirectory(at: cache.appending(path: "bodies"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appending(path: "bodies/1.bin"))
        for f in [mail.path, mail.path + "-wal", mail.path + "-shm"] { FileManager.default.createFile(atPath: f, contents: Data("y".utf8)) }
        let items: Set<KeychainItemRef> = [.init(service: "ai.niivo.mail.cachekey", account: "acct-1")]
        let kc = FakeKeychain(items)
        func make() throws -> DefaultWipeExecutor {
            try DefaultWipeExecutor(cacheDirectories: [cache], storeFiles: [mail], keychainItems: Array(items), keychain: kc,
                                    tombstoneURL: tomb, now: { t0 })
        }
        let w = try make()
        check(w.canServeData && w.tombstone == nil, "before wipe: data served")
        let r1 = try w.wipe(reason: "sessionRevoked")
        let fm = FileManager.default
        check(!fm.fileExists(atPath: cache.path) && !fm.fileExists(atPath: mail.path) && !fm.fileExists(atPath: mail.path + "-wal"),
              "cache dir and store files (+ -wal/-shm) deleted (\(r1.removedPaths) paths)")
        check(kc.items.isEmpty && r1.removedKeychainItems == 1, "keychain items removed")
        check(w.tombstone == WipeTombstone(reason: "sessionRevoked", wipedAt: t0, completed: true) && !w.canServeData, "tombstone recorded")
        let r2 = try w.wipe(reason: "other")
        check(r2.removedPaths == 0 && r2.failures.isEmpty && w.tombstone?.reason == "sessionRevoked", "second wipe is a no-op, keeps first reason")
        let restarted = try make()
        check(!restarted.canServeData, "after restart (new executor) data still blocked")
        check(!restarted.clearTombstone(freshSignInSucceeded: true, serverConfirmedNotRevoked: false), "sign-in alone doesn't clear")
        check(!restarted.clearTombstone(freshSignInSucceeded: false, serverConfirmedNotRevoked: true), "server confirmation alone doesn't clear")
        check(SessionHealth.decide(policy: .byodDefault, lastError: nil, wipeGroupMembers: nil, grace: .ok(offlineSeconds: 0), posture: .allow,
                                   tombstoned: !restarted.canServeData) == .locked("wipedAwaitingSignIn"), "decision: tombstone → locked")
        check(restarted.clearTombstone(freshSignInSucceeded: true, serverConfirmedNotRevoked: true) && restarted.canServeData,
              "fresh sign-in + server confirmation clears it")
        // Interrupted wipe resumes at launch.
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("z".utf8).write(to: cache.appending(path: "late.bin"))
        try enc.encode(WipeTombstone(reason: "userDisabled", wipedAt: t0, completed: false)).write(to: tomb)
        let resumed = try make().resumeIfNeeded()
        let afterResume = try make().tombstone
        check(resumed != nil && !fm.fileExists(atPath: cache.path) && afterResume?.completed == true, "interrupted wipe resumes on launch")
        try Data("garbage".utf8).write(to: tomb)
        let corrupt = try make()
        check(!corrupt.canServeData && corrupt.tombstone?.reason == "unreadableTombstone", "corrupt tombstone still blocks (fail closed)")
        // Tombstone can't be written (its parent is a regular file): data is still deleted, then the error surfaces.
        let blocker = root.appending(path: "blocker")
        try Data("f".utf8).write(to: blocker)
        let victim = root.appending(path: "victim")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("v".utf8).write(to: victim.appending(path: "a.bin"))
        let broken = try DefaultWipeExecutor(cacheDirectories: [victim], storeFiles: [], keychainItems: [], keychain: kc,
                                             tombstoneURL: blocker.appending(path: "wipe.tombstone"))
        var threw = false
        do { try broken.wipe(reason: "sessionRevoked") } catch { threw = true }
        check(threw && !fm.fileExists(atPath: victim.path), "unwritable tombstone: data deleted anyway, error reported")
        do {
            _ = try DefaultWipeExecutor(cacheDirectories: [root], storeFiles: [], keychainItems: [], keychain: kc, tombstoneURL: tomb)
            check(false, "tombstone inside a wiped dir rejected")
        } catch { check(error as? WipeError == .tombstoneInsideWipedLocation, "tombstone inside a wiped dir rejected") }
        try? fm.removeItem(at: root)
    } catch { failures += 1; print("  ✗ wipe threw \(error)") }

    // MARK: App lock
    section("App lock: idle, sleep, policy change")
    do {
        let clk = TestClock(t0), auth = FakeAuth()
        let lock = AppLock(policy: .init(requireBiometric: true, idleMinutes: 5), authenticator: auth, now: clk.now)
        check(lock.state == .locked(.launch), "locked at launch")
        let u1 = await lock.unlock()
        check(u1 && lock.state == .unlocked && auth.calls == 1, "biometric unlock")
        clk.t = t0.addingTimeInterval(4 * 60); lock.tick()
        check(lock.state == .unlocked, "4 min idle → still unlocked")
        lock.noteActivity()
        clk.t = t0.addingTimeInterval(8 * 60); lock.tick()
        check(lock.state == .unlocked, "activity resets the idle timer")
        clk.t = t0.addingTimeInterval(9 * 60); lock.tick()
        check(lock.state == .locked(.idle), "5 min idle → locked(idle)")
        auth.succeed = false
        let u2 = await lock.unlock()
        check(!u2 && lock.isLocked, "failed auth stays locked")
        auth.succeed = true
        _ = await lock.unlock()
        lock.systemWillSleep()
        check(lock.state == .locked(.sleep), "sleep → locked(sleep)")
        _ = await lock.unlock()
        lock.policyChanged(.init(requireBiometric: true, idleMinutes: 2))
        check(lock.state == .locked(.policyChanged) && lock.policy.idleMinutes == 2, "policy change → locked(policyChanged)")
        lock.policyChanged(.init(requireBiometric: false, idleMinutes: 0))
        check(lock.isLocked, "policy disabling the lock doesn't unlock a locked app without auth")
        _ = await lock.unlock()
        lock.systemWillSleep(); clk.advance(days: 1); lock.tick(); lock.policyChanged(.init(requireBiometric: false, idleMinutes: 0))
        check(lock.state == .unlocked, "app lock disabled → never locks")
    }

    // MARK: Audit log
    section("Audit log: encrypted, append-only, no content")
    do {
        let dir = tmpDir(), url = dir.appending(path: "audit.log")
        let aes = AESGCMCipher(key: SymmetricKey(size: .bits256))
        let cap = Capture()
        let secret = "Project Falcon: acquisition of Contoso"
        let addr = "ceo@contoso.example"
        let log = try AuditLog(url: url, seal: { d in cap.lines.append(d); return try aes.seal(d) }, now: { t0 })
        try log.append(.policyApplied(version: 3, sources: ["managedForced", "tenantSigned"]))
        try log.append(.postureResult(decision: "restrict", reasons: ["notNotarized"]))
        try log.append(.copyBlocked(itemId: secret, labelId: "hc-label"))          // caller bug: subject passed as id
        try log.append(.aiAccess(client: "claude", tool: "mail.search", itemIds: ["AAMkAD1=", addr], count: 2, decision: "metadataOnly"))
        try log.append(.wipeStarted(reason: "sessionRevoked"))
        try log.append(.locked(.idle))
        let plain = cap.lines.map { String(data: $0, encoding: .utf8)! }.joined(separator: "\n")
        check(!plain.contains(secret) && !plain.contains("Falcon") && !plain.contains(addr) && !plain.contains("@"),
              "plaintext lines never contain the subject or the address")
        check(plain.contains("redacted") && plain.contains("AAMkAD1=") && plain.contains("notNotarized"), "ids and reason codes kept, content redacted")
        let disk = try Data(contentsOf: url)
        check(disk.range(of: Data("policyApplied".utf8)) == nil, "on disk: sealed (no plaintext JSON)")
        let records = try AuditLog.read(url: url, open: { try aes.open($0) })
        check(records.count == 6 && records[2].kind == "copyBlocked" && AuditLog.verifyChain(records), "reads back, hash chain verifies")
        check(!AuditLog.verifyChain(Array(records.dropFirst(2))) && !AuditLog.verifyChain([records[0], records[2]]),
              "dropping lines breaks the chain")
        let reopened = try AuditLog(url: url, seal: { try aes.seal($0) }, open: { try aes.open($0) }, now: { t0 })
        try reopened.append(.unlocked)
        let all = try AuditLog.read(url: url, open: { try aes.open($0) })
        check(all.count == 7 && AuditLog.verifyChain(all), "reopen appends and continues the chain")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        check(perms == 0o600, "audit file mode 0600")
        try? FileManager.default.removeItem(at: dir)
    } catch { failures += 1; print("  ✗ audit threw \(error)") }

    // MARK: Enclave vault (key wrapping, crypto-shred)
    section("Enclave vault: wrap/unwrap, context separation, shred, migration")
    do {
        func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }
        let fm = FileManager.default
        let root = tmpDir()
        let vault = EnclaveVault(directory: root.appending(path: "vault"), backend: SoftwareKeyBackend())
        check(!vault.hasKey && vault.wrappedNames.isEmpty, "fresh vault: no key yet")
        let k = SymmetricKey(size: .bits256)
        let w = try vault.wrap(k, name: "acct/calendar-cache", purpose: .calendarCache)
        check(vault.hasKey && !w.sealed.isEmpty && w.sealed.range(of: bytes(k)) == nil,
              "wrap creates the key-agreement key; ciphertext doesn't contain the key")
        try vault.store(w)
        let back = try await vault.unwrap(w, context: nil)
        check(bytes(back) == bytes(k), "wrap → unwrap round-trip")
        let stored = vault.wrapped(named: "acct/calendar-cache")
        check(stored == w && (try? vault.unwrapSync(stored!, context: nil)).map(bytes) == bytes(k), "persisted wrapped key unwraps")
        let w2 = try vault.wrap(k, name: "acct/calendar-cache", purpose: .calendarCache)
        check(w2.sealed != w.sealed && w2.ephemeralPublicKey != w.ephemeralPublicKey, "each wrap uses a fresh ephemeral key")
        func mode(_ u: URL) -> Int? { (try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int }
        check(mode(vault.blobURL) == 0o600 && mode(vault.keysURL) == 0o600 && mode(vault.directory) == 0o700,
              "blob + wrapped keys 0600, directory 0700")
        let excluded = (try? vault.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
        check(excluded == true, "vault directory excluded from Time Machine")

        // HKDF context separation and slot binding.
        let km = SymmetricKey(size: .bits256)
        let wm = try vault.wrap(km, name: "acct/mail-cache", purpose: .mailCache)
        check((try? vault.unwrapSync(wm, as: .mailCache, context: nil)).map(bytes) == bytes(km), "mail-cache unwraps as mail-cache")
        var wrongPurpose: VaultError?
        do { _ = try vault.unwrapSync(wm, as: .calendarCache, context: nil) } catch { wrongPurpose = error as? VaultError }
        check(wrongPurpose == .unwrapFailed, "key wrapped for mail-cache doesn't unwrap as calendar-cache")
        var relabelled = wm; relabelled.purpose = .calendarCache
        check((try? vault.unwrapSync(relabelled, context: nil)) == nil, "relabelling the purpose field fails too")
        var moved = wm; moved.name = "other/mail-cache"
        check((try? vault.unwrapSync(moved, context: nil)) == nil, "moving a wrapped key to another slot fails (name in AAD)")

        // Tampering.
        var tampered = w; tampered.sealed[tampered.sealed.count / 2] ^= 0x01
        check((try? vault.unwrapSync(tampered, context: nil)) == nil, "tampered ciphertext fails")
        var tamperedTag = w; tamperedTag.sealed[tamperedTag.sealed.count - 1] ^= 0x80
        check((try? vault.unwrapSync(tamperedTag, context: nil)) == nil, "tampered tag fails")
        var swappedEph = w; swappedEph.ephemeralPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        check((try? vault.unwrapSync(swappedEph, context: nil)) == nil, "substituted ephemeral key fails")

        // Another vault (another Mac's SE key) can't unwrap.
        let otherVault = EnclaveVault(directory: root.appending(path: "vault2"), backend: SoftwareKeyBackend())
        _ = try otherVault.createKey(name: "x/audit", purpose: .audit)
        check((try? otherVault.unwrapSync(w, context: nil)) == nil, "another vault's key can't unwrap it")

        // unwrapAll: one pass, one context.
        try vault.store(wm)
        let all = try vault.unwrapAll(context: nil)
        check(all.count == 2 && all["acct/mail-cache"].map(bytes) == bytes(km) && all["acct/calendar-cache"].map(bytes) == bytes(k),
              "unwrapAll returns every stored key")
        try vault.remove(names: ["acct/mail-cache"])
        check(vault.wrappedNames == ["acct/calendar-cache"], "remove(names:) drops just that slot")

        // Shred: blob + wrapped keys gone; a lingering copy of the wrapped-keys file is useless without the blob.
        let lingering = try Data(contentsOf: vault.keysURL)
        try vault.shred()
        check(!fm.fileExists(atPath: vault.blobURL.path) && !fm.fileExists(atPath: vault.keysURL.path) && !vault.hasKey,
              "shred deletes the blob and the wrapped keys")
        var afterShred: VaultError?
        do { _ = try vault.unwrapSync(w, context: nil) } catch { afterShred = error as? VaultError }
        check(afterShred == .noKey, "after shred, unwrap fails")
        try fm.createDirectory(at: vault.directory, withIntermediateDirectories: true)
        try lingering.write(to: vault.keysURL)
        check((try? vault.unwrapSync(w, context: nil)) == nil && (try? vault.unwrapAll(context: nil)) == nil,
              "restored wrapped-keys file still can't unwrap (the SE key is gone)")
        try? fm.removeItem(at: vault.keysURL)
        try vault.shred()
        check(true, "shred is idempotent")
        let fresh = try vault.createKey(name: "acct/calendar-cache", purpose: .calendarCache)
        check(bytes(fresh) != bytes(k) && vault.hasKey, "after shred a new key starts a fresh vault")

        // Migration from a plain Keychain key (fake Keychain: closures).
        final class Legacy: @unchecked Sendable { var key: SymmetricKey?; var deletes = 0; var failDelete = false }
        let mv = EnclaveVault(directory: root.appending(path: "vault-mig"), backend: SoftwareKeyBackend())
        let legacy = Legacy(); let lk = SymmetricKey(size: .bits256); legacy.key = lk
        let adopted = try mv.adoptLegacy(name: "acct/calendar-cache", purpose: .calendarCache, legacy: { legacy.key },
                                         deleteLegacy: { legacy.deletes += 1; legacy.key = nil })
        check(adopted.map(bytes) == bytes(lk) && legacy.key == nil && legacy.deletes == 1, "legacy key adopted, plain copy deleted")
        check(mv.wrapped(named: "acct/calendar-cache").flatMap { try? mv.unwrapSync($0, context: nil) }.map(bytes) == bytes(lk),
              "adopted key unwraps to the legacy key (existing cache stays readable)")
        legacy.key = SymmetricKey(size: .bits256)  // a stray plain copy reappears (older build)
        let again = try mv.adoptLegacy(name: "acct/calendar-cache", purpose: .calendarCache, legacy: { legacy.key },
                                       deleteLegacy: { legacy.deletes += 1; legacy.key = nil })
        check(again == nil && legacy.key == nil &&
              mv.wrapped(named: "acct/calendar-cache").flatMap { try? mv.unwrapSync($0, context: nil) }.map(bytes) == bytes(lk),
              "existing wrapped key is never replaced by a stray legacy copy; the stray is deleted")
        check(try mv.adoptLegacy(name: "acct/mail-cache", purpose: .mailCache, legacy: { nil }, deleteLegacy: {}) == nil,
              "nothing to adopt → nil")
        let legacy2 = Legacy(); legacy2.key = SymmetricKey(size: .bits256)
        var delErr: VaultError?
        do {
            _ = try mv.adoptLegacy(name: "acct/mail-cache", purpose: .mailCache, legacy: { legacy2.key },
                                   deleteLegacy: { throw VaultError.legacyDeleteFailed })
        } catch { delErr = error as? VaultError }
        check(delErr == .legacyDeleteFailed && mv.wrapped(named: "acct/mail-cache") != nil,
              "plain-copy delete failure reported; wrapped copy kept (next run deletes the stray)")
        let mailLegacy = SymmetricKey(size: .bits256)
        let idx = try mv.adoptLegacy(name: "acct/mail-index", purpose: .mailIndex,
                                     legacy: { MailStore.deriveIndexKey(from: mailLegacy) }, deleteLegacy: {})
        check(idx.map(bytes) == bytes(MailStore.deriveIndexKey(from: mailLegacy)), "mail-index migrates as the HKDF-derived legacy index key")

        // No-SE fallback: software key in a (fake) Keychain; shred deletes the item.
        final class MemSecret: VaultSecretStore, @unchecked Sendable {
            var data: Data?
            func read() -> Data? { data }
            func write(_ d: Data) throws { data = d }
            func delete() throws { data = nil }
        }
        let sec = MemSecret()
        let fb = EnclaveVault(directory: root.appending(path: "vault-fb"), backend: KeychainFallbackBackend(store: sec))
        let fk = try fb.createKey(name: "acct/calendar-cache", purpose: .calendarCache)
        check(!fb.isHardwareBacked && sec.data != nil && (try? Data(contentsOf: fb.blobURL)) != sec.data,
              "fallback: private key in the Keychain, not in the blob file")
        check(fb.wrapped(named: "acct/calendar-cache").flatMap { try? fb.unwrapSync($0, context: nil) }.map(bytes) == bytes(fk),
              "fallback round-trip")
        try fb.shred()
        check(sec.data == nil && !fb.hasKey, "fallback shred deletes the Keychain item")
        let noSE = PostureReport(fileVault: .yes, sip: .yes, screenLock: .yes, osVersion: OSVersion(27), codeSignature: .notarized,
                                 secureEnclave: .no)
        check(PostureChecker.decide(noSE, policy: .byodDefault) == .restrict(["noSecureEnclave"]), "no Secure Enclave → restrict")
        check(StaticPostureProbes(noSE).secureEnclave() == .no
              && PostureChecker.report(StaticPostureProbes(noSE)).secureEnclave == .no, "posture report carries secureEnclave")

        // Wipe: crypto-shred first, then delete; data unreadable even when file deletion fails.
        final class ShredSpy: CryptoShredding, @unchecked Sendable {
            let watch: URL; let inner: CryptoShredding
            var fileExistedAtShred: Bool?
            init(watch: URL, inner: CryptoShredding) { self.watch = watch; self.inner = inner }
            func shred() throws { fileExistedAtShred = FileManager.default.fileExists(atPath: watch.path); try inner.shred() }
        }
        let wroot = tmpDir()
        let locked = wroot.appending(path: "ro"), storeURL = locked.appending(path: "cal.sqlite")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let wv = EnclaveVault(directory: wroot.appending(path: "vault"), backend: SoftwareKeyBackend())
        let ck = try wv.createKey(name: "acct/calendar-cache", purpose: .calendarCache)
        do {
            let s = try LocalStore(url: storeURL, cipher: AESGCMCipher(key: ck))
            try s.setValue("secret", for: "k")
        }
        let wrappedBefore = wv.wrapped(named: "acct/calendar-cache")!
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)  // file deletion will fail
        let spy = ShredSpy(watch: storeURL, inner: wv)
        let wex = try DefaultWipeExecutor(cacheDirectories: [], storeFiles: [storeURL], keychainItems: [], keychain: FakeKeychain([]),
                                          shredders: [spy], tombstoneURL: wroot.appending(path: "state/wipe.tombstone"), now: { t0 })
        let wr = try wex.wipe(reason: "sessionRevoked")
        check(spy.fileExistedAtShred == true && wr.shreddedVaults == 1, "wipe shreds the vault before deleting any file")
        check(fm.fileExists(atPath: storeURL.path) && wr.failures.contains("path:cal.sqlite") && wex.tombstone?.completed == false,
              "file deletion failed (read-only dir) and is reported")
        check((try? wv.unwrapSync(wrappedBefore, context: nil)) == nil && !wv.hasKey,
              "…but the lingering cache's key can't be recovered: crypto-shredded")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        let wr2 = try wex.wipe(reason: "sessionRevoked")
        check(wr2.failures.isEmpty && !fm.fileExists(atPath: storeURL.path) && wex.tombstone?.completed == true,
              "retry deletes the file; shredding an already-shredded vault is fine")
        try? fm.removeItem(at: wroot)

        // A cancelled prompt must never reset the vault; a dead key must.
        struct FailingBackend: VaultKeyBackend {
            let error: Error
            var kind: VaultBackendKind { .software }
            func create() throws -> (blob: Data, publicKey: P256.KeyAgreement.PublicKey) { try SoftwareKeyBackend().create() }
            func sharedSecret(blob: Data, peer: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret { throw error }
            func destroy() throws {}
        }
        let cancelErr = NSError(domain: "CryptoKit", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: LAErrorDomain, code: LAError.userCancel.rawValue)])
        check(SecureEnclaveBackend.isAuthenticationError(cancelErr)
              && SecureEnclaveBackend.isAuthenticationError(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)))
              && !SecureEnclaveBackend.isAuthenticationError(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))),
              "SE errors: cancel / auth failures (also nested) are classified as authentication, not a dead key")
        let cdir = root.appending(path: "vault-cancel")
        _ = try EnclaveVault(directory: cdir, backend: SoftwareKeyBackend()).createKey(name: "acct/calendar-cache", purpose: .calendarCache)
        let cv = EnclaveVault(directory: cdir, backend: FailingBackend(error: VaultError.authenticationRequired))
        var cancelError: Error?
        do { _ = try cv.unwrapAll(context: nil) } catch { cancelError = error }
        check(cancelError.map { !EnclaveVault.shouldReset(after: $0) } == true && cv.hasKey && cv.wrappedNames.count == 1,
              "cancelled authentication → no reset, vault files survive")
        let dv = EnclaveVault(directory: cdir, backend: FailingBackend(error: VaultError.keyUnusable("test")))
        var deadError: Error?
        do { _ = try dv.unwrapAll(context: nil) } catch { deadError = error }
        check(deadError.map(EnclaveVault.shouldReset) == true && EnclaveVault.shouldReset(after: VaultError.unwrapFailed),
              "unusable key / failed unwrap → reset")

        // App lock: the unlock hook gates the transition (keys unwrapped before the UI unlocks).
        let hookAuth = FakeAuth()
        let hl = AppLock(policy: .init(requireBiometric: true, idleMinutes: 5), authenticator: hookAuth, now: { t0 })
        var hookCalls = 0, hookResult = false
        hl.unlockHook = { ctx in hookCalls += 1; return ctx == nil && hookResult }
        let hu1 = await hl.unlock()
        check(!hu1 && hl.isLocked && hookCalls == 1, "unlock hook failing keeps the app locked")
        hookResult = true
        let hu2 = await hl.unlock()
        check(hu2 && !hl.isLocked && hookCalls == 2, "unlock hook success → unlocked")
        hookAuth.succeed = false; hl.lockNow()
        _ = await hl.unlock()
        check(hookCalls == 2 && hl.isLocked, "failed authentication never reaches the hook")

        // One real Secure Enclave round-trip (no user-presence flag → no prompt). Temp directory, shredded after.
        if EnclaveVault.isAvailable {
            let sv = EnclaveVault(directory: root.appending(path: "vault-se"), backend: SecureEnclaveBackend(flags: [.privateKeyUsage]))
            let sk = try sv.createKey(name: "selftest/calendar-cache", purpose: .calendarCache)
            let blobLen = (try? Data(contentsOf: sv.blobURL))?.count ?? 0
            let su = sv.wrapped(named: "selftest/calendar-cache").flatMap { try? sv.unwrapSync($0, context: nil) }
            check(sv.isHardwareBacked && blobLen > 0 && su.map(bytes) == bytes(sk), "REAL Secure Enclave: create + wrap + unwrap (blob \(blobLen) B)")
            let sw = sv.wrapped(named: "selftest/calendar-cache")!
            try sv.shred()
            check((try? sv.unwrapSync(sw, context: nil)) == nil, "REAL Secure Enclave: shredded → unwrap fails")
        } else {
            print("  – Secure Enclave not available here: real SE test skipped")
        }
        try? fm.removeItem(at: root)
    } catch { failures += 1; print("  ✗ vault threw \(error)") }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var failure: Failure? { if case .failure(let f) = self { f } else { nil } }
}
