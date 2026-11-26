import SwiftUI
import AppKit
import CalendarCore

/// Entry point is `AppEntry` (ThemePreview.swift), which runs this unless `--theme-preview` is given.
struct CompliantCalendarApp: App {
    // `@State` is a macro in the macOS 27 SDK and its plugin ships only with Xcode; the App is created once,
    // so a plain reference is equivalent here.
    private let model = AppModel()
    @NSApplicationDelegateAdaptor(LifecycleDelegate.self) private var lifecycleDelegate   // LIFECYCLE-HOOK: mailto/.ics, menu bar

    init() {
        AppLifecycle.shared.model = model   // LIFECYCLE-HOOK
        // Allow running the bare SwiftPM binary (no .app bundle) as a proper foreground app.
        // A calendar should always open its window. With a MenuBarExtra in the scene, AppKit's saved state can
        // restore "no windows" (seen after a force-quit), leaving only the menu-bar item. Skip window restoration.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        NSApplication.shared.setActivationPolicy(.regular)
        _ = NiivoFonts.available   // register the bundled brand faces before the first view
        // Start with the app, not the window: the menu-bar item must work with the window closed.
        let m = model
        Task { @MainActor in await m.start() }
    }

    var body: some Scene {
        WindowGroup("Calendar", id: "main") {
            RootView()
                .environment(model)
                .task { await model.start() }
                .modifier(OpenWindowCapture())   // LIFECYCLE-HOOK: reopen the main window from the menu bar / URLs
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        // With a MenuBarExtra, macOS would otherwise restore "no windows" after a quit with the window closed.
        .defaultLaunchBehavior(.presented)
        .commands {
            ReaderCommands(model: model)   // READER2-HOOK: ⌘P print, ⌥⌘F find in message
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.mail.showSettings = true }.keyboardShortcut(",", modifiers: .command)
                    .disabled(model.trust.hidesContent)
            }
            CommandGroup(after: .newItem) {
              if model.section == .mail {
                // Calendar's ⌘N/⌘E/⌘⌫ present sheets that only exist in the calendar view: route ⌘N to Mail instead.
                Button("New Message") { model.mail.run(.compose) }.keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.mail.started || model.trust.hidesContent)
              } else {
                Button("New Event") { model.newEvent() }.keyboardShortcut("n", modifiers: .command)
                Button("Edit Event") { model.editSelected() }.keyboardShortcut("e", modifiers: .command)
                    .disabled(!(model.selectedEvent.map(model.canEdit) ?? false))
                Button(model.selectedEvent.map { model.removeMode(for: $0) == .cancel ? "Cancel Meeting…" : (model.removeMode(for: $0) == .decline ? "Decline Meeting…" : "Delete Event…") } ?? "Delete Event…") {
                    model.askRemoveSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(model.selectedEvent.map(model.canRemove) ?? false))
                Divider()
                CalendarExtrasCommands(model: model)   // CALENDAR-HOOK: add calendar, .ics import
              }
            }
            CommandGroup(after: .toolbar) { MailListViewMenu(model: model) }   // LIST-HOOK: density + clean list (MailListLayout.swift)
            CommandGroup(after: .toolbar) { ConversationViewCommands(model: model) }   // THREAD-HOOK: View → Group by Conversation
            CommandMenu("Go") {
                Button("Mail") { DeskModel.shared.go(.mail, model) }.keyboardShortcut("1", modifiers: [.command, .control])   // DESK-HOOK: in the Desk, brings the tile forward
                Button("Calendar") { DeskModel.shared.go(.calendar, model) }.keyboardShortcut("2", modifiers: [.command, .control])
                Divider()
                Button("Today") { model.goToday() }.keyboardShortcut("t", modifiers: .command)
                Button("Previous") { model.shiftWeek(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next") { model.shiftWeek(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Find…") { if model.section == .mail { model.mail.focusSearchToken += 1 } else { model.focusSearchToken += 1 } }.keyboardShortcut("f", modifiers: [.command])
                Divider()
                Button("Calendar Grid") { model.viewMode = .grid }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Schedule") { model.viewMode = .schedule }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Month") { model.viewMode = .month }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Agenda") { model.viewMode = .agenda }.keyboardShortcut("4", modifiers: [.command, .option])
                SecondZoneMenu()   // CALENDAR-HOOK: second time zone in the week/day gutter
                Divider()
                // DESK-HOOK: ⌘1…⌘8 pick Desk surfaces while the Desk shows; the day counts keep ⌘1/3/5/7 in the classic shell.
                let desk = DeskModel.shared.isActive(model)
                Button("Day") { model.dayCount = 1 }.keyboardShortcut(desk ? nil : KeyboardShortcut("1", modifiers: .command))
                Button("3 Days") { model.dayCount = 3 }.keyboardShortcut(desk ? nil : KeyboardShortcut("3", modifiers: .command))
                Button("Work Week") { model.dayCount = 5 }.keyboardShortcut(desk ? nil : KeyboardShortcut("5", modifiers: .command))
                Button("Week") { model.dayCount = 7 }.keyboardShortcut(desk ? nil : KeyboardShortcut("7", modifiers: .command))
                Divider()
                Button(model.overlap ? "Show Calendars Side by Side" : "Overlap Calendars") { model.overlap.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Group by Day") { model.grouping = .byDay; model.overlap = false }.keyboardShortcut("d", modifiers: [.command, .option])
                Button("Group by Calendar") { model.grouping = .byCalendar; model.overlap = false }.keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                // Outlook keymap (MailBulk.swift) takes ⌘R for Reply in Mail; Sync Now moves to ⌥⌘R there.
                Button("Sync Now") { Task { if model.section == .mail { await model.mail.syncNow() } else { await model.syncNow() } } }
                    .keyboardShortcut("r", modifiers: MailListUI.shared.keymap == .outlook && model.section == .mail ? [.command, .option] : .command)
            }
            CommandMenu("Mail") { MailMenuContent(model: model); OutlookKeymapMenu(model: model); MailA11yMenu(model: model) }   // A11Y-HOOK
            CommandMenu("Desk") { DeskMenuContent(model: model) }   // DESK-HOOK: surfaces ⌘1…⌘8, layouts ⌘\, Desk on/off ⇧⌘D
        }

        // niivo pop-out composer (one active draft, moved — not copied — between pane and window).
        Window("Search", id: "search") { SearchWindowRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled).commands { SearchCommands() }   // SEARCH-HOOK
        Window("People", id: "people") { PeopleWindowRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled).commands { PeopleCommands() }; Window("Tasks", id: "tasks") { TasksWindowRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)   // PEOPLE-HOOK (PeopleViews.swift)
        WindowGroup("Message", id: "composer-extra", for: UUID.self) { $id in ExtraComposerWindowRoot(composerId: id).environment(model) }   // COMPOSE2-HOOK: further drafts
            .windowStyle(.titleBar).defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        Window("Person", id: "knowledge") { KnowledgePageRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)   // PEOPLE-HOOK: person / matter pages
        Window("Loop", id: "loop") { LoopPageRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)   // LOOPS-HOOK: loop page
        Window("When", id: "when") { WhenWindowRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled).commands { WorkCommands() }; Window("Deep", id: "deep") { DeepWindowRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)   // WHEN-HOOK / DEEP-HOOK (WhenViews.swift, DeepViews.swift)
        Window("Train Triage", id: "triage-train") { TriageTrainerRoot().environment(model) }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)   // TRIAGE2-HOOK
        Window("Message", id: "composer") { ComposerWindowRoot().environment(model) }
            .windowStyle(.titleBar)   // standard title bar: traffic lights always visible (hidden one lost the close button)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .defaultSize(width: 760, height: 720)

        // Message windows: double-click a row or ⌘O. Several at once.
        WindowGroup("Message", id: "message", for: String.self) { $id in MessageWindowRoot(messageId: id).environment(model) }
            .windowStyle(.titleBar)   // standard title bar: traffic lights always visible (hidden one lost the close button)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .defaultSize(width: 820, height: 760)

        // Plain title/symbol: a TimelineView in a status-item label spins the main thread at launch.
        MenuBarExtra {
            MenuBarPanel().environment(model).skinned(model.skin)
        } label: {
            // niivo: the solid ıı as a monochrome template image; other themes keep the status symbol.
            // LIFECYCLE-HOOK: unread Inbox count (a number only, never a sender — the menu bar shows in screen shares).
            let title = [model.menuBarTitle, AppLifecycle.shared.menuBarUnread.map { "✉︎ \($0 > 999 ? "999+" : "\($0)")" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
            if model.theme.brand { Image(nsImage: NiivoGlyphs.menuBarImage()); Text(title) }
            else { Label(title, systemImage: model.menuBarSymbol) }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @FocusState private var searchFocused: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
          if model.trust.hidesContent {
            TrustGateView()
          } else {
            switch model.mode {
            case .loading: ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSignIn: SignInView()
            case .unconfigured where model.calendars.isEmpty: SignInView()
            default:
                Group {
                    if DeskModel.shared.isActive(model) {
                        DeskView()   // DESK-HOOK: the Desk (rail + tiles) is the default niivo main window
                    } else if model.section == .mail && model.theme.brand {
                        MailRootView()   // niivo: own header bar; the posture banner sits inside it
                    } else if model.section == .mail {
                        MailRootView().toolbar { SectionSwitch() }.safeAreaInset(edge: .top, spacing: 0) { PostureBanner() }
                    } else if model.theme.brand {
                        calendarShell   // niivo: own header + sidebar + inspector column
                    } else {
                        calendarSplit.safeAreaInset(edge: .top, spacing: 0) { PostureBanner() }
                    }
                }
                // §17: track the presenting size so the sheet never lays out beyond the window (MailSettingsView.fit).
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.mail.settingsHost = $0 }
                .sheet(isPresented: Bindable(model.mail).showSettings) { MailSettingsView() }
            }
          }
        }
        .skinned(model.skin)
        .containerBackground(model.skin.brand ? AnyShapeStyle(model.skin.ground) : AnyShapeStyle(.windowBackground), for: .window)
        // Window-level enforcement: exclude the window from screenshots / screen sharing while anything on
        // screen carries a label that forbids capture (Mail also honours the device trust policy).
        .background(WindowSharingGuard(blocked: captureBlocked && !demoCaptureOverride))
        // niivo mail + lock screen: hidden title bar, full-size content, traffic lights inside our header.
        .background(WindowChrome(custom: model.theme.brand))
    }

    private var captureBlocked: Bool {
        if DeskModel.shared.isActive(model) { return DeskModel.shared.captureBlocked(model) }   // DESK-HOOK: union over the tiles
        if model.section == .mail && model.mail.started {
            // Message content is shielded per region (ReaderView.captureShield); the window itself is only withheld
            // when the device trust policy forbids capture altogether.
            return model.trust.blocksScreenCapture
        }
        return model.screenPolicy.preventScreenCapture
    }

    /// niivo calendar: same sheets/alerts as `calendarSplit` (CalendarSheets, DeskViews.swift; the Desk applies it once too).
    @ViewBuilder private var calendarShell: some View {
        CalendarShellView().modifier(CalendarSheets())
    }

    @ViewBuilder private var calendarSplit: some View {
        @Bindable var model = model
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
                } detail: {
                    Group {
                        if model.isSearching { SearchResultsView() }
                        else { CalendarContent() }   // CALENDAR-HOOK: grid / schedule / month / agenda
                    }
                        .overlay(alignment: .top) {
                            if let b = model.alerts.banner { AlertBannerView(banner: b) }
                        }
                        .searchable(text: Bindable(model).searchText, placement: .toolbar, prompt: "Search meetings, people, rooms")
                        .searchFocused($searchFocused)
                        .onChange(of: model.focusSearchToken) { searchFocused = true }
                        .inspector(isPresented: Binding(get: { model.selectedEventId != nil },
                                                        set: { if !$0 { model.selectedEventId = nil } })) {
                            if let e = model.selectedEvent { EventInspector(event: e).inspectorColumnWidth(min: 300, ideal: 340) }
                        }
                }
                .toolbar { SectionSwitch() }
                .toolbar { MainToolbar() }
                .sheet(isPresented: Bindable(model).showEditor) { EventEditor() }
                .sheet(item: Bindable(model).removal) { e in RemoveSheet(event: e) }
                .modifier(CalendarExtrasSheets())   // CALENDAR-HOOK
                .alert("Couldn’t complete that", isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } })) {
                    Button("OK") { model.writeError = nil }
                } message: { Text(model.writeError ?? "") }
                .confirmationDialog(model.calendarMove.map { $0.blocked ? "Meetings can’t move to another calendar" : "Move to \($0.target.ownerDisplay)’s calendar?" } ?? "",
                                    isPresented: Binding(get: { model.calendarMove != nil }, set: { if !$0 { model.calendarMove = nil } }),
                                    presenting: model.calendarMove) { mv in
                    if !mv.blocked { Button("Move") { model.confirmCalendarMove() } }
                    Button(mv.blocked ? "OK" : "Cancel", role: .cancel) { model.calendarMove = nil }
                } message: { mv in
                    Text(mv.blocked ? "It has attendees: moving it would cancel it for everyone and send a new invitation. Create it in \(mv.target.ownerDisplay)’s calendar instead."
                                    : "It’s created in \(mv.target.ownerDisplay) · \(mv.target.name) and removed from the original calendar.")
                }
    }
}

/// Fixture mode only: lets us screenshot the demo. Never honoured with a real tenant.
@MainActor private var demoCaptureOverride: Bool {
    AppModelBox.isFixture && ProcessInfo.processInfo.environment["CC_DEMO_ALLOW_CAPTURE"] == "1"
}
@MainActor enum AppModelBox { static var isFixture = false }

// SignInView: SignInViews.swift (BACKLOG §17)

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.viewMode.isTimeGrid ? model.weekStart : model.anchorDate,
                     format: .dateTime.month(.wide).year()).font(.title2.weight(.semibold))
                Text(model.viewMode == .month ? "Month" : model.viewMode == .agenda ? "Next \(AppModel.agendaDays) days"
                     : model.dayCount >= 5 ? "Week \(Calendar.current.component(.weekOfYear, from: model.weekStart))"
                                         : model.weekStart.formatted(.dateTime.weekday(.wide).day()))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            SyncBadge()
            if model.isFixtureMode {
                Toggle(isOn: $model.simulateOffline) { Label("Offline", systemImage: "wifi.slash") }
                    .toggleStyle(.button).help("Fixture mode: simulate losing the network")
            }
            Picker("Days", selection: $model.dayCount) {
                Text("1").tag(1); Text("3").tag(3); Text("5").tag(5); Text("7").tag(7)
            }
            .pickerStyle(.segmented).fixedSize()
            .accessibilityLabel("Days shown: day, three days, work week, week")
            .help("⌘1 / ⌘3 / ⌘5 / ⌘7")
            Button { model.newEvent() } label: { Label("New Event", systemImage: "plus") }
                .help("New event (⌘N) — or drag on an empty slot")
                .disabled(model.writableCalendars.isEmpty)
            Picker("View", selection: $model.viewMode) {
                ForEach(AppModel.ViewMode.allCases) { v in Label(v.title, systemImage: v.symbol).tag(v) }
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly).fixedSize()
            .help("Calendar grid or schedule (rows per calendar, ⌥⌘1 / ⌥⌘2)")
            Menu {
                Picker("Theme", selection: $model.theme) {
                    ForEach(Theme.all) { t in Label(t.name, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.inline)
            } label: { Label("Theme", systemImage: "paintpalette") }
            .help("Theme: niivo, Glass, Outlook, Google, Classic")
            Toggle(isOn: $model.overlap) { Label("Overlap", systemImage: "square.stack") }
                .disabled(model.viewMode != .grid)
                .toggleStyle(.button)
                .help(model.overlap ? "Calendars overlap in one column per day — click to show them side by side (⌥⌘L)"
                                    : "Calendars side by side — click to overlap them (⌥⌘L)")
            Picker("Group", selection: $model.grouping) {
                ForEach(AppModel.Grouping.allCases) { g in Label(g.title, systemImage: g.symbol).tag(g) }
            }
            .pickerStyle(.segmented).labelStyle(.iconOnly).fixedSize()
            .disabled(model.overlap || model.dayCount == 1 || model.viewMode != .grid)
            .help(model.overlap ? "Grouping applies when calendars are side by side"
                  : "Group lanes by day (⌥⌘D) or by calendar (⌥⌘C)")
            ControlGroup {
                Button { model.shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { model.goToday() }
                Button { model.shiftWeek(1) } label: { Image(systemName: "chevron.right") }
            }
            Button { Task { await model.syncNow() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .help("Sync now (⌘R)")
        }
    }
}

struct SyncBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .syncing: ProgressView().controlSize(.small); Text("Syncing")
            case .offline: Image(systemName: "icloud.slash").foregroundStyle(.orange); Text("Offline — showing cached")
            case .error(let m): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text("Sync error").help(m)
            case .idle(let d):
                Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                if let d { Text(d, style: .relative) + Text(" ago") } else { Text("Up to date") }
            }
            if model.pending > 0 {
                Text("\(model.pending) pending").padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            if model.screenPolicy.preventScreenCapture {
                Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Screen capture blocked by sensitivity label")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
}

/// Sets NSWindow.sharingType. `.none` asks the window server to omit the window from captures.
/// Caveat (see FINDINGS): ScreenCaptureKit on recent macOS may not honour this — best-effort control.
struct WindowSharingGuard: NSViewRepresentable {
    var blocked: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.sharingType = blocked ? .none : .readOnly }
    }
}

extension Color {
    init(hex: String?, fallback: Color = .accentColor) {
        guard let hex, let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            self = fallback; return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Mail menu: every triage shortcut. Bare-letter keys are handled by the mail view (a menu key equivalent without
/// modifiers would swallow typing in search and the composer), so their hints are shown in the titles.
struct MailMenuContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow   // TRIAGE2-HOOK: Train Triage…
    var body: some View {
        let mail = model.mail
        let enabled = model.section == .mail && mail.started && !model.trust.hidesContent
        Button("Re-triage Inbox (AI)") { mail.ai.retriage() }.keyboardShortcut("t", modifiers: [.command, .control, .shift])
            .disabled(!enabled || !mail.ai.enabled)
        Button("Train Triage…") { openWindow(id: "triage-train") }.keyboardShortcut("l", modifiers: [.command, .control, .shift])   // TRIAGE2-HOOK
            .disabled(!enabled || !mail.ai.usesConversationTriage)
        Divider()
        ForEach(MailKeymap.groups, id: \.title) { g in
            ForEach(g.commands) { c in
                if c == .palette {
                    Button(c.title) { mail.run(c) }.keyboardShortcut("k", modifiers: .command).disabled(!enabled)
                } else if c == .cheatSheet {
                    Button(c.title) { mail.run(c) }.keyboardShortcut("/", modifiers: .command).disabled(!enabled)
                } else if c == .settings || c == .sync {
                    Button("\(c.title)  (\(c.hint))") { mail.run(c) }.disabled(!enabled)
                } else {
                    Button("\(c.title)  (\(c.hint))") { mail.run(c) }
                        .disabled(!enabled || (c.needsSelection && mail.selectedRow == nil))
                }
            }
            Divider()
        }
        Button("Lock Now") { model.trust.lockNow() }.keyboardShortcut("l", modifiers: [.command, .control])
        if model.isFixtureMode {
            Divider()
            Button("Debug: Simulate Remote Wipe (fixtures, in-memory)") { model.simulateRemoteWipe() }
                .disabled(model.trust.isWiped)
        }
    }
}
