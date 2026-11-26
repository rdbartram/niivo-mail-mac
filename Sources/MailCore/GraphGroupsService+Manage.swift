import Foundation

// MARK: - Microsoft 365 Groups: files, members, join / leave, follow in inbox, favourite
//
// Checked on learn.microsoft.com (2026-11-20), Graph v1.0 — except where marked UNVERIFIED:
//  * `GET /groups/{id}/members`: least privilege GroupMember.ReadBasic.All (delegated; the caller must be a member or
//    owner). Our read set has GroupMember.Read.All (higher) → read token. UNVERIFIED: the `/microsoft.graph.user` cast
//    segment on this list (documented for other directory collections).
//  * `GET /groups/{id}/drive` → `webUrl`: least privilege Files.Read (delegated) → the OneDrive token (Files.ReadWrite).
//  * `POST /groups/{id}/subscribeByMail` / `unsubscribeByMail` ("follow in inbox"): delegated Group.ReadWrite.All
//    only, Microsoft 365 groups only; 200 empty (204 with return=minimal) → write token.
//  * `POST /groups/{id}/addFavorite` / `removeFavorite`: delegated Group.ReadWrite.All only → write token.
//  * Join: `POST /groups/{id}/members/$ref {"@odata.id": ".../directoryObjects/{me}"}`; leave:
//    `DELETE /groups/{id}/members/{me}/$ref` (MUST end in `/$ref`, otherwise Graph may delete the object). Least
//    privilege GroupMember.ReadWrite.All; Group.ReadWrite.All (our write set) is a higher documented permission. In
//    delegated mode the user also needs `microsoft.directory/groups/members/update` (owner or an admin role); Learn
//    makes no exception for a member joining a public group, so a plain user is EXPECTED to get 403 → `.notAllowed`.
//    UNVERIFIED against a tenant.
//  * UNVERIFIED: `GET /groups?$filter=groupTypes/any(c:c eq 'Unified') and visibility eq 'Public'` + `$search` lists
//    joinable groups (advanced query: ConsistencyLevel eventual + $count); that `visibility` is filterable together
//    with `$search`, and that Group.ReadWrite.All alone suffices for join/leave, weren't confirmed.

public struct GroupMember: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var mail: String?
    public var jobTitle: String?
    public init(id: String, displayName: String, mail: String?, jobTitle: String?) {
        self.id = id; self.displayName = displayName; self.mail = mail; self.jobTitle = jobTitle
    }
}

public enum GroupManageError: Error, Sendable, Equatable {
    /// 403: the tenant doesn't let this user change membership (owners / admins only).
    case notAllowed
    case alreadyMember
}

public protocol GroupManageService: Sendable {
    func members(groupId: String, top: Int) async throws -> [GroupMember]
    func filesURL(groupId: String, filesToken: GraphHTTP.TokenProvider?) async throws -> URL?
    func publicGroups(search: String) async throws -> [M365Group]
    func join(groupId: String) async throws
    func leave(groupId: String) async throws
    func setFollowInInbox(groupId: String, _ on: Bool) async throws
    func setFavourite(groupId: String, _ on: Bool) async throws
}

struct GGMember: Decodable { var id: String; var displayName: String?; var mail: String?; var jobTitle: String? }
struct GGDrive: Decodable { var webUrl: String? }
struct GGMe: Decodable { var id: String }

extension GraphGroupsService: GroupManageService {
    public func members(groupId: String, top: Int = 100) async throws -> [GroupMember] {
        let page: GHPage<GGMember> = try await read.get(read.url("groups/\(groupId)/members/microsoft.graph.user", [
            "$select": "id,displayName,mail,jobTitle", "$top": "\(top)",
        ]))
        return page.value.map { GroupMember(id: $0.id, displayName: $0.displayName ?? $0.mail ?? "", mail: $0.mail, jobTitle: $0.jobTitle) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func filesURL(groupId: String, filesToken: GraphHTTP.TokenProvider?) async throws -> URL? {
        let http = filesToken.map { GraphHTTP(token: $0, session: read.session) } ?? read
        let d: GGDrive = try await http.get(http.url("groups/\(groupId)/drive", ["$select": "webUrl"]))
        guard let s = d.webUrl, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }

    public func publicGroups(search: String) async throws -> [M365Group] {
        var q = ["$filter": "groupTypes/any(c:c eq 'Unified') and visibility eq 'Public'", "$count": "true", "$top": "50",
                 "$select": "id,displayName,mail"]
        let t = search.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        if !t.isEmpty { q["$search"] = "\"displayName:\(t)\"" }
        let page: GHPage<GGGroup> = try await read.get(read.url("groups", q), headers: ["ConsistencyLevel": "eventual"])
        return page.value.map { M365Group(id: $0.id, displayName: $0.displayName ?? "", mail: $0.mail) }
    }

    func meId() async throws -> String {
        let me: GGMe = try await read.get(read.url("me", ["$select": "id"]))
        return me.id
    }

    public func join(groupId: String) async throws {
        let me = try await meId()
        let body = try JSONSerialization.data(withJSONObject: ["@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/\(me)"])
        do { _ = try await write.send(write.url("groups/\(groupId)/members/$ref"), method: "POST", body: body, idempotent: false) }
        catch MailServiceError.forbidden { throw GroupManageError.notAllowed }
        catch MailServiceError.http(400, _) { throw GroupManageError.alreadyMember }
    }

    public func leave(groupId: String) async throws {
        let me = try await meId()
        do { _ = try await write.send(write.url("groups/\(groupId)/members/\(me)/$ref"), method: "DELETE", body: nil, idempotent: true) }
        catch MailServiceError.forbidden { throw GroupManageError.notAllowed }
    }

    public func setFollowInInbox(groupId: String, _ on: Bool) async throws {
        _ = try await write.send(write.url("groups/\(groupId)/\(on ? "subscribeByMail" : "unsubscribeByMail")"), method: "POST",
                                 body: nil, prefer: ["return=minimal"], idempotent: true)
    }

    public func setFavourite(groupId: String, _ on: Bool) async throws {
        _ = try await write.send(write.url("groups/\(groupId)/\(on ? "addFavorite" : "removeFavorite")"), method: "POST",
                                 body: nil, prefer: ["return=minimal"], idempotent: true)
    }
}

extension FixtureGroupsService: GroupManageService {
    public func members(groupId: String, top: Int) async throws -> [GroupMember] {
        [GroupMember(id: "u1", displayName: "Alex Example", mail: "alex@contoso.example", jobTitle: "Engineer"),
         GroupMember(id: "u2", displayName: "Sam Sample", mail: "sam@contoso.example", jobTitle: nil)]
    }
    public func filesURL(groupId: String, filesToken: GraphHTTP.TokenProvider?) async throws -> URL? {
        URL(string: "https://contoso.example.invalid/sites/\(groupId)/Shared%20Documents")
    }
    public func publicGroups(search: String) async throws -> [M365Group] { [] }
    public func join(groupId: String) async throws {}
    public func leave(groupId: String) async throws {}
    public func setFollowInInbox(groupId: String, _ on: Bool) async throws {}
    public func setFavourite(groupId: String, _ on: Bool) async throws {}
}
