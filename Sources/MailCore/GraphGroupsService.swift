import Foundation
import CalendarCore

// MARK: - Microsoft 365 Groups (Unified groups): membership, conversations, threads, posts
//
// Checked on learn.microsoft.com (2026-11-19):
//  * `GET /me/memberOf/microsoft.graph.group?$filter=groupTypes/any(c:c eq 'Unified')`: delegated least privilege
//    User.Read for /me; `$filter` on memberOf is an advanced query → `ConsistencyLevel: eventual` + `$count=true`.
//  * `GET /groups/{id}/conversations`, `/conversations/{id}/threads`, `/threads/{id}/posts`: delegated least
//    privilege Group-Conversation.Read.All (admin consent). `$expand` supported on list posts (one relationship).
//  * `POST /groups/{id}/threads/{id}/reply` (202, no body) and `POST /groups/{id}/conversations`: delegated
//    Group.ReadWrite.All only (admin consent).
//  * The `post` resource has `singleValueExtendedProperties`; `GET …/posts/{id}?$expand=singleValueExtendedProperties(
//    $filter=id eq '…')` is documented. So posts CAN carry the msip_labels header → labels are read like mail and an
//    unreadable label fails closed (see `GroupPostLabel`).
//  * `unseenCount` is returned only on `GET /groups/{id}?$select=unseenCount` (signed-in user's count).
// UNVERIFIED against a tenant:
//  * that the msip_labels property id used for messages comes back on posts (same MAPI named property; posts are
//    Exchange items in the group mailbox, so expected);
//  * that list posts accepts the `$expand` with a `$filter` (fallback: per-post GET with the expand, then unknown).
//
// Nothing here is persisted: group lists, conversations and posts live in memory only (no new plaintext cache).

public struct M365Group: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var mail: String?
    /// Conversations with new posts since the signed-in user last visited (server count; nil = unknown).
    public var unseenCount: Int?
    public init(id: String, displayName: String, mail: String?, unseenCount: Int? = nil) {
        self.id = id; self.displayName = displayName; self.mail = mail; self.unseenCount = unseenCount
    }
}

public struct GroupConversation: Sendable, Hashable, Identifiable {
    public var id: String
    public var topic: String
    public var preview: String
    public var lastDelivered: Date?
    public var hasAttachments: Bool
    public var senders: [String]
    public init(id: String, topic: String, preview: String, lastDelivered: Date?, hasAttachments: Bool, senders: [String]) {
        self.id = id; self.topic = topic; self.preview = preview; self.lastDelivered = lastDelivered
        self.hasAttachments = hasAttachments; self.senders = senders
    }
}

public struct GroupThread: Sendable, Hashable, Identifiable {
    public var id: String
    public var topic: String
    public var lastDelivered: Date?
    public init(id: String, topic: String, lastDelivered: Date?) { self.id = id; self.topic = topic; self.lastDelivered = lastDelivered }
}

/// What we know about a post's sensitivity label.
public enum GroupPostLabel: Sendable, Hashable {
    /// The label property was asked for and isn't there (or is another organisation's / disabled, as for mail).
    case none
    case label(String)
    /// The label property couldn't be read → fail closed (treated as a label we have no definition for).
    case unknown
}

public struct GroupPost: Sendable, Hashable, Identifiable {
    public var id: String
    public var threadId: String
    public var from: EmailAddress?
    public var sender: EmailAddress?
    public var received: Date?
    public var body: String
    public var bodyIsHTML: Bool
    public var hasAttachments: Bool
    public var label: GroupPostLabel
    public init(id: String, threadId: String, from: EmailAddress?, sender: EmailAddress?, received: Date?, body: String,
                bodyIsHTML: Bool, hasAttachments: Bool, label: GroupPostLabel) {
        self.id = id; self.threadId = threadId; self.from = from; self.sender = sender; self.received = received
        self.body = body; self.bodyIsHTML = bodyIsHTML; self.hasAttachments = hasAttachments; self.label = label
    }
}

public protocol GroupsService: Sendable {
    func myGroups() async throws -> [M365Group]
    func unseenCount(groupId: String) async throws -> Int?
    func conversations(groupId: String, top: Int) async throws -> [GroupConversation]
    func threads(groupId: String, conversationId: String) async throws -> [GroupThread]
    func posts(groupId: String, threadId: String) async throws -> [GroupPost]
    /// Sends immediately (Graph has no draft for posts). Callers must go through the app's explicit send + undo flow.
    func reply(groupId: String, threadId: String, html: String) async throws
    /// Sends immediately. Same rule as `reply`.
    func newConversation(groupId: String, topic: String, html: String) async throws
}

// MARK: - Policy for posts (same label core as mail)

public enum GroupPostPolicy {
    /// Stand-in id for "label property unreadable": never a real label, so the engine fails closed on it.
    public static let unreadableLabelId = "unreadable-post-label"

    /// Group content is someone else's mailbox (the group's), so `.shared` access, as for a shared calendar.
    public static func policy(for p: GroupPost, engine: CachedLabelPolicyEngine) -> ContentPolicy {
        let id: String? = switch p.label { case .none: nil; case .label(let l): l; case .unknown: unreadableLabelId }
        return engine.policy(labelId: id, isPrivate: false, access: .shared, itemId: p.id)
    }

    public static let labelledReplyReason =
        "Replying to a labelled group conversation isn't supported yet: the label can't be applied to a group post, so the reply would leave unlabelled."

    /// Reply only to a thread whose posts are all unlabelled and allow REPLY. A labelled thread is refused (the post
    /// API can't carry our label, so a reply would downgrade it); an unreadable label is refused (fail closed).
    public static func replyRefusal(posts: [GroupPost], engine: CachedLabelPolicyEngine) -> String? {
        for p in posts {
            let pol = policy(for: p, engine: engine)
            if pol.labelState != .unlabeled { return labelledReplyReason }
            if !pol.allowReply { return MailActionRights.deniedReason }
        }
        return nil
    }
}

// MARK: - Graph implementation

public final class GraphGroupsService: GroupsService, @unchecked Sendable {
    let read: GraphHTTP   // ORG2-HOOK: internal for GraphGroupsService+Manage.swift
    let write: GraphHTTP
    static let labelExpand = "singleValueExtendedProperties($filter=id eq '\(MIPMetadata.extendedPropertyId)')"
    static let postSelect = "id,from,sender,receivedDateTime,body,hasAttachments"

    /// `readToken`: Group-Conversation.Read.All (+ User.Read). `writeToken`: Group.ReadWrite.All, asked only when the
    /// user first posts (incremental consent).
    public init(readToken: @escaping GraphHTTP.TokenProvider, writeToken: @escaping GraphHTTP.TokenProvider,
                session: URLSession = .shared) {
        read = GraphHTTP(token: readToken, session: session)
        write = GraphHTTP(token: writeToken, session: session)
    }

    public func myGroups() async throws -> [M365Group] {
        var out: [M365Group] = []
        var next: URL? = read.url("me/memberOf/microsoft.graph.group", [
            "$filter": "groupTypes/any(c:c eq 'Unified')", "$count": "true", "$top": "100",
            "$select": "id,displayName,mail",
        ])
        while let u = next {
            let page: GHPage<GGGroup> = try await read.get(u, headers: ["ConsistencyLevel": "eventual"])
            out += page.value.map { M365Group(id: $0.id, displayName: $0.displayName ?? "", mail: $0.mail) }
            next = page.nextLink.flatMap(URL.init(string:))
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func unseenCount(groupId: String) async throws -> Int? {
        let g: GGGroup = try await read.get(read.url("groups/\(groupId)", ["$select": "unseenCount"]))
        return g.unseenCount
    }

    public func conversations(groupId: String, top: Int) async throws -> [GroupConversation] {
        let page: GHPage<GGConversation> = try await read.get(read.url("groups/\(groupId)/conversations", ["$top": "\(top)"]))
        return page.value.map {
            GroupConversation(id: $0.id, topic: $0.topic ?? "", preview: $0.preview ?? "",
                              lastDelivered: GraphMailService.parseISO($0.lastDeliveredDateTime),
                              hasAttachments: $0.hasAttachments ?? false, senders: $0.uniqueSenders ?? [])
        }.sorted { ($0.lastDelivered ?? .distantPast) > ($1.lastDelivered ?? .distantPast) }
    }

    public func threads(groupId: String, conversationId: String) async throws -> [GroupThread] {
        let page: GHPage<GGThread> = try await read.get(read.url("groups/\(groupId)/conversations/\(conversationId)/threads"))
        return page.value.map { GroupThread(id: $0.id, topic: $0.topic ?? "", lastDelivered: GraphMailService.parseISO($0.lastDeliveredDateTime)) }
            .sorted { ($0.lastDelivered ?? .distantPast) < ($1.lastDelivered ?? .distantPast) }
    }

    public func posts(groupId: String, threadId: String) async throws -> [GroupPost] {
        let path = "groups/\(groupId)/threads/\(threadId)/posts"
        do {
            let page: GHPage<GGPost> = try await read.get(read.url(path, ["$select": Self.postSelect, "$expand": Self.labelExpand]))
            return page.value.map { $0.toModel(threadId: threadId, labelKnown: true) }.sorted(by: Self.oldestFirst)
        } catch MailServiceError.http(400, _) {
            // The list rejected the expand: fetch the label per post (documented on GET post); a post whose label
            // still can't be read fails closed.
            let page: GHPage<GGPost> = try await read.get(read.url(path, ["$select": Self.postSelect]))
            var out: [GroupPost] = []
            for p in page.value {
                if let one: GGPost = try? await read.get(read.url("\(path)/\(p.id)", ["$select": "id", "$expand": Self.labelExpand])) {
                    var m = p; m.singleValueExtendedProperties = one.singleValueExtendedProperties ?? []
                    out.append(m.toModel(threadId: threadId, labelKnown: true))
                } else {
                    out.append(p.toModel(threadId: threadId, labelKnown: false))
                }
            }
            return out.sorted(by: Self.oldestFirst)
        }
    }

    static func oldestFirst(_ a: GroupPost, _ b: GroupPost) -> Bool { (a.received ?? .distantPast) < (b.received ?? .distantPast) }

    static func bodyJSON(_ html: String) -> [String: Any] { ["contentType": "html", "content": html] }

    public func reply(groupId: String, threadId: String, html: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["post": ["body": Self.bodyJSON(html)]], options: [.sortedKeys])
        try await write.send(write.url("groups/\(groupId)/threads/\(threadId)/reply"), method: "POST", body: body, idempotent: false)
    }

    public func newConversation(groupId: String, topic: String, html: String) async throws {
        let json: [String: Any] = ["topic": topic, "threads": [["posts": [["body": Self.bodyJSON(html)]]]]]
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try await write.send(write.url("groups/\(groupId)/conversations"), method: "POST", body: body, idempotent: false)
    }
}

struct GGGroup: Decodable { var id: String; var displayName: String?; var mail: String?; var unseenCount: Int? }
struct GGConversation: Decodable {
    var id: String; var topic: String?; var preview: String?; var lastDeliveredDateTime: String?
    var hasAttachments: Bool?; var uniqueSenders: [String]?
}
struct GGThread: Decodable { var id: String; var topic: String?; var lastDeliveredDateTime: String? }
struct GGPost: Decodable {
    struct Body: Decodable { var contentType: String?; var content: String? }
    struct Prop: Decodable { var id: String; var value: String? }
    var id: String
    var from: GMAddr?; var sender: GMAddr?
    var receivedDateTime: String?
    var body: Body?
    var hasAttachments: Bool?
    var singleValueExtendedProperties: [Prop]?

    /// `labelKnown`: the label property was asked for. Then absent = unlabelled; else unknown (fail closed).
    func toModel(threadId: String, labelKnown: Bool) -> GroupPost {
        let label: GroupPostLabel
        if !labelKnown { label = .unknown }
        else if let raw = singleValueExtendedProperties?.first(where: { $0.id.lowercased().contains("msip_labels") })?.value {
            label = MIPMetadata.activeLabelId(in: raw).map { .label($0) } ?? .none
        } else { label = .none }
        return GroupPost(id: id, threadId: threadId, from: GMMessage.addr(from), sender: GMMessage.addr(sender),
                         received: GraphMailService.parseISO(receivedDateTime), body: body?.content ?? "",
                         bodyIsHTML: (body?.contentType ?? "html").lowercased() == "html",
                         hasAttachments: hasAttachments ?? false, label: label)
    }
}

// MARK: - Fixtures

/// Synthetic groups for fixtures mode and the self-test. Posts are recorded in memory, never sent anywhere.
public final class FixtureGroupsService: GroupsService, @unchecked Sendable {
    public struct Sent: Sendable, Equatable { public var groupId: String; public var threadId: String?; public var topic: String?; public var html: String }
    private let lock = NSLock()
    private var _sent: [Sent] = []
    public var sent: [Sent] { lock.withLock { _sent } }
    public static let projectGroup = "grp-project", allHands = "grp-allhands"

    public init() {}

    public func myGroups() async throws -> [M365Group] {
        [M365Group(id: Self.allHands, displayName: "All Hands", mail: "allhands@contoso.example"),
         M365Group(id: Self.projectGroup, displayName: "Project Falcon", mail: "falcon@contoso.example")]
    }

    public func unseenCount(groupId: String) async throws -> Int? { groupId == Self.projectGroup ? 2 : 0 }

    public func conversations(groupId: String, top: Int) async throws -> [GroupConversation] {
        let now = Date()
        if groupId == Self.allHands {
            return [GroupConversation(id: "conv-ah-1", topic: "Office move on Friday", preview: "Bring your laptop chargers.",
                                      lastDelivered: now.addingTimeInterval(-7200), hasAttachments: false, senders: ["Alex Morgan"])]
        }
        return [
            GroupConversation(id: "conv-pf-1", topic: "Kick-off notes", preview: "Notes from Monday's kick-off.",
                              lastDelivered: now.addingTimeInterval(-3600), hasAttachments: false, senders: ["Priya Natarajan", "You"]),
            GroupConversation(id: "conv-pf-2", topic: "Budget (confidential)", preview: "",
                              lastDelivered: now.addingTimeInterval(-86400), hasAttachments: true, senders: ["Jordan Lee"]),
            GroupConversation(id: "conv-pf-3", topic: "Forwarded supplier mail", preview: "",
                              lastDelivered: now.addingTimeInterval(-2 * 86400), hasAttachments: false, senders: ["Alex Morgan"]),
        ]
    }

    public func threads(groupId: String, conversationId: String) async throws -> [GroupThread] {
        [GroupThread(id: "th-" + conversationId, topic: "", lastDelivered: nil)]
    }

    public func posts(groupId: String, threadId: String) async throws -> [GroupPost] {
        let t = Date().addingTimeInterval(-3600)
        let alex = EmailAddress(name: "Alex Morgan", address: "alex@contoso.example")
        let priya = EmailAddress(name: "Priya Natarajan", address: "priya@fabrikam.example")
        switch threadId {
        case "th-conv-pf-2":
            return [GroupPost(id: "post-budget", threadId: threadId, from: EmailAddress(name: "Jordan Lee", address: "jordan@fabrikam.example"),
                              sender: nil, received: t, body: "<p>Budget figures attached.</p>", bodyIsHTML: true, hasAttachments: true,
                              label: .label(FixtureMailService.labelConfidential))]
        case "th-conv-pf-3":
            return [GroupPost(id: "post-unknown", threadId: threadId, from: alex, sender: nil, received: t,
                              body: "<p>Supplier terms.</p>", bodyIsHTML: true, hasAttachments: false, label: .unknown)]
        case "th-conv-ah-1":
            return [GroupPost(id: "post-ah", threadId: threadId, from: alex, sender: nil, received: t,
                              body: "<p>Bring your laptop chargers. <img src=\"https://tracker.example/p.gif\"></p>", bodyIsHTML: true,
                              hasAttachments: false, label: .none)]
        default:
            return [
                GroupPost(id: "post-kick-1", threadId: threadId, from: priya, sender: nil, received: t,
                          body: "<p>Notes from Monday's kick-off.</p>", bodyIsHTML: true, hasAttachments: false, label: .none),
                GroupPost(id: "post-kick-2", threadId: threadId, from: FixtureMailService.me, sender: nil, received: t.addingTimeInterval(600),
                          body: "<p>Thanks, I'll pick up the timeline.</p>", bodyIsHTML: true, hasAttachments: false, label: .none),
            ]
        }
    }

    public func reply(groupId: String, threadId: String, html: String) async throws {
        lock.withLock { _sent.append(Sent(groupId: groupId, threadId: threadId, topic: nil, html: html)) }
    }

    public func newConversation(groupId: String, topic: String, html: String) async throws {
        lock.withLock { _sent.append(Sent(groupId: groupId, threadId: nil, topic: topic, html: html)) }
    }
}
