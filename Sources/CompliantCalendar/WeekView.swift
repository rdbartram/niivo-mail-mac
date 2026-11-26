import AppKit
import SwiftUI
import CalendarCore

/// One vertical lane of the grid. Overlay: one per day (all calendars). Side by side: one per (day, calendar).
struct GridColumn: Hashable {
    var day: Date
    var calendar: CalendarInfo?
    /// First lane of its group (a day, or a calendar) — gets the strong divider.
    var startsGroup: Bool
}

struct WeekView: View {
    @Environment(AppModel.self) private var model
    private var hourHeight: CGFloat { model.theme.hourHeight }
    /// Wider when a second time zone is shown (CALENDAR-HOOK: CalendarExtras.secondZone).
    private var gutter: CGFloat { CalendarExtras.shared.secondZone == nil ? 56 : 100 }

    private var columns: [GridColumn] {
        let cals = model.visibleCalendars
        let days = model.visibleDays
        guard model.layout == .split, !cals.isEmpty else {
            return days.map { GridColumn(day: $0, calendar: nil, startsGroup: true) }
        }
        switch model.grouping {
        case .byDay:
            return days.flatMap { d in cals.enumerated().map { GridColumn(day: d, calendar: $1, startsGroup: $0 == 0) } }
        case .byCalendar:
            return cals.flatMap { c in days.enumerated().map { GridColumn(day: $1, calendar: c, startsGroup: $0 == 0) } }
        }
    }

    private func events(in c: GridColumn) -> [CalendarEvent] {
        guard let cal = c.calendar else { return model.weekEvents }
        return model.weekEvents.filter { $0.calendarId == cal.id }
    }

    var body: some View {
        GeometryReader { geo in
            let cols = columns
            let colW = (geo.size.width - gutter) / CGFloat(max(cols.count, 1))
            let _ = syncColumns(cols)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(cols, colW)
                    allDayStrip(cols, colW)
                }
                .themedChrome(model.theme)
                if model.theme.fill != .glass { Divider() }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            GridCanvas(hourHeight: hourHeight, gutter: gutter, colW: colW, columns: cols, tints: model.tints, theme: model.theme,
                                       secondZone: CalendarExtras.shared.secondZone)
                                .frame(height: hourHeight * 24)
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { h in Color.clear.frame(height: hourHeight).id(h) }
                            }
                            // Empty-slot layer: drag to create, double-click for a 30-min event.
                            ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                                CreateLane(column: col, hourHeight: hourHeight)
                                    .frame(width: colW, height: hourHeight * 24)
                                    .offset(x: gutter + CGFloat(i) * colW)
                            }
                            if let g = model.createGhost, g.column < cols.count {
                                CreateGhost(startMinute: g.startMinute, endMinute: g.endMinute, hourHeight: hourHeight,
                                            tint: model.tint(cols[g.column].calendar ?? model.defaultWriteCalendar))
                                    .frame(width: colW - 6, height: max(CGFloat(g.endMinute - g.startMinute) / 60 * hourHeight, 10))
                                    .offset(x: gutter + CGFloat(g.column) * colW + 3, y: CGFloat(g.startMinute) / 60 * hourHeight)
                                    .allowsHitTesting(false)
                            }
                            ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                                let inset: CGFloat = colW > 40 ? 3 : 1
                                ForEach(DayLayout.place(events(in: col), day: col.day), id: \.event.id) { p in
                                    let w = (colW - inset * 2) / CGFloat(p.columns)
                                    EventBlock(placed: p, hourHeight: hourHeight, width: max(w - 1, 4),
                                               height: max(CGFloat(p.endMinute - p.startMinute) / 60 * hourHeight - 2, 14),
                                               colW: colW,
                                               onDrop: { dCols, mins in drop(p.event, from: i, by: dCols, minutes: mins, cols: cols) })
                                        .frame(width: max(w - 1, 4), alignment: .top)
                                        .offset(x: gutter + CGFloat(i) * colW + inset + CGFloat(p.column) * w,
                                                y: CGFloat(p.startMinute) / 60 * hourHeight + 1)
                                }
                            }
                            NowLine(hourHeight: hourHeight, gutter: gutter, colW: colW, columns: cols)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollPosition(Bindable(model).gridScroll)
                    // Scroll to the working day after layout settles; again when the range or layout changes,
                    // because those rebuild the grid and reset the offset.
                    .onAppear { scrollToMorning(proxy) }
                    .onChange(of: model.dayCount) { scrollToMorning(proxy) }
                    .onChange(of: model.layout) { scrollToMorning(proxy) }
                    .onChange(of: model.grouping) { scrollToMorning(proxy) }
                    // First sync (and calendar list changes) rebuild the grid — re-anchor once data lands.
                    .onChange(of: model.calendars.map(\.id)) { scrollToMorning(proxy) }
                    .onChange(of: model.weekStart) { scrollToMorning(proxy) }
                }
            }
        }
        .background(model.theme.gridBackground)
        .fontDesign(model.theme.design)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedEventId = nil }
    }

    /// Keeps the model's lane list current for CreateLane (deferred: no state writes during body evaluation).
    private func syncColumns(_ cols: [GridColumn]) {
        if model.gridColumns != cols { DispatchQueue.main.async { model.gridColumns = cols } }
    }

    /// Dropped `dCols` lanes sideways and `minutes` down: new day (and calendar, in side-by-side lanes).
    private func drop(_ e: CalendarEvent, from i: Int, by dCols: Int, minutes: Int, cols: [GridColumn]) {
        let t = min(max(i + dCols, 0), cols.count - 1)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: cols[i].day),
                                                   to: Calendar.current.startOfDay(for: cols[t].day)).day ?? 0
        model.move(e, dayOffset: days, byMinutes: minutes, to: cols[t].calendar)
    }

    private func scrollToMorning(_ proxy: ScrollViewProxy) {
        let y = hourHeight * 7
        for delay in [0.05, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.gridScroll.scrollTo(y: y) }
        }
    }

    // MARK: Header

    private func header(_ cols: [GridColumn], _ colW: CGFloat) -> some View {
        let split = cols.contains { $0.calendar != nil }
        let byCal = split && model.grouping == .byCalendar && model.dayCount > 1
        // Top row: one cell per group. Bottom row (split only): one cell per lane.
        let groups: [(start: Int, span: Int)] = {
            var out: [(Int, Int)] = []
            for (i, c) in cols.enumerated() {
                if c.startsGroup || out.isEmpty { out.append((i, 1)) } else { out[out.count - 1].1 += 1 }
            }
            return out
        }()
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 40)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    Group {
                        if byCal, let cal = cols[g.start].calendar {
                            CalendarGroupHeader(calendar: cal)
                        } else {
                            dayLabel(cols[g.start].day)
                        }
                    }
                    .frame(width: colW * CGFloat(g.span), height: 40)
                }
            }
            if split {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 22)
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                        Group {
                            if byCal { CompactDayLabel(day: c.day, width: colW) }
                            else { CalendarLaneHeader(calendar: c.calendar!, width: colW) }
                        }
                        .frame(width: colW, height: 22)
                    }
                }
            }
        }
    }

    private func dayLabel(_ d: Date) -> some View {
        let today = Calendar.current.isDateInToday(d)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(d, format: .dateTime.weekday(model.dayCount == 1 ? .wide : .abbreviated))
                .font(model.theme.brand ? NiivoFonts.mono(NV.Size.label) : .callout).textCase(model.theme.brand ? .uppercase : nil).foregroundStyle(.secondary)
            Text(d, format: .dateTime.day())
                .font(model.theme.brand ? model.theme.font(17, today ? .medium : .regular) : .title3.weight(today ? .bold : .regular))
                .fixedSize()
                .foregroundStyle(today ? model.theme.todayText : .primary)
                .padding(.horizontal, today ? 7 : 0).padding(.vertical, today ? 1 : 0)
                .background { if today { if model.theme.brand { Rectangle().fill(model.theme.todayFill) } else { Capsule().fill(model.theme.todayFill) } } }
        }
    }

    private func allDayStrip(_ cols: [GridColumn], _ colW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(.caption2).foregroundStyle(.tertiary).frame(width: gutter, alignment: .trailing).padding(.trailing, 6)
            ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                let next = Calendar.current.date(byAdding: .day, value: 1, to: col.day)!
                VStack(spacing: 2) {
                    ForEach(events(in: col).filter { $0.isAllDay && $0.start < next && $0.end > col.day }) { e in
                        let c = model.tint(for: e)
                        Text(model.policy(for: e).redactDetails ? "Private" : e.subject)
                            .font(.caption.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, colW > 40 ? 6 : 2).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(c.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                            .help(model.policy(for: e).redactDetails ? "Private" : e.subject)
                            .meetingActions(e, model.policy(for: e))
                            .onTapGesture { model.selectedEventId = e.id }
                    }
                }
                .padding(.horizontal, colW > 40 ? 3 : 1)
                .frame(width: colW, alignment: .top)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Group caption when grouped by calendar: spans that calendar's days.
struct CalendarGroupHeader: View {
    @Environment(AppModel.self) private var model
    var calendar: CalendarInfo
    var body: some View {
        let tint = model.tint(calendar)
        let who = calendar.access == .own ? calendar.name : (calendar.ownerName.isEmpty ? calendar.name : calendar.ownerName)
        HStack(spacing: 6) {
            OwnerBadge(calendar: calendar, tint: tint, size: 18)
            Text(who).font(.callout.weight(.semibold)).lineLimit(1)
            if calendar.access != .own, calendar.name != who {
                Text(calendar.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.08))
        .help(calendar.access == .own ? calendar.name : "\(calendar.name) · \(calendar.ownerName)")
    }
}

/// Day caption under a calendar group: "Mo 16", or just "16" when narrow. Today is marked.
struct CompactDayLabel: View {
    @Environment(AppModel.self) private var model
    var day: Date
    var width: CGFloat
    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        HStack(spacing: 3) {
            if width > 44 { Text(day, format: .dateTime.weekday(.abbreviated)).foregroundStyle(.secondary) }
            Text(day, format: .dateTime.day())
                .fontWeight(today ? (model.theme.brand ? .medium : .bold) : .regular)
                .foregroundStyle(today ? model.theme.todayText : .primary)
                .padding(.horizontal, today ? 4 : 0)
                .background { if today { if model.theme.brand { Rectangle().fill(model.theme.todayFill) } else { Capsule().fill(model.theme.todayFill) } } }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity)
        .help(day.formatted(date: .complete, time: .omitted))
    }
}

/// Lane caption in side-by-side mode: colour bar always, name when there's room, full name on hover.
struct CalendarLaneHeader: View {
    @Environment(AppModel.self) private var model
    var calendar: CalendarInfo
    var width: CGFloat
    var body: some View {
        let tint = model.tint(calendar)
        let title = calendar.access == .own ? calendar.name : (calendar.ownerName.isEmpty ? calendar.name : calendar.ownerName)
        HStack(spacing: 4) {
            if width > 30 { OwnerBadge(calendar: calendar, tint: tint, size: 14) }
            else { RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 12) }
            if width > 60 {
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: width > 60 ? .leading : .center)
        .background(tint.opacity(0.08))
        .help(calendar.access == .own ? calendar.name : "\(calendar.name) · \(calendar.ownerName)")
    }
}

/// The whole grid drawn in one Canvas pass — no per-cell views, so resizing/scrolling stays at frame rate.
struct GridCanvas: View {
    var hourHeight: CGFloat, gutter: CGFloat, colW: CGFloat, columns: [GridColumn]
    var tints: [String: Color] = [:]
    var theme: Theme = .classic
    /// Secondary time zone: its hour labels in a column left of the primary ones (zone names at the top).
    var secondZone: TimeZone? = nil

    var body: some View {
        let multiDay = Set(columns.map { Calendar.current.startOfDay(for: $0.day) }).count > 1
        Canvas { ctx, size in
            for (i, c) in columns.enumerated() {
                let rect = CGRect(x: gutter + CGFloat(i) * colW, y: 0, width: colW, height: size.height)
                if Calendar.current.isDateInWeekend(c.day) { ctx.fill(Path(rect), with: .color(theme.brand ? NV.ink.opacity(0.03) : .primary.opacity(0.025))) }
                if multiDay, Calendar.current.isDateInToday(c.day) { ctx.fill(Path(rect), with: .color(theme.todayColumn)) }
                if let cal = c.calendar { ctx.fill(Path(rect), with: .color((tints[cal.id] ?? .gray).opacity(0.035))) }
            }
            for h in 0..<24 {
                let y = CGFloat(h) * hourHeight
                var line = Path(); line.move(to: .init(x: gutter, y: y)); line.addLine(to: .init(x: size.width, y: y))
                // niivo: 1 pt hairline rules, quiet half-hour tick, mono hour labels.
                ctx.stroke(line, with: .color(theme.brand ? NV.hair : .primary.opacity(theme.gridLine)), lineWidth: theme.brand ? 1 : 0.5)
                var half = Path(); half.move(to: .init(x: gutter, y: y + hourHeight / 2)); half.addLine(to: .init(x: size.width, y: y + hourHeight / 2))
                ctx.stroke(half, with: .color(theme.brand ? NV.hair.opacity(0.5) : .primary.opacity(0.04)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                if h > 0 {
                    let label = theme.brand ? Text(String(format: "%02d:00", h)).font(NiivoFonts.mono(9.5)).foregroundStyle(NV.muted)
                                            : Text(String(format: "%02d:00", h)).font(.caption2).foregroundStyle(.secondary)
                    ctx.draw(label, at: .init(x: gutter - 8, y: y), anchor: .trailing)
                    if let z = secondZone {
                        let s = SecondaryZone.label(hour: h, day: columns.first?.day ?? .now, zone: z)
                        let l2 = theme.brand ? Text(s).font(NiivoFonts.mono(9)).foregroundStyle(NV.muted.opacity(0.7))
                                             : Text(s).font(.caption2).foregroundStyle(.tertiary)
                        ctx.draw(l2, at: .init(x: gutter - 52, y: y), anchor: .trailing)
                    }
                } else if let z = secondZone {
                    let day = columns.first?.day ?? .now
                    let a = Text(SecondaryZone.shortName(z, at: day)).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    let b = Text(SecondaryZone.shortName(.current, at: day)).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    ctx.draw(a, at: .init(x: gutter - 52, y: 8), anchor: .trailing)
                    ctx.draw(b, at: .init(x: gutter - 8, y: 8), anchor: .trailing)
                }
            }
            for i in 0...columns.count {
                let x = gutter + CGFloat(i) * colW
                let dayEdge = i == columns.count || columns[i].startsGroup
                var v = Path(); v.move(to: .init(x: x, y: 0)); v.addLine(to: .init(x: x, y: size.height))
                ctx.stroke(v, with: .color(theme.brand ? (dayEdge ? NV.hair2 : NV.hair) : .primary.opacity(dayEdge ? 0.16 : 0.05)), lineWidth: dayEdge ? 1 : 0.5)
            }
        }
    }
}

struct NowLine: View {
    @Environment(\.skin) private var skin
    var hourHeight: CGFloat, gutter: CGFloat, colW: CGFloat, columns: [GridColumn]
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let mins = ctx.date.timeIntervalSince(Calendar.current.startOfDay(for: ctx.date)) / 60
            let y = CGFloat(mins) / 60 * hourHeight
            // Today's lanes may be contiguous (grouped by day) or spread out (grouped by calendar): draw runs.
            let runs: [(Int, Int)] = columns.indices.reduce(into: []) { acc, i in
                guard Calendar.current.isDate(columns[i].day, inSameDayAs: ctx.date) else { return }
                if let last = acc.last, last.0 + last.1 == i { acc[acc.count - 1].1 += 1 } else { acc.append((i, 1)) }
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    if skin.brand {
                        // niivo: the view's one cyan element — a 1.5 pt line with a square head.
                        HStack(spacing: 0) {
                            Rectangle().fill(skin.accentFill).frame(width: 7, height: 7)
                            Rectangle().fill(skin.accentFill).frame(width: colW * CGFloat(r.1) - 4, height: 1.5)
                        }
                        .offset(x: gutter + CGFloat(r.0) * colW - 4, y: y - 3.5)
                        .accessibilityHidden(true)
                    } else {
                        HStack(spacing: 0) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Rectangle().fill(.red).frame(width: colW * CGFloat(r.1) - 4, height: 1.5)
                        }
                        .offset(x: gutter + CGFloat(r.0) * colW - 4, y: y - 4)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

struct EventBlock: View {
    @Environment(AppModel.self) private var model
    var placed: PlacedEvent
    var hourHeight: CGFloat
    var width: CGFloat
    var height: CGFloat
    var colW: CGFloat
    var onDrop: (Int, Int) -> Void
    @GestureState private var drag: CGSize = .zero
    @GestureState private var stretch: CGFloat = 0

    var body: some View {
        let e = placed.event
        let policy = model.policy(for: e)
        let tint = model.tint(for: e)
        let owner = model.calendar(for: e)
        let selected = model.selectedEventId == e.id
        let snapped = (drag.height / hourHeight * 60 / 15).rounded() * 15
        let laneShift = (drag.width / colW).rounded()
        let stretchMin = (stretch / hourHeight * 60 / 15).rounded() * 15
        let editable = model.canEdit(e)

        let t = model.theme
        let onSolid = t.fill == .solid && e.showAs != .tentative
        HStack(spacing: 0) {
            if t.leadingBar > 0 { Rectangle().fill(tint).frame(width: t.leadingBar) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if model.showsOwnerBadges, model.layout == .overlay, let owner, width > 44 {
                        OwnerBadge(calendar: owner, tint: tint, size: 13)
                    }
                    if let l = policy.label { LabelGlyph(label: l) }
                    // Unknown label id: not proven ours (events carry no provenance) → no glyph (LabelProvenance.swift).
                    if width > 34 {
                        Text(policy.redactDetails ? "Private appointment" : e.subject)
                            .font(t.font(11.5, t.titleWeight)).lineLimit(width > 90 ? 2 : 1)
                    }
                    if !policy.redactDetails, width > 70 { EventCategoryDots(names: e.categories ?? []) }   // CALENDAR-HOOK
                }
                if placed.endMinute - placed.startMinute >= 45 && width > 60 {
                    Text(e.start, format: .dateTime.hour().minute()).font(t.brand ? NiivoFonts.mono(9.5) : .system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    if !policy.redactDetails, let loc = e.location {
                        Text(loc).font(t.brand ? NiivoFonts.sans(10.5) : .system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(onSolid ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .eventSurface(t, tint: tint, selected: selected, tentative: e.showAs == .tentative)
        .overlay {
            if e.showAs == .tentative {
                RoundedRectangle(cornerRadius: t.corner, style: .continuous).strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if !policy.redactDetails, e.onlineMeetingURL != nil, width > 50 {
                    NSymbol("video.fill", size: 8.5, label: "Online meeting").foregroundStyle(tint)
                }
                if e.pendingSync { Circle().fill(.orange).frame(width: 6, height: 6).help("Waiting to sync") }
            }.padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: t.corner, style: .continuous))
        .frame(height: max(height + stretchMin / 60 * hourHeight, hourHeight / 4))
        .overlay(alignment: .bottom) {
            // Resize handle: bottom edge, 15-min snaps.
            if editable && height > 18 {
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 2)
                            .updating($stretch) { v, s, _ in s = v.translation.height }
                            .onEnded { v in model.resize(e, byMinutes: Int((v.translation.height / hourHeight * 60 / 15).rounded() * 15)) }
                    )
            }
        }
        .shadow(color: .black.opacity(t.brand ? 0 : (selected ? 0.2 : t.blockShadow)), radius: selected ? 8 : 3, y: selected ? 3 : 1)
        .overlay(alignment: .topLeading) {
            if drag != .zero {
                let st = Calendar.current.date(byAdding: .minute, value: Int(snapped), to: e.start)!
                Text(st, format: .dateTime.hour().minute())
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -18)
            }
        }
        .zIndex(drag != .zero || stretch != 0 ? 10 : 0)
        .offset(x: laneShift * colW, y: snapped / 60 * hourHeight)
        .meetingActions(e, policy)
        .onTapGesture { model.selectedEventId = e.id }
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($drag) { v, state, _ in if editable { state = v.translation } }
                .onEnded { v in
                    guard editable else { return }
                    let mins = Int((v.translation.height / hourHeight * 60 / 15).rounded() * 15)
                    onDrop(Int((v.translation.width / colW).rounded()), mins)
                }
        )
        .help("\(owner?.ownerDisplay ?? "") · " + (policy.redactDetails ? "Private appointment" : e.subject) + (editable ? " — drag to move, drag the bottom edge to resize" : (model.canRemove(e) ? " — invitation (decline only)" : " — view only")))
        .animation(.snappy(duration: 0.18), value: snapped)
    }
}

/// Empty grid space for one lane: drag to sketch a new event, double-click for 30 minutes.
struct CreateLane: View {
    @Environment(AppModel.self) private var model
    var column: GridColumn
    var hourHeight: CGFloat

    private func minute(_ y: CGFloat) -> Int { max(0, min(24 * 60 - 15, Int((y / hourHeight * 60 / 15).rounded(.down) * 15))) }
    private var target: CalendarInfo? { column.calendar.flatMap { $0.canEdit ? $0 : nil } ?? (column.calendar == nil ? model.defaultWriteCalendar : nil) }
    private func date(_ m: Int) -> Date { Calendar.current.date(byAdding: .minute, value: m, to: Calendar.current.startOfDay(for: column.day))! }

    var body: some View {
        let idx = model.gridColumnIndex(column)
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { p in
                guard let target else { return }
                let m = minute(p.y)
                model.newEvent(start: date(m), end: date(m + 30), calendar: target)
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { v in
                        guard target != nil else { return }
                        let a = minute(min(v.startLocation.y, v.location.y)), b = minute(max(v.startLocation.y, v.location.y)) + 15
                        model.createGhost = .init(column: idx, startMinute: a, endMinute: b)
                    }
                    .onEnded { _ in
                        guard let g = model.createGhost, let target else { model.createGhost = nil; return }
                        model.createGhost = nil
                        model.newEvent(start: date(g.startMinute), end: date(g.endMinute), calendar: target)
                    }
            )
            .help(target == nil ? "View only" : "Drag to create an event in \(target!.ownerDisplay)’s calendar")
    }
}

struct CreateGhost: View {
    var startMinute: Int, endMinute: Int, hourHeight: CGFloat, tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .overlay(alignment: .topLeading) {
                Text("\(ScheduleView.clock(startMinute))–\(ScheduleView.clock(endMinute))")
                    .font(.caption2.weight(.semibold).monospacedDigit()).padding(5)
            }
    }
}
