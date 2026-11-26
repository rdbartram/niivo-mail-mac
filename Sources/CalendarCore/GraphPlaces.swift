import Foundation

/// A bookable room (Graph `room` place). Free/busy comes from `getSchedule` on `emailAddress`.
public struct Room: Codable, Sendable, Hashable, Identifiable {
    public var id: String { emailAddress.lowercased() }
    public var name: String
    public var emailAddress: String
    public var capacity: Int?
    public var building: String?
    public var floor: String?
    public init(name: String, emailAddress: String, capacity: Int? = nil, building: String? = nil, floor: String? = nil) {
        self.name = name; self.emailAddress = emailAddress; self.capacity = capacity; self.building = building; self.floor = floor
    }
}

public struct RoomList: Codable, Sendable, Hashable, Identifiable {
    public var id: String { emailAddress.lowercased() }
    public var name: String
    public var emailAddress: String
    public init(name: String, emailAddress: String) { self.name = name; self.emailAddress = emailAddress }
}

/// One entry of the user's Outlook master category list.
public struct OutlookCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    public var name: String
    /// `preset0`…`preset24` or `none`.
    public var preset: String
    public init(name: String, preset: String) { self.name = name; self.preset = preset }
    public var hex: String? { OutlookCategory.hex(preset: preset) }

    /// Outlook's 25 category presets (names per Graph `categoryColor`), approximate hex.
    public static func hex(preset: String) -> String? {
        let table = ["#E7484F", "#F68D3B", "#AB7B57", "#F2C631", "#5CB85C", "#3FB1B0", "#8E9A5E", "#4A90E2",
                     "#A365C9", "#E5457B", "#7A8C9E", "#4E5D6C", "#A6A6A6", "#666666", "#1F1F1F", "#A4262C",
                     "#CA5010", "#8E562E", "#C19C00", "#0B6A0B", "#038387", "#5C6B32", "#004E8C", "#5C2E91", "#8B1A50"]
        guard preset.hasPrefix("preset"), let i = Int(preset.dropFirst(6)), table.indices.contains(i) else { return nil }
        return table[i]
    }

    /// Category names are matched case-insensitively (Outlook does).
    public static func lookup(_ name: String, in list: [OutlookCategory]) -> OutlookCategory? {
        list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public extension CalendarService {
    func roomLists() async throws -> [RoomList] { [] }
    func rooms(inList listAddress: String?) async throws -> [Room] { [] }
    func masterCategories() async throws -> [OutlookCategory] { [] }
}

extension GraphCalendarService {
    private struct GPlace: Decodable {
        var displayName: String?; var emailAddress: String?; var capacity: Int?; var building: String?; var floorLabel: String?
    }

    /// `GET /places/microsoft.graph.roomlist` (Place.Read.All). Needs the tenant's Places set-up (Learn prerequisites);
    /// an empty list is a normal answer.
    public func roomLists() async throws -> [RoomList] {
        let page: GPage<GPlace> = try await get(base.appending(path: "places/microsoft.graph.roomlist").with(query: ["$top": "100"]))
        return page.value.compactMap { p in p.emailAddress.map { RoomList(name: p.displayName ?? $0, emailAddress: $0) } }
    }

    /// Rooms in a list (`GET /places/{list-email}/microsoft.graph.roomlist/rooms`, by email, not id: Learn), or every
    /// room (`GET /places/microsoft.graph.room`) when `listAddress` is nil. Follows nextLink up to 500 rooms.
    public func rooms(inList listAddress: String?) async throws -> [Room] {
        var next = (listAddress.map { base.appending(path: "places/\($0)/microsoft.graph.roomlist/rooms") }
                    ?? base.appending(path: "places/microsoft.graph.room")).with(query: ["$top": "100"])
        var out: [Room] = []
        while out.count < 500 {
            let page: GPage<GPlace> = try await get(next)
            out += page.value.compactMap { p in
                p.emailAddress.map { Room(name: p.displayName ?? $0, emailAddress: $0, capacity: p.capacity,
                                          building: p.building, floor: p.floorLabel) }
            }
            guard let n = page.nextLink, let u = URL(string: n) else { break }
            next = u
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `GET /me/outlook/masterCategories` (MailboxSettings.Read: the mail scope set's MailboxSettings.ReadWrite).
    /// Only the signed-in user's list: a delegate's/shared calendar's categories show by name with a neutral colour.
    public func masterCategories() async throws -> [OutlookCategory] {
        struct C: Decodable { var displayName: String; var color: String? }
        let page: GPage<C> = try await get(base.appending(path: "me/outlook/masterCategories"))
        return page.value.map { OutlookCategory(name: $0.displayName, preset: $0.color ?? "none") }
    }
}
