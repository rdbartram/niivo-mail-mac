import SwiftUI
import CalendarCore

/// New / edit event sheet. What it can change follows the same rules as the grid (organiser, write access,
/// policy), and it says out loud when saving will email people or act on someone else's behalf.
struct EventEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin

    var body: some View {
        @Bindable var m = model
        let isNew = model.editorOriginal == nil
        let cal = model.calendars.first { $0.id == model.editorDraft.calendarId }
        let policy = model.editorOriginal.map { model.policy(for: $0) }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let cal { OwnerBadge(calendar: cal, tint: model.tint(cal), size: 28) }
                VStack(alignment: .leading, spacing: 1) {
                    if skin.brand {
                        MonoLabel(cal.map { "\($0.ownerDisplay) · \($0.name)" } ?? "Calendar", bracket: true)
                        Text(isNew ? "New event." : "Edit event.").font(skin.sans(NV.Size.title)).tracking(skin.titleTrack(NV.Size.title))
                    } else {
                        Text(isNew ? "New Event" : "Edit Event").font(.title3.weight(.semibold))
                        if let cal { Text("\(cal.ownerDisplay) · \(cal.name)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 12)

            Form {
                if let o = model.editorOriginal, o.seriesMasterId != nil {
                    Picker("Change", selection: $m.editorScope) {
                        Text("This occurrence").tag(AppModel.SeriesScope.occurrence)
                        Text("All occurrences").tag(AppModel.SeriesScope.series)
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Title", text: $m.editorDraft.subject, prompt: Text("Title"))
                    .font(.title3)
                if isNew {
                    Picker("Calendar", selection: $m.editorDraft.calendarId) {
                        ForEach(model.writableCalendars) { c in Text("\(c.ownerDisplay) · \(c.name)").tag(c.id) }
                    }
                }
                Toggle("All day", isOn: $m.editorDraft.isAllDay)
                DatePicker("Starts", selection: $m.editorDraft.start,
                           displayedComponents: model.editorDraft.isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $m.editorDraft.end, in: model.editorDraft.start...,
                           displayedComponents: model.editorDraft.isAllDay ? [.date] : [.date, .hourAndMinute])
                if isNew {
                    Picker("Repeat", selection: $m.editorDraft.repeats) {
                        ForEach(EventDraft.Repeat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                TextField("Location", text: $m.editorDraft.location)
                if isNew || !(model.editorOriginal?.onlineMeetingURL != nil) {
                    Toggle("Teams meeting", isOn: $m.editorDraft.isOnlineMeeting)
                } else {
                    LabeledContent("Online meeting") { Text("Join link kept").foregroundStyle(.secondary) }
                }
                Picker("Show as", selection: $m.editorDraft.showAs) {
                    Text("Busy").tag(ShowAs.busy); Text("Tentative").tag(ShowAs.tentative)
                    Text("Free").tag(ShowAs.free); Text("Out of office").tag(ShowAs.oof)
                    Text("Working elsewhere").tag(ShowAs.workingElsewhere)
                }
                EditorRoomRow()       // CALENDAR-HOOK: room finder
                EditorCategoryRow()   // CALENDAR-HOOK: categories
                Toggle("Private", isOn: $m.editorDraft.isPrivate)
                    .help("Hidden from delegates and people you share your calendar with")

                Section {
                    ForEach(model.editorDraft.attendees, id: \.address) { a in
                        let busy = model.editorConflicts.contains(a.address)
                        let known = model.editorFreeBusy[a.address] != nil
                        HStack {
                            NSymbol("person.crop.circle", size: 13).foregroundStyle(.secondary)
                            Text(a.name.isEmpty ? a.address : "\(a.name) <\(a.address)>").lineLimit(1)
                            Spacer()
                            if known {
                                NLabel(busy ? "Busy" : "Free", systemImage: busy ? "exclamationmark.circle.fill" : "checkmark.circle", size: 10)
                                    .font(.caption).foregroundStyle(busy ? .orange : .green)
                            }
                            Button { model.editorDraft.attendees.removeAll { $0.address == a.address } } label: {
                                NSymbol("minus.circle", size: 13, label: "Remove attendee")
                            }.buttonStyle(.borderless)
                        }
                    }
                    TextField("Add attendee (email)", text: $m.attendeeDraft)
                        .onSubmit { model.addAttendee() }
                    FindTimeSection()   // ORG2-HOOK: Find a time (FindTime.swift)
                    if !model.editorFreeBusy.isEmpty {
                        AvailabilityStrip(day: model.editorDraft.start, start: model.editorDraft.start, end: model.editorDraft.end,
                                          rows: model.editorDraft.attendees.map { a in (a.name.isEmpty ? a.address : a.name, model.editorFreeBusy[a.address] ?? []) })
                    }
                } header: {
                    Text("Attendees")
                } footer: {
                    if !model.editorFreeBusy.isEmpty {
                        Text("Free/busy only — subjects are never fetched. Not stored on this Mac.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if isNew {
                    Section("Notes") { TextEditor(text: $m.editorDraft.notes).frame(minHeight: 60) }
                } else if let o = model.editorOriginal, let p = o.bodyPreview, !p.isEmpty {
                    Section("Notes") {
                        Text(p).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        Text("Notes keep their formatting and join links; edit them in Outlook.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(skin.brand ? .hidden : .automatic)
            .modifier(BrandToggles())
            .onChange(of: model.editorDraft.start) { model.refreshEditorFreeBusy() }

            notices(cal: cal, policy: policy, isNew: isNew)

            HStack {
                Button("Cancel", role: .cancel) { model.showEditor = false }
                    .modifier(BrandButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.editorSendsMail ? (isNew ? "Send" : "Send Update") : "Save") { model.saveEditor() }
                    .modifier(BrandButton(kind: .primary, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.editorDraft.subject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 680)
        .background(skin.brand ? skin.card : .clear)
    }

    @ViewBuilder private func notices(cal: CalendarInfo?, policy: ContentPolicy?, isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cal, cal.access != .own, !model.editorDraft.attendees.isEmpty {
                notice("paperplane", "Invitations go out on behalf of \(cal.ownerDisplay).")
            } else if model.editorSendsMail {
                notice("paperplane", isNew ? "Attendees will get an invitation." : "Attendees will get an update.")
            }
            if let l = policy?.label {
                notice("shield.lefthalf.filled", "Sensitivity label “\(l.name)” is kept. Changing labels needs the Purview SDK.")
            } else if isNew && !model.compliance.availableLabels().isEmpty {
                PurviewMeetingLabelRow()   // PURVIEW-HOOK: label for a new meeting (default from the policy)
            }
            if model.editorScope == .series {
                notice("repeat", "Changes every occurrence. Times shift by the same amount; moving the series to another day is done in Outlook.")
            }
            if policy?.bodyIsProtected == true { notice("lock.shield", "Encrypted content stays as it is; only time and place change here.") }
        }
        .padding(.horizontal, 20)
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        NLabel(text, systemImage: icon, size: skin.brand ? NV.Size.bodySm : 10).font(skin.brand ? skin.sans(NV.Size.bodySm) : .caption).foregroundStyle(.secondary)
    }
}

/// Delete / Cancel meeting / Decline — Exchange does three different things, the sheet says which.
struct RemoveSheet: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent

    var body: some View {
        @Bindable var m = model
        let mode = model.removeMode(for: event)
        let cal = model.calendar(for: event)
        let p = model.policy(for: event)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                NSymbol(mode == .delete ? "trash" : (mode == .cancel ? "calendar.badge.minus" : "xmark.circle"), size: 17)
                    .foregroundStyle(.red)
                Text(mode == .delete ? "Delete event?" : (mode == .cancel ? "Cancel meeting?" : "Decline meeting?"))
                    .font(.title3.weight(.semibold))
            }
            Text(p.redactDetails ? "Private appointment" : event.subject).font(.headline)
            if event.seriesMasterId != nil {
                Picker("", selection: $m.removalScope) {
                    Text("This occurrence").tag(AppModel.SeriesScope.occurrence)
                    Text("Whole series").tag(AppModel.SeriesScope.series)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Text(explanation(mode, cal) + (model.removalScope == .series && event.seriesMasterId != nil ? " This applies to every occurrence." : ""))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if mode != .delete {
                TextField(mode == .cancel ? "Message to attendees (optional)" : "Message to the organiser (optional)",
                          text: $m.removalComment, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Keep") { model.removal = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode == .delete ? "Delete" : (mode == .cancel ? "Send Cancellation" : "Decline"), role: .destructive) {
                    model.confirmRemove()
                }
                .buttonStyle(.borderedProminent).tint(.red).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func explanation(_ mode: RemoveMode, _ cal: CalendarInfo?) -> String {
        let onBehalf = cal.map { $0.access == .own ? "" : " on behalf of \($0.ownerDisplay)" } ?? ""
        switch mode {
        case .delete: return "It will be removed from \(cal?.ownerDisplay == "You" ? "your" : "\(cal?.ownerDisplay ?? "the")’s") calendar. Nobody is notified."
        case .cancel: return "All \(event.attendees.count) attendees get a cancellation\(onBehalf), and it’s removed from every calendar."
        case .decline: return "The organiser (\(event.organizer ?? "unknown")) is told you declined\(onBehalf), and it’s removed from this calendar."
        }
    }
}

/// Outlook-style mini scheduling assistant: 07–19 h, each attendee's busy blocks, the drafted slot outlined.
struct AvailabilityStrip: View {
    var day: Date, start: Date, end: Date
    var rows: [(String, [FreeBusySlot])]
    private let from = 7, to = 19

    var body: some View {
        let c = Calendar.current
        let d0 = c.date(bySettingHour: from, minute: 0, second: 0, of: day)!
        let span = Double((to - from) * 3600)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.0).font(.caption2).lineLimit(1).frame(width: 80, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.5))
                            ForEach(Array(row.1.enumerated()), id: \.offset) { _, s in
                                let x0 = max(0, s.start.timeIntervalSince(d0) / span), x1 = min(1, s.end.timeIntervalSince(d0) / span)
                                if x1 > x0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(s.status == .tentative ? Color.blue.opacity(0.35) : (s.status == .oof ? Color.purple.opacity(0.6) : Color.blue.opacity(0.7)))
                                        .frame(width: g.size.width * (x1 - x0)).offset(x: g.size.width * x0)
                                }
                            }
                            let a = max(0, start.timeIntervalSince(d0) / span), b = min(1, end.timeIntervalSince(d0) / span)
                            if b > a {
                                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: max(g.size.width * (b - a), 2)).offset(x: g.size.width * a)
                            }
                        }
                    }
                    .frame(height: 12)
                }
            }
            HStack {
                Spacer().frame(width: 86)
                Text("\(from):00").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("13:00").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(to):00").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
