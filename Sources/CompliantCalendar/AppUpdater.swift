import SwiftUI
import Sparkle
import TrustCore

/// UPDATE-HOOK: Sparkle 2 auto-update (docs/RELEASING.md). The feed and public key come from Info.plist
/// (scripts/bundle.sh); without them, or when `disableUpdates` is set (MDM), the updater is never started and the
/// menu item / Settings rows explain why instead.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    let policy: UpdatePolicy
    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO) so the menu item enables/disables like Sparkle's own target/action.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (KVO) so the Settings toggle redraws.
    private(set) var autoChecks = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        // Bare `swift run` binaries have no bundle id / Info.plist: resolve() reports .notConfigured.
        policy = UpdatePolicy.resolve(info: Bundle.main.infoDictionary ?? [:],
                                      prefs: CFManagedPreferences(bundleId: AppConfig.bundleId))
        guard policy.updatesAllowed else { controller = nil; return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        // A forced SUEnableAutomaticChecks needs no code: Sparkle reads it through our user defaults, where the
        // managed value wins. Sparkle's docs: don't set automaticallyChecksForUpdates on launch.
        c.startUpdater()
        refresh()
        // Sparkle mutates these on the main thread; hop explicitly and re-read there (strict concurrency).
        let hop: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.refresh() } }
        observations = [
            c.updater.observe(\.canCheckForUpdates) { _, _ in hop() },
            c.updater.observe(\.lastUpdateCheckDate) { _, _ in hop() },
            c.updater.observe(\.automaticallyChecksForUpdates) { _, _ in hop() },
        ]
    }

    private func refresh() {
        guard let u = controller?.updater else { return }
        canCheckForUpdates = u.canCheckForUpdates
        lastCheck = u.lastUpdateCheckDate
        autoChecks = u.automaticallyChecksForUpdates
    }

    var isActive: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { autoChecks }
        set {
            guard let c = controller, policy.forcedAutomaticChecks == nil else { return }
            c.updater.automaticallyChecksForUpdates = newValue   // Sparkle persists it in our user defaults
            refresh()
        }
    }

    /// Why updates are off, for the Settings row; nil when the updater runs.
    var offReason: String? {
        switch policy.off {
        case nil: nil
        case .notConfigured: "This build has no update feed (built without SPARKLE_PUBLIC_KEY). Install new versions manually."
        case .disabled(forced: true): "Updates are managed by your organisation."
        case .disabled(forced: false): "Updates are turned off on this Mac (disableUpdates)."
        }
    }

    var versionString: String {
        let i = Bundle.main.infoDictionary ?? [:]
        let short = i["CFBundleShortVersionString"] as? String ?? "–"
        let build = i["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }
}

/// App menu: "Check for Updates…" right after "About niivo mail".
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if AppUpdater.shared.isActive { CheckForUpdatesButton() }
        }
    }
}

/// A View (not inline in `Commands`), as in Sparkle's SwiftUI guide, so the enabled state tracks the updater.
private struct CheckForUpdatesButton: View {
    var body: some View {
        let u = AppUpdater.shared
        Button("Check for Updates…") { u.checkForUpdates() }.disabled(!u.canCheckForUpdates)
    }
}

/// Settings → Updates.
struct UpdateSettingsSection: View {
    var body: some View {
        let u = AppUpdater.shared
        Section("Updates") {
            LabeledContent("Version") { Text(u.versionString) }
            if let why = u.offReason {
                Text(why).font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Check for updates automatically",
                       isOn: Binding(get: { u.automaticallyChecks }, set: { u.automaticallyChecks = $0 }))
                    .disabled(u.policy.forcedAutomaticChecks != nil)
                if u.policy.forcedAutomaticChecks != nil {
                    Text("Set by your organisation.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Now") { u.checkForUpdates() }.disabled(!u.canCheckForUpdates)
                    if let d = u.lastCheck {
                        Text("Last checked \(d.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
