import SwiftUI
import CalendarCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.persona == .assistant {
                principalsSection
                section("My Calendars", .own)
            } else {
                section("My Calendars", .own)
                teammatesSection
                section("Shared with Me", .shared)
                section("Delegate Access", .delegated)
            }
            AddedCalendarsSection()   // CALENDAR-HOOK: add by address / group
            Section("Sensitivity Labels") {
                if model.compliance.availableLabels().isEmpty {
                    NLabel(model.labelSyncIssue == nil ? "Policy not synced — labelled items locked"
                                                      : "Label policy unavailable for this account — labelled items locked",
                          systemImage: "lock.trianglebadge.exclamationmark", size: 10)
                        .help(model.labelSyncIssue ?? "")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.compliance.availableLabels()) { l in
                    HStack(spacing: 8) {
                        LabelGlyph(label: l)
                        Text(l.name)
                        Spacer()
                        if l.hasProtection { NSymbol("lock.fill", size: 10, label: "Protected").foregroundStyle(.secondary) }
                    }
                    .help(l.tooltip ?? l.name)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Picker("Mode", selection: Bindable(model).persona) {
                ForEach(AppModel.Persona.allCases) { p in Label(p.title, systemImage: p.symbol).tag(p) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .help("My Calendar: your time + teammates' availability. Assistant: everyone you look after, side by side.")
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: Assistant — the people I look after are the primary objects

    @ViewBuilder private var principalsSection: some View {
        if !model.principals.isEmpty {
            Section("People I Support") {
                ForEach(model.principals) { c in
                    calendarRow(c) {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in VStack(alignment: .leading, spacing: 1) {
                            let n = model.meetingsToday(c)
                            if let next = model.nextUp(c) {
                                Text("Next \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text(n == 0 ? "No meetings today" : "\(n) meeting\(n == 1 ? "" : "s") today · \(c.canEdit ? "can edit" : "view only")")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        } }
                    }
                }
            }
        }
    }

    // MARK: Personal — teammates by free/busy only

    @ViewBuilder private var teammatesSection: some View {
        Section("Teammates") {
            ForEach(model.teammates) { t in
                HStack(spacing: 10) {
                    TeammateBadge(teammate: t, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).lineLimit(1)
                        if let a = model.availabilityNow(t) {
                            HStack(spacing: 4) {
                                Circle().fill(a.busy ? Color.red : Color.green).frame(width: 6, height: 6)
                                Text(a.text)
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Availability loading…").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .help("\(t.address) — free/busy only (no meeting details)")
                .contextMenu { Button("Remove Teammate") { model.removeTeammate(t) } }
            }
            AddTeammateField()
        }
    }

    @ViewBuilder private func section(_ title: String, _ access: CalendarAccess) -> some View {
        let cals = model.calendars.filter { $0.access == access }
        if !cals.isEmpty {
            Section(title) {
                ForEach(cals) { c in calendarRow(c) { EmptyView() } }
            }
        }
    }

    private func calendarRow<Extra: View>(_ c: CalendarInfo, @ViewBuilder extra: () -> Extra) -> some View {
        let access = c.access
        return Button { model.toggle(c) } label: {
            HStack(spacing: 10) {
                let on = model.enabledCalendars.contains(c.id)
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(model.tint(c), lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(on ? model.tint(c) : .clear))
                    .overlay { if on { NSymbol("checkmark", size: 8).fontWeight(.heavy).foregroundStyle(.white) } }
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(access == .own ? c.name : c.ownerDisplay).lineLimit(1)
                    if access != .own && model.persona == .personal {
                        Text((c.name != c.ownerDisplay && c.name != "Calendar" ? c.name + " · " : "") + (c.canEdit ? "Can edit" : "View only"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    extra()
                }
                Spacer()
                if !c.canEdit { NSymbol("eye", size: 10, label: "View only").foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Colour") {
                ForEach(CalendarPalette.swatches, id: \.hex) { sw in
                    Button { model.setColor(sw.hex, for: c) } label: {
                        Label { Text(sw.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(hex: sw.hex)) }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                NSymbol(model.isFixtureMode ? "testtube.2" : "building.2", size: 10)
                Text(model.isFixtureMode ? "Fixture tenant (synthetic data)" : "Microsoft 365")
            }
            Text(String(format: "Week loaded from encrypted cache in %.1f ms · %d events", model.queryMillis, model.weekEvents.count))
            if model.conflictCount > 0 {
                Text("\(model.conflictCount) edit(s) superseded by organiser").foregroundStyle(.orange)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LabelGlyph: View {
    var label: SensitivityLabel
    var body: some View {
        NSymbol(label.hasProtection ? "lock.shield.fill" : "shield.lefthalf.filled", size: 10,
                label: label.name + (label.hasProtection ? ", protected" : ""))
            .foregroundStyle(Color(hex: label.hexColor, fallback: .gray))
    }
}

struct TeammateBadge: View {
    var teammate: Teammate
    var size: CGFloat
    var body: some View {
        let initials = teammate.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials)
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Circle().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
    }
}

struct AddTeammateField: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TextField("Add teammate (email)", text: Bindable(model).teammateDraft)
            .textFieldStyle(.roundedBorder).font(.caption)
            .onSubmit { model.addTeammate(model.teammateDraft); model.teammateDraft = "" }
    }
}
