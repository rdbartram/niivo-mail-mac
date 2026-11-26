import SwiftUI
import CalendarCore

// Month and Agenda views. Both render only `model.weekEvents`, which `AppModel.visibleRange` makes exactly what is on
// screen — so `screenPolicy` (capture blocking) and the inspector's selection cover them like the grid.
// Ownership: calendar colour on every chip, owner initials when more than one owner is visible; labels: LabelGlyph,
// "Private appointment" when the policy redacts.

struct MonthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let days = CalendarRanges.monthGrid(containing: model.anchorDate)
        let month = Calendar.current.component(.month, from: model.anchorDate)
        let symbols = Self.weekdaySymbols()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    MonoLabel(s, size: NV.Size.labelSm).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
            }
            .padding(.vertical, 6)
            .hairline(skin)
            GeometryReader { geo in
                let rowH = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { c in
                                let d = days[r * 7 + c]
                                MonthCell(day: d, inMonth: Calendar.current.component(.month, from: d) == month, height: rowH)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(alignment: .trailing) { if c < 6 { Rectangle().fill(skin.hair).frame(width: 1) } }
                            }
                        }
                        .frame(height: rowH)
                        .overlay(alignment: .bottom) { if r < 5 { Rectangle().fill(skin.hair).frame(height: 1) } }
                    }
                }
            }
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : model.theme.gridBackground)
        .accessibilityLabel("Month")
    }

    static func weekdaySymbols() -> [String] {
        let c = Calendar.current
        let s = c.shortWeekdaySymbols
        return (0..<7).map { s[(c.firstWeekday - 1 + $0) % 7] }
    }
}

struct MonthCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var day: Date
    var inMonth: Bool
    var height: CGFloat

    var body: some View {
        let events = CalendarRanges.events(on: day, in: model.weekEvents)
        let today = Calendar.current.isDateInToday(day)
        let capacity = max(1, Int((height - 26) / 17))
        let chips = CalendarRanges.chips(events, capacity: capacity)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(day, format: .dateTime.day())
                    .font(skin.mono(11, today ? .semibold : .regular))
                    .foregroundStyle(today ? skin.onAccent : (inMonth ? skin.ink : skin.muted.opacity(0.6)))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background { if today { Rectangle().fill(skin.accentFill) } }
                Spacer(minLength: 0)
            }
            ForEach(chips.shown) { e in MonthChip(event: e, day: day) }
            if chips.more > 0 {
                Button { model.openDay(day) } label: {
                    MonoLabel("+\(chips.more) more", size: NV.Size.labelSm)
                }
                .buttonStyle(.plain).help("Open this day")
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openDay(day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(events.count) events")
    }
}

struct MonthChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var event: CalendarEvent
    var day: Date

    var body: some View {
        let p = model.policy(for: event)
        let tint = model.tint(for: event)
        let cal = model.calendar(for: event)
        let selected = model.selectedEventId == event.id
        let title = p.redactDetails ? "Private appointment" : event.subject
        HStack(spacing: 4) {
            if event.isAllDay || !Calendar.current.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1)) {
                Rectangle().fill(tint).frame(width: 3, height: 11)
            } else {
                Rectangle().fill(tint).frame(width: 5, height: 5)
                if Calendar.current.isDate(event.start, inSameDayAs: day) {
                    Text(event.start, format: .dateTime.hour().minute()).font(skin.mono(9.5)).foregroundStyle(skin.muted)
                }
            }
            if model.showsOwnerBadges, let cal { OwnerInitials(name: cal.ownerDisplay, color: tint, size: 12) }
            if let l = p.label { LabelGlyph(label: l) }
            // Unknown label id: not proven ours (events carry no provenance) → no glyph (LabelProvenance.swift).
            Text(title).font(skin.sans(11)).foregroundStyle(skin.ink).lineLimit(1)
            if !p.redactDetails { EventCategoryDots(names: event.categories ?? []) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(selected ? tint.opacity(0.22) : (event.showAs == .tentative ? Color.clear : tint.opacity(0.08)))
        .overlay { if event.showAs == .tentative { Rectangle().strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) } }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedEventId = event.id }
        .help("\(cal?.ownerDisplay ?? "") · \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(cal?.ownerDisplay ?? ""), \(event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Up-next list: the next `AppModel.agendaDays` days from the anchor, grouped by day.
struct AgendaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        let range = model.visibleRange
        let sections = CalendarRanges.agendaSections(model.weekEvents, interval: range)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sections.isEmpty {
                    Notice(icon: "calendar", text: "Nothing scheduled in the next \(AppModel.agendaDays) days on the calendars shown.")
                        .padding(24)
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 8) {
                        MonoLabel(s.day.formatted(.dateTime.weekday(.wide).day().month(.wide)), color: Calendar.current.isDateInToday(s.day) ? skin.accentInk : skin.ink,
                                  wide: true, weight: .medium)
                        if Calendar.current.isDateInToday(s.day) { NChip("Today") }
                        Spacer()
                        MonoLabel("\(s.events.count)", size: NV.Size.labelSm)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(s.events) { e in
                        AgendaRow(event: e, now: .now)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedEventId = e.id }
                            .nRow(selected: model.selectedEventId == e.id, hoverKey: AnyHashable("agenda:" + e.id + "\(s.day.timeIntervalSince1970)"), skin: skin)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .background(skin.brand ? AnyShapeStyle(skin.ground) : model.theme.gridBackground)
        .accessibilityLabel("Agenda")
    }
}

struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var event: CalendarEvent
    var now: Date

    var body: some View {
        let cal = model.calendar(for: event)
        let p = model.policy(for: event)
        let tint = model.tint(for: event)
        let live = event.start <= now && event.end > now
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay { MonoLabel("All day", size: NV.Size.labelSm) }
                else {
                    Text(event.start, format: .dateTime.hour().minute()).font(skin.mono(11, .medium)).foregroundStyle(skin.ink)
                    Text(event.end, format: .dateTime.hour().minute()).font(skin.mono(10)).foregroundStyle(skin.muted)
                }
            }
            .frame(width: 52, alignment: .trailing)
            Rectangle().fill(tint).frame(width: 3)
            if let cal { OwnerBadge(calendar: cal, tint: tint, size: 22) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let l = p.label { LabelGlyph(label: l) }
                    // Unknown label id: not proven ours (events carry no provenance) → no glyph (LabelProvenance.swift).
                    Text(p.redactDetails ? "Private appointment" : event.subject).font(skin.sans(13, .medium)).foregroundStyle(skin.ink).lineLimit(1)
                    if live { NChip("Now") }
                    if event.showAs == .tentative || event.myResponse == "tentativelyAccepted" { NChip("Tentative") }
                    if event.myResponse == "notResponded" || event.myResponse == "none" , event.isOrganizer == false { NChip("Not answered") }
                }
                Text([p.redactDetails ? nil : event.location, cal.map { "\($0.ownerDisplay) · \($0.name)" }].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(skin.sans(11)).foregroundStyle(skin.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !p.redactDetails { EventCategoryDots(names: event.categories ?? []) }
            if !p.redactDetails, let url = event.onlineMeetingURL, event.end > now {
                NButton("Join", systemImage: "video.fill", kind: live ? .primary : .ghost) { MeetingLauncher.join(url) }
                    .fixedSize().help("Join \(MeetingProvider(url: url).displayName)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Category colour dots (master list colours; unknown names grey). Names in the tooltip.
struct EventCategoryDots: View {
    var names: [String]
    var body: some View {
        if !names.isEmpty {
            let cats = CalendarExtras.shared.categories
            HStack(spacing: 2) {
                ForEach(names.prefix(4), id: \.self) { n in
                    let hex = OutlookCategory.lookup(n, in: cats)?.hex
                    Circle().fill(hex.map { Color(hex: $0) } ?? Color.gray).frame(width: 6, height: 6)
                }
            }
            .help("Categories: " + names.joined(separator: ", "))
            .accessibilityLabel("Categories: " + names.joined(separator: ", "))
        }
    }
}
