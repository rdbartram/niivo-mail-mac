import SwiftUI
import AppKit
import WebKit
import CalendarCore
import MailCore

// Accessibility + layout + localisation plumbing for the mail window (BACKLOG §13 / §14):
//  * A11yPrefs: reading pane position, density, preview lines, reader zoom, swipe / strip actions, UI language
//    (MailViewPreferences in MailCore, persisted in UserDefaults) + the mailbox's regional date formats.
//  * L(): strings from the bundled String Catalog (StringCatalog in MailCore; no compiled tables with the CLT).
//  * MailFocus: pane focus cycle — Tab / ⇧Tab on the sidebar and list, ⌥⌘→ / ⌥⌘← anywhere in the mail window,
//    Esc in the reader → back to the list.
//  * NMotion: Reduce Motion / Reduce Transparency fallbacks.

// MARK: - Preferences

@MainActor @Observable final class A11yPrefs {
    static let shared = A11yPrefs()
    var prefs: MailViewPreferences {
        didSet {
            prefs.save()
            if oldValue.readerZoom != prefs.readerZoom { MailFocus.shared.applyZoom(prefs.readerZoom) }
        }
    }
    /// Date / time formats from the signed-in mailbox's `mailboxSettings` (system formats until read).
    var regional = MailRegionalFormat(nil)

    init() {
        prefs = .load()
    }

    func zoom(_ dir: Int) {
        prefs.readerZoom = dir == 0 ? 1.0 : MailViewPreferences.stepZoom(prefs.readerZoom, dir)
    }

    /// Reads the mailbox's regional settings once mail is open. Failure keeps the system formats.
    func loadRegional(_ mail: MailModel) async {
        guard let sync = mail.sync, let r = try? await sync.regionalSettings() else { return }
        regional = MailRegionalFormat(r)
    }
}

// MARK: - Localisation

/// Bundled String Catalog. Located like NiivoFonts (never `Bundle.module`, which traps when the bundle is missing).
enum Loc {
    /// Resolved once at launch (the setting applies after a restart), independent of who touches A11yPrefs first.
    static let language = StringCatalog.resolve(MailViewPreferences.load().language, preferred: Locale.preferredLanguages)
    static let catalog: StringCatalog = {
        let name = "Localizable.xcstrings"
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { roots.append(exe) }
        for root in roots {
            let b = root.appendingPathComponent(NiivoFonts.bundleName)
            for sub in [name, "Contents/Resources/" + name] {
                if let c = try? StringCatalog(contentsOf: b.appendingPathComponent(sub)) { return c }
            }
        }
        FileHandle.standardError.write(Data("[niivo] \(name) not found: English UI\n".utf8))
        return StringCatalog()
    }()
    static var locale: Locale { Locale(identifier: language) }
}

/// UI string in the current language. Keys are the British English source strings. Never pass tenant data
/// (folder, label, category names, senders, subjects) through this.
func L(_ key: String) -> String { Loc.catalog.string(key, language: Loc.language) }

/// Format key (`%@`, `%lld`), e.g. `L("%lld selected", n)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc.catalog.string(key, language: Loc.language), locale: Loc.locale, arguments: args)
}

// MARK: - Motion / transparency

enum NMotion {
    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @MainActor static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    /// nil (no animation) under Reduce Motion.
    @MainActor static func animation(_ a: Animation) -> Animation? { reduceMotion ? nil : a }
    @MainActor static func with<R>(_ a: Animation, _ body: () throws -> R) rethrows -> R {
        reduceMotion ? try body() : try withAnimation(a, body)
    }
}

extension View {
    /// Material / glass background, solid under Reduce Transparency.
    @ViewBuilder func nMaterial<S: InsettableShape>(_ m: Material, in shape: S, reduce: Bool, solid: Color = Color(nsColor: .windowBackgroundColor)) -> some View {
        if reduce { self.background(solid, in: shape) } else { self.background(m, in: shape) }
    }

    /// Visible keyboard focus ring for a pane (both skins).
    func paneFocusRing(_ on: Bool, skin: Skin) -> some View {
        overlay {
            if on {
                if skin.brand { Rectangle().strokeBorder(skin.accentInk, lineWidth: 2).allowsHitTesting(false) }
                else { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).allowsHitTesting(false) }
            }
        }
    }
}

// MARK: - Pane focus

@MainActor @Observable final class MailFocus {
    static let shared = MailFocus()
    /// Last pane that took keyboard focus (set by the panes).
    var current: MailPane?
    var sidebarToken = 0
    /// The reading pane's web view is first responder (main mail window only).
    var readerFocused = false
    /// Set by sidebar ↑↓: the folder change's focusListToken bump must not pull focus to the list.
    @ObservationIgnored var keepSidebar = false
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var mail: MailModel?
    @ObservationIgnored private let webViews = NSHashTable<ReaderWebView>.weakObjects()

    func register(_ w: ReaderWebView) {
        webViews.add(w)
        w.pageZoom = A11yPrefs.shared.prefs.readerZoom
    }

    func applyZoom(_ z: Double) { for w in webViews.allObjects { w.pageZoom = z } }

    func present(_ mail: MailModel) -> Set<MailPane> {
        var s: Set<MailPane> = [.list]
        if !mail.started { return s }
        if MailChrome.shared.sidebarVisible { s.insert(.sidebar) }
        if A11yPrefs.shared.prefs.pane != .off {
            if mail.composer != nil && ComposeHost.shared.placement == .inline { s.insert(.composer) }
            if mail.reader != nil { s.insert(.reader) }
        }
        return s
    }

    func cycle(forward: Bool, mail: MailModel) {
        guard let next = MailPane.cycle(from: detectCurrent(mail), forward: forward, present: present(mail)) else { return }
        focus(next, mail: mail)
    }

    private func detectCurrent(_ mail: MailModel) -> MailPane? {
        if let r = (mainWindow ?? NSApp.keyWindow)?.firstResponder as? NSView {
            if r is ReaderWebView || r.enclosing(ReaderWebView.self) != nil { return .reader }
            if r is ComposerTextView || (r is NSTextView && mail.composer != nil && current != .sidebar && current != .list) { return .composer }
        }
        return current
    }

    func focus(_ pane: MailPane, mail: MailModel) {
        current = pane
        switch pane {
        case .sidebar: sidebarToken += 1
        case .list: mail.focusListToken += 1
        case .reader:
            guard let win = mainWindow ?? NSApp.keyWindow,
                  let w = webViews.allObjects.first(where: { $0.window === win }) else { mail.focusListToken += 1; return }
            win.makeFirstResponder(w)
        case .composer:
            guard let win = mainWindow ?? NSApp.keyWindow, let tv = win.contentView?.first(ComposerTextView.self) else { return }
            win.makeFirstResponder(tv)
        }
    }

    /// Tab / ⇧Tab / Esc from the reading pane's web view. true = handled.
    func readerKey(_ e: NSEvent, from w: ReaderWebView) -> Bool {
        guard let mail, let win = w.window, win === mainWindow,
              e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }   // ⌥Tab stays WebKit's
        switch e.keyCode {
        case 48: cycle(forward: !e.modifierFlags.contains(.shift), mail: mail); return true   // Tab
        case 53: focus(.list, mail: mail); return true                                        // Esc
        default: return false
        }
    }

    /// Sidebar ↑↓ moved the folder: keep focus there (cleared after the bump, or shortly after if none came).
    func holdSidebar() {
        keepSidebar = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.keepSidebar = false }
    }

    func readerResponder(_ w: ReaderWebView, focused: Bool) {
        guard w.window != nil, w.window === mainWindow else { return }
        readerFocused = focused
        if focused { current = .reader }
    }

    /// Tab / ⇧Tab on a SwiftUI pane (sidebar, list). `.ignored` for anything else.
    func tabKey(_ press: KeyPress, mail: MailModel) -> KeyPress.Result {
        let backTab = press.characters == "\u{19}"
        guard press.key == .tab || backTab else { return .ignored }
        guard press.modifiers.subtracting([.shift]).isEmpty else { return .ignored }
        cycle(forward: !(press.modifiers.contains(.shift) || backTab), mail: mail)
        return .handled
    }
}

extension NSView {
    func enclosing<T: NSView>(_ t: T.Type) -> T? {
        var v = superview
        while let s = v { if let m = s as? T { return m }; v = s.superview }
        return nil
    }
    func first<T: NSView>(_ t: T.Type) -> T? {
        for s in subviews {
            if let m = s as? T { return m }
            if let m = s.first(t) { return m }
        }
        return nil
    }
}

/// Remembers the main mail window (pane focus only acts there, not in message / composer windows).
struct MainMailWindowCapture: NSViewRepresentable {
    var mail: MailModel
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let mail = mail
        MailFocus.shared.mail = mail
        DispatchQueue.main.async { if let w = v.window { MailFocus.shared.mainWindow = w } }
    }
}

/// Hidden key equivalents for the mail window: ⌘= (zoom in on layouts where + needs ⇧).
struct A11yHiddenKeys: View {
    var body: some View {
        Button("") { A11yPrefs.shared.zoom(1) }.keyboardShortcut("=", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Mail menu: pane focus and reader zoom (in both keymaps; no collision with ⌘← / ⌘→, ⌥⌘1–4, ⌘1–7).
struct MailA11yMenu: View {
    var model: AppModel
    var body: some View {
        let off = model.section != .mail || !model.mail.started
        Divider()
        Button(L("Next Pane")) { MailFocus.shared.cycle(forward: true, mail: model.mail) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(off)
        Button(L("Previous Pane")) { MailFocus.shared.cycle(forward: false, mail: model.mail) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(off)
        Button(L("Focus Message List")) { MailFocus.shared.focus(.list, mail: model.mail) }.disabled(off)
        Divider()
        Button(L("Zoom In")) { A11yPrefs.shared.zoom(1) }.keyboardShortcut("+", modifiers: .command).disabled(model.section != .mail)
        Button(L("Zoom Out")) { A11yPrefs.shared.zoom(-1) }.keyboardShortcut("-", modifiers: .command).disabled(model.section != .mail)
        Button(L("Actual Size")) { A11yPrefs.shared.zoom(0) }.keyboardShortcut("0", modifiers: .command).disabled(model.section != .mail)
    }
}

// MARK: - Row actions (labels / symbols for the MailCore enum)

extension RowQuickAction {
    var title: String {
        switch self {
        case .toggleRead: L("Mark as Read / Unread")
        case .flag: L("Flag / Clear Flag")
        case .snooze: L("Snooze")
        case .archive: L("Archive")
        case .delete: L("Delete")
        }
    }
}

// MARK: - VoiceOver

enum MailA11y {
    /// Spoken row summary. Built only from what the row itself shows under the content policy (redacted → "Private").
    @MainActor static func rowLabel(_ row: MailRow) -> String {
        let m = row.message, p = row.policy
        var parts: [String] = []
        if !m.isRead { parts.append(L("Unread")) }
        parts.append(p.redactDetails ? L("Private") : (m.from?.display ?? L("(no sender)")))
        parts.append(p.redactDetails ? L("Private message") : (m.subject.isEmpty ? L("(no subject)") : m.subject))
        if m.importance == .high { parts.append(L("High importance")) }
        if m.flag.status == .flagged { parts.append(L("Flagged")) }
        if m.hasAttachments { parts.append(L("Has attachments")) }
        if p.bodyIsProtected { parts.append(L("Encrypted")) }
        if case .labeled(let l) = p.labelState { parts.append(L("Label %@", l.name)) }
        if m.snoozedUntil != nil { parts.append(L("Snoozed")) }
        if m.pendingSync { parts.append(L("Waiting to sync")) }
        if row.count > 1 { parts.append(L("%lld messages", row.count)) }
        parts.append(A11yPrefs.shared.regional.dateTime(m.received))
        return parts.joined(separator: ", ")
    }
}

extension View {
    /// Message row for VoiceOver: one element, gated label, triage actions (the hover strip only exists on hover).
    func messageRowAccessibility(_ row: MailRow, selected: Bool, mail: MailModel) -> some View {
        let m = row.message
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MailA11y.rowLabel(row))
            .accessibilityHint(L("Return opens the message. Actions: archive, delete, flag, snooze, read."))
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { mail.selectedMessageId = row.id }
            .accessibilityAction(named: m.isRead ? L("Mark as Unread") : L("Mark as Read")) { mail.rowAction(.toggleRead, id: row.id) }
            .accessibilityAction(named: m.flag.status == .flagged ? L("Clear Flag") : L("Flag")) { mail.rowAction(.flag, id: row.id) }
            .accessibilityAction(named: L("Archive")) { mail.rowAction(.archive, id: row.id) }
            .accessibilityAction(named: L("Delete")) { mail.rowAction(.delete, id: row.id) }
            .accessibilityAction(named: L("Snooze")) { mail.rowAction(.snooze, id: row.id) }
            .accessibilityAction(named: L("Reply")) { mail.selectedMessageId = row.id; mail.run(.reply) }
    }

    /// Rotors over the message list: unread and flagged messages.
    func messageListRotors(_ rows: [MailRow]) -> some View {
        self
            .accessibilityRotor(L("Unread messages")) {
                ForEach(rows.filter { !$0.message.isRead }) { r in AccessibilityRotorEntry(MailA11y.rowLabel(r), id: r.id) }
            }
            .accessibilityRotor(L("Flagged messages")) {
                ForEach(rows.filter { $0.message.flag.status == .flagged }) { r in AccessibilityRotorEntry(MailA11y.rowLabel(r), id: r.id) }
            }
    }
}

// MARK: - Layout helpers

/// Horizontal drag handle (reading pane at the bottom).
struct NSplitHandleH: View {
    @Environment(\.skin) private var skin
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    var body: some View {
        Rectangle().fill(skin.hair).frame(height: 1)
            .overlay {
                Color.clear.frame(height: 7).contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation.height) }
                        .onEnded { _ in onEnd() })
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Settings tab

struct LayoutAccessibilitySettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var a = A11yPrefs.shared
        Form {
            Section(L("Reading pane")) {
                Picker(L("Position"), selection: $a.prefs.pane) {
                    Text(L("Right")).tag(ReadingPanePosition.right)
                    Text(L("Bottom")).tag(ReadingPanePosition.bottom)
                    Text(L("Off")).tag(ReadingPanePosition.off)
                }
                Text(L("With the reading pane off, messages open in their own window (Return or double-click) and aren't marked as read by selecting them."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Text size"), selection: $a.prefs.readerZoom) {
                    ForEach(MailViewPreferences.zoomSteps, id: \.self) { z in Text("\(Int((z * 100).rounded())) %").tag(z) }
                }
                Text(L("⌘+ / ⌘− / ⌘0 change it while reading.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Message list")) {
                Picker(L("Density"), selection: $a.prefs.density) {
                    Text(L("Compact")).tag(ListDensity.compact)
                    Text(L("Standard")).tag(ListDensity.standard)
                    Text(L("Roomy")).tag(ListDensity.roomy)
                }
                Picker(L("Preview lines"), selection: $a.prefs.previewLines) {
                    Text(L("None")).tag(0)
                    ForEach(1...3, id: \.self) { n in Text("\(n)").tag(n) }
                }
                Toggle(L("Clean list"), isOn: $a.prefs.cleanList)   // LIST-HOOK (View ▸ Clean List, ⌥⌘K)
                Text(L("Rows show only the sender, subject and snippet, date and the sensitivity label. Hover a row for its actions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Swipe and hover actions")) {
                Picker(L("Swipe left"), selection: $a.prefs.swipeLeft) {
                    ForEach(RowQuickAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L("Swipe right"), selection: $a.prefs.swipeRight) {
                    ForEach(RowQuickAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ForEach(RowQuickAction.allCases, id: \.self) { act in
                    Toggle(L("Show %@ on hover", act.title), isOn: Binding(
                        get: { a.prefs.stripActions.contains(act) },
                        set: { on in
                            var s = a.prefs.stripActions.filter { $0 != act }
                            if on { s.append(act); s.sort { RowQuickAction.allCases.firstIndex(of: $0)! < RowQuickAction.allCases.firstIndex(of: $1)! } }
                            a.prefs.stripActions = s
                        }))
                }
            }
            Section(L("Language")) {
                Picker(L("Interface language"), selection: $a.prefs.language) {
                    Text(L("System")).tag(UILanguage.system)
                    Text("English").tag(UILanguage.en)
                    Text("Deutsch").tag(UILanguage.de)
                    Text("Français").tag(UILanguage.fr)
                    Text("Italiano").tag(UILanguage.it)
                }
                Text(L("Takes effect after restarting niivo mail. Dates follow your mailbox's regional settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Keyboard")) {
                LabeledContent(L("Next / previous pane")) { Text("⌥⌘→  ⌥⌘←  ·  Tab  ⇧Tab") }
                LabeledContent(L("Back to the message list")) { Text("Esc") }
                Text(L("Reduce Motion and Reduce Transparency follow System Settings › Accessibility › Display."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
