import SwiftUI
import AppKit
import MailCore

/// Process entry. `--theme-preview <dir>` renders the key views to PNGs (fixtures only) and exits without starting the
/// app's scenes (no WindowGroup, no menu-bar item, no alerts). Anything else runs the app.
@main
enum AppEntry {
    @MainActor static func main() {
        if ThemePreview.isRunning { ThemePreview.run() } else { CompliantCalendarApp.main() }
    }
}

/// Offscreen renderer for design review. Always on synthetic fixture data (AppModel forces fixtures while this runs),
/// never signs in, never writes the theme to UserDefaults. Renders through an offscreen NSWindow + `cacheDisplay`
/// so AppKit-backed controls (List, TextField, segmented pickers, toolbars) draw, which `ImageRenderer` can't.
@MainActor enum ThemePreview {
    nonisolated static let isRunning = CommandLine.arguments.contains("--theme-preview") || CommandLine.arguments.contains("--render-icon")

    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run() {
        // Fixture demo switches: no notification-centre registration, no launch lock (the lock shot locks manually).
        setenv("CC_DEMO_ALLOW_CAPTURE", "1", 1)
        setenv("CC_DEMO_NO_LOCK", "1", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let a = CommandLine.arguments
                if let i = a.firstIndex(of: "--render-icon") {
                    // `--render-icon <dir>`: iconset + AppIcon.icns + previews (scripts/bundle.sh embeds build/icon/AppIcon.icns).
                    let dir = URL(fileURLWithPath: i + 1 < a.count ? a[i + 1] : "build/icon", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try await IconRender.run(outDir: dir)
                    print("render-icon: wrote \(dir.path)")
                } else {
                    try await render()
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("theme-preview failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    private static var outDir: URL {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--theme-preview"), i + 1 < a.count, !a[i + 1].hasPrefix("-") {
            return URL(fileURLWithPath: a[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: "build/theme-preview", isDirectory: true)
    }

    private static func render() async throws {
        guard NiivoFonts.available else { throw Failure(description: "brand fonts not registered (resource bundle missing?)") }
        let dir = outDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel()
        await model.start()
        guard model.isFixtureMode else { throw Failure(description: "not in fixture mode; refusing to render") }
        guard model.theme.brand else { throw Failure(description: "theme is \(model.theme.id), expected niivo") }
        await model.startMailIfNeeded()
        let mail = model.mail
        try await waitFor("mail rows") { !mail.visibleRows.isEmpty }

        // Reader: a labelled, watermarked message if the fixtures have one, else any labelled one.
        let rows = mail.visibleRows
        let pick = rows.first { $0.policy.watermark != nil && $0.policy.labelState != .unlabeled && !$0.policy.bodyIsProtected }
            ?? rows.first { $0.policy.label != nil } ?? rows[0]
        mail.selectedMessageId = pick.id
        try await waitFor("reader") { mail.reader != nil && mail.reader?.loading == false }

        let skin = model.skin
        func shot<V: View>(_ name: String, _ size: CGSize, dark: Bool, _ v: V) async throws {
            let root = v.environment(model).skinned(skin)
                .background(skin.ground)
                .frame(width: size.width, height: size.height)
            try await capture(root, size: size, dark: dark, to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }

        model.section = .mail
        for dark in [false, true] {
            try await shot("mail", CGSize(width: 1360, height: 820), dark: dark, MailRootView())
        }

        // Unknown-label row + reader: a second mail shot with the unknown-label message selected (if fixtures have one).
        if let unknown = rows.first(where: { if case .unknown = $0.policy.labelState { true } else { false } }) {
            mail.selectedMessageId = unknown.id
            try await waitFor("reader (unknown label)") { mail.reader?.header.id == unknown.id && mail.reader?.loading == false }
            try await shot("mail-unknown-label", CGSize(width: 1360, height: 820), dark: false, MailRootView())
            mail.selectedMessageId = pick.id
            try await waitFor("reader") { mail.reader?.header.id == pick.id && mail.reader?.loading == false }
        }

        // Composer: an external recipient, a label and some text.
        mail.run(.compose)
        if let c = mail.composer {
            c.to = [EmailAddress(name: "Alex Kim", address: "alex.kim@contoso.example"),
                    EmailAddress(name: "Person1", address: "person1@fabrikam.example")]
            c.subject = "Board pack, Q4 draft"
            c.body = "Hi both,\n\nThe draft is in the shared folder. Comments by Thursday work.\n\nThanks"
            if let l = mail.compliance.availableLabels().first(where: { $0.name.localizedCaseInsensitiveContains("confidential") })
                ?? mail.compliance.availableLabels().last {
                c.setLabel(l.id, engine: mail.compliance)
            }
            for dark in [false, true] {
                try await shot("composer", CGSize(width: 720, height: 700), dark: dark, ComposerView(composer: c))
            }
            mail.composer = nil
        }

        mail.paletteQuery = "ar"
        for dark in [false, true] {
            try await shot("palette", CGSize(width: 540, height: 400), dark: dark, CommandPaletteView())
        }
        mail.paletteQuery = ""
        try await shot("cheatsheet", CGSize(width: 980, height: 520), dark: false, CheatSheetView())
        for dark in [false, true] {
            try await shot("settings", CGSize(width: 820, height: 600), dark: dark, MailSettingsView())
        }

        // Perf (fixtures): 200 j/k selection steps through the niivo shell hosted in a live offscreen window,
        // each step = model change + one SwiftUI update pass (layout + render) before the next.
        do {
            let host = NSHostingView(rootView: MailRootView().environment(model).skinned(skin).frame(width: 1360, height: 820))
            let w = OffscreenWindow(contentRect: NSRect(x: -30000, y: 0, width: 1360, height: 820), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.contentView = host; w.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))
            var worst = 0.0
            let t0 = Date()
            for i in 0..<200 {
                let s0 = Date()
                mail.run(i % 80 < 40 ? .next : .previous)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                worst = max(worst, Date().timeIntervalSince(s0))
            }
            let total = Date().timeIntervalSince(t0)
            print(String(format: "perf: %d rows, 200 selection steps in %.0f ms (avg %.2f ms, worst %.2f ms)",
                         mail.visibleRows.count, total * 1000, total * 5, worst * 1000))
            w.orderOut(nil)
            mail.selectedMessageId = pick.id
            try await waitFor("reader") { mail.reader?.header.id == pick.id && mail.reader?.loading == false }
        }

        // Multi-select + hover: three marked rows, the pointer over a fourth.
        let ids = mail.visibleRows.map(\.id)
        if ids.count > 6 {
            MailChrome.shared.marked = Set(ids[1...3]); MailChrome.shared.anchor = ids[1]
            mail.selectedMessageId = ids[3]
            NUI.shared.hovered = AnyHashable(ids[5])
            try await waitFor("reader (multi)") { mail.reader?.header.id == ids[3] && mail.reader?.loading == false }
            try await shot("mail-hover-select", CGSize(width: 1360, height: 820), dark: false, MailRootView())
            MailChrome.shared.marked = []; NUI.shared.hovered = nil
            mail.selectedMessageId = pick.id
            try await waitFor("reader") { mail.reader?.header.id == pick.id && mail.reader?.loading == false }
        }

        // AI surfaces with canned content (no provider): row "needs you" lines, reader intents + thread header,
        // briefing, composer AI bar + draft popover.
        let tags: [AITriageTag] = [.replyNeeded, .waitingOnThem, .replyNeeded, .fyi, .bulk, .fyi, .replyNeeded]
        let asks = ["Approve the Q4 board pack by Thursday", "Waiting for Alex to confirm the venue", "Send the signed NDA back",
                    nil, nil, nil, "Pick a slot for the steering call"]
        var tri: [String: AITriage] = [:]
        for (i, r) in mail.visibleRows.prefix(14).enumerated() { tri[r.id] = AITriage(tag: tags[i % tags.count], ask: asks[i % asks.count], aiGenerated: true) }
        mail.ai.preview = .init(triage: tri, summary: AIThreadSummary(
            tldr: "Alex needs the Q4 board pack signed off before Thursday's meeting; finance has already approved the numbers.",
            decisions: [AICitedLine(text: "Board meets Thursday 14:00, room 3.02", cites: [1])],
            openQuestions: [AICitedLine(text: "Does legal need to review the appendix?", cites: [2])],
            owes: [AICitedLine(text: "You: approve the pack", cites: [1]), AICitedLine(text: "Alex: circulate the final PDF", cites: [2])],
            sources: [], notes: ["Summarised on this Mac's provider · 3 messages"]))
        for dark in [false, true] {
            try await shot("reader-intents", CGSize(width: 820, height: 760), dark: dark, ReaderView())
            try await shot("briefing", CGSize(width: 560, height: 520), dark: dark, AIBriefingView())
        }
        try await shot("mail-ai", CGSize(width: 1360, height: 820), dark: false, MailRootView())
        if let plain = mail.visibleRows.first(where: { !$0.policy.bodyIsProtected && !$0.policy.redactDetails && MailActionRights.allows(.reply, policy: $0.policy) }) {
            mail.selectedMessageId = plain.id
            try? await waitFor("reader (reply)", timeout: 5) { mail.reader?.header.id == plain.id && mail.reader?.loading == false }
        }
        mail.run(.reply)
        try? await waitFor("reply composer", timeout: 5) { mail.composer != nil }
        if let c = mail.composer {
            c.body = "Hi Alex,\n\nThanks — approved from my side. One question on the appendix below.\n\n" + c.body
            for dark in [false, true] {
                try await shot("composer-ai", CGSize(width: 1140, height: 700), dark: dark,
                               HStack(alignment: .top, spacing: 0) { ComposerView(composer: c).frame(width: 720); AIDraftPopover().padding(.top, 60).padding(.leading, 10); Spacer() })
            }
            mail.composer = nil
        }
        mail.ai.preview = nil

        // Inline reply in the reading pane, the same draft popped out into a window, and a message window.
        if let plain = mail.visibleRows.first(where: { !$0.policy.bodyIsProtected && !$0.policy.redactDetails && MailActionRights.allows(.reply, policy: $0.policy) }) {
            mail.selectedMessageId = plain.id
            try? await waitFor("reader (inline)", timeout: 5) { mail.reader?.header.id == plain.id && mail.reader?.loading == false }
            mail.run(.reply)
            try? await waitFor("inline composer", timeout: 5) { mail.composer != nil }
            if let c = mail.composer {
                c.body = "Thanks Jordan — Thursday works. I'll bring the draft agenda."
                ComposeHost.shared.placement = .inline
                for dark in [false, true] { try await shot("mail-inline-reply", CGSize(width: 1360, height: 820), dark: dark, MailRootView()) }
                ComposeHost.shared.placement = .window
                try await shot("composer-window", CGSize(width: 760, height: 720), dark: false, ComposerWindowRoot())
                ComposeHost.shared.placement = .inline
                mail.composer = nil
            }
        }
        await MessageWindows.shared.load(pick.id, mail: mail)
        for dark in [false, true] { try await shot("message-window", CGSize(width: 820, height: 760), dark: dark, MessageWindowRoot(messageId: pick.id)) }
        mail.selectedMessageId = pick.id
        try await waitFor("reader") { mail.reader?.header.id == pick.id && mail.reader?.loading == false }
        for dark in [false, true] { try await shot("reader-label", CGSize(width: 820, height: 760), dark: dark, ReaderView()) }

        // Calendar: week grid + inspector on the first event that carries a label.
        model.section = .calendar
        model.selectedEventId = model.weekEvents.first { model.policy(for: $0).label != nil }?.id ?? model.weekEvents.first?.id
        for dark in [false, true] {
            try await shot("calendar", CGSize(width: 1360, height: 820), dark: dark, PreviewCalendar())
        }
        model.viewMode = .schedule
        for dark in [false, true] {
            try await shot("calendar-schedule", CGSize(width: 1360, height: 820), dark: dark, PreviewCalendar())
        }
        model.viewMode = .grid
        if let e = model.selectedEvent {
            for dark in [false, true] {
                try await shot("calendar-inspector", CGSize(width: 360, height: 820), dark: dark, EventInspector(event: e).frame(width: 340).background(skin.card))
            }
        }
        if let ed = model.weekEvents.first(where: { model.canEdit($0) && model.policy(for: $0).label != nil }) ?? model.weekEvents.first(where: { model.canEdit($0) }) {
            model.selectedEventId = ed.id
            InlineEventEdit.shared.begin(ed)
            for dark in [false, true] {
                try await shot("calendar-inspector-edit", CGSize(width: 360, height: 820), dark: dark, EventInspector(event: ed).frame(width: 340).background(skin.card))
            }
            InlineEventEdit.shared.cancel()
        }
        model.newEvent()
        for dark in [false, true] {
            try await shot("calendar-editor", CGSize(width: 640, height: 760), dark: dark, EventEditor())
        }
        model.showEditor = false

        // Lock screen: the launch-lock state, rendered without locking (the preview runs with the launch lock off).
        for dark in [false, true] {
            try await shot("lock", CGSize(width: 1100, height: 720), dark: dark, TrustGateView(previewState: .locked(.launch)))
        }
        try IconRender.glyphSheet(outDir: dir)
        try await IconRender.run(outDir: dir.appendingPathComponent("icon", isDirectory: true))
        print("theme-preview: wrote PNGs to \(dir.path)")
    }

    private static func waitFor(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { throw Failure(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A borderless-free, unconstrained window placed far offscreen.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(1200))
        host.layoutSubtreeIfNeeded()
        // The frame view includes the titlebar/toolbar; fall back to the hosting view.
        let target: NSView = w.contentView?.superview ?? host
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw Failure(description: "no bitmap for \(url.lastPathComponent)") }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "png encode failed") }
        try png.write(to: url)
        w.orderOut(nil)
        w.close()
    }
}

/// The calendar section's split, as RootView builds it, for the preview.
private struct PreviewCalendar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.theme.brand { CalendarShellView() } else { split }
    }
    private var split: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            WeekView()
                .inspector(isPresented: .constant(model.selectedEvent != nil)) {
                    if let e = model.selectedEvent { EventInspector(event: e).inspectorColumnWidth(min: 300, ideal: 340) }
                }
        }
        .toolbar { SectionSwitch() }
        .toolbar { MainToolbar() }
    }
}
