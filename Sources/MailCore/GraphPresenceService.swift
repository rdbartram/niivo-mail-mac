import Foundation

// MARK: - Teams presence for visible people
//
// Checked on learn.microsoft.com (2026-11-20):
//  * `POST /communications/getPresencesByUserId` {"ids":[…]}: delegated Presence.Read.All; "Maximum of 650 user IDs
//    are supported per API request"; "1500 API requests in a 30 second period, per application per tenant".
//  * ids are directory object ids, so addresses are resolved first (`PeopleService.directoryIds`, User.ReadBasic.All),
//    for INTERNAL people only (external senders never cause a directory call). Misses are negative-cached.
// UNVERIFIED against a tenant: presence for guests / users without Teams (expected `PresenceUnknown`).
//
// Memory only. Presence is passive UI: tokens are silent; a token or 401/403 failure switches dots off until the user
// grants explicitly (the hub owns that switch).

public struct PresenceInfo: Sendable, Hashable {
    public enum Availability: String, Sendable, Hashable {
        case available = "Available", availableIdle = "AvailableIdle", away = "Away", beRightBack = "BeRightBack"
        case busy = "Busy", busyIdle = "BusyIdle", doNotDisturb = "DoNotDisturb", offline = "Offline"
        case unknown = "PresenceUnknown"
    }
    public var id: String
    public var availability: Availability
    public var activity: String
    public init(id: String, availability: Availability, activity: String = "") {
        self.id = id; self.availability = availability; self.activity = activity
    }
    public var label: String {
        switch availability {
        case .available, .availableIdle: "Available"
        case .away: "Away"
        case .beRightBack: "Be right back"
        case .busy, .busyIdle: activity == "InAMeeting" ? "In a meeting" : activity == "InACall" ? "In a call" : "Busy"
        case .doNotDisturb: activity == "Presenting" ? "Presenting" : "Do not disturb"
        case .offline: "Offline"
        case .unknown: "Status unknown"
        }
    }
}

public protocol PresenceService: Sendable {
    func presences(ids: [String]) async throws -> [PresenceInfo]
}

public final class GraphPresenceService: PresenceService, @unchecked Sendable {
    public static let maxIds = 650
    private let http: GraphHTTP
    /// `token`: Presence.Read.All (`Auth.presenceScopes`), silent only.
    public init(token: @escaping GraphHTTP.TokenProvider, session: URLSession = .shared) {
        http = GraphHTTP(token: token, session: session)
    }

    public func presences(ids: [String]) async throws -> [PresenceInfo] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var out: [PresenceInfo] = []
        for start in stride(from: 0, to: unique.count, by: Self.maxIds) {
            let chunk = Array(unique[start..<min(start + Self.maxIds, unique.count)])
            let body = try JSONSerialization.data(withJSONObject: ["ids": chunk])
            // POST but read-only: safe to retry on 503/504.
            let data = try await http.send(http.url("communications/getPresencesByUserId"), method: "POST", body: body,
                                           idempotent: true)
            guard let page = try? JSONDecoder().decode(GHPage<GHPresence>.self, from: data) else {
                throw MailServiceError.http(200, "decode")
            }
            out += page.value.map {
                PresenceInfo(id: $0.id, availability: .init(rawValue: $0.availability ?? "") ?? .unknown, activity: $0.activity ?? "")
            }
        }
        return out
    }
}

struct GHPresence: Decodable { var id: String; var availability: String?; var activity: String? }

/// Injectable clock (tests advance it instead of sleeping).
public final class PresenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var fixed: Date?
    public init(fixed: Date? = nil) { self.fixed = fixed }
    public var now: Date { lock.withLock { fixed ?? Date() } }
    public func advance(_ s: TimeInterval) { lock.withLock { fixed = (fixed ?? Date()).addingTimeInterval(s) } }
}

/// Address → presence with a TTL cache, address→id resolution (internal only, negative-cached), dedupe and a minimum
/// interval between network rounds (rate limit). Callers ask only for people on screen.
public actor PresenceCache {
    public typealias Resolver = @Sendable ([String]) async throws -> [String: String]
    private let service: PresenceService
    private let resolve: Resolver
    private let clock: PresenceClock
    public nonisolated let ttl: TimeInterval
    public nonisolated let minInterval: TimeInterval
    private var ids: [String: String] = [:]        // address → object id
    private var misses: Set<String> = []           // addresses not in the directory
    private var values: [String: (PresenceInfo, Date)] = [:]   // id → (presence, fetched)
    private var lastRound: Date?
    public private(set) var rounds = 0

    public init(service: PresenceService, resolve: @escaping Resolver, clock: PresenceClock = PresenceClock(),
                ttl: TimeInterval = 60, minInterval: TimeInterval = 5) {
        self.service = service; self.resolve = resolve; self.clock = clock; self.ttl = ttl; self.minInterval = minInterval
    }

    /// Cached presence for addresses (no network).
    public func cached(_ addresses: [String]) -> [String: PresenceInfo] {
        var out: [String: PresenceInfo] = [:]
        for a in addresses { let k = a.lowercased(); if let id = ids[k], let v = values[id] { out[k] = v.0 } }
        return out
    }

    /// Refreshes stale entries for `addresses` (already filtered to internal people by the caller) and returns what is
    /// known. Within `minInterval` of the last round only the cache is returned.
    public func lookup(_ addresses: [String]) async throws -> [String: PresenceInfo] {
        let now = clock.now
        let keys = Array(Set(addresses.map { $0.lowercased() }.filter { $0.contains("@") })).sorted()
        if let l = lastRound, now.timeIntervalSince(l) < minInterval { return cached(keys) }
        let unresolved = keys.filter { ids[$0] == nil && !misses.contains($0) }
        let stale = keys.compactMap { ids[$0] }.filter { id in values[id].map { now.timeIntervalSince($0.1) >= ttl } ?? true }
        guard !unresolved.isEmpty || !stale.isEmpty else { return cached(keys) }
        lastRound = now; rounds += 1
        var toFetch = stale
        if !unresolved.isEmpty {
            let found = try await resolve(unresolved)
            for a in unresolved {
                if let id = found[a] { ids[a] = id; toFetch.append(id) } else { misses.insert(a) }
            }
        }
        if !toFetch.isEmpty {
            for p in try await service.presences(ids: toFetch) { values[p.id] = (p, now) }
        }
        return cached(keys)
    }

    /// Addresses that are neither answered nor known misses (the caller re-asks after `minInterval`).
    public func unanswered(_ addresses: [String]) -> Int {
        addresses.map { $0.lowercased() }.filter { a in
            guard !misses.contains(a) else { return false }
            guard let id = ids[a] else { return true }
            return values[id] == nil
        }.count
    }

    public func reset() { ids = [:]; misses = []; values = [:]; lastRound = nil }
}

public final class FixturePresenceService: PresenceService, @unchecked Sendable {
    public init() {}
    public func presences(ids: [String]) async throws -> [PresenceInfo] {
        let all: [PresenceInfo.Availability] = [.available, .busy, .away, .doNotDisturb, .offline]
        return ids.map { id in PresenceInfo(id: id, availability: all[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % all.count]) }
    }
}
