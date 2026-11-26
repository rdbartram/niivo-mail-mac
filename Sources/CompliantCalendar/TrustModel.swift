import SwiftUI
import AppKit
import TrustCore

/// App-wide BYOD trust state: effective policy (managed prefs → tenant file → defaults), posture, app lock and the
/// (fixture-only) wipe simulation. Views read this; nothing here touches mail or calendar content.
@MainActor @Observable
final class TrustModel {
    enum WipeState: Equatable { case none, wiped(reason: String, at: Date) }

    private(set) var loaded: LoadedPolicy?
    var policy: TrustPolicy { loaded?.policy ?? .byodDefault }
    private(set) var posture: PostureReport?
    private(set) var postureDecision: PostureDecision = .allow
    private(set) var postureChecking = false
    private(set) var lastRefresh: Date?
    /// Mirrors `AppLock.state` (AppLock isn't observable).
    /// Locked until `start` has read the policy, so nothing renders before the lock decision.
    private(set) var lockState: AppLockState = .locked(.launch)
    private(set) var unlockFailed = false
    private(set) var wipe: WipeState = .none
    private(set) var started = false

    private var lock: AppLock?
    /// Live mode only: the SE-backed cache keys. Set by AppModel once an account is known.
    var keyring: CacheKeyring?
    /// Fired on every transition to locked / unlocked (AppModel closes and reopens its file-backed stores).
    var onLocked: (() -> Void)?
    var onUnlocked: (() async -> Void)?
    private var timer: Timer?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isLocked: Bool { if case .locked = lockState { true } else { false } }
    var isWiped: Bool { wipe != .none }
    var isBlocked: Bool { if case .block = postureDecision { true } else { false } }
    /// Content must not be on screen: locked or wiped. Posture `.block` is shown as a banner in this pass (so a
    /// failing probe on a dev Mac can't take the calendar down); enforcing it as a gate is a one-line change here.
    var hidesContent: Bool { isLocked || isWiped }

    /// Screen capture is a TrustPolicy control on top of per-label rules.
    var blocksScreenCapture: Bool { !effectivePolicy.allowScreenCapture }

    /// Posture `.restrict` tightens the policy (TrustPolicy.restrictedForPosture).
    var effectivePolicy: TrustPolicy {
        if case .restrict = postureDecision { return policy.restrictedForPosture() }
        return policy
    }

    func start(fixtures: Bool) {
        guard !started else { return }
        started = true
        reloadPolicy()
        var lockPolicy = policy.appLock
        // Fixture demo aid only (synthetic data): skip the launch lock for screenshots/automation.
        if fixtures, ProcessInfo.processInfo.environment["CC_DEMO_NO_LOCK"] == "1" { lockPolicy.requireBiometric = false }
        let l = AppLock(policy: lockPolicy, authenticator: LocalAuthenticationAuthenticator())
        l.onChange = { [weak self] s in
            guard let self else { return }
            self.lockState = s
            if case .locked = s {
                self.keyring?.lock()   // drop keys from memory
                self.onLocked?()
            } else {
                Task { await self.onUnlocked?() }
            }
        }
        // Unwrap the cache keys with the context AppLock just authenticated, before the UI unlocks: one prompt.
        l.unlockHook = { [weak self] ctx in await self?.keyring?.unlock(with: ctx) ?? true }
        lock = l
        lockState = l.state
        installMonitors()
        Task { await checkPosture() }
    }

    func reloadPolicy() {
        // No tenant-hosted policy file yet: managed preferences (if any MDM pushes them) over built-in defaults.
        let loader = PolicyLoader(prefs: CFManagedPreferences(bundleId: AppConfig.bundleId),
                                  pinnedKeys: PinnedPolicyKeys(keys: [:]))
        let new = loader.load(tenantJSON: nil, tenantSignature: nil)
        let changed = loaded.map { $0.policy != new.policy } ?? false
        loaded = new
        lastRefresh = .now
        if changed { lock?.policyChanged(new.policy.appLock) }
    }

    func checkPosture() async {
        postureChecking = true
        defer { postureChecking = false }
        // Probes shell out (fdesetup, csrutil, codesign…) with timeouts: keep them off the main thread.
        let report = await Task.detached(priority: .utility) { PostureChecker.report(SystemPostureProbes()) }.value
        posture = report
        postureDecision = PostureChecker.decide(report, policy: policy)
        // Content-free diagnostic: why capture / AI might be clamped on this Mac.
        FileHandle.standardError.write(Data("[Trust] profile=\(policy.profile) posture=\(postureDecision) capture=\(effectivePolicy.allowScreenCapture) ai=\(effectivePolicy.aiAccess)\n".utf8))
        lastRefresh = .now
    }

    // MARK: Lock

    func lockNow() { lock?.lockNow() }

    /// Keys for opening a file-backed store. Locked → false (open after unlock). Unlocked but keys not yet unwrapped (app
    /// lock disabled by policy, or the keyring arrived after the unlock) → one prompt of its own.
    func ensureKeys() async -> Bool {
        guard !isLocked, let keyring else { return false }
        return await keyring.unlock(with: nil)
    }

    func unlock() async {
        unlockFailed = false
        let ok = await lock?.unlock() ?? true
        unlockFailed = !ok
    }

    private func installMonitors() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.lock?.noteActivity() }
            return e
        }
        // Sleep notifications are posted on NSWorkspace's own centre, not NotificationCenter.default.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock?.systemWillSleep() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock?.tick() }
        }
    }

    // MARK: Remote wipe (simulation, fixtures only)

    /// Runs the real decision path (`SessionHealth.decide` with a revoked session) and executes it with an in-memory
    /// executor that only wipes the in-memory fixture stores. Never constructs `DefaultWipeExecutor`.
    func simulateRemoteWipe(executor: InMemoryWipeExecutor) {
        let decision = SessionHealth.decide(policy: policy, lastError: .revoked(.userNotAssigned), wipeGroupMembers: nil,
                                            grace: .ok(offlineSeconds: 0), posture: postureDecision, tombstoned: executor.tombstone != nil)
        guard case .wipe(let reason) = decision else { return }
        _ = try? executor.wipe(reason: reason)
        wipe = .wiped(reason: reason, at: executor.tombstone?.wipedAt ?? .now)
    }

    func resetWipeSimulation(executor: InMemoryWipeExecutor) {
        _ = executor.clearTombstone(freshSignInSucceeded: true, serverConfirmedNotRevoked: true)
        wipe = .none
    }

    // MARK: Display

    static func describe(_ r: ProbeResult) -> (text: String, ok: Bool?) {
        switch r {
        case .yes: ("On", true)
        case .no: ("Off", false)
        case .unverified(let why): ("Couldn't verify (\(why))", nil)
        }
    }

    static func describe(_ s: CodeSignatureState) -> (text: String, ok: Bool?) {
        switch s {
        case .notarized: ("Notarised", true)
        case .signedNotNotarized: ("Signed, not notarised", nil)
        case .adhoc: ("Ad-hoc (development build)", nil)
        case .unsigned: ("Unsigned", nil)
        case .invalid: ("Invalid signature", false)
        case .unverified(let why): ("Couldn't verify (\(why))", nil)
        }
    }

    static func reasonText(_ code: String) -> String {
        switch code {
        case "osBelowMinimum": return "macOS is older than your organisation requires"
        case "fileVaultOff": return "FileVault is off"
        case "sipOff": return "System Integrity Protection is off"
        case "screenLockOff": return "Screen lock isn't required"
        case "codeSignatureInvalid": return "This app's signature is invalid"
        case "notNotarized": return "This build isn't notarised"
        case "noSecureEnclave": return "No Secure Enclave: cache keys are protected by the Keychain only"
        default:
            if code.hasPrefix("fileVaultUnverified") { return "FileVault state couldn't be verified" }
            if code.hasPrefix("sipUnverified") { return "SIP state couldn't be verified" }
            if code.hasPrefix("screenLockUnverified") { return "Screen lock state couldn't be verified" }
            if code.hasPrefix("secureEnclaveUnverified") { return "Secure Enclave state couldn't be verified" }
            return code
        }
    }

    var postureReasons: [String] {
        switch postureDecision {
        case .allow: []
        case .restrict(let r), .block(let r): r.map(Self.reasonText)
        }
    }
}

/// Fixture-only wipe executor: the "wiped locations" are closures over in-memory stores. Keeps a tombstone in memory.
/// Mirrors the `WipeExecutor` contract (tombstone first → delete → mark completed) but can't formally conform:
/// `TrustCore.WipeReport` has no public initialiser (API change requested in the report).
final class InMemoryWipeExecutor: @unchecked Sendable {
    struct Report: Equatable { var removedStores: Int; var failures: [String] }
    private let lock = NSLock()
    private var _tombstone: WipeTombstone?
    private let targets: [@Sendable () throws -> Void]

    init(targets: [@Sendable () throws -> Void]) { self.targets = targets }

    var tombstone: WipeTombstone? { lock.withLock { _tombstone } }
    var canServeData: Bool { tombstone == nil }

    @discardableResult func wipe(reason: String) throws -> Report {
        lock.withLock { _tombstone = WipeTombstone(reason: reason, wipedAt: Date(), completed: false) }
        var removed = 0
        var failures: [String] = []
        for (i, t) in targets.enumerated() {
            do { try t(); removed += 1 } catch { failures.append("store:\(i)") }
        }
        lock.withLock { _tombstone?.completed = failures.isEmpty }
        return Report(removedStores: removed, failures: failures)
    }

    @discardableResult func resumeIfNeeded() throws -> Report? {
        guard let t = tombstone, !t.completed else { return nil }
        return try wipe(reason: t.reason)
    }

    @discardableResult func clearTombstone(freshSignInSucceeded: Bool, serverConfirmedNotRevoked: Bool) -> Bool {
        lock.withLock {
            guard freshSignInSucceeded, serverConfirmedNotRevoked, _tombstone?.completed == true else { return false }
            _tombstone = nil
            return true
        }
    }
}
