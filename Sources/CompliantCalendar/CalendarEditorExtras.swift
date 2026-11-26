import SwiftUI
import CalendarCore

// CALENDAR: event editor rows (categories, room finder) and the .ics import preview (model: CalendarExtras.swift).

struct EditorCategoryRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let x = CalendarExtras.shared
        let chosen = model.editorDraft.categories
        let known = x.categories.map(\.name)
        let all = known + chosen.filter { c in !known.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }
        LabeledContent("Categories") {
            Menu {
                if all.isEmpty { Text("No categories in your Outlook list") }
                ForEach(all, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { chosen.contains { $0.caseInsensitiveCompare(name) == .orderedSame } },
                        set: { on in
                            var c = model.editorDraft.categories.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
                            if on { c.append(name) }
                            model.editorDraft.categories = c
                        }))
                }
            } label: {
                Text(chosen.isEmpty ? "None" : chosen.joined(separator: ", ")).lineLimit(1)
            }
            .fixedSize()
        }
        .task { x.loadCategories(model) }
    }
}

struct EditorRoomRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let x = CalendarExtras.shared
        LabeledContent("Room") {
            HStack {
                if !model.editorDraft.locationEmail.isEmpty { Text(model.editorDraft.location).lineLimit(1) }
                Button(model.editorDraft.locationEmail.isEmpty ? "Find a Room…" : "Change…") { x.openRooms(model) }
            }
        }
        .sheet(isPresented: Bindable(x).showRooms) { RoomFinderSheet() }
    }
}

struct RoomFinderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var body: some View {
        let x = CalendarExtras.shared
        let d = model.editorDraft
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a room").font(skin.sans(NV.Size.title)).foregroundStyle(skin.ink)
            MonoLabel("\(d.start.formatted(date: .abbreviated, time: .shortened)) – \(d.end.formatted(date: .omitted, time: .shortened))", size: NV.Size.labelSm)
            if !x.roomLists.isEmpty {
                Picker("Building / list", selection: Binding(get: { x.roomList ?? "" }, set: { x.selectList($0.isEmpty ? nil : $0, model) })) {
                    Text("All rooms").tag("")
                    ForEach(x.roomLists) { l in Text(l.name).tag(l.emailAddress) }
                }
            }
            if x.loadingRooms { ProgressView().controlSize(.small) }
            if let e = x.roomsError {
                Text(e).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.danger).fixedSize(horizontal: false, vertical: true)
                NButton("Grant access…", kind: .ghost) { x.grant(Auth.placeScopes, model) { x.openRooms(model) } }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(x.rooms) { r in roomRow(r, busy: x.roomBusy[r.id]) { x.pick(r, model) } }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            Text("The room is invited as a resource and set as the location; Exchange books it and the room answers.")
                .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Cancel") { x.showRooms = false }.modifier(BrandButton()).keyboardShortcut(.cancelAction) }
        }
        .padding(22)
        .frame(width: 420)
        .background(skin.brand ? skin.card : .clear)
    }

    private func roomRow(_ r: Room, busy: Bool?, pick: @escaping () -> Void) -> some View {
        let detail = [r.capacity.map { "\($0) seats" }, r.building, r.floor.map { "Floor \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return Button(action: pick) {
            HStack(spacing: 10) {
                NSymbol("building.2", size: 12).foregroundStyle(skin.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink)
                    if !detail.isEmpty { MonoLabel(detail, size: NV.Size.labelSm) }
                }
                Spacer()
                if let busy {
                    NLabel(busy ? "Busy" : "Free", systemImage: busy ? "xmark.circle" : "checkmark.circle", size: 10)
                        .font(.caption).foregroundStyle(busy ? .orange : .green)
                }
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(r.name + (busy == true ? ", busy" : busy == false ? ", free" : ""))
    }
}

struct ICSImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    var body: some View {
        let x = CalendarExtras.shared
        @Bindable var b = x
        let count = min(x.importEvents.count, 200)
        let invited = x.importEvents.reduce(0) { $0 + $1.attendeeCount }
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(x.importFileName)").font(skin.sans(NV.Size.title)).foregroundStyle(skin.ink).lineLimit(1)
            if let e = x.importError { Text(e).font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.danger) }
            if !x.importEvents.isEmpty {
                Picker("Into", selection: $b.importCalendarId) {
                    ForEach(model.writableCalendars) { c in Text("\(c.ownerDisplay) · \(c.name)").tag(c.id) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(x.importEvents.prefix(200).enumerated()), id: \.offset) { _, e in row(e) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 300)
                Text("Created as new events through the normal sync queue."
                     + (invited > 0 ? " Attendees in the file aren’t added, so nobody is sent an invitation." : "")
                     + (x.importEvents.count > 200 ? " Only the first 200 events are imported." : ""))
                    .font(skin.sans(NV.Size.bodySm)).foregroundStyle(skin.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { x.showImport = false }.modifier(BrandButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(count == 1 ? "Import Event" : "Import \(count) Events") { x.confirmImport(model) }
                    .modifier(BrandButton(kind: .primary, prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(x.importEvents.isEmpty || x.importCalendarId.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(skin.brand ? skin.card : .clear)
    }

    private func row(_ e: ICSEvent) -> some View {
        let when = e.isAllDay ? e.start.formatted(date: .abbreviated, time: .omitted) + " · all day"
            : "\(e.start.formatted(date: .abbreviated, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))"
        return VStack(alignment: .leading, spacing: 1) {
            Text(e.summary.isEmpty ? "Imported event" : e.summary).font(skin.sans(NV.Size.body, .medium)).foregroundStyle(skin.ink)
            MonoLabel(when, size: NV.Size.labelSm)
            if e.recurrenceDropped { MonoLabel("Repeats — only the first occurrence is imported", size: NV.Size.labelSm, color: .orange) }
            else if e.repeats != .never { MonoLabel("Repeats: \(e.repeats.title)", size: NV.Size.labelSm) }
            if let z = e.unknownZone { MonoLabel("Time zone “\(z)” not recognised — read as this Mac’s time", size: NV.Size.labelSm, color: .orange) }
        }
    }
}
