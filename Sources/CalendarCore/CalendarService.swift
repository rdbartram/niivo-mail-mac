import Foundation

/// Result of one sync pass for one calendar.
public struct SyncBatch: Sendable {
    public enum Mode: Sendable {
        /// Incremental: apply `upserts` and `removedIds` on top of the cache.
        case delta
        /// Snapshot of the whole window: replace everything this calendar has in the store.
        case replaceWindow
    }
    public var mode: Mode
    public var upserts: [CalendarEvent]
    public var removedIds: [String]
    /// Persist and pass back next time. nil for snapshot mode.
    public var deltaLink: String?

    public init(mode: Mode, upserts: [CalendarEvent], removedIds: [String] = [], deltaLink: String? = nil) {
        self.mode = mode; self.upserts = upserts; self.removedIds = removedIds; self.deltaLink = deltaLink
    }
}

public enum ServiceError: Error, Equatable {
    /// 410 Gone / syncStateNotFound — the delta token is dead, start a full round.
    case syncStateInvalid
    /// 412 — server copy changed since our edit was based on it.
    case conflict
    case offline
    case unauthorized
    case http(Int, String)
}

/// A colleague whose availability we show without having access to their calendar (Graph getSchedule).
public struct Teammate: Codable, Sendable, Hashable, Identifiable {
    public var id: String { address.lowercased() }
    public var name: String
    public var address: String
    public init(name: String, address: String) { self.name = name; self.address = address }
}

/// Busy block from free/busy. Deliberately has no subject, location or attendees: those are never requested,
/// and free/busy is never written to disk.
public struct FreeBusySlot: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var status: ShowAs
    public init(start: Date, end: Date, status: ShowAs) { self.start = start; self.end = end; self.status = status }
}

/// Everything the app needs from Microsoft 365. Graph and fixture implementations conform.
public protocol CalendarService: Sendable {
    func listCalendars() async throws -> [CalendarInfo]
    func sync(calendar: CalendarInfo, window: DateInterval, deltaLink: String?) async throws -> SyncBatch
    /// Purview label definitions published to the signed-in user.
    func sensitivityLabels() async throws -> [SensitivityLabel]
    /// PATCH an event. Returns the server's copy (new changeKey).
    func update(calendar: CalendarInfo, eventId: String, patch: Data, ifMatch: String?) async throws -> CalendarEvent
    /// Free/busy for people we have no calendar access to, keyed by lower-cased address.
    func freeBusy(for addresses: [String], window: DateInterval) async throws -> [String: [FreeBusySlot]]
    /// POST a new event into `calendar`. Returns the server copy (real id, changeKey).
    func create(calendar: CalendarInfo, body: Data) async throws -> CalendarEvent
    /// GET one event (used for a recurring series' master, which the calendar view never returns).
    func fetch(calendar: CalendarInfo, eventId: String) async throws -> CalendarEvent
    /// Delete, cancel (organiser, notifies attendees) or decline (attendee).
    func remove(calendar: CalendarInfo, eventId: String, mode: RemoveMode, comment: String?, ifMatch: String?) async throws

    // Added calendars (CalendarSources.swift). Defaults: none.
    func setSources(_ s: [CalendarSource])
    /// Last listCalendars problem per source id (403 vs 404 kept apart). Empty = all fine.
    var sourceProblems: [String: CalendarSourceError] { get }
    /// Validate a source before saving it (Add calendar…). Throws CalendarSourceError.
    func probe(source: CalendarSource) async throws -> [CalendarInfo]
    func myGroups() async throws -> [GroupRef]
    // Room finder + categories (GraphPlaces.swift).
    func roomLists() async throws -> [RoomList]
    func rooms(inList listAddress: String?) async throws -> [Room]
    func masterCategories() async throws -> [OutlookCategory]
}

public extension CalendarService {
    func create(calendar: CalendarInfo, body: Data) async throws -> CalendarEvent { throw ServiceError.http(501, "create not supported") }
    func fetch(calendar: CalendarInfo, eventId: String) async throws -> CalendarEvent { throw ServiceError.http(501, "fetch not supported") }
    func remove(calendar: CalendarInfo, eventId: String, mode: RemoveMode, comment: String?, ifMatch: String?) async throws {
        throw ServiceError.http(501, "remove not supported")
    }
    func freeBusy(for addresses: [String], window: DateInterval) async throws -> [String: [FreeBusySlot]] { [:] }
    func setSources(_ s: [CalendarSource]) {}
    var sourceProblems: [String: CalendarSourceError] { [:] }
    func probe(source: CalendarSource) async throws -> [CalendarInfo] { throw CalendarSourceError.other("not supported") }
    func myGroups() async throws -> [GroupRef] { [] }
}
