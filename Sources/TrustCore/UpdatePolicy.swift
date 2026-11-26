import Foundation

/// Whether the app may update itself (Sparkle, docs/RELEASING.md), resolved from the bundle's Info.plist and the
/// app's preference domain. UI-free so CoreSelfTest can cover it; the app wires it to Sparkle (AppUpdater.swift).
///
/// Managed preferences (same domain as the trust policy, see `CFManagedPreferences`):
///   - `disableUpdates` (Bool) — true turns the updater off entirely: no checks, no "Check for Updates…". Typically
///     forced by MDM so a fleet updates through its own software distribution instead.
///   - `SUEnableAutomaticChecks` (Bool) — Sparkle's own key. When forced by MDM the Settings toggle is locked to it.
public struct UpdatePolicy: Equatable, Sendable {
    public enum Off: Equatable, Sendable {
        /// The build carries no feed URL or public key (a fork or local build without SPARKLE_PUBLIC_KEY).
        case notConfigured
        /// `disableUpdates` is set (`forced` = by MDM, otherwise the user's own `defaults write`).
        case disabled(forced: Bool)
    }

    /// nil = the updater may run.
    public var off: Off?
    /// Non-nil when MDM forces `SUEnableAutomaticChecks`: the automatic-check toggle shows this and can't change.
    public var forcedAutomaticChecks: Bool?

    public var updatesAllowed: Bool { off == nil }

    public init(off: Off?, forcedAutomaticChecks: Bool?) {
        self.off = off; self.forcedAutomaticChecks = forcedAutomaticChecks
    }

    public static let disableKey = "disableUpdates"
    public static let automaticChecksKey = "SUEnableAutomaticChecks"

    /// `info` is the bundle's Info.plist (`Bundle.main.infoDictionary`).
    public static func resolve(info: [String: Any], prefs: ManagedPreferencesReading) -> UpdatePolicy {
        let forcedAuto = prefs.isForced(key: automaticChecksKey) ? bool(prefs.value(forKey: automaticChecksKey)) : nil
        if bool(prefs.value(forKey: disableKey)) == true {
            return UpdatePolicy(off: .disabled(forced: prefs.isForced(key: disableKey)), forcedAutomaticChecks: forcedAuto)
        }
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let feed, feed.scheme == "https", !key.isEmpty else {
            return UpdatePolicy(off: .notConfigured, forcedAutomaticChecks: forcedAuto)
        }
        return UpdatePolicy(off: nil, forcedAutomaticChecks: forcedAuto)
    }

    /// Plist booleans arrive as Bool/NSNumber, or as a string from a hand-written `defaults write … -string`.
    private static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() { case "1", "true", "yes": return true; case "0", "false", "no": return false; default: return nil }
        default: return nil
        }
    }
}
