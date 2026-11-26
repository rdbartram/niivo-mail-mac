import SwiftUI
import AppKit
import MailCore

// The Desk (docs/SUITE.md, wireframes v0 / v0-2): a slim glass rail of surfaces on the left and one to four tiles.
// It is the default niivo main window (`desk.enabled`, default on); the classic Mail / Calendar shells stay one
// toggle away (⇧⌘D, the rail's last button, the Desk button in the classic headers). State: MailCore `DeskState`.
// Each surface mounts its existing view; a surface sits in at most one tile (every surface runs off a shared model).

// MARK: - Model

@MainActor @Observable final class DeskModel {
    static let shared = DeskModel()

    /// Desk (true) or the classic shells. Brand theme only; other themes always use the classic system shells.
    var enabled: Bool = UserDefaults.standard.object(forKey: DeskState.enabledKey) as? Bool ?? DeskState.enabledDefault {
        didSet { UserDefaults.standard.set(enabled, forKey: DeskState.enabledKey) }
    }
    private(set) var state = DeskState.decode(UserDefaults.standard.string(forKey: DeskState.defaultsKey))
    /// True while a DeskView is on screen (routes loop / person opens into tiles instead of windows).
    var mounted = false

    func isActive(_ app: AppModel) -> Bool { enabled && app.theme.brand }

    private func update(_ f: (inout DeskState) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        UserDefaults.standard.set(s.encoded, forKey: DeskState.defaultsKey)
    }

    func show(_ s: DeskSurface) { update { $0.show(s) } }
    func place(_ s: DeskSurface, inSlot slot: Int) { update { $0.place(s, inSlot: slot) } }
    func focus(_ slot: Int) { update { $0.setFocus(slot) } }
    func setLayout(_ l: DeskLayout) { update { $0.setLayout(l) } }
    func cycleLayout(forward: Bool = true) { update { $0.cycleLayout(forward: forward) } }

    /// Show `s` beside the focused tile when the Desk is on screen; with one tile (or no Desk) run `otherwise`
    /// (open the surface's own window), so the tile the user clicked in is never replaced.
    func present(_ s: DeskSurface, otherwise: () -> Void) {
        guard mounted else { otherwise(); return }
        var ok = false
        update { ok = $0.reveal(s) }
        if !ok { otherwise() }
    }

    /// Bring `s` forward for something the app started (section change, a new composer): beside the focused tile,
    /// or in place of it with one tile.
    func bringForward(_ s: DeskSurface) {
        update { if !$0.reveal(s) { $0.show(s) } }
    }

    /// Go → Mail / Calendar: the tile in the Desk, the section in the classic shell.
    func go(_ s: DeskSurface, _ app: AppModel) {
        if isActive(app) { show(s); syncSection(app) } else { app.section = s == .calendar ? .calendar : .mail }
    }

    /// Keep `app.section` in step with the focused tile: ⌘N, Find, Sync and the Mail menu branch on it.
    func syncSection(_ app: AppModel) {
        switch state.focused {
        case .calendar: if app.section != .calendar { app.section = .calendar }
        case .mail, .signal, .loops, .people: if app.section != .mail { app.section = .mail }
        case .when, .deep, .notes: break
        }
    }

    /// Window capture guard: the union over every visible tile (RootView's rule per section, the People window's rule).
    func captureBlocked(_ app: AppModel) -> Bool {
        if app.trust.blocksScreenCapture { return true }
        let v = state.visible
        if v.contains(.calendar) && app.screenPolicy.preventScreenCapture { return true }
        if v.contains(.people) && (app.mail.screenPolicy.preventScreenCapture || PeopleSurfaceModel.shared.preventCapture) { return true }
        if !app.mail.started && app.screenPolicy.preventScreenCapture { return true }   // as RootView before mail starts
        return false
    }
}

/// Tells a mounted shell it sits in a Desk tile (no traffic-light inset, no section tabs) and whether Signal has a
/// tile of its own (then the Mail tile shows the Today list instead of a second Signal).
struct DeskTileContext: Sendable, Equatable {
    var inTile = false
    var signalTiled = false
    /// The tile is narrow: shells hide their own sidebars (mailboxes, calendars).
    var compact = false
}

private struct DeskTileKey: EnvironmentKey { static let defaultValue = DeskTileContext() }
extension EnvironmentValues {
    var deskTile: DeskTileContext {
        get { self[DeskTileKey.self] }
        set { self[DeskTileKey.self] = newValue }
    }
}

// MARK: - Desk

struct DeskView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let desk = DeskModel.shared
        let st = desk.state
        VStack(spacing: 0) {
            DeskTopBar()
            PostureBanner().fixedSize(horizontal: false, vertical: true)   // once for the Desk (tiled shells skip theirs)
            HStack(alignment: .center, spacing: 10) {
                DeskRail()
                DeskTiles(state: st)
            }
            .padding(.leading, 10).padding(.trailing, 12).padding(.bottom, 12)
        }
        .environment(\.deskTile, DeskTileContext(inTile: true, signalTiled: st.isVisible(.signal)))
        .background(skin.ground)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .windowToolbar)
        .modifier(MailRootChrome())    // mail sheets, toasts, key catchers, start-up (once for every tile)
        .modifier(CalendarSheets())    // event editor, remove sheet, alerts (once for every tile)
        .onAppear { desk.mounted = true; desk.syncSection(app) }
        .onDisappear { desk.mounted = false }
        .onChange(of: st.focused) { desk.syncSection(app) }
        // Code elsewhere sets `app.section` (notifications, mailto / .ics, menu bar, palette, People actions): show
        // the matching tile. Focus → section and section → tile agree, so this never loops.
        .onChange(of: app.section) {
            switch app.section {
            case .calendar: if desk.state.focused != .calendar { desk.bringForward(.calendar) }
            case .mail: if desk.state.focused == .calendar { desk.bringForward(.mail) }
            }
        }
        // A new composer shows inline in a reader: the Mail tile's, or the Signal tile's Now card.
        .onChange(of: app.mail.composer != nil) { _, open in
            guard open else { return }
            let signalShows = st.isVisible(.signal) && SignalModel.shared.isActive(app.mail)
            if !st.isVisible(.mail) && !signalShows { desk.bringForward(.mail) }
        }
    }
}

/// Top bar: traffic-light inset, "Desk", the tile-layout picker and the classic toggle (glass controls on ground).
struct DeskTopBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let desk = DeskModel.shared
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)   // traffic lights
            MonoLabel(L("Desk"), color: skin.ink, wide: true, weight: .medium)
            MonoLabel(desk.state.focused.title, size: NV.Size.labelSm)
            Spacer(minLength: 12)
            PostUnlockSync()
            NiivoGlassContainer(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(DeskLayout.allCases, id: \.self) { l in
                        let on = desk.state.layout == l
                        Button { desk.setLayout(l) } label: {
                            DeskLayoutGlyph(layout: l, color: on ? skin.ink : skin.muted)
                                .frame(width: 22, height: 14).padding(.horizontal, 6).padding(.vertical, 5)
                                .background(Capsule().fill(on ? skin.soft : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("%@ (⌘\\ cycles)", L(l.title)))
                        .accessibilityLabel(L(l.title))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(3)
                .niivoGlassCapsule()
            }
            Button(L("Classic")) { desk.enabled = false }
                .niivoGlassButton(skin)
                .help(L("Classic Mail and Calendar windows (⇧⌘D)"))
            NIconButton("lock", label: L("Lock now"), help: L("Lock now (⌃⌘L)")) { app.trust.lockNow() }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background { skin.ground.gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
    }
}

/// A tiny drawing of a tile layout (the v0-2 thumbnails).
struct DeskLayoutGlyph: View {
    var layout: DeskLayout
    var color: Color
    var body: some View {
        let r = RoundedRectangle(cornerRadius: 1.5).stroke(color, lineWidth: 1)
        HStack(spacing: 2) {
            r
            switch layout {
            case .one: EmptyView()
            case .two: r
            case .onePlusTwo: VStack(spacing: 2) { r; r }
            case .onePlusThree: VStack(spacing: 2) { r; HStack(spacing: 2) { r; r } }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Rail

/// The slim glass rail (v0): one key per surface, rail order, focused surface filled, visible ones marked.
struct DeskRail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let desk = DeskModel.shared
        NiivoGlassContainer(spacing: 6) {
            VStack(spacing: 4) {
                ForEach(DeskSurface.railOrder, id: \.self) { s in
                    let focused = desk.state.focused == s
                    let visible = desk.state.isVisible(s)
                    Button { desk.show(s); desk.syncSection(app) } label: {
                        Image(systemName: s.symbol)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(focused ? skin.card : (s.isBuilt ? skin.ink : skin.muted))
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(focused ? skin.ink : (visible ? skin.soft : .clear)))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(L("%@ (⌘%lld)", L(s.title), s.shortcutDigit))
                    .accessibilityLabel(L(s.title))
                    .accessibilityAddTraits(focused ? .isSelected : [])
                }
                Rectangle().fill(skin.hair).frame(width: 22, height: 1).padding(.vertical, 2)
                Button { desk.cycleLayout() } label: {
                    DeskLayoutGlyph(layout: desk.state.layout, color: skin.ink).frame(width: 20, height: 13)
                        .frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Next tile layout (⌘\\)"))
                .accessibilityLabel(L("Next tile layout"))
            }
            .padding(5)
            .niivoGlassCard(radius: 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Surfaces"))
    }
}

// MARK: - Tiles

struct DeskTiles: View {
    var state: DeskState
    private let gap: CGFloat = 10
    var body: some View {
        switch state.layout {
        case .one:
            tile(0)
        case .two:
            HStack(spacing: gap) { tile(0); tile(1) }
        case .onePlusTwo:
            HStack(spacing: gap) {
                tile(0)
                VStack(spacing: gap) { tile(1); tile(2) }
            }
        case .onePlusThree:
            HStack(spacing: gap) {
                tile(0)
                VStack(spacing: gap) {
                    tile(1)
                    HStack(spacing: gap) { tile(2); tile(3) }
                }
            }
        }
    }

    private func tile(_ i: Int) -> some View {
        DeskTile(slot: i, surface: state.slots[i], focused: state.focus == i).id(state.slots[i])
    }
}

/// One tile: a glass header (surface, key, replace menu) over the surface's own view (solid, clipped).
struct DeskTile: View {
    @Environment(\.skin) private var skin
    @Environment(\.deskTile) private var ctx
    var slot: Int
    var surface: DeskSurface
    var focused: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            DeskTileHeader(slot: slot, surface: surface, focused: focused)
            GeometryReader { g in
                // Narrow tiles (< 1000 pt) drop the shells' own sidebars so the mail list and reader keep their width.
                DeskSurfaceContent(surface: surface)
                    .environment(\.deskTile, DeskTileContext(inTile: true, signalTiled: ctx.signalTiled, compact: g.size.width < 1000))
                    .frame(width: g.size.width, height: g.size.height)
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.card)
        .clipShape(shape)
        // The focused tile takes an accent-ink frame (a line, never the cyan fill: one cyan element per view).
        .overlay(shape.strokeBorder(focused ? skin.accentInk : skin.hair, lineWidth: focused ? 1.5 : 1).allowsHitTesting(false))
        .simultaneousGesture(TapGesture().onEnded { if !focused { DeskModel.shared.focus(slot) } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("%@ tile", L(surface.title)))
    }
}

struct DeskTileHeader: View {
    @Environment(\.skin) private var skin
    var slot: Int
    var surface: DeskSurface
    var focused: Bool
    var body: some View {
        let desk = DeskModel.shared
        HStack(spacing: 8) {
            Image(systemName: surface.symbol).font(.system(size: 11)).foregroundStyle(focused ? skin.ink : skin.muted)
            MonoLabel(L(surface.title), color: focused ? skin.ink : skin.muted, wide: true, weight: focused ? .medium : .regular)
            MonoLabel("⌘\(surface.shortcutDigit)", size: NV.Size.labelSm)
            Spacer(minLength: 4)
            Menu {
                ForEach(DeskSurface.railOrder, id: \.self) { s in
                    Button { desk.place(s, inSlot: slot) } label: {
                        Text(desk.state.isVisible(s) ? L("%@ (swap)", L(s.title)) : L(s.title))
                    }
                    .disabled(s == surface)
                }
            } label: {
                Image(systemName: "rectangle.2.swap").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Show another surface in this tile"))
            .accessibilityLabel(L("Replace this tile"))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .niivoGlass(in: Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(skin.hair).frame(height: 1) }
    }
}

/// The surface views, mounted as they are. DESK-HOOK markers: When, Deep and Notes are wired here after merge.
struct DeskSurfaceContent: View {
    var surface: DeskSurface
    var body: some View {
        switch surface {
        case .mail: MailRootView(chromeless: true)   // the full niivo mail shell (list, reader, Today, Flow)
        case .calendar: CalendarShellView()
        case .signal: DeskSignalTile()
        case .loops: LoopPageRoot()
        case .people: PeopleSurfaceView()
        case .when: WhenSurface()   // DESK-HOOK: when (WhenViews.swift)
        case .deep: DeepSurface()   // DESK-HOOK: deep (DeepViews.swift)
        case .notes: DeskPlaceholderTile(surface: .notes)   // DESK-HOOK: notes
        }
    }
}

/// Signal renders only with Today selected (SignalModel.isActive); otherwise the tile offers to open it.
struct DeskSignalTile: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let mail = app.mail
        let s = SignalModel.shared
        if !mail.started {
            ProgressView(L("Opening mail…")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if s.isActive(mail) {
            SignalView()
        } else if !mail.ai.usesConversationTriage {
            DeskNote(symbol: "scope", title: L("Signal"), text: L("Signal needs conversation triage. Turn it on in Settings → AI."))
        } else if TodayModel.shared.flow != nil {
            DeskNote(symbol: "scope", title: L("Signal"), text: L("Flow is running in the Mail tile."))
        } else {
            DeskNote(symbol: "scope", title: L("Signal"), text: L("What needs you, one at a time, with who it is and which loop it belongs to.")) {
                Button(L("Open Signal")) { s.enabled = true; mail.selectedFolderId = TodayModel.folderId }
                    .niivoGlassButton(skin, prominent: true)
            }
        }
    }
}

/// When / Deep / Notes until their builders land.
struct DeskPlaceholderTile: View {
    var surface: DeskSurface
    var body: some View {
        DeskNote(symbol: surface.symbol, title: L(surface.title), text: Self.text(surface))
    }
    static func text(_ s: DeskSurface) -> String {
        switch s {
        case .when: L("A loop's next piece of work gets a slot in the calendar. Coming soon.")
        case .deep: L("A focused block on one loop: the work item, the loop's items, done-when criteria and a timer. Coming soon.")
        case .notes: L("Notes that link into loops and people. Coming soon.")
        default: ""
        }
    }
}

struct DeskNote<Actions: View>: View {
    @Environment(\.skin) private var skin
    var symbol: String
    var title: String
    var text: String
    var actions: Actions
    init(symbol: String, title: String, text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.text = text; self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(skin.muted)
            Text(title).font(skin.sans(NV.Size.bodyLg)).foregroundStyle(skin.ink)
            Text(text).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).multilineTextAlignment(.center).frame(maxWidth: 320)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Commands and toggles

/// Desk menu: ⌘1…⌘8 surfaces (only while the Desk shows; the classic shell keeps ⌘1/3/5/7 for day counts),
/// ⌘\ / ⇧⌘\ tile layouts, ⇧⌘D Desk on / off.
struct DeskMenuContent: View {
    var model: AppModel
    var body: some View {
        let desk = DeskModel.shared
        let on = desk.isActive(model) && !model.trust.hidesContent
        ForEach(DeskSurface.railOrder, id: \.self) { s in
            Button(s.isBuilt ? L(s.title) : L("%@ (coming soon)", L(s.title))) { desk.show(s); desk.syncSection(model) }
                .keyboardShortcut(on ? KeyboardShortcut(KeyEquivalent(Character(String(s.shortcutDigit))), modifiers: .command) : nil)
                .disabled(!on)
        }
        Divider()
        Button(L("Next Tile Layout")) { desk.cycleLayout() }.keyboardShortcut("\\", modifiers: .command).disabled(!on)
        Button(L("Previous Tile Layout")) { desk.cycleLayout(forward: false) }.keyboardShortcut("\\", modifiers: [.command, .shift]).disabled(!on)
        ForEach(DeskLayout.allCases, id: \.self) { l in
            Toggle(L(l.title), isOn: Binding(get: { desk.state.layout == l }, set: { if $0 { desk.setLayout(l) } })).disabled(!on)
        }
        Divider()
        Toggle(L("Use the Desk"), isOn: Binding(get: { desk.enabled }, set: { desk.enabled = $0 }))
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.theme.brand)
    }
}

/// Classic headers: back to the Desk.
struct DeskToggleButton: View {
    var body: some View {
        NIconButton("rectangle.3.group", label: L("Desk"), help: L("Desk: surfaces side by side (⇧⌘D)")) { DeskModel.shared.enabled = true }
    }
}

// MARK: - Calendar sheets (shared by the classic niivo calendar and the Desk)

/// The niivo calendar's sheets, alert and move dialog, moved from RootView.calendarShell so the Desk can apply them once.
struct CalendarSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        @Bindable var model = model
        content
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
