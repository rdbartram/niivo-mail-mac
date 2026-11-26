import SwiftUI
import AppKit
import CalendarCore
import MailCore

// WHEN (wireframe v0-4): one work item in focus ("Decide on notice period · 50 min · due Fri"), the day strip with the
// proposed slots beside it, and the numbered actions: 1 / 2 / 3 take slot 1 / 2 / 3 (confirm step first), L later,
// S shorter, N not mine. Return confirms, Esc cancels. Mounted as a window ("when", ⌃⌘6) and by the Desk shell.

/// WHEN-HOOK: the When surface. Needs `AppModel` in the environment; `loopId` narrows it to one loop.
struct WhenSurface: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool
    var loopId: String?
    init(loopId: String? = nil) { self.loopId = loopId }

    var body: some View {
        let m = WorkModel.shared
        let _ = m.revision
        Group {
            if app.trust.hidesContent || !app.mail.started {
                Text(L("Unlock to plan your work.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    WhenStrip().frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        WhenFocusCard()
                        Spacer(minLength: 0)
                        if m.pending != nil { WhenConfirmCard() } else { WhenActionStrip() }
                    }
                    .frame(width: 300)
                }
                .padding(12)
            }
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : AnyShapeStyle(.background))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        .task(id: "\(loopId ?? "-")|\(m.whenLoop ?? "-")|\(m.whenFirst ?? "-")") {
            if let loopId { m.whenLoop = loopId }
            await m.load(app)
        }
        .accessibilityLabel(L("When"))
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let m = WorkModel.shared
        guard press.modifiers.subtracting(.shift).isEmpty, !WorkKeys.typing else { return .ignored }
        if m.pending != nil {
            if press.key == .return { m.confirmPending(app); return .handled }
            if press.key == .escape { m.cancelPending(); return .handled }
            return .ignored
        }
        switch press.characters.lowercased() {
        case "1": m.take(0, app: app)
        case "2": m.take(1, app: app)
        case "3": m.take(2, app: app)
        case "l": m.later(app)
        case "s": m.shorter(app)
        case "n": m.notMine(app)
        default: return .ignored
        }
        return .handled
    }
}

enum WorkKeys {
    /// A text field has the keyboard: bare keys are typing, not actions.
    @MainActor static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }
}

enum WhenText {
    static func minutes(_ m: Int) -> String {
        m < 60 ? L("%lld min", m) : (m % 60 == 0 ? L("%lld h", m / 60) : L("%lld h %lld", m / 60, m % 60))
    }
    static func slot(_ s: DateInterval) -> String {
        let day = s.start.formatted(.dateTime.weekday(.abbreviated))
        return L("%@ %@ to %@", day, s.start.formatted(date: .omitted, time: .shortened), s.end.formatted(date: .omitted, time: .shortened))
    }
    static func due(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? L("due today") : L("due %@", d.formatted(.dateTime.weekday(.abbreviated)))
    }
}

struct WhenFocusCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        @Bindable var model = m
        SignalPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(L("To place"), wide: true)
                    Spacer()
                    if !m.queue.isEmpty, let c = m.current, let i = m.queue.firstIndex(of: c) { MonoLabel(L("%lld of %lld", i + 1, m.queue.count), size: NV.Size.labelSm) }
                }
                if let item = m.current {
                    TextField(L("Work item"), text: $model.editTitle, axis: .vertical)
                        .textFieldStyle(.plain).font(skin.sans(NV.Size.title, .medium)).foregroundStyle(skin.ink).lineLimit(1...3)
                        .onSubmit { let t = m.editTitle; m.editCurrent(app) { $0.rename($1, to: t) } }
                        .accessibilityLabel(L("Work item title"))
                    if let t = m.loopTitles[item.loopId] {
                        HStack(spacing: 6) {
                            Circle().strokeBorder(skin.ink, lineWidth: 1.2).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(t).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).lineLimit(1)
                        }
                    }
                    HStack(spacing: 6) {
                        NChip(WhenText.minutes(item.minutes), tone: .muted)
                        NChip(L(item.kind.tag), tone: .muted)
                        if let d = item.due { NChip(WhenText.due(d), tone: d < Date() ? .danger : .ink) }
                    }
                    WhenItemEditor(item: item)
                    if item.isMissed(now: Date()) { Text(L("Its block passed without work starting: give it a new time.")).font(.caption).foregroundStyle(skin.muted) }
                    if let p = m.proposal, m.proposalFor == item.id {
                        if p.tooLong { Text(L("Longer than a working day: make it shorter (S) or split it.")).font(.caption).foregroundStyle(skin.muted) }
                        else if p.nothingBeforeDue { Text(L("Nothing free before it's due. These slots are after the due date.")).font(.caption).foregroundStyle(skin.danger) }
                        else if p.slots.isEmpty { Text(L("No free slot in the next two weeks.")).font(.caption).foregroundStyle(skin.muted) }
                    }
                    if item.movingFrom != nil { Text(L("Rescheduling: the old block is removed when you confirm the new one.")).font(.caption2).foregroundStyle(skin.muted) }
                } else if m.loaded {
                    Text(L("Everything has a time.")).font(skin.sans(NV.Size.title, .medium)).foregroundStyle(skin.ink)
                    Text(L("%lld placed", m.placed.count)).font(.caption).foregroundStyle(skin.muted)
                    if m.whenLoop != nil { Button(L("Show all loops")) { m.whenLoop = nil; m.revision += 1 }.buttonStyle(.link).font(.caption) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct WhenActionStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        let slots = (m.current != nil && m.proposalFor == m.current?.id) ? (m.proposal?.slots ?? []) : []
        let has = m.current != nil
        SignalPanel {
            VStack(spacing: 6) {
                WorkKey(title: slots.first.map { L("Place %@", WhenText.slot($0)) } ?? L("No slot"), key: "1", primary: true, enabled: slots.count > 0) { m.take(0, app: app) }
                HStack(spacing: 6) {
                    WorkKey(title: slots.count > 1 ? WhenText.slot(slots[1]) : L("No slot"), key: "2", enabled: slots.count > 1) { m.take(1, app: app) }
                    WorkKey(title: slots.count > 2 ? WhenText.slot(slots[2]) : L("No slot"), key: "3", enabled: slots.count > 2) { m.take(2, app: app) }
                }
                HStack(spacing: 6) {
                    WorkKey(title: L("Later"), key: "L", enabled: has) { m.later(app) }
                    WorkKey(title: L("Shorter"), key: "S", enabled: has) { m.shorter(app) }
                    WorkKey(title: L("Not mine"), key: "N", enabled: has) { m.notMine(app) }
                }
                if let e = m.writeError { Text(e).font(.caption).foregroundStyle(skin.danger) }
                Text(L("Taking a slot asks first. Blocks go on your own calendar as tentative; nobody is invited."))
                    .font(skin.sans(NV.Size.labelSm)).foregroundStyle(skin.muted).lineLimit(3)
            }
        }
    }
}

/// Kind, estimate and due date of the item in focus (the title is edited in place above).
struct WhenItemEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var item: WorkItem
    var body: some View {
        let m = WorkModel.shared
        let cal = Calendar.current
        HStack(spacing: 8) {
            Picker(L("Kind"), selection: Binding(get: { item.kind }, set: { k in m.editCurrent(app) { $0.setKind($1, k) } })) {
                ForEach(WorkItemKind.allCases, id: \.self) { Text(L($0.tag)).tag($0) }
            }
            .labelsHidden().frame(width: 92).accessibilityLabel(L("Kind"))
            Stepper(WhenText.minutes(item.minutes), value: Binding(get: { item.minutes }, set: { v in m.editCurrent(app) { $0.setMinutes($1, v) } }),
                    in: 5...480, step: 5)
                .font(.caption).accessibilityLabel(L("Estimate"))
        }
        HStack(spacing: 8) {
            if let due = item.due {
                DatePicker(L("Due"), selection: Binding(get: { due }, set: { d in m.editCurrent(app) { $0.setDue($1, cal.startOfDay(for: d)) } }), displayedComponents: .date)
                    .font(.caption)
                Button(L("No due date")) { m.editCurrent(app) { $0.setDue($1, nil) } }.buttonStyle(.link).font(.caption)
            } else {
                Button(L("Add a due date")) {
                    let d = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
                    m.editCurrent(app) { $0.setDue($1, d) }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// The explicit confirm step: nothing is written before Return / "Add to my calendar".
struct WhenConfirmCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        SignalPanel {
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel(L("Confirm"), wide: true)
                if let p = m.pending {
                    Text(WhenText.slot(p.plan.slot)).font(skin.sans(NV.Size.bodyLg, .medium)).foregroundStyle(skin.ink)
                    Text(L("A tentative block \u{201C}%@\u{201D} on your own calendar. No attendees, no invitations.", p.plan.subject))
                        .font(.caption).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
                    if p.plan.replacing != nil { Text(L("Your earlier block for this item is removed.")).font(.caption).foregroundStyle(skin.muted) }
                    if let e = m.writeError { Text(e).font(.caption).foregroundStyle(skin.danger) }
                    HStack(spacing: 6) {
                        WorkKey(title: m.writing ? L("Adding…") : L("Add to my calendar"), key: "↩", primary: true, enabled: !m.writing) { m.confirmPending(app) }
                        WorkKey(title: L("Cancel"), key: "esc", enabled: !m.writing) { m.cancelPending() }
                    }
                }
            }
        }
    }
}

/// A numbered action key (same glass key as Signal's strip: control layer, NiivoGlass.swift).
struct WorkKey: View {
    @Environment(\.skin) private var skin
    var title: String
    var key: String
    var primary = false
    var enabled = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(skin.sans(NV.Size.bodySm, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                NiivoKeyCap(key: key)
            }
        }
        .buttonStyle(NiivoGlassKeyStyle(primary: primary)).disabled(!enabled)   // GLASS: action strip keys
        .help(L("%@ (%@)", title, key))
        .accessibilityLabel(title)
    }
}

// MARK: - Day strip

/// Working days from today to the last proposed slot (3 to 5 columns): busy time grey (no subjects), focus blocks by
/// item title, proposed slots outlined with their number, free time per day.
struct WhenStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    var body: some View {
        let m = WorkModel.shared
        let cal = Calendar.current
        let hours = WorkHoursSetting.current
        let slots = (m.current != nil && m.proposalFor == m.current?.id) ? (m.proposal?.slots ?? []) : []
        let days = Self.days(slots: slots, hours: hours, cal: cal)
        let range = (from: max(0, hours.startMinute / 60 - 1) * 60, to: min(24, (hours.endMinute + 59) / 60 + 1) * 60)
        SignalPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    MonoLabel(L("When"), wide: true)
                    Spacer()
                    if let f = slots.first { MonoLabel(L("First free · %@", f.start.formatted(.dateTime.weekday(.abbreviated).day())), size: NV.Size.labelSm) }
                }
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 8) {
                        hourRuler(range, height: geo.size.height - 22)
                        ForEach(days, id: \.self) { day in
                            column(day, slots: slots, range: range, hours: hours, height: geo.size.height - 22)
                        }
                    }
                }
            }
        }
    }

    static func days(slots: [DateInterval], hours: SlotHours, cal: Calendar) -> [Date] {
        var out: [Date] = []
        var d = cal.startOfDay(for: Date())
        let last = slots.map(\.start).max().map { cal.startOfDay(for: $0) } ?? d
        var guardN = 0
        while (out.count < 3 || d <= last) && out.count < 5 && guardN < 30 {
            if hours.weekdays.contains(cal.component(.weekday, from: d)) { out.append(d) }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400); guardN += 1
        }
        return out
    }

    private func hourRuler(_ r: (from: Int, to: Int), height: CGFloat) -> some View {
        let span = CGFloat(r.to - r.from)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: r.from, through: r.to, by: 120)), id: \.self) { mm in
                Text(String(format: "%02d", mm / 60)).font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted)
                    .offset(y: 22 + CGFloat(mm - r.from) / span * height - 6)
            }
        }
        .frame(width: 20, height: height + 22, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func column(_ day: Date, slots: [DateInterval], range: (from: Int, to: Int), hours: SlotHours, height: CGFloat) -> some View {
        let m = WorkModel.shared
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: day)
        let d1 = cal.date(byAdding: .day, value: 1, to: d0) ?? d0
        let busy = SlotFinder.merge(app.ownBusy(from: d0, to: d1, excluding: Set(m.placed.compactMap { $0.slot?.eventId })))
        let focus = m.placed.filter { ($0.slot?.start).map { cal.isDate($0, inSameDayAs: day) } ?? false }
        let daySlots = slots.enumerated().filter { cal.isDate($0.element.start, inSameDayAs: day) }
        let span = CGFloat(range.to - range.from)
        func y(_ t: Date) -> CGFloat {
            let mins = CGFloat(t.timeIntervalSince(d0) / 60) - CGFloat(range.from)
            return max(0, min(height, mins / span * height))
        }
        let free = Self.freeMinutes(day: day, busy: busy + focus.compactMap { $0.slot?.interval }, hours: hours, cal: cal)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.abbreviated).day())).font(skin.mono(NV.Size.label, .medium)).foregroundStyle(skin.ink)
                Spacer()
                Text(L("%@ free", WhenText.minutes(free))).font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted)
            }
            .frame(height: 18)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear).frame(height: height)
                ForEach(Array(busy.enumerated()), id: \.offset) { _, b in
                    RoundedRectangle(cornerRadius: 4).fill(skin.muted.opacity(0.35))
                        .frame(height: max(3, y(b.end) - y(b.start))).offset(y: y(b.start))
                        .accessibilityLabel(L("Busy %@", b.start.formatted(date: .omitted, time: .shortened)))
                }
                ForEach(focus) { f in
                    if let s = f.slot {
                        RoundedRectangle(cornerRadius: 4).fill(skin.soft).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(skin.ink, lineWidth: 1))
                            .overlay(alignment: .topLeading) { Text(f.title ?? L("Focus block")).font(skin.sans(NV.Size.labelSm, .medium)).foregroundStyle(skin.ink).lineLimit(1).padding(4) }
                            .frame(height: max(14, y(s.end) - y(s.start))).offset(y: y(s.start))
                    }
                }
                ForEach(daySlots, id: \.offset) { i, s in
                    Button { m.take(i, app: app) } label: {
                        RoundedRectangle(cornerRadius: NiivoGlass.keyRadius).strokeBorder(skin.ink, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            .niivoGlass(in: RoundedRectangle(cornerRadius: NiivoGlass.keyRadius), interactive: true)   // GLASS: slot chips (controls)
                            .overlay(alignment: .topLeading) {
                                HStack(spacing: 4) {
                                    NiivoKeyCap(key: "\(i + 1)")
                                    Text(s.start.formatted(date: .omitted, time: .shortened)).font(skin.sans(NV.Size.labelSm))
                                }
                                .foregroundStyle(skin.ink).padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(height: max(18, y(s.end) - y(s.start))).offset(y: y(s.start))
                    .help(L("Slot %lld: %@", i + 1, WhenText.slot(s)))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Free working minutes on a day after busy time (no buffers: what the strip shows).
    static func freeMinutes(day: Date, busy: [DateInterval], hours: SlotHours, cal: Calendar) -> Int {
        guard let s = cal.date(bySettingHour: hours.startMinute / 60, minute: hours.startMinute % 60, second: 0, of: day),
              let e = cal.date(bySettingHour: hours.endMinute / 60, minute: hours.endMinute % 60, second: 0, of: day), s < e else { return 0 }
        let start = max(s, Date() > s && cal.isDateInToday(day) ? Date() : s)
        guard start < e else { return 0 }
        var free = e.timeIntervalSince(start)
        for b in SlotFinder.merge(busy) { let a = max(b.start, start), z = min(b.end, e); if z > a { free -= z.timeIntervalSince(a) } }
        return max(0, Int(free / 60) / 5 * 5)
    }
}

// MARK: - Window, menu, loop page hooks

struct WhenWindowRoot: View {
    var body: some View { WhenSurface().frame(minWidth: 820, minHeight: 520) }
}

/// ⌃⌘6 When, ⌃⌘7 Deep (⌃⌘1–5 are sections / People / Tasks / Directory).
struct WorkCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("When") { WorkModel.shared.whenLoop = nil; WorkModel.shared.present(.when, openWindow: openWindow) }.keyboardShortcut("6", modifiers: [.command, .control])
            Button("Deep") { WorkModel.shared.present(.deep, openWindow: openWindow) }.keyboardShortcut("7", modifiers: [.command, .control])
        }
    }
}

/// Loop page: "Schedule" opens When for this loop.
struct LoopScheduleButton: View {
    @Environment(\.openWindow) private var openWindow
    var loopId: String
    var body: some View {
        NButton(L("Schedule"), kind: .ghost) {
            WorkModel.shared.whenLoop = loopId; WorkModel.shared.whenFirst = nil
            WorkModel.shared.present(.when, openWindow: openWindow)   // DESK-HOOK: the When tile when the Desk shows
        }
        .help(L("Give this loop's work a time (When)"))
    }
}

/// Loop page: the loop's work items, the suggestions (accept / not this), and a field for a new item.
struct LoopWorkSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.skin) private var skin
    @Environment(\.openWindow) private var openWindow
    var loopId: String
    var body: some View {
        let m = WorkModel.shared
        @Bindable var model = m
        let _ = m.revision
        let items = m.pageItems[loopId] ?? []
        let sug = m.pageSuggestions[loopId] ?? []
        VStack(alignment: .leading, spacing: 6) {
            NSectionHeader(L("Work · %lld", items.count))
            ForEach(items) { x in
                HStack(spacing: 8) {
                    Image(systemName: x.state == .done ? "checkmark.circle.fill" : x.state == .inProgress ? "circle.lefthalf.filled" : "circle")
                        .font(.caption).accessibilityHidden(true)
                    Text(x.title ?? L("Work item")).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                        .strikethrough(x.state == .done)
                    MonoLabel(L(x.kind.tag).uppercased(), size: NV.Size.labelSm)
                    Spacer()
                    if let s = x.slot, x.state != .done { Text(WhenText.slot(s.interval)).font(.caption).foregroundStyle(skin.muted) }
                    else { Text(WhenText.minutes(x.minutes)).font(.caption).foregroundStyle(skin.muted) }
                    if x.state == .scheduled || x.state == .inProgress {
                        Button(L("Deep")) { m.deepItemId = x.id; m.present(.deep, openWindow: openWindow); Task { await m.loadDeep(app, prefer: x.id) } }.buttonStyle(.link).font(.caption)
                    }
                    if x.state == .scheduled, (x.slot?.start ?? .distantPast) > Date() {
                        Button(L("Reschedule")) { let id = x.id; m.pageEdit(loopId, app: app) { $0.reschedule(id) }; m.whenLoop = nil; m.whenFirst = id; m.present(.when, openWindow: openWindow) }
                            .buttonStyle(.link).font(.caption)
                    }
                    if x.state == .done { Button(L("Reopen")) { let id = x.id; m.pageEdit(loopId, app: app) { $0.reopen(id) } }.buttonStyle(.link).font(.caption) }
                }
            }
            if !sug.isEmpty {
                MonoLabel(L("Suggested"), size: NV.Size.labelSm)
                ForEach(sug) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(skin.muted).accessibilityHidden(true)
                        Text(s.title ?? (s.kind == .reply ? L("Reply to a protected conversation") : L("A promise in a protected message")))
                            .font(skin.sans(NV.Size.body)).foregroundStyle(skin.muted).lineLimit(1)
                        MonoLabel(L(s.kind.tag).uppercased(), size: NV.Size.labelSm)
                        Spacer()
                        Button(L("Add")) { m.pageEdit(loopId, app: app) { $0.accept(s) } }.buttonStyle(.link).font(.caption)
                        Button(L("Not this")) { m.pageEdit(loopId, app: app) { $0.dismiss(s) } }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            TextField(L("New work item (return to add)"), text: $model.newItemTitle)
                .textFieldStyle(.plain).font(skin.sans(NV.Size.body))
                .onSubmit {
                    let t = m.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    m.newItemTitle = ""
                    m.pageEdit(loopId, app: app) { $0.add(loopId: loopId, title: t) }
                }
                .accessibilityLabel(L("New work item"))
        }
        .task(id: loopId) { await m.loadPage(loopId, app: app) }
    }
}
