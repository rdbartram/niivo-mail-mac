import SwiftUI
import AppKit
import CalendarCore

// The niivo calendar window: same chrome as MailShell (own header with traffic lights, custom sidebar, no system
// toolbar / List / inspector). Other themes keep `calendarSplit` in CompliantCalendarApp.swift.

@MainActor @Observable final class CalendarChrome {
    static let shared = CalendarChrome()
    var sidebarWidth: CGFloat = 248
    var sidebarVisible = true
    private var base: CGFloat?
    func resize(by dx: CGFloat) { if base == nil { base = sidebarWidth }; sidebarWidth = min(380, max(200, (base ?? 0) + dx)) }
    func endResize() { base = nil }
}

struct CalendarShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    @Environment(\.deskTile) private var deskTile   // DESK-HOOK
    var body: some View {
        let chrome = CalendarChrome.shared
        VStack(spacing: 0) {
            CalendarHeaderBar()
            if !deskTile.inTile { PostureBanner().fixedSize(horizontal: false, vertical: true) }   // DESK-HOOK: the Desk shows it once
            HStack(spacing: 0) {
                if chrome.sidebarVisible && !deskTile.compact {   // DESK-HOOK: narrow tile
                    NiivoCalendarSidebar().frame(width: chrome.sidebarWidth)
                    NSplitHandle(onDrag: { chrome.resize(by: $0) }, onEnd: chrome.endResize)
                }
                Group {
                    if model.isSearching { SearchResultsView() }
                    else { CalendarContent() }   // CALENDAR-HOOK: grid / schedule / month / agenda
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { if let b = model.alerts.banner { AlertBannerView(banner: b) } }
                if let e = model.selectedEvent {
                    Rectangle().fill(skin.hair).frame(width: 1)
                    EventInspector(event: e).frame(width: 340).background(skin.card)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(skin.ground)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .windowToolbar)
    }
}

struct CalendarHeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow   // PEOPLE2-HOOK
    @Environment(\.skin) private var skin
    @Environment(\.deskTile) private var deskTile   // DESK-HOOK
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var m = model
        let chrome = CalendarChrome.shared
        HStack(spacing: 10) {
            if !deskTile.inTile {   // DESK-HOOK: a Desk tile has no traffic lights and no section tabs (the rail switches)
            Color.clear.frame(width: 64)   // traffic lights
            NTabs(title: "Section", items: AppModel.AppSection.allCases, selection: $m.section,
                  label: { $0.title }, count: { _ in 0 }, divider: false, horizontalPadding: 0)
                .fixedSize().help("Mail (⌃⌘1) · Calendar (⌃⌘2)")
            DeskToggleButton()   // DESK-HOOK: back to the Desk (⇧⌘D)
            }
            NIconButton("person.2", label: L("People"), help: L("People directory (⌃⌘5)")) { KnowledgeHub.shared.openDirectory(openWindow: openWindow) }   // PEOPLE2-HOOK
            NIconButton("sidebar.left", label: "Show or hide calendars", isOn: chrome.sidebarVisible ? nil : false) { chrome.sidebarVisible.toggle() }
            HStack(spacing: 2) {
                NIconButton("chevron.left", label: "Previous", help: "Previous (⌘←)") { model.shiftWeek(-1) }
                NButton("Today", kind: .ghost) { model.goToday() }.fixedSize().help("Today (⌘T)")
                NIconButton("chevron.right", label: "Next", help: "Next (⌘→)") { model.shiftWeek(1) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(model.viewMode.isTimeGrid ? model.weekStart : model.anchorDate, format: .dateTime.month(.wide).year()).font(skin.sans(15)).tracking(skin.titleTrack(15)).foregroundStyle(skin.ink).lineLimit(1)
                MonoLabel(model.viewMode == .month ? "Month" : model.viewMode == .agenda ? "Next \(AppModel.agendaDays) days"
                          : model.dayCount >= 5 ? "Week \(Calendar.current.component(.weekOfYear, from: model.weekStart))"
                                              : model.weekStart.formatted(.dateTime.weekday(.wide).day()), size: NV.Size.labelSm)
            }
            .fixedSize()
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 10)
            NTabs(title: "Days", items: [1, 3, 5, 7], selection: $m.dayCount,
                  label: { $0 == 1 ? "Day" : $0 == 5 ? "Work wk" : $0 == 7 ? "Week" : "3 days" }, count: { _ in 0 }, divider: false, horizontalPadding: 0)
                .fixedSize().help("⌘1 / ⌘3 / ⌘5 / ⌘7")
                .accessibilityLabel("Days shown")
            NTabs(title: "View", items: AppModel.ViewMode.allCases, selection: $m.viewMode,
                  label: { $0.title }, count: { _ in 0 }, divider: false, horizontalPadding: 0)
                .fixedSize().help("Calendar grid, schedule, month or agenda (⌥⌘1 – ⌥⌘4)")
            NField("Search meetings, people, rooms", text: $m.searchText, style: .bordered, symbol: "magnifyingglass", focus: $searchFocused)
                .frame(minWidth: 110, idealWidth: 200, maxWidth: 220)
                .layoutPriority(-1)
                .onChange(of: model.focusSearchToken) { searchFocused = true }
                .onExitCommand { model.searchText = "" }
            SyncBadge().font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted).lineLimit(1).frame(maxWidth: 130).help("Calendar sync")
            HStack(spacing: 2) {
                NIconButton("square.stack", label: "Overlap calendars", help: model.overlap ? "Calendars overlap — click for side by side (⌥⌘L)" : "Side by side — click to overlap (⌥⌘L)",
                            isOn: model.overlap) { model.overlap.toggle() }
                    .disabled(model.viewMode != .grid)
                if model.isFixtureMode {
                    NIconButton("wifi.slash", label: "Simulate offline", help: "Fixture mode: simulate losing the network", isOn: model.simulateOffline) { model.simulateOffline.toggle() }
                }
                NIconButton("arrow.triangle.2.circlepath", label: "Sync now", help: "Sync now (⌘R)") { Task { await model.syncNow() } }
                NIconButton("gearshape", label: "Settings", help: "Settings (⌘,)") { model.mail.showSettings = true }
                NIconButton("lock", label: "Lock now", help: "Lock now (⌃⌘L)") { model.trust.lockNow() }
            }
            NButton("New event", systemImage: "plus") { model.newEvent() }.fixedSize()
                .disabled(model.writableCalendars.isEmpty).help("New event (⌘N) — or drag on an empty slot")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background { skin.ground.gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        .hairline(skin)
    }
}

// MARK: - Sidebar (custom-drawn, matches the mail tree)

struct NiivoCalendarSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: 0) {
            NTabs(title: "Mode", items: AppModel.Persona.allCases, selection: Bindable(model).persona,
                  label: { $0.title }, count: { _ in 0 })
                .help("My Calendar: your time + teammates' availability. Assistant: everyone you look after, side by side.")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    var n = 0
                    let next: () -> Int = { n += 1; return n }
                    if model.persona == .assistant {
                        if !model.principals.isEmpty {
                            header("People I support", next())
                            ForEach(model.principals) { c in calendarRow(c, principal: true) }
                        }
                        calSection("My calendars", .own, next)
                    } else {
                        calSection("My calendars", .own, next)
                        header("Teammates", next())
                        ForEach(model.teammates) { t in teammateRow(t) }
                        AddTeammateField().padding(.horizontal, 14).padding(.vertical, 6)
                        calSection("Shared with me", .shared, next)
                        calSection("Delegate access", .delegated, next)
                    }
                    AddedCalendarsSection().padding(.horizontal, 16).padding(.top, 8)   // CALENDAR-HOOK
                    header("Sensitivity labels", next())
                    if model.compliance.availableLabels().isEmpty {
                        Label(model.labelSyncIssue == nil ? "Policy not synced — labelled items locked"
                                                          : "Label policy unavailable — labelled items locked",
                              systemImage: "lock.trianglebadge.exclamationmark")
                            .font(skin.sans(NV.Size.bodySm)).foregroundStyle(.orange).padding(.horizontal, 16).padding(.vertical, 4)
                            .help(model.labelSyncIssue ?? "")
                    }
                    ForEach(model.compliance.availableLabels()) { l in
                        HStack(spacing: 9) {
                            Rectangle().fill(Color(hex: l.hexColor, fallback: .gray)).frame(width: 2, height: 12)
                            Text(l.name).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            if l.hasProtection { NSymbol("lock.fill", size: 8).font(.system(size: 8)).foregroundStyle(skin.muted).accessibilityLabel("Encrypted") }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .help(l.tooltip ?? l.name)
                    }
                }
                .padding(.bottom, 12)
            }
            footer
        }
        .background(skin.ground)
        .accessibilityLabel("Calendars")
    }

    @ViewBuilder private func calSection(_ title: String, _ access: CalendarAccess, _ next: () -> Int) -> some View {
        let cals = model.calendars.filter { $0.access == access }
        if !cals.isEmpty {
            header(title, next())
            ForEach(cals) { c in calendarRow(c, principal: false) }
        }
    }

    private func header(_ title: String, _ index: Int) -> some View {
        HStack(spacing: 7) {
            MonoLabel(String(format: "%02d", index), size: NV.Size.labelSm, color: skin.accentInk)
            MonoLabel(title, color: skin.ink, wide: true, weight: .medium).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    /// Square check in the calendar colour + owner initials: the ownership cues stay.
    private func calendarRow(_ c: CalendarInfo, principal: Bool) -> some View {
        let on = model.enabledCalendars.contains(c.id)
        let tint = model.tint(c)
        return Button { model.toggle(c) } label: {
            HStack(spacing: 9) {
                Rectangle().strokeBorder(tint, lineWidth: 1.5)
                    .background(Rectangle().fill(on ? tint : .clear))
                    .overlay { if on { NSymbol("checkmark", size: 7).font(.system(size: 7, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 12, height: 12)
                if c.access != .own { OwnerInitials(name: c.ownerDisplay, color: tint) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.access == .own ? c.name : c.ownerDisplay).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                    if principal {
                        let n = model.meetingsToday(c)
                        if let nx = model.nextUp(c) {
                            Text("Next \(nx.start.formatted(date: .omitted, time: .shortened)) · \(nx.title)").font(skin.sans(11)).foregroundStyle(skin.muted).lineLimit(1)
                        }
                        MonoLabel(n == 0 ? "No meetings today" : "\(n) today · \(c.canEdit ? "can edit" : "view only")", size: NV.Size.labelSm)
                    } else if c.access != .own && model.persona == .personal {
                        MonoLabel((c.name != c.ownerDisplay && c.name != "Calendar" ? c.name + " · " : "") + (c.canEdit ? "Can edit" : "View only"), size: NV.Size.labelSm).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !c.canEdit { NSymbol("eye", size: 10).font(.system(size: 10, weight: .light)).foregroundStyle(skin.muted).accessibilityLabel("View only") }
            }
            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nRow(selected: false, hoverKey: AnyHashable("cal:" + c.id), divider: false, skin: skin)
        .accessibilityLabel("\(c.access == .own ? c.name : c.ownerDisplay), \(on ? "shown" : "hidden")")
        .accessibilityAddTraits(on ? .isSelected : [])
        .contextMenu {   // native NSMenu (same decision as mail)
            Menu("Colour") {
                ForEach(CalendarPalette.swatches, id: \.hex) { sw in
                    Button { model.setColor(sw.hex, for: c) } label: {
                        Label { Text(sw.name) } icon: { NSymbol("circle.fill").foregroundStyle(Color(hex: sw.hex)) }
                    }
                }
                Divider()
                Button("Use Outlook Colour") { model.setColor(nil, for: c) }
            }
            Toggle("Meeting Alerts", isOn: Binding(get: { model.alertsOn(c) }, set: { model.setAlerts($0, for: c) }))
            Button(model.enabledCalendars == [c.id] ? "Show All Calendars" : "Show Only This Calendar") {
                model.showOnly(model.enabledCalendars == [c.id] ? nil : c)
            }
        }
    }

    private func teammateRow(_ t: Teammate) -> some View {
        HStack(spacing: 9) {
            TeammateBadge(teammate: t, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                if let a = model.availabilityNow(t) {
                    HStack(spacing: 5) {
                        Rectangle().fill(a.busy ? skin.danger : Color.green).frame(width: 6, height: 6)
                        MonoLabel(a.text, size: NV.Size.labelSm)
                    }
                } else { MonoLabel("Availability loading", size: NV.Size.labelSm) }
            }
            Spacer()
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 5)
        .help("\(t.address) — free/busy only (no meeting details)")
        .contextMenu { Button("Remove Teammate") { model.removeTeammate(t) } }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                NiivoWordmark(size: 15, blinks: false, color: skin.ink).accessibilityHidden(true)
                Spacer()
                MonoLabel(model.isFixtureMode ? "Fixtures" : "Microsoft 365", size: NV.Size.labelSm)
            }
            MonoLabel(String(format: "Cache %.1f ms · %d events", model.queryMillis, model.weekEvents.count), size: NV.Size.labelSm)
            if model.conflictCount > 0 { MonoLabel("\(model.conflictCount) edit(s) superseded by organiser", size: NV.Size.labelSm, color: .orange) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(skin, edge: .top)
    }
}

/// Owner initials in a square (ownership cue for shared / delegated / principal calendars).
struct OwnerInitials: View {
    @Environment(\.skin) private var skin
    var name: String
    var color: Color
    var size: CGFloat = 18
    var body: some View {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        let ini = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        Text(ini.isEmpty ? "?" : ini)
            .font(skin.mono(size * 0.42, .semibold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// niivo square button style for existing calendar buttons; other themes keep their native style.
struct BrandButton: ViewModifier {
    @Environment(\.skin) private var skin
    var kind: NVButtonStyle.Kind = .ghost
    var prominent = false
    func body(content: Content) -> some View {
        if skin.brand { content.buttonStyle(NVButtonStyle(kind: kind)) }
        else if prominent { content.buttonStyle(.borderedProminent).controlSize(.large) }
        else { content.buttonStyle(.bordered) }
    }
}

struct BrandToggles: ViewModifier {
    @Environment(\.skin) private var skin
    func body(content: Content) -> some View {
        if skin.brand { content.toggleStyle(NToggleStyle()) } else { content }
    }
}
