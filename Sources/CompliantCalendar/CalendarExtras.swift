import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CalendarCore

// CALENDAR: added calendars (by address, Microsoft 365 groups) — invite responses live in InviteResponse.swift /
// ReaderActions2.swift (reader agent) — room finder, categories, .ics import, secondary time zone. State lives here (no @State: macros don't compile
// under CLT); AppModel only exposes its store / engine / service (`extrasStore`, `extrasSync`, `aiCalendarService`).
// Views: CalendarExtrasViews.swift, CalendarEditorExtras.swift. Wired in by `// CALENDAR-HOOK` lines.

@MainActor @Observable
final class CalendarExtras {
    static let shared = CalendarExtras()

    // MARK: Added calendars
    enum AddTab: String, CaseIterable, Identifiable { case person = "Person or mailbox", group = "Group"; var id: String { rawValue } }
    private(set) var sources: [CalendarSource] = []
    var showAddCalendar = false
    var addTab: AddTab = .person
    var addressDraft = ""
    private(set) var addError: String?
    private(set) var adding = false
    private(set) var groups: [GroupRef] = []
    private(set) var groupsError: CalendarSourceError?
    private(set) var loadingGroups = false

    func loadSources(_ app: AppModel) { sources = app.extrasStore?.calendarSources() ?? [] }

    func beginAdd(_ app: AppModel) {
        loadSources(app)
        addError = nil; addressDraft = ""; showAddCalendar = true
        if addTab == .group { loadGroups(app) }
    }

    func addPerson(_ app: AppModel) {
        guard let addr = CalendarSources.address(from: addressDraft) else { addError = "Enter an email address, e.g. name@company.com."; return }
        add(.user(address: addr), app)
    }

    func addGroup(_ g: GroupRef, _ app: AppModel) { add(.group(id: g.id, name: g.name, mail: g.mail), app) }

    /// Validate first (403 and 404 are different messages), then persist sealed and resync.
    private func add(_ source: CalendarSource, _ app: AppModel) {
        guard let service = app.aiCalendarService, let store = app.extrasStore else { return }
        if sources.contains(where: { $0.id == source.id }) { addError = "That calendar is already added."; return }
        adding = true; addError = nil
        Task {
            defer { adding = false }
            do {
                let found = try await service.probe(source: source)
                guard !found.isEmpty else { addError = CalendarSourceError.notFound.message; return }
                sources = CalendarSources.adding(source, to: sources)
                try store.setCalendarSources(sources)
                service.setSources(sources)
                showAddCalendar = false; addressDraft = ""
                await app.syncNow()
            } catch {
                addError = CalendarSourceError(error).message
            }
        }
    }

    func remove(_ source: CalendarSource, _ app: AppModel) {
        guard let service = app.aiCalendarService, let store = app.extrasStore else { return }
        sources.removeAll { $0.id == source.id }
        try? store.setCalendarSources(sources)
        service.setSources(sources)
        Task { await app.syncNow() }   // the engine drops the calendar and its cached events
    }

    /// Why an added calendar isn't showing (last sync), or nil.
    func problem(_ source: CalendarSource, _ app: AppModel) -> String? {
        app.aiCalendarService?.sourceProblems[source.id]?.message
    }

    func loadGroups(_ app: AppModel) {
        guard let service = app.aiCalendarService, !loadingGroups else { return }
        loadingGroups = true; groupsError = nil
        Task {
            defer { loadingGroups = false }
            do { groups = try await service.myGroups() } catch { groupsError = CalendarSourceError(error) }
        }
    }

    /// Interactive consent for an optional scope set (groups, places), then retry.
    func grant(_ scopes: [String], _ app: AppModel, then: @escaping @MainActor () -> Void) {
        guard let auth = app.auth else { return }
        Task {
            do { try await auth.grantAccess(scopes: scopes); then() }
            catch { addError = "Access wasn’t granted." }
        }
    }

    // MARK: Categories (master list; colours only, never stored on disk)
    private(set) var categories: [OutlookCategory] = []
    private var categoriesLoaded = false
    func loadCategories(_ app: AppModel) {
        guard !categoriesLoaded, let service = app.aiCalendarService else { return }
        categoriesLoaded = true
        Task { categories = (try? await service.masterCategories()) ?? [] }
    }

    // MARK: Rooms
    var showRooms = false
    private(set) var roomLists: [RoomList] = []
    private(set) var rooms: [Room] = []
    var roomList: String? = nil
    private(set) var roomBusy: [String: Bool] = [:]
    private(set) var roomsError: String?
    private(set) var loadingRooms = false

    func openRooms(_ app: AppModel) {
        showRooms = true; roomsError = nil
        guard let service = app.aiCalendarService else { return }
        loadingRooms = true
        Task {
            defer { loadingRooms = false }
            do {
                roomLists = try await service.roomLists()
                if roomList == nil { roomList = roomLists.first?.emailAddress }
                try await loadRooms(service, app)
            } catch { roomsError = Self.placesMessage(error) }
        }
    }

    func selectList(_ list: String?, _ app: AppModel) {
        roomList = list
        guard let service = app.aiCalendarService else { return }
        Task { do { try await loadRooms(service, app) } catch { roomsError = Self.placesMessage(error) } }
    }

    private func loadRooms(_ service: any CalendarService, _ app: AppModel) async throws {
        rooms = try await service.rooms(inList: roomList)
        let d = app.editorDraft
        let window = DateInterval(start: d.start, end: max(d.end, d.start.addingTimeInterval(60)))
        let fb = (try? await service.freeBusy(for: rooms.map(\.emailAddress), window: window)) ?? [:]
        var busy: [String: Bool] = [:]
        for r in rooms { busy[r.id] = (fb[r.id] ?? []).contains { $0.status != .free && $0.start < d.end && $0.end > d.start } }
        roomBusy = busy
    }

    private static func placesMessage(_ e: Error) -> String {
        switch CalendarSourceError(e) {
        case .noAccess, .needsConsent: "The room directory needs access (Place.Read.All). Grant access and try again."
        case .offline: "You’re offline."
        default: "Rooms couldn’t be loaded. Your organisation may not have room lists set up."
        }
    }

    /// Room → location + resource attendee (Exchange books it and the room answers). Replaces a room picked before.
    func pick(_ r: Room, _ app: AppModel) {
        var d = app.editorDraft
        if !d.locationEmail.isEmpty { d.attendees.removeAll { $0.isResource && $0.address.lowercased() == d.locationEmail.lowercased() } }
        d.location = r.name; d.locationEmail = r.emailAddress
        if !d.attendees.contains(where: { $0.address.lowercased() == r.id }) {
            d.attendees.append(Attendee(name: r.name, address: r.emailAddress, response: "none", type: "resource"))
        }
        app.editorDraft = d
        showRooms = false
        app.refreshEditorFreeBusy()
    }

    // MARK: .ics import
    var showImport = false
    private(set) var importEvents: [ICSEvent] = []
    var importCalendarId = ""
    private(set) var importFileName = ""
    private(set) var importError: String?

    func openICSPanel(_ app: AppModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
        p.allowsMultipleSelection = false
        p.message = "Choose a calendar file (.ics) to import"
        if p.runModal() == .OK, let url = p.url { load(url, app) }
    }

    /// Parsed in memory; nothing is stored until the user confirms (then the normal write path / outbox).
    func load(_ url: URL, _ app: AppModel) {
        importError = nil
        importFileName = url.lastPathComponent
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 5_000_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            importEvents = []; importError = "That file couldn’t be read."; showImport = true; return
        }
        importEvents = ICSParser.parse(text)
        if importEvents.isEmpty { importError = "No events found in that file." }
        importCalendarId = app.defaultWriteCalendar?.id ?? app.writableCalendars.first?.id ?? ""
        showImport = true
    }

    func confirmImport(_ app: AppModel) {
        guard let sync = app.extrasSync, !importCalendarId.isEmpty else { return }
        let drafts = importEvents.prefix(200).map { $0.draft(calendarId: importCalendarId) }
        showImport = false
        app.wlog("ics import \(drafts.count) into \(importCalendarId)")
        Task {
            var firstId: String?
            for d in drafts { if let id = try? await sync.create(d), firstId == nil { firstId = id } }
            if let firstId { app.selectedEventId = firstId }
            await app.refreshAfterExtras()
        }
        importEvents = []
    }

    // MARK: Secondary time zone (view preference, not sensitive → UserDefaults like the other view settings)
    var secondZoneId: String? = UserDefaults.standard.string(forKey: "secondaryTimeZone") {
        didSet { UserDefaults.standard.set(secondZoneId, forKey: "secondaryTimeZone") }
    }
    var secondZone: TimeZone? { secondZoneId.flatMap(TimeZone.init(identifier:)) }
}

// MARK: - Content switch (grid / schedule / month / agenda)

struct CalendarContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            switch model.viewMode {
            case .grid: WeekView()
            case .schedule: ScheduleView()
            case .month: MonthView()
            case .agenda: AgendaView()
            }
        }
        .task(id: model.mode == .live || model.mode == .fixtures) {
            CalendarExtras.shared.loadSources(model); CalendarExtras.shared.loadCategories(model)
        }
        // Drop an .ics on the calendar → preview → import.
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ics" }) else { return false }
            CalendarExtras.shared.load(u, model); return true
        }
    }
}

/// Sheets/alerts for the extras, attached to both calendar shells.
struct CalendarExtrasSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        let x = CalendarExtras.shared
        content
            .sheet(isPresented: Bindable(x).showAddCalendar) { AddCalendarSheet() }
            .sheet(isPresented: Bindable(x).showImport) { ICSImportSheet() }
    }
}

// MARK: - Menu commands

struct CalendarExtrasCommands: View {
    var model: AppModel
    var body: some View {
        let x = CalendarExtras.shared
        Button("Add Calendar…") { model.section = .calendar; x.beginAdd(model) }
        Button("Import Calendar File (.ics)…") { model.section = .calendar; x.openICSPanel(model) }
            .disabled(model.writableCalendars.isEmpty)
    }
}

struct SecondZoneMenu: View {
    var body: some View {
        let x = CalendarExtras.shared
        let ids = SecondaryZone.common + (x.secondZoneId.map { SecondaryZone.common.contains($0) ? [] : [$0] } ?? [])
        Picker("Second Time Zone", selection: Binding(get: { x.secondZoneId ?? "" }, set: { x.secondZoneId = $0.isEmpty ? nil : $0 })) {
            Text("None").tag("")
            ForEach(ids, id: \.self) { id in
                Text("\(id.replacingOccurrences(of: "_", with: " ")) (\(TimeZone(identifier: id).map { SecondaryZone.shortName($0) } ?? ""))").tag(id)
            }
        }
    }
}
