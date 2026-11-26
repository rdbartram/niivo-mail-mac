import Foundation

/// Composer lookups against Graph: recipient suggestions, MailTips, and the attachments of a message (reply with
/// attachments, reopened drafts).
///
/// Endpoints (Microsoft Learn, from the API reference as remembered; not re-fetched for this change — UNVERIFIED
/// against a tenant):
///  * `GET /me/people?$search="q"` (People.Read): relevance-ranked people incl. groups / distribution lists
///    (`personType.class == "Group"`).
///  * `GET /users?$search="displayName:q" OR "mail:q"` + `ConsistencyLevel: eventual` (User.ReadBasic.All).
///  * `GET /groups?$search=…` + `ConsistencyLevel: eventual` (GroupMember.Read.All — the Groups consent, optional).
///  * `POST /me/getMailTips` (`/users/{mailbox}/getMailTips` for a shared From) `{EmailAddresses, MailTipsOptions}`
///    → `{value: [mailTips]}` (Mail.Read; covered by Mail.ReadWrite).
///  * `GET /{mb}/messages/{id}/attachments?$select=…`, `GET …/attachments/{aid}/$value`, `DELETE …/attachments/{aid}`.
/// Each source of a lookup fails on its own: a missing consent empties that source, never the others.
public protocol ComposeService: Sendable {
    func recipients(_ query: String) async -> [RecipientSuggestion]
    func mailTips(_ addresses: [String], mailbox: String) async throws -> [MailTip]
    func attachments(messageId: String, mailbox: String) async throws -> [DraftServerAttachment]
    /// File attachment bytes (nil for item / reference attachments, which can't be copied as files).
    func attachmentContent(messageId: String, attachment: DraftServerAttachment, mailbox: String) async throws -> OutgoingAttachment?
    func deleteAttachment(messageId: String, attachmentId: String, mailbox: String) async throws
}

public final class GraphComposeService: ComposeService, @unchecked Sendable {
    private let mail: GraphHTTP
    private let directory: GraphHTTP?
    private let groups: GraphHTTP?
    /// Sources that answered 401/403 are not asked again this session (no consent → no request per keystroke).
    private let lock = NSLock()
    private var disabled = Set<String>()

    public init(mailToken: @escaping GraphHTTP.TokenProvider, directoryToken: GraphHTTP.TokenProvider?,
                groupToken: GraphHTTP.TokenProvider? = nil, session: URLSession = .shared) {
        mail = GraphHTTP(token: mailToken, session: session)
        directory = directoryToken.map { GraphHTTP(token: $0, session: session) }
        groups = groupToken.map { GraphHTTP(token: $0, session: session) }
    }

    static func p(_ mailbox: String) -> String { mailbox == "me" ? "me" : "users/\(mailbox)" }

    /// `$search` term: quotes and backslashes removed (they'd break the KQL-ish clause), trimmed.
    public static func searchTerm(_ q: String) -> String {
        q.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isDisabled(_ s: String) -> Bool { lock.withLock { disabled.contains(s) } }
    private func note(_ s: String, _ e: Error) {
        switch e as? MailServiceError {
        case .forbidden?, .http(401, _)?, .http(403, _)?: _ = lock.withLock { disabled.insert(s) }
        default: break
        }
    }

    public func recipients(_ query: String) async -> [RecipientSuggestion] {
        let q = Self.searchTerm(query)
        guard q.count >= 2 else { return [] }
        async let people = self.people(q)
        async let users = self.users(q)
        async let groups = self.groupHits(q)
        return await people + users + groups
    }

    private func people(_ q: String) async -> [RecipientSuggestion] {
        guard let directory, !isDisabled("people") else { return [] }
        do {
            let page: GHPage<GCPerson> = try await directory.get(directory.url("me/people",
                ["$search": "\"\(q)\"", "$top": "10", "$select": "displayName,scoredEmailAddresses,userPrincipalName,personType"]))
            let n = Double(max(page.value.count, 1))
            return page.value.enumerated().compactMap { i, p in
                guard let a = p.scoredEmailAddresses?.first?.address ?? p.userPrincipalName, a.contains("@") else { return nil }
                return RecipientSuggestion(address: a, name: p.displayName ?? "", source: .people,
                                           isGroup: p.personType?.class?.lowercased() == "group", relevance: 1 - Double(i) / n)
            }
        } catch { note("people", error); return [] }
    }

    private func users(_ q: String) async -> [RecipientSuggestion] {
        guard let directory, !isDisabled("users") else { return [] }
        do {
            let page: GHPage<GHUser> = try await directory.get(directory.url("users",
                ["$search": "\"displayName:\(q)\" OR \"mail:\(q)\"", "$top": "8", "$select": "displayName,mail,userPrincipalName"]),
                headers: ["ConsistencyLevel": "eventual"])
            return page.value.compactMap { u in
                (u.mail ?? u.userPrincipalName).map { RecipientSuggestion(address: $0, name: u.displayName ?? "", source: .directory, relevance: 0.3) }
            }
        } catch { note("users", error); return [] }
    }

    private func groupHits(_ q: String) async -> [RecipientSuggestion] {
        guard let groups, !isDisabled("groups") else { return [] }
        do {
            let page: GHPage<GCGroup> = try await groups.get(groups.url("groups",
                ["$search": "\"displayName:\(q)\" OR \"mail:\(q)\"", "$top": "6", "$select": "displayName,mail,mailEnabled,groupTypes"]),
                headers: ["ConsistencyLevel": "eventual"])
            return page.value.compactMap { g in
                guard g.mailEnabled != false, let m = g.mail, !m.isEmpty else { return nil }
                return RecipientSuggestion(address: m, name: g.displayName ?? "", source: .group, isGroup: true, relevance: 0.3)
            }
        } catch { note("groups", error); return [] }
    }

    public func mailTips(_ addresses: [String], mailbox: String) async throws -> [MailTip] {
        guard !addresses.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: MailTipsRequest.body(addresses), options: [.sortedKeys])
        // Read-only POST: retried like a GET.
        let data = try await mail.send(mail.url("\(Self.p(mailbox))/getMailTips"), method: "POST", body: body, idempotent: true)
        return try Self.parseMailTips(data)
    }

    public static func parseMailTips(_ data: Data) throws -> [MailTip] {
        let page: GHPage<GCMailTip>
        do { page = try JSONDecoder().decode(GHPage<GCMailTip>.self, from: data) } catch { throw MailServiceError.http(200, "decode") }
        return page.value.compactMap { t in
            guard let a = t.emailAddress?.address, !a.isEmpty else { return nil }
            let oof = t.automaticReplies?.message.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return MailTip(address: a, automaticReply: oof, mailboxFull: t.mailboxFull ?? false,
                           externalMemberCount: t.externalMemberCount, totalMemberCount: t.totalMemberCount,
                           deliveryRestricted: t.deliveryRestricted ?? false, recipientScope: t.recipientScope,
                           error: t.error.map { $0.code ?? "error" })
        }
    }

    public func attachments(messageId: String, mailbox: String) async throws -> [DraftServerAttachment] {
        let page: GHPage<GCAttachment> = try await mail.get(mail.url("\(Self.p(mailbox))/messages/\(messageId)/attachments",
                                                                      ["$select": "id,name,contentType,size,isInline"]))
        return page.value.map { $0.model }
    }

    public func attachmentContent(messageId: String, attachment a: DraftServerAttachment, mailbox: String) async throws -> OutgoingAttachment? {
        guard a.kind == .file else { return nil }
        let data = try await mail.send(mail.url("\(Self.p(mailbox))/messages/\(messageId)/attachments/\(a.id)/$value"),
                                       method: "GET", body: nil, idempotent: true)
        return OutgoingAttachment(name: a.name, contentType: a.contentType, data: data)
    }

    public func deleteAttachment(messageId: String, attachmentId: String, mailbox: String) async throws {
        try await mail.send(mail.url("\(Self.p(mailbox))/messages/\(messageId)/attachments/\(attachmentId)"),
                            method: "DELETE", body: nil, idempotent: true)
    }
}

struct GCPerson: Decodable {
    struct A: Decodable { var address: String? }
    struct T: Decodable { var `class`: String?; var subclass: String? }
    var displayName: String?; var scoredEmailAddresses: [A]?; var userPrincipalName: String?; var personType: T?
}
struct GCGroup: Decodable { var displayName: String?; var mail: String?; var mailEnabled: Bool?; var groupTypes: [String]? }
struct GCMailTip: Decodable {
    struct Addr: Decodable { var address: String?; var name: String? }
    struct Auto: Decodable { var message: String? }
    struct Err: Decodable { var code: String?; var message: String? }
    var emailAddress: Addr?; var automaticReplies: Auto?; var mailboxFull: Bool?; var externalMemberCount: Int?
    var totalMemberCount: Int?; var deliveryRestricted: Bool?; var recipientScope: String?; var error: Err?
}
struct GCAttachment: Decodable {
    var id: String; var name: String?; var contentType: String?; var size: Int?; var isInline: Bool?; var type: String?
    enum CodingKeys: String, CodingKey { case id, name, contentType, size, isInline, type = "@odata.type" }
    var model: DraftServerAttachment {
        let t = (type ?? "").lowercased()
        let kind: DraftServerAttachment.Kind = t.hasSuffix("itemattachment") ? .item : t.hasSuffix("referenceattachment") ? .reference : .file
        return DraftServerAttachment(id: id, name: name ?? "attachment", contentType: contentType ?? "application/octet-stream",
                                     size: size ?? 0, isInline: isInline ?? false, kind: kind)
    }
}

/// Fixtures and the self-test: canned people (never the network). `ooo` in an address → automatic reply on;
/// `@external.example` → external; `all-staff@` → a 120-member list with 3 external members; `nobody@` → error.
public final class FixtureComposeService: ComposeService, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: [DraftServerAttachment]] = [:]
    public init(draftAttachments: [String: [DraftServerAttachment]] = [:]) { drafts = draftAttachments }

    public func recipients(_ query: String) async -> [RecipientSuggestion] {
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        let people = FixtureMailService.people.filter { $0.address.lowercased().contains(q) || $0.name.lowercased().contains(q) }
            .map { RecipientSuggestion(address: $0.address, name: $0.name, source: .people, relevance: 0.6) }
        let groups = [RecipientSuggestion(address: "all-staff@contoso.example", name: "All Staff", source: .group, isGroup: true, relevance: 0.3)]
            .filter { $0.address.contains(q) || $0.name.lowercased().contains(q) }
        return people + groups
    }

    public func mailTips(_ addresses: [String], mailbox: String) async throws -> [MailTip] {
        addresses.map { a in
            let l = a.lowercased()
            if l.hasPrefix("nobody@") { return MailTip(address: a, error: "ErrorInvalidRecipients") }
            if l.hasPrefix("all-staff@") { return MailTip(address: a, externalMemberCount: 3, totalMemberCount: 120, recipientScope: "internal") }
            return MailTip(address: a, automaticReply: l.contains("ooo") ? "<p>I'm away until Monday. For urgent matters contact the team.</p>" : nil,
                           recipientScope: l.hasSuffix("@external.example") ? "external" : "internal")
        }
    }

    public func attachments(messageId: String, mailbox: String) async throws -> [DraftServerAttachment] {
        lock.withLock { drafts[messageId] ?? [] }
    }

    public func attachmentContent(messageId: String, attachment a: DraftServerAttachment, mailbox: String) async throws -> OutgoingAttachment? {
        a.kind == .file ? OutgoingAttachment(name: a.name, contentType: a.contentType, data: Data(repeating: 0x41, count: max(1, min(a.size, 4096)))) : nil
    }

    public func deleteAttachment(messageId: String, attachmentId: String, mailbox: String) async throws {
        lock.withLock { drafts[messageId]?.removeAll { $0.id == attachmentId } }
    }
}
