import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import CalendarCore
import MailCore

// App lifecycle + system integration: launch at login, keep running in the menu bar, the background sync clock's
// "are windows open" input, mailto: / .ics handling, the default-mail-app button and the sync-status surface.
// Pure logic (mailto parsing, claims, cadence, filters) is in MailCore/AppLifecycle.swift.

/// AppKit delegate (via `NSApplicationDelegateAdaptor`). URLs arrive through our own Apple-event handler only, so a
/// mailto: link opens exactly one composer; files (.ics) through `application(_:open:)`.
final class LifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppLifecycle.shared.keepRunningInMenuBar }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for u in urls { AppLifecycle.shared.open(u) } }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // mailto: parsed from the raw string: URL(string:) can reject or re-encode a sloppy link.
        MainActor.assumeIsolated { AppLifecycle.shared.open(raw: s) }
    }
}

@MainActor @Observable
final class AppLifecycle {
    static let shared = AppLifecycle()

    @ObservationIgnored weak var model: AppModel?
    /// Captured from a live view: lets the menu bar, notifications and URL handlers recreate a closed main window.
    @ObservationIgnored var openWindow: OpenWindowAction?

    // MARK: Settings

    /// Closing the last window leaves the app in the menu bar (syncing, notifying). Default on.
    var keepRunningInMenuBar: Bool = UserDefaults.standard.object(forKey: "app.keepRunningInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepRunningInMenuBar, forKey: "app.keepRunningInMenuBar") }
    }

    private(set) var launchAtLoginError: String?
    private(set) var launchAtLoginTick = 0   // re-read the SMAppService status after a change

    var launchAtLogin: Bool {
        _ = launchAtLoginTick
        return SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    var launchAtLoginNote: String? {
        _ = launchAtLoginTick
        if let launchAtLoginError { return launchAtLoginError }
        if SMAppService.mainApp.status == .requiresApproval { return "Approve niivo mail in System Settings › General › Login Items." }
        return nil
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginError = Bundle.main.bundleIdentifier == nil
                ? "Launch at login needs the app bundle; this build can't register."
                : "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLoginTick += 1
    }

    // MARK: Windows

    /// A real document window is on screen (menu bar panel, status item and minimised windows don't count).
    var windowsVisible: Bool {
        NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && !(w is NSPanel) && w.canBecomeMain && w.level == .normal
        }
    }

    /// Bring the main window forward, recreating it if it was closed. Every lifecycle entry point goes through here,
    /// so an interactive sign-in has a real window to present from.
    func ensureMainWindow() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: "main")
        } else {
            AppModel.raiseMainWindow()
        }
    }

    // MARK: URLs and files

    private var pendingMailto: MailtoLink?
    private var pendingICS: URL?
    private var drainTask: Task<Void, Never>?
    private var lastURL: (String, Date)?
    private var waitingToastShown = false

    func open(raw: String) {
        if raw.lowercased().hasPrefix("mailto:") { openMailto(raw) }
        else if let url = URL(string: raw) { open(url) }
    }

    private func openMailto(_ raw: String) {
        if isDuplicate(raw) { return }
        guard let link = MailtoLink.parse(raw) else { return }
        pendingMailto = link
        model?.section = .mail
        ensureMainWindow()
        drain()
    }

    /// One path per URL: ignore an immediate duplicate (Apple event + scene delivery).
    private func isDuplicate(_ key: String) -> Bool {
        if let (k, d) = lastURL, k == key, Date().timeIntervalSince(d) < 1 { return true }
        lastURL = (key, Date())
        return false
    }

    func open(_ url: URL) {
        if url.scheme?.lowercased() == "mailto" { openMailto(url.absoluteString); return }
        if isDuplicate(url.absoluteString) { return }
        if url.isFileURL, url.pathExtension.lowercased() == "ics" {
            pendingICS = url
            model?.section = .calendar
        } else {
            return   // msauth.* and anything else: not ours
        }
        ensureMainWindow()
        drain()
    }

    /// Waits (up to 10 min) for Mail / the calendar to be ready and unlocked, then acts.
    private func drain() {
        guard drainTask == nil else { return }
        waitingToastShown = false
        drainTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(600)
            while let self, Date() < deadline, self.pendingMailto != nil || self.pendingICS != nil {
                if let model = self.model, !model.trust.hidesContent {
                    if let link = self.pendingMailto, model.mail.started, self.composeFromMailto(link, model: model) { self.pendingMailto = nil }
                    if let url = self.pendingICS, !model.writableCalendars.isEmpty {
                        self.pendingICS = nil
                        if model.section != .calendar { model.section = .calendar }
                        CalendarExtras.shared.load(url, model)   // the existing import preview; nothing saved until confirmed
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.pendingMailto = nil; self?.pendingICS = nil
            self?.drainTask = nil
        }
    }

    /// Opens a prefilled composer. Never replaces an open draft: waits for it to close (with one toast).
    private func composeFromMailto(_ link: MailtoLink, model: AppModel) -> Bool {
        let mail = model.mail
        if mail.composer != nil {
            if !waitingToastShown {
                waitingToastShown = true
                mail.toast(MailToast(text: "Close the open message to start the one from the link", symbol: "envelope"))
            }
            return false
        }
        if model.section != .mail { model.section = .mail }
        mail.compose()
        guard let c = mail.composer else { return false }
        c.to = link.to.map { EmailAddress(name: "", address: $0) }
        c.cc = link.cc.map { EmailAddress(name: "", address: $0) }
        c.bcc = link.bcc.map { EmailAddress(name: "", address: $0) }
        c.showCcBcc = !link.cc.isEmpty || !link.bcc.isEmpty
        c.subject = link.subject
        if !link.body.isEmpty { c.editor.insert(RichDoc.plain(link.body + "\n"), at: NSRange(location: 0, length: 0)) }
        ensureMainWindow()
        return true
    }

    // MARK: Default mail app

    private(set) var defaultMailError: String?
    private(set) var defaultMailTick = 0

    var defaultMailAppName: String? {
        _ = defaultMailTick
        guard let u = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:x@example.com")!) else { return nil }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }

    var isDefaultMailApp: Bool {
        _ = defaultMailTick
        guard let mine = Bundle.main.bundleURL.standardizedFileURL as URL?,
              let cur = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:x@example.com")!) else { return false }
        return cur.standardizedFileURL == mine
    }

    func makeDefaultMailApp() {
        defaultMailError = nil
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            defaultMailError = "Only the app bundle can be the default mail app."; return
        }
        Task { @MainActor in
            do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") }
            catch { self.defaultMailError = "macOS didn't accept the change: \(error.localizedDescription)" }
            self.defaultMailTick += 1
        }
    }

    // MARK: Auth state (fed by Auth.mailToken)

    /// The silent mail token needs interaction (refresh token expired / revoked, MFA step-up).
    private(set) var mailTokenNeedsInteraction = false
    private(set) var reauthInFlight = false
    private(set) var reauthError: String?
    @ObservationIgnored private var silentTriedFor: String?

    /// TRUST-WIRING: the session enforcer decided "prompt" (MFA, CA, consent, interaction required) on the calendar or
    /// mail token path: the existing "Sign-in required" state, content stays on screen.
    func sessionNeedsInteraction() { mailTokenNeedsInteraction = true }

    func mailTokenSucceeded() { if mailTokenNeedsInteraction { mailTokenNeedsInteraction = false } }

    func mailTokenFailed(_ error: Error) {
        let ns = error as NSError
        // MSALErrorInteractionRequired = -50002 in MSALErrorDomain; "Not signed in" (Auth code 2).
        if (ns.domain == "MSALErrorDomain" && ns.code == -50002) || (ns.domain == "Auth" && ns.code == 2) {
            mailTokenNeedsInteraction = true
        }
    }

    /// What the footer and the menu bar show.
    func health(_ s: MailSyncStatus, now: Date = Date()) -> MailSyncHealth {
        let h = s.health(now: now)
        if mailTokenNeedsInteraction, !h.needsSignIn { return .authRequired }
        return h
    }

    /// Network work pauses while sign-in is needed (no replaying a refused token every 30 s).
    var mailNeedsSignIn: Bool { model.map { health($0.mail.status).needsSignIn } ?? false }

    /// MailModel status hook: a fresh claims challenge gets one silent retry with the claims (queued, no UI).
    func statusChanged(_ s: MailSyncStatus) {
        guard s.authRequired || s.claimsChallenge != nil else { silentTriedFor = nil; return }
        // A claims challenge: silent with the claims. A plain 401: silent with a forced refresh. Once per episode.
        let key = s.claimsChallenge ?? "401"
        guard silentTriedFor != key, !reauthInFlight else { return }
        silentTriedFor = key
        Task { await reauthenticate(interactive: false) }
    }

    /// "Sign in again": silent with the claims, then the sign-in sheet (interactive only from a click), then a sync.
    func reauthenticate(interactive: Bool) async {
        guard let model, let auth = model.auth, !reauthInFlight else { return }
        if interactive {
            // From the menu bar the key window is the panel: bring up the main window to present the sign-in sheet.
            ensureMainWindow()
            try? await Task.sleep(for: .milliseconds(400))
        }
        reauthInFlight = true; reauthError = nil
        defer { reauthInFlight = false }
        do {
            try await auth.reauthenticateMail(claims: model.mail.status.claimsChallenge, interactive: interactive)
            mailTokenNeedsInteraction = false
            await model.mail.sync?.clearAuthChallenge()
            await model.mail.syncNow()
        } catch {
            if interactive { reauthError = "Sign-in didn't complete. Try again." }
            mailTokenFailed(error)
        }
    }

    /// Mail has started on this Mac before (consent granted): start it in the background after login / unlock even
    /// when the calendar is showing, so notifications and counts work without visiting Mail first.
    var startsMailInBackground: Bool { UserDefaults.standard.bool(forKey: "mail.startedBefore") }
    func noteMailStarted() { if !startsMailInBackground { UserDefaults.standard.set(true, forKey: "mail.startedBefore") } }

    // MARK: Menu bar

    /// Unread Inbox count for the menu bar label (setting on, unlocked).
    var menuBarUnread: Int? {
        guard let model, !model.trust.hidesContent, model.mail.started else { return nil }
        let s = MailNotifier.shared.settings(model.mail)
        guard s.menuBarCount, MailNotifier.shared.unreadCount > 0 else { return nil }
        return MailNotifier.shared.unreadCount
    }
}

/// Captures `openWindow` for the lifecycle controller (attach to any always-built view).
struct OpenWindowCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { AppLifecycle.shared.openWindow = openWindow }
    }
}

// MARK: - Sync status surface

/// Sidebar footer / menu bar row: shown only when something needs attention (offline, throttled, sign-in, error).
struct SyncStatusRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var compact = false

    var body: some View {
        let lc = AppLifecycle.shared
        let h = lc.health(app.mail.status)
        if app.mail.started, !app.trust.hidesContent, showsRow(h) {
            HStack(spacing: 6) {
                NSymbol(symbol(h), size: 11, label: h.title).foregroundStyle(tint(h))
                Text(h.title).lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                    .help(detail(h))
                Spacer(minLength: 4)
                if h.needsSignIn {
                    Button(lc.reauthInFlight ? "Signing in…" : "Sign in again") { Task { await lc.reauthenticate(interactive: true) } }
                        .controlSize(.small).disabled(lc.reauthInFlight)
                } else if h == .offline || isError(h) {
                    Button("Retry") { Task { await app.mail.syncNow() } }.controlSize(.small).buttonStyle(.borderless)
                }
            }
            .font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 14 : 12).padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .hairline(skin, edge: .top)
            if let e = lc.reauthError, h.needsSignIn {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }

    private func showsRow(_ h: MailSyncHealth) -> Bool {
        switch h { case .ok, .syncing: false; default: true }
    }
    private func isError(_ h: MailSyncHealth) -> Bool { if case .error = h { true } else { false } }
    private func symbol(_ h: MailSyncHealth) -> String {
        switch h {
        case .offline: "icloud.slash"
        case .throttled: "tortoise"
        case .authRequired, .claimsChallenge: "person.badge.key"
        case .error: "exclamationmark.triangle.fill"
        default: "checkmark.icloud"
        }
    }
    private func tint(_ h: MailSyncHealth) -> Color {
        switch h { case .error, .authRequired, .claimsChallenge: .red; case .offline, .throttled: .orange; default: .green }
    }
    private func detail(_ h: MailSyncHealth) -> String {
        switch h {
        case .claimsChallenge: "Continuous Access Evaluation: your session was revoked or a policy changed. Mail resumes after you sign in."
        case .authRequired: "Microsoft 365 no longer accepts this session. Mail resumes after you sign in."
        case .error(let m): m
        case .throttled: "Exchange Online asked us to slow down (HTTP 429 Retry-After). Mail resumes automatically."
        case .offline: "Showing mail cached on this Mac. Changes are queued and sent when you're back online."
        default: ""
        }
    }
}

/// Menu bar panel: mail glance (unread, sync status) above the calendar list.
struct MenuBarMailSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.mail.started {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Mail").font(.headline)
                    Spacer()
                    let n = MailNotifier.shared.unreadCount
                    Text(n == 0 ? "No unread mail" : "\(n) unread").font(.caption).foregroundStyle(.secondary)
                    Button("Open Mail") { app.section = .mail; AppLifecycle.shared.ensureMainWindow() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                SyncStatusRow(compact: true)
                Divider().padding(.top, 4)
            }
        }
    }
}

// MARK: - Settings

@MainActor private func saveNotificationSettings(_ mail: MailModel, _ change: (inout MailNotificationSettings) -> Void) {
    var n = MailNotifier.shared.settings(mail)
    change(&n)
    let final = n
    Task {
        await mail.update { $0.notifications = final }
        MailNotifier.shared.settingsChanged(final)
    }
}

/// Per-mailbox notification rule (overrides the global Focused / VIP switches).
struct MailboxNotificationRulePicker: View {
    @Environment(AppModel.self) private var app
    var mailbox: String
    var body: some View {
        let mail = app.mail
        let s = MailNotifier.shared.settings(mail)
        let rules = MailNotificationRule.allCases.filter { $0 != .vip || MailNotifier.shared.vipLookup != nil }
        Picker("Notify for", selection: Binding<MailNotificationRule?>(
            get: { s.mailboxRules[mailbox] },
            set: { r in saveNotificationSettings(mail) { $0.mailboxRules[mailbox] = r } })) {
            Text("Default (as above)").tag(MailNotificationRule?.none)
            ForEach(rules, id: \.self) { r in Text(r.title).tag(Optional(r)) }
        }
        .padding(.leading, 26)
        .accessibilityLabel("Notifications for \(MailboxDisplay.title(mailbox))")
    }
}

/// Non-Inbox folders that also notify (e.g. a folder a rule files VIP mail into).
struct NotificationFolderPicker: View {
    @Environment(AppModel.self) private var app
    private static let excluded: Set<WellKnownFolder> = [.inbox, .drafts, .sentitems, .deleteditems, .junkemail, .outbox]

    var body: some View {
        let mail = app.mail
        let s = MailNotifier.shared.settings(mail)
        let candidates = s.mailboxes.sorted().flatMap { mb in
            (mail.folders[mb] ?? []).filter { f in f.wellKnown.map { !Self.excluded.contains($0) } ?? true }
        }
        let chosen = candidates.filter { s.folderIds.contains($0.id) }
        LabeledContent("Also notify for folders") {
            Menu(chosen.isEmpty ? "None" : chosen.map(\.displayName).joined(separator: ", ")) {
                ForEach(candidates) { f in
                    Toggle(isOn: Binding(get: { s.folderIds.contains(f.id) }, set: { on in
                        saveNotificationSettings(mail) { if on { $0.folderIds.insert(f.id) } else { $0.folderIds.remove(f.id) } }
                        // Only opened folders take part in the background full pass: open it so its arrivals arrive.
                        if on { Task { await mail.sync?.openFolder(f.id) } }
                    })) {
                        Text(f.mailbox == "me" ? f.displayName : "\(f.displayName) — \(MailboxDisplay.title(f.mailbox))")
                    }
                }
                if candidates.isEmpty { Text("No other folders synced yet") }
            }
            .fixedSize()
        }
    }
}

/// Mail Settings → App: launch at login, menu bar, default mail app.
struct AppLifecycleSettingsSection: View {
    var body: some View {
        let lc = AppLifecycle.shared
        Section("App") {
            Toggle("Open niivo mail when I log in", isOn: Binding(get: { lc.launchAtLogin }, set: { lc.setLaunchAtLogin($0) }))
            if let n = lc.launchAtLoginNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            Toggle("Keep running in the menu bar when the last window closes",
                   isOn: Binding(get: { lc.keepRunningInMenuBar }, set: { lc.keepRunningInMenuBar = $0 }))
            Text("Mail keeps syncing in the background (the Inbox every 2 minutes, everything every 5) so notifications and the counts stay current. Nothing syncs while the app is locked.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Default mail app") {
                HStack {
                    Text(lc.isDefaultMailApp ? "niivo mail" : (lc.defaultMailAppName ?? "None"))
                    if !lc.isDefaultMailApp {
                        Button("Make niivo mail the default mail app") { lc.makeDefaultMailApp() }
                    }
                }
            }
            if let e = lc.defaultMailError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }
}
