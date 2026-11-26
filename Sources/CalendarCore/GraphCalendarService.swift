import Foundation

/// Microsoft Graph implementation.
///
/// Sync strategy (verified against Graph v1.0 docs, 2026-11):
///  * `event: delta` exists ONLY for a mailbox's primary calendar (`/me/calendarView/delta`,
///    `/users/{id}/calendarView/delta`). We use it for the user's own primary and for each delegated mailbox.
///  * Secondary calendars and calendars shared into the user's list have no delta → windowed
///    `calendarView` snapshot, replaced atomically in the store.
///  * delta can't `$expand`, so the Purview label (MIP metadata in an extended property) is fetched for
///    changed items with `$batch`. Snapshot requests expand it inline.
public final class GraphCalendarService: CalendarService, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () async throws -> String
    /// Token per scope set (Auth keeps one MSAL token per incremental-consent set). nil → `token` for everything.
    public typealias ScopedTokenProvider = @Sendable (GraphScope) async throws -> String

    private let token: TokenProvider
    private let scopedToken: ScopedTokenProvider?
    /// Calendars added by address / group (sealed in the store by the app, pushed in before each sync).
    private let sourcesLock = NSLock()
    nonisolated(unsafe) private var _sources: [CalendarSource] = []
    nonisolated(unsafe) private var _sourceProblems: [String: CalendarSourceError] = [:]
    private let session: URLSession
    let base = URL(string: "https://graph.microsoft.com/v1.0")!
    private let beta = URL(string: "https://graph.microsoft.com/beta")!
    /// Mailboxes where the user is a delegate (configured — Graph has no "list my delegations" API).
    private let delegatedMailboxes: [String]
    /// ACCOUNTS-HOOK: owning account's tenant for label parsing (docs/ACCOUNTS.md A9); nil = default-account shim.
    public let accountTenant: String?
    var labelTenant: String? { MIPMetadata.tenant(forAccount: accountTenant) }

    public init(token: @escaping TokenProvider, delegatedMailboxes: [String] = [], session: URLSession = .shared,
                scopedToken: ScopedTokenProvider? = nil, accountTenant: String? = nil) {
        self.accountTenant = accountTenant?.lowercased()
        self.token = token
        self.scopedToken = scopedToken
        self.delegatedMailboxes = delegatedMailboxes
        self.session = session
    }

    // MARK: Calendars

    public func listCalendars() async throws -> [CalendarInfo] {
        let me: GMe = try await get(base.appending(path: "me").with(query: ["$select": "displayName,mail,userPrincipalName"]))
        let myAddress = (me.mail ?? me.userPrincipalName ?? "").lowercased()
        let select = "id,name,hexColor,isDefaultCalendar,canEdit,owner"

        var result: [CalendarInfo] = []
        let mine: GPage<GCalendar> = try await get(base.appending(path: "me/calendars").with(query: ["$select": select, "$top": "100"]))
        for c in mine.value {
            let owner = c.owner?.address?.lowercased() ?? myAddress
            let isMine = owner == myAddress
            result.append(CalendarInfo(
                id: c.id, name: c.name, ownerName: c.owner?.name ?? me.displayName ?? "",
                ownerAddress: owner, mailboxPath: "/me", access: isMine ? .own : .shared,
                canEdit: c.canEdit ?? false, hexColor: c.hexColor, isDefault: isMine && (c.isDefaultCalendar ?? false)))
        }
        for mailbox in delegatedMailboxes {
            let path = "/users/\(mailbox)"
            let page: GPage<GCalendar> = try await get(base.appending(path: "users/\(mailbox)/calendars")
                .with(query: ["$select": select, "$top": "100"]))
            for c in page.value where !result.contains(where: { $0.id == c.id }) {
                result.append(CalendarInfo(
                    id: c.id, name: c.name, ownerName: c.owner?.name ?? mailbox, ownerAddress: mailbox.lowercased(),
                    mailboxPath: path, access: .delegated, canEdit: c.canEdit ?? false, hexColor: c.hexColor,
                    isDefault: c.isDefaultCalendar ?? false))
            }
        }
        for source in sources {
            do {
                for c in try await calendars(for: source) where !result.contains(where: { $0.id == c.id }) { result.append(c) }
                setProblem(nil, for: source)
            } catch ServiceError.offline {
                throw ServiceError.offline
            } catch {
                // One revoked share or an unconsented group must not stop the rest of the calendar syncing.
                setProblem(CalendarSourceError(error), for: source)
            }
        }
        return result
    }

    // MARK: Added calendars (by address, groups)

    public func setSources(_ s: [CalendarSource]) { sourcesLock.withLock { _sources = s } }
    public var sources: [CalendarSource] { sourcesLock.withLock { _sources } }
    public var sourceProblems: [String: CalendarSourceError] { sourcesLock.withLock { _sourceProblems } }
    private func setProblem(_ p: CalendarSourceError?, for s: CalendarSource) { sourcesLock.withLock { _sourceProblems[s.id] = p } }

    public func probe(source: CalendarSource) async throws -> [CalendarInfo] {
        do { return try await calendars(for: source, validate: true) } catch ServiceError.offline { throw ServiceError.offline }
        catch { throw CalendarSourceError(error) }
    }

    /// Someone else's calendars: `GET /users/{addr}/calendars`; when only the default calendar folder is shared
    /// (listing the folders is refused), `GET /users/{addr}/calendar`. Groups: `GET /groups/{id}/calendar`.
    /// Never `isDefault`: added calendars take the windowed snapshot path, not delta (verified for own/delegated only).
    /// Groups aren't fetched on every sync (`validate: false`): the calendar comes from the source itself, so a group
    /// token that needs consent doesn't make the calendar (and its cache) disappear; the snapshot reports it instead.
    func calendars(for source: CalendarSource, validate: Bool = false) async throws -> [CalendarInfo] {
        let select = "id,name,hexColor,isDefaultCalendar,canEdit,owner"
        switch source {
        case .user(let raw):
            let address = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let make: (GCalendar) -> CalendarInfo = { c in
                CalendarInfo(id: c.id, name: c.name, ownerName: c.owner?.name ?? address, ownerAddress: address,
                             mailboxPath: "/users/\(address)", access: .shared, canEdit: c.canEdit ?? false,
                             hexColor: c.hexColor, isDefault: false)
            }
            do {
                let page: GPage<GCalendar> = try await get(base.appending(path: "users/\(address)/calendars")
                    .with(query: ["$select": select, "$top": "100"]))
                return page.value.map(make)
            } catch ServiceError.http(403, _) {
                let one: GCalendar = try await get(base.appending(path: "users/\(address)/calendar").with(query: ["$select": select]))
                return [make(one)]
            }
        case .group(let id, let name, let mail):
            if validate {
                let _: GCalendar = try await get(base.appending(path: "groups/\(id)/calendar").with(query: ["$select": "id,name"]))
            }
            // Group calendar writes: POST /groups/{id}/calendar/events, PATCH/DELETE /groups/{id}/events/{id}
            // (Group.ReadWrite.All, Learn). UNVERIFIED against a tenant.
            return [CalendarInfo(id: "group:\(id)", name: name, ownerName: name, ownerAddress: (mail ?? id).lowercased(),
                                 mailboxPath: "/groups/\(id)", access: .shared, canEdit: true, hexColor: nil, isDefault: false)]
        }
    }

    /// Microsoft 365 groups the user belongs to (for "Add group calendar…"). Membership token (GroupMember.Read.All).
    public func myGroups() async throws -> [GroupRef] {
        struct G: Decodable { var id: String; var displayName: String?; var mail: String? }
        var next = base.appending(path: "me/memberOf/microsoft.graph.group").with(query: [
            "$filter": "groupTypes/any(c:c eq 'Unified')", "$count": "true", "$select": "id,displayName,mail", "$top": "100"])
        var out: [GroupRef] = []
        while true {
            let page: GPage<G> = try await send(next, method: "GET", body: nil, headers: ["ConsistencyLevel": "eventual"])
            out += page.value.map { GroupRef(id: $0.id, name: $0.displayName ?? $0.mail ?? $0.id, mail: $0.mail) }
            guard let n = page.nextLink, let u = URL(string: n) else { break }
            next = u
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Graph path (no leading slash) of a calendar's events parent.
    /// User calendars: `{mailbox}/calendars/{id}`; group calendars: `groups/{gid}` (+ `/calendar/events` to create).
    func eventsRoot(_ cal: CalendarInfo) -> String {
        if let g = cal.groupId { return "groups/\(g)" }
        return String(cal.mailboxPath.dropFirst()) + "/calendars/\(cal.id)"
    }
    func itemURL(_ cal: CalendarInfo, _ eventId: String) -> URL { base.appending(path: eventsRoot(cal) + "/events/\(eventId)") }

    // MARK: Events

    public func sync(calendar: CalendarInfo, window: DateInterval, deltaLink: String?) async throws -> SyncBatch {
        if calendar.isDefault { return try await deltaRound(calendar, window: window, deltaLink: deltaLink) }
        return try await snapshot(calendar, window: window)
    }

    private func deltaRound(_ cal: CalendarInfo, window: DateInterval, deltaLink: String?) async throws -> SyncBatch {
        var next: URL = if let deltaLink, let u = URL(string: deltaLink) { u } else {
            base.appending(path: String(cal.mailboxPath.dropFirst()) + "/calendarView/delta")
                .with(query: ["startDateTime": iso(window.start), "endDateTime": iso(window.end)])
        }
        var upserts: [CalendarEvent] = [], removed: [String] = []
        while true {
            let page: GPage<GEvent> = try await get(next, prefer: ["odata.maxpagesize=200", #"outlook.timezone="UTC""#])
            for e in page.value {
                if e.removed != nil { removed.append(e.id); continue }
                // VERIFIED against a real tenant: calendarView/delta also returns seriesMaster items (alongside
                // occurrences). The master's start/end is the first instance, so storing it would duplicate a slot.
                if e.type == "seriesMaster" { continue }
                if let ev = e.toModel(calendarId: cal.id, tenant: labelTenant) { upserts.append(ev) }
            }
            if let n = page.nextLink, let u = URL(string: n) { next = u; continue }
            // Labels for changed items (delta can't $expand).
            let labels = try await fetchLabels(eventIds: upserts.map(\.id), mailboxPath: cal.mailboxPath)
            for i in upserts.indices { upserts[i].labelId = labels[upserts[i].id] }
            return SyncBatch(mode: .delta, upserts: upserts, removedIds: removed, deltaLink: page.deltaLink)
        }
    }

    private func snapshot(_ cal: CalendarInfo, window: DateInterval) async throws -> SyncBatch {
        // Groups: GET /groups/{id}/calendarView (Learn: Group.Read.All least privileged; group token).
        // UNVERIFIED: whether group events honour the msip_labels $expand (if ignored, labelled items read as unlabelled).
        var next = base.appending(path: eventsRoot(cal) + "/calendarView")
            .with(query: [
                "startDateTime": iso(window.start), "endDateTime": iso(window.end), "$top": "250",
                "$expand": "singleValueExtendedProperties($filter=id eq '\(MIPMetadata.extendedPropertyId)')",
            ])
        var events: [CalendarEvent] = []
        while true {
            let page: GPage<GEvent> = try await get(next, prefer: [#"outlook.timezone="UTC""#])
            events += page.value.compactMap { $0.toModel(calendarId: cal.id, tenant: labelTenant) }
            guard let n = page.nextLink, let u = URL(string: n) else { break }
            next = u
        }
        return SyncBatch(mode: .replaceWindow, upserts: events)
    }

    /// `$batch` (20 per request) to read the MIP label metadata for changed events.
    private func fetchLabels(eventIds: [String], mailboxPath: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        let expand = "singleValueExtendedProperties($filter=id eq '\(MIPMetadata.extendedPropertyId)')"
        let enc = expand.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expand
        for chunk in stride(from: 0, to: eventIds.count, by: 20).map({ Array(eventIds[$0..<min($0 + 20, eventIds.count)]) }) {
            let requests = chunk.enumerated().map { i, id in
                ["id": "\(i)", "method": "GET", "url": "\(mailboxPath)/events/\(id)?$select=id&$expand=\(enc)"]
            }
            let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
            let resp: GBatchResponse = try await send(base.appending(path: "$batch"), method: "POST", body: body)
            for r in resp.responses where r.status == 200 {
                guard let e = r.body, let raw = e.singleValueExtendedProperties?.first?.value,
                      let label = MIPMetadata.activeLabelId(in: raw, homeTenant: labelTenant) else { continue }
                out[e.id] = label
            }
        }
        return out
    }

    // MARK: Labels

    public func sensitivityLabels() async throws -> [SensitivityLabel] {
        // beta-only today; v1.0 equivalent is under /security/dataSecurityAndGovernance (different scope).
        let page: GPage<GLabel> = try await get(beta.appending(path: "me/security/informationProtection/sensitivityLabels"))
        // Hierarchy, colour inheritance and ordering: GraphLabelMapper (LabelTree.swift).
        var out = GraphLabelMapper.map(page.value)
        for i in out.indices where out[i].hasProtection && out[i].isAppliable != false {
            out[i].rights = await labelRights(labelId: out[i].id)
        }
        return out
    }

    /// The calling user's usage rights under one encrypted label:
    /// `GET /v1.0/security/dataSecurityAndGovernance/sensitivityLabels/{labelId}/rights` → `usageRightsIncluded`
    /// (https://learn.microsoft.com/graph/api/usagerightsincluded-get?view=graph-rest-1.0). Documented 403/404 when the
    /// label has no admin-defined protection or the user lacks VIEW.
    ///
    /// CONSENT NEEDED: least-privileged delegated scope is `SensitivityLabel.Read`, which `Auth.calendarScopes` doesn't
    /// request (changing it would change the silent token for existing sessions). Until it's consented this call 403s
    /// and the label falls back to VIEW only. Live behaviour (incl. whether the omitted `ownerEmail` yields the user's
    /// label-level rights, as the docs suggest) is UNVERIFIED against a tenant.
    /// Any failure → nil (fail closed). This never fails the label list.
    private func labelRights(labelId: String) async -> UsageRights? {
        let url = base.appending(path: "security/dataSecurityAndGovernance/sensitivityLabels/\(labelId)/rights")
        guard let r: GUsageRightsIncluded = try? await get(url) else { return nil }
        return UsageRights.parse(r.value?.tokens ?? [])
    }

    // MARK: Writes

    public func create(calendar: CalendarInfo, body: Data) async throws -> CalendarEvent {
        // Calendar-scoped so delegates create in the principal's calendar (Exchange sends as/on behalf of them).
        let url = calendar.isGroup ? base.appending(path: eventsRoot(calendar) + "/calendar/events")
                                   : base.appending(path: eventsRoot(calendar) + "/events")
        // PURVIEW-HOOK: a rejected msip_labels property never blocks the save (one retry without it, session memory).
        let prefer = ["Prefer": #"outlook.timezone="UTC""#]
        let e: GEvent
        if LabelStampGuard.isRejected, let plain = LabelStampGuard.stripped(body) {
            e = try await send(url, method: "POST", body: plain, headers: prefer)
        } else {
            do { e = try await send(url, method: "POST", body: body, headers: prefer) }
            catch ServiceError.http(let s, let m) where LabelStampGuard.isRejection(status: s, message: m) {
                guard let plain = LabelStampGuard.stripped(body) else { throw ServiceError.http(s, m) }
                LabelStampGuard.noteRejected(status: s)
                e = try await send(url, method: "POST", body: plain, headers: prefer)
            }
        }
        guard let model = e.toModel(calendarId: calendar.id, tenant: labelTenant) else { throw ServiceError.http(500, "bad event") }
        return model
    }

    public func remove(calendar: CalendarInfo, eventId: String, mode: RemoveMode, comment: String?, ifMatch: String?) async throws {
        let item = itemURL(calendar, eventId)
        do {
            // VERIFIED against a test tenant (LiveWriteProbe, 2026-11-19): Exchange honours If-Match on PATCH
            // (412) but IGNORES it on DELETE/cancel/decline. Compare changeKeys ourselves first, so an offline delete
            // can't silently remove something the organiser changed meanwhile. (Small race window remains.)
            if let ifMatch {
                let current: GChangeKey = try await get(item.with(query: ["$select": "changeKey"]))
                if let ck = current.changeKey, ck != ifMatch { throw ServiceError.conflict }
            }
            switch mode {
            case .delete:
                var h: [String: String] = [:]
                if let ifMatch { h["If-Match"] = #"W/""# + ifMatch + #"""# }
                let _: GraphEmpty = try await send(item, method: "DELETE", body: nil, headers: h)
            case .cancel:
                let _: GraphEmpty = try await send(item.appending(path: "cancel"), method: "POST",
                                                   body: try JSONSerialization.data(withJSONObject: ["comment": comment ?? ""]))
            case .decline:
                let _: GraphEmpty = try await send(item.appending(path: "decline"), method: "POST",
                                                   body: try JSONSerialization.data(withJSONObject: ["comment": comment ?? "", "sendResponse": true]))
            }
        } catch ServiceError.http(404, _) {
            return   // already gone on the server: the local intent is satisfied
        }
    }

    public func fetch(calendar: CalendarInfo, eventId: String) async throws -> CalendarEvent {
        let url = itemURL(calendar, eventId)
        let e: GEvent = try await get(url, prefer: [#"outlook.timezone="UTC""#])
        guard let model = e.toModel(calendarId: calendar.id, tenant: labelTenant) else { throw ServiceError.http(500, "bad event") }
        return model
    }

    public func update(calendar: CalendarInfo, eventId: String, patch: Data, ifMatch: String?) async throws -> CalendarEvent {
        // Calendar-scoped path, not `/me/events/{id}`: for calendars shared INTO the user's list the item lives in
        // the owner's mailbox; this is the same addressing the snapshot read uses.
        let url = itemURL(calendar, eventId)
        var headers: [String: String] = [:]
        // UNVERIFIED: weak ETag built from changeKey. Confirm a stale value yields 412 against a real mailbox.
        if let ifMatch { headers["If-Match"] = #"W/""# + ifMatch + #"""# }
        let e: GEvent = try await send(url, method: "PATCH", body: patch, headers: headers)
        guard let model = e.toModel(calendarId: calendar.id, tenant: labelTenant) else { throw ServiceError.http(500, "bad event") }
        return model
    }

    // MARK: HTTP

    /// Which consent set a request needs. Calendar scopes never change (existing sessions keep refreshing silently).
    static func scope(for url: URL) -> GraphScope {
        let p = url.path
        if p.contains("/memberOf") { return .groupMembership }
        if p.hasPrefix("/v1.0/groups/") { return .groupCalendar }
        if p.hasPrefix("/v1.0/places") { return .places }
        if p.contains("/outlook/masterCategories") { return .mailboxSettings }
        return .calendar
    }

    func get<T: Decodable>(_ url: URL, prefer: [String] = []) async throws -> T {
        var h: [String: String] = [:]
        if !prefer.isEmpty { h["Prefer"] = prefer.joined(separator: ", ") }
        return try await send(url, method: "GET", body: nil, headers: h)
    }

    func send<T: Decodable>(_ url: URL, method: String, body: Data?, headers: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        let bearer: String
        if let scopedToken { bearer = try await scopedToken(Self.scope(for: url)) } else { bearer = try await token() }
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CompliantCalendar/0.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        for attempt in 0..<4 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .dataNotAllowed].contains(e.code) {
                throw ServiceError.offline
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                if T.self == GraphEmpty.self { return GraphEmpty() as! T }   // 202/204 with no body
                return try JSONDecoder().decode(T.self, from: data)
            case 401: throw ServiceError.unauthorized
            case 410: throw ServiceError.syncStateInvalid
            case 412: throw ServiceError.conflict
            case 429, 503, 504:
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(wait, 30)))
            default:
                let msg = String(data: data, encoding: .utf8) ?? ""
                if msg.contains("syncStateNotFound") || msg.contains("SyncStateNotFound") { throw ServiceError.syncStateInvalid }
                throw ServiceError.http(status, String(msg.prefix(300)))
            }
        }
        throw ServiceError.http(429, "throttled")
    }

    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}

struct GChangeKey: Decodable { var changeKey: String? }
struct GraphEmpty: Decodable {}

// MARK: - Free/busy (teammates)

extension GraphCalendarService {
    /// POST /me/calendar/getSchedule. Needs only Calendars.ReadBasic-level access to the other mailbox (default
    /// org sharing gives free/busy to everyone). We decode status and times only; subjects/locations that some
    /// sharing levels expose are ignored by the decoder and never stored.
    public func freeBusy(for addresses: [String], window: DateInterval) async throws -> [String: [FreeBusySlot]] {
        guard !addresses.isEmpty else { return [:] }
        struct T: Codable { var dateTime: String; var timeZone = "UTC" }
        struct Req: Encodable { var schedules: [String]; var startTime: T; var endTime: T; var availabilityViewInterval = 15 }
        struct Item: Decodable { var status: String; var start: T; var end: T }
        struct Sched: Decodable { var scheduleId: String; var scheduleItems: [Item]? }
        struct Resp: Decodable { var value: [Sched] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var out: [String: [FreeBusySlot]] = [:]
        // getSchedule takes at most 20 schedules per call.
        for chunk in stride(from: 0, to: addresses.count, by: 20).map({ Array(addresses[$0..<min($0 + 20, addresses.count)]) }) {
            let body = try JSONEncoder().encode(Req(schedules: chunk, startTime: T(dateTime: f.string(from: window.start)),
                                                    endTime: T(dateTime: f.string(from: window.end))))
            let r: Resp = try await send(URL(string: "https://graph.microsoft.com/v1.0/me/calendar/getSchedule")!, method: "POST",
                                         body: body, headers: ["Prefer": #"outlook.timezone="UTC""#])
            for s in r.value {
                out[s.scheduleId.lowercased()] = (s.scheduleItems ?? []).compactMap { i in
                    guard let a = GraphTime.parse(i.start.dateTime, allDay: false), let b = GraphTime.parse(i.end.dateTime, allDay: false)
                    else { return nil }
                    return FreeBusySlot(start: a, end: b, status: ShowAs(rawValue: i.status) ?? .busy)
                }
            }
        }
        return out
    }
}

// MARK: - Purview label metadata on Exchange items

public enum MIPMetadata {
    /// MIP labels are written into the item's `msip_labels` named property (PS_INTERNET_HEADERS namespace).
    /// UNVERIFIED for calendar items: confirmed only for mail; verify against a labelled meeting in a tenant.
    public static let extendedPropertyId = "String {00020386-0000-0000-C000-000000000046} Name msip_labels"

    /// The signed-in tenant (from the MSAL home account id `<oid>.<tid>`). Set once at sign-in.
    public static var homeTenantId: String? {
        get { tenantLock.withLock { _homeTenant } }
        set { tenantLock.withLock { _homeTenant = newValue?.lowercased() } }
    }
    nonisolated(unsafe) private static var _homeTenant: String?
    private static let tenantLock = NSLock()

    /// Parses `MSIP_Label_<guid>_Enabled=true; MSIP_Label_<guid>_SiteId=<tenant>; …` and returns the enabled label of
    /// *our* tenant. Mail from another organisation carries that organisation's labels (SiteId = their tenant); those
    /// GUIDs are meaningless here, so like Outlook they are ignored instead of showing as an unknown (restricted)
    /// label (found live 2026-11-19). Labels without a SiteId, or when the home tenant isn't known yet, count as ours.
    /// Encryption is detected separately from the content, so ignoring a foreign label never hides protection.
    public static func activeLabelId(in raw: String, homeTenant: String? = homeTenantId) -> String? {
        read(raw, homeTenant: homeTenant).labelId   // LabelProvenance.swift
    }
}

// MARK: - Graph DTOs

struct GPage<T: Decodable>: Decodable {
    var value: [T]
    var nextLink: String?
    var deltaLink: String?
    enum CodingKeys: String, CodingKey {
        case value, nextLink = "@odata.nextLink", deltaLink = "@odata.deltaLink"
    }
}

struct GMe: Decodable { var displayName: String?; var mail: String?; var userPrincipalName: String? }
struct GEmail: Decodable { var name: String?; var address: String? }
struct GCalendar: Decodable {
    var id: String; var name: String; var hexColor: String?; var isDefaultCalendar: Bool?; var canEdit: Bool?; var owner: GEmail?
}
struct GLabel: Decodable {
    /// The nested parent object (often the only place a parent label appears in the response).
    struct Parent: Decodable {
        var id: String; var name: String?; var description: String?; var tooltip: String?; var color: String?
        var sensitivity: Int?; var isActive: Bool?; var isAppliable: Bool?; var hasProtection: Bool?
    }
    var id: String; var name: String; var description: String?; var tooltip: String?; var color: String?
    var sensitivity: Int?; var isActive: Bool?; var hasProtection: Bool?; var parent: Parent?
    var isAppliable: Bool?
}
/// `usageRightsIncluded`. `value` is a comma-separated string in the documented example
/// (`"docEdit, edit, forward, …"`) but the enum page says callers see a list of names, so both are decoded.
struct GUsageRightsIncluded: Decodable {
    enum Value: Decodable {
        case one(String), many([String])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        var tokens: [String] { switch self { case .one(let s): [s]; case .many(let a): a } }
    }
    var id: String?; var ownerEmail: String?; var userEmail: String?; var value: Value?
}
struct GBatchResponse: Decodable {
    struct R: Decodable {
        var id: String; var status: Int; var body: GEvent?
        enum CodingKeys: String, CodingKey { case id, status, body }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            status = try c.decode(Int.self, forKey: .status)
            body = status == 200 ? try? c.decode(GEvent.self, forKey: .body) : nil // error bodies aren't events
        }
    }
    var responses: [R]
}

struct GEvent: Decodable {
    struct DT: Decodable { var dateTime: String; var timeZone: String? }
    struct Loc: Decodable { var displayName: String? }
    struct Who: Decodable { var emailAddress: GEmail? }
    struct Att: Decodable { struct S: Decodable { var response: String? }; var emailAddress: GEmail?; var status: S?; var type: String? }
    struct Resp: Decodable { var response: String? }
    struct Online: Decodable { var joinUrl: String? }
    struct Body: Decodable { var content: String? }
    struct Prop: Decodable { var id: String; var value: String? }
    struct Removed: Decodable { var reason: String? }

    var id: String
    var subject: String?
    var start: DT?
    var end: DT?
    var isAllDay: Bool?
    var location: Loc?
    var organizer: Who?
    var attendees: [Att]?
    var bodyPreview: String?
    var showAs: String?
    var sensitivity: String?
    var changeKey: String?
    var isCancelled: Bool?
    var onlineMeeting: Online?
    /// Decoded only to find non-Teams join links; never stored (bodyPreview is the stored excerpt).
    var body: Body?
    var webLink: String?
    var singleValueExtendedProperties: [Prop]?
    var removed: Removed?
    var type: String?
    var isOrganizer: Bool?
    var seriesMasterId: String?
    var categories: [String]?
    var responseStatus: Resp?
    var allowNewTimeProposals: Bool?

    enum CodingKeys: String, CodingKey {
        case id, subject, start, end, isAllDay, location, organizer, attendees, bodyPreview, showAs, sensitivity,
             changeKey, isCancelled, onlineMeeting, body, webLink, singleValueExtendedProperties, type, isOrganizer, seriesMasterId,
             categories, responseStatus, allowNewTimeProposals, removed = "@removed"
    }

    func toModel(calendarId: String, tenant: String? = MIPMetadata.homeTenantId) -> CalendarEvent? {
        let allDay = isAllDay ?? false
        guard let s = start.flatMap({ GraphTime.parse($0.dateTime, allDay: allDay) }),
              let e = end.flatMap({ GraphTime.parse($0.dateTime, allDay: allDay) }) else { return nil }
        return CalendarEvent(
            id: id, calendarId: calendarId, subject: subject ?? "", start: s, end: e, isAllDay: allDay,
            location: location?.displayName.flatMap { $0.isEmpty ? nil : $0 },
            organizer: organizer?.emailAddress?.name,
            attendees: (attendees ?? []).map { Attendee(name: $0.emailAddress?.name ?? "", address: $0.emailAddress?.address ?? "",
                                                         response: $0.status?.response ?? "none",
                                                         type: $0.type.flatMap { $0 == "required" ? nil : $0 }) },
            bodyPreview: bodyPreview, showAs: ShowAs(rawValue: showAs ?? "") ?? .unknown,
            legacySensitivity: LegacySensitivity(rawValue: sensitivity ?? "") ?? .normal,
            labelId: singleValueExtendedProperties?.first?.value.flatMap { MIPMetadata.activeLabelId(in: $0, homeTenant: tenant) },
            changeKey: changeKey, isCancelled: isCancelled ?? false,
            onlineMeetingURL: MeetingLink.extract(joinUrl: onlineMeeting?.joinUrl,
                                                  location: location?.displayName, body: body?.content),
            webLink: webLink.flatMap(URL.init(string:)), isOrganizer: isOrganizer,
            seriesMasterId: seriesMasterId, categories: categories.flatMap { $0.isEmpty ? nil : $0 },
            myResponse: responseStatus?.response, allowNewTimeProposals: allowNewTimeProposals)
    }
}

public enum GraphTime {
    /// Graph returns `2026-11-18T09:30:00.0000000` (no zone; UTC because we send Prefer: outlook.timezone="UTC").
    /// All-day events are floating dates: anchor them at local midnight so they don't drift across days.
    public static func parse(_ s: String, allDay: Bool) -> Date? {
        let trimmed = String(s.prefix(19))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = allDay ? .current : TimeZone(identifier: "UTC")
        return f.date(from: trimmed)
    }
}

extension URL {
    func with(query: [String: String]) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}
