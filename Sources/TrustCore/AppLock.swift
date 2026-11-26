import Foundation
import LocalAuthentication

public enum LockReason: String, Sendable, Codable {
    case launch, idle, sleep, policyChanged, manual
}

public enum AppLockState: Sendable, Equatable {
    case unlocked
    case locked(LockReason)
}

public protocol LocalAuthenticating: Sendable {
    /// `reason` is shown in the system sheet. Returns true on success.
    func authenticate(reason: String) async -> Bool
}

/// An LAContext that has just passed `.deviceOwnerAuthentication`. It goes to `EnclaveVault.unwrapAll`, so every
/// cache key unwraps behind that one prompt (the SE accepts an evaluated context for its access-control check;
/// `touchIDAuthenticationAllowableReuseDuration` alone wouldn't cover the password fallback). `LAContext` isn't
/// Sendable: this box only moves it from the authenticator to the unlock hook, and the hook must not keep it.
/// `AppLock` invalidates it once the hook returns.
public final class AuthenticatedContext: @unchecked Sendable {
    public let context: LAContext
    public init(_ context: LAContext) { self.context = context }
}

/// An authenticator that can hand out the authenticated context (for SE key unwrapping).
public protocol ContextAuthenticating: LocalAuthenticating {
    func authenticateContext(reason: String) async -> AuthenticatedContext?
}

/// Touch ID with the Mac password as fallback (`.deviceOwnerAuthentication`). One fresh `LAContext` per attempt; the
/// successful one is handed to the vault, then invalidated.
public struct LocalAuthenticationAuthenticator: ContextAuthenticating {
    public init() {}
    public func authenticateContext(reason: String) async -> AuthenticatedContext? {
        let ctx = LAContext()
        // No `touchIDAuthenticationAllowableReuseDuration`: a recent Mac unlock must not satisfy the app lock silently.
        // The evaluated context itself is what the SE accepts for every key in this unlock.
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return nil }
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        return AuthenticatedContext(ctx)
    }
    public func authenticate(reason: String) async -> Bool {
        guard let c = await authenticateContext(reason: reason) else { return false }
        c.context.invalidate()
        return true
    }
}

/// Event-driven app-lock state machine with injected time (no timers inside; the app calls `tick()` from its
/// own timer and forwards activity / sleep notifications).
@MainActor
public final class AppLock {
    public private(set) var state: AppLockState
    public private(set) var policy: AppLockPolicy
    private let now: TrustNow
    private let authenticator: LocalAuthenticating
    private var lastActivity: Date
    public var onChange: ((AppLockState) -> Void)?
    /// Runs after a successful authentication and before the state flips to `.unlocked`; returning false keeps the app
    /// locked. The app unwraps its cache keys here with the authenticated context (nil if the authenticator can't
    /// provide one), so "unlocked" implies "keys in memory".
    public var unlockHook: (@MainActor (AuthenticatedContext?) async -> Bool)?

    public init(policy: AppLockPolicy, authenticator: LocalAuthenticating, now: @escaping TrustNow = { Date() }) {
        self.policy = policy; self.authenticator = authenticator; self.now = now
        lastActivity = now()
        state = policy.requireBiometric ? .locked(.launch) : .unlocked
    }

    public var isLocked: Bool { if case .locked = state { true } else { false } }

    private func set(_ s: AppLockState) { guard s != state else { return }; state = s; onChange?(s) }

    private func lock(_ r: LockReason) {
        guard policy.requireBiometric, !isLocked else { return }
        set(.locked(r))
    }

    /// User input (key, click, scroll) while unlocked.
    public func noteActivity() { if !isLocked { lastActivity = now() } }

    /// Call periodically; locks after `idleMinutes` without activity.
    public func tick() {
        guard !isLocked, policy.idleMinutes > 0 else { return }
        if now().timeIntervalSince(lastActivity) >= Double(policy.idleMinutes) * 60 { lock(.idle) }
    }

    /// NSWorkspace.willSleepNotification / screensDidSleepNotification / session resign.
    public func systemWillSleep() { lock(.sleep) }

    public func lockNow() { lock(.manual) }

    /// Call whenever the effective `TrustPolicy` changes (any field, not just the lock settings): re-locks so the new
    /// rules apply behind a fresh unlock. A policy that disables the lock never unlocks a locked app by itself;
    /// it takes one successful authentication first.
    public func policyChanged(_ new: AppLockPolicy) {
        policy = new
        if isLocked { if new.requireBiometric { set(.locked(.policyChanged)) } }
        else { lock(.policyChanged) }
    }

    @discardableResult
    public func unlock(reason: String = "Unlock niivo mail") async -> Bool {
        guard isLocked else { return true }
        var ctx: AuthenticatedContext?
        if let ca = authenticator as? ContextAuthenticating {
            ctx = await ca.authenticateContext(reason: reason)
            guard ctx != nil else { return false }
        } else {
            guard await authenticator.authenticate(reason: reason) else { return false }
        }
        defer { ctx?.context.invalidate() }
        if let unlockHook, !(await unlockHook(ctx)) { return false }
        guard isLocked else { return true }  // a concurrent unlock won
        lastActivity = now()
        set(.unlocked)
        return true
    }
}
