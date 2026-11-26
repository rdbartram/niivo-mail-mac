import SwiftUI
import CalendarCore

/// Outlook-style schedule: one row per calendar, time runs left → right across one day, scaled to fit the
/// window (no horizontal scrolling). The top row merges everyone's busy time and shows the gaps — the
/// point of this view is "when can all of these people meet?".
struct ScheduleView: View {
    @Environment(AppModel.self) private var model
    private let nameW: CGFloat = 190
    private let rowH: CGFloat = 58
    private let subH: CGFloat = 26

    private var day: Date { model.weekStart }
    private var dayStart: Date { Calendar.current.startOfDay(for: day) }

    /// Working window: 07–19 by default, widened to include any timed event that day.
    private var window: (start: Int, end: Int) {
        let timed = model.weekEvents.filter { !$0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: day) }
        let mins = timed.map { Int($0.start.timeIntervalSince(dayStart) / 60) }
        let ends = timed.map { Int(min($0.end.timeIntervalSince(dayStart) / 60, 1440)) }
        let s = min(7 * 60, (mins.min() ?? 1440) / 60 * 60)
        let e = max(19 * 60, ((ends.max() ?? 0) + 59) / 60 * 60)
        return (s, e)
    }

    var body: some View {
        GeometryReader { geo in
            let w = window
            let pxPerMin = (geo.size.width - nameW - 16) / CGFloat(w.end - w.start)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    axis(w, pxPerMin).themedChrome(model.theme)
                    freeRow(w, pxPerMin)
                    Divider()
                    ForEach(model.visibleCalendars) { cal in
                        row(cal, w, pxPerMin)
                        Divider().opacity(0.5)
                    }
                    if model.showsTeammates {
                        HStack {
                            Text("TEAMMATES · FREE/BUSY ONLY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                        ForEach(model.teammates) { t in
                            teammateRow(t, w, pxPerMin)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .overlay(alignment: .topLeading) { nowLine(w, pxPerMin) }
            }
        }
        .background(model.theme.gridBackground)
        .fontDesign(model.theme.design)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedEventId = nil }
    }

    private func x(_ minute: Int, _ w: (start: Int, end: Int), _ ppm: CGFloat) -> CGFloat {
        nameW + CGFloat(minute - w.start) * ppm
    }

    // MARK: Axis

    private func axis(_ w: (start: Int, end: Int), _ ppm: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                Text(day, format: .dateTime.weekday(.wide)).foregroundStyle(.secondary)
                Text(day, format: .dateTime.day().month(.wide)).font(.title3.weight(.semibold))
            }
            .frame(width: nameW, height: 40)
            // First tick sits under the date label — start labels one hour in.
            ForEach(Array(stride(from: w.start + 60, through: w.end, by: 60)), id: \.self) { m in
                Text(String(format: "%02d:00", m / 60)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: x(m, w, ppm) - 14, y: 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
    }

    // MARK: Free row

    private func freeRow(_ w: (start: Int, end: Int), _ ppm: CGFloat) -> some View {
        let teammateBusy: [CalendarEvent] = model.showsTeammates ? model.teammates.flatMap { t in
            model.slots(for: t).map { s in
                var e = CalendarEvent(id: "fb-\(t.id)-\(s.start.timeIntervalSince1970)", calendarId: "", subject: "", start: s.start, end: s.end,
                                      isAllDay: s.end.timeIntervalSince(s.start) >= 86_000)
                e.showAs = s.status; return e
            }
        } : []
        let people = model.visibleCalendars.count + (model.showsTeammates ? model.teammates.count : 0)
        let gaps = FreeTime.gaps(model.weekEvents.filter { model.enabledCalendars.contains($0.calendarId) } + teammateBusy,
                                 day: dayStart, from: w.start, to: w.end)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                NSymbol("person.3.fill", size: 13).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Everyone free").font(.callout.weight(.semibold))
                    Text("\(people) people & calendars").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: nameW, height: 44, alignment: .leading).padding(.leading, 12)
            ForEach(gaps, id: \.0) { g in
                let width = CGFloat(g.1 - g.0) * ppm
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.green.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.green.opacity(0.45), lineWidth: 1))
                    .overlay {
                        if width > 54 {
                            Text(Self.duration(g.1 - g.0)).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                        }
                    }
                    .frame(width: max(width - 2, 2), height: 26)
                    .offset(x: x(g.0, w, ppm) + 1, y: 9)
                    .help("Free for everyone: \(Self.clock(g.0))–\(Self.clock(g.1)) (\(Self.duration(g.1 - g.0)))")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
    }

    // MARK: Calendar rows

    private func row(_ cal: CalendarInfo, _ w: (start: Int, end: Int), _ ppm: CGFloat) -> some View {
        let tint = model.tint(cal)
        let placed = DayLayout.place(model.weekEvents.filter { $0.calendarId == cal.id }, day: day)
        let lanes = max(placed.map(\.columns).max() ?? 1, 1)
        let height = max(rowH, CGFloat(lanes) * (subH + 3) + 8)
        return ZStack(alignment: .topLeading) {
            // Hour grid for this row.
            Canvas { ctx, size in
                for m in stride(from: w.start, through: w.end, by: 60) {
                    let px = x(m, w, ppm)
                    var p = Path(); p.move(to: .init(x: px, y: 0)); p.addLine(to: .init(x: px, y: size.height))
                    ctx.stroke(p, with: .color(.primary.opacity(model.theme.gridLine)), lineWidth: 0.5)
                }
                ctx.fill(Path(CGRect(x: nameW, y: 0, width: size.width - nameW, height: size.height)),
                         with: .color(tint.opacity(0.03)))
            }
            HStack(spacing: 10) {
                OwnerBadge(calendar: cal, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cal.ownerDisplay).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(cal.access == .own ? cal.name : "\(cal.name) · \(cal.canEdit ? "can edit" : "view only")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: nameW - 12, height: height, alignment: .leading)
            .padding(.leading, 12)
            ForEach(placed, id: \.event.id) { p in
                ScheduleChip(event: p.event, tint: tint,
                             width: max(CGFloat(p.endMinute - p.startMinute) * ppm - 2, 6))
                    .frame(width: max(CGFloat(p.endMinute - p.startMinute) * ppm - 2, 6), height: subH)
                    .offset(x: x(max(p.startMinute, w.start), w, ppm) + 1,
                            y: 4 + CGFloat(p.column) * (subH + 3) + (lanes == 1 ? (height - subH) / 2 - 4 : 0))
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
    }

    private func teammateRow(_ t: Teammate, _ w: (start: Int, end: Int), _ ppm: CGFloat) -> some View {
        let slots = model.slots(for: t).filter { $0.end > dayStart && $0.start < dayStart.addingTimeInterval(86_400) && $0.status != .free }
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                TeammateBadge(teammate: t, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("Availability only").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: nameW - 12, height: 44, alignment: .leading).padding(.leading, 12)
            ForEach(Array(slots.enumerated()), id: \.offset) { _, s in
                let a = max(Int(s.start.timeIntervalSince(dayStart) / 60), w.start)
                let b = min(Int(s.end.timeIntervalSince(dayStart) / 60), w.end)
                if b > a {
                    let label = s.status == .oof ? "Away" : (s.status == .tentative ? "Tentative" : "Busy")
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(s.status == .tentative ? 0.10 : 0.22))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: s.status == .tentative ? [3, 2] : [])))
                        .overlay { if CGFloat(b - a) * ppm > 44 { Text(label).font(.caption2).foregroundStyle(.secondary) } }
                        .frame(width: max(CGFloat(b - a) * ppm - 2, 4), height: 22)
                        .offset(x: x(a, w, ppm) + 1, y: 11)
                        .help("\(t.name): \(label) \(Self.clock(a))–\(Self.clock(b))")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
    }

    private func nowLine(_ w: (start: Int, end: Int), _ ppm: CGFloat) -> some View {
        TimelineView(.everyMinute) { ctx in
            let m = Int(ctx.date.timeIntervalSince(dayStart) / 60)
            if Calendar.current.isDate(ctx.date, inSameDayAs: day), m >= w.start, m <= w.end {
                Rectangle().fill(model.theme.todayFill).frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .offset(x: x(m, w, ppm))
                    .allowsHitTesting(false)
            }
        }
    }

    static func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
    static func duration(_ m: Int) -> String { m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)") : "\(m) min" }
}

/// Horizontal event chip used by the schedule view; same policy, owner and meeting rules as grid blocks.
struct ScheduleChip: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent
    var tint: Color
    var width: CGFloat

    var body: some View {
        let p = model.policy(for: event)
        let t = model.theme
        let solid = t.fill == .solid && event.showAs != .tentative
        HStack(spacing: 4) {
            if let l = p.label, width > 40 { LabelGlyph(label: l) }
            if width > 28 {
                Text(p.redactDetails ? "Private" : event.subject)
                    .font(.system(size: 11, weight: t.titleWeight, design: t.design)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !p.redactDetails, event.onlineMeetingURL != nil, width > 70 {
                NSymbol("video.fill", size: 9, label: "Online meeting")
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(solid ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .eventSurface(t, tint: tint, selected: model.selectedEventId == event.id, tentative: event.showAs == .tentative)
        .overlay(alignment: .leading) {
            if t.leadingBar > 0 { Rectangle().fill(tint).frame(width: t.leadingBar) }
        }
        .clipShape(RoundedRectangle(cornerRadius: t.corner, style: .continuous))
        .help((p.redactDetails ? "Private appointment" : event.subject) + " · " +
              event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened))
        .meetingActions(event, p)
        .onTapGesture { model.selectedEventId = event.id }
    }
}
