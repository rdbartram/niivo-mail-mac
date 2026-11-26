import Foundation

/// Fetches the encrypted payload of a protected message or event from Graph. Bytes stay in memory.
/// Strategy (both paths UNVERIFIED against a live tenant, the probe reports which one worked):
///  1. `GET /{mailbox}/{messages|events}/{id}/attachments?$select=id,name,contentType,size` → the attachment that
///     looks like an rpmsg → `GET …/attachments/{aid}/$value` (raw bytes;
///     https://learn.microsoft.com/graph/api/attachment-get?view=graph-rest-1.0).
///  2. Messages only: `GET /{mailbox}/messages/{id}/$value` (MIME; https://learn.microsoft.com/graph/outlook-get-mime-message)
///     → the rpmsg part.
public struct RPMSGFetcher: Sendable {
    public enum Kind: String, Sendable { case message = "messages", event = "events" }
    public enum Path: String, Sendable { case attachment, mime }
    public enum FetchError: Error, Sendable, CustomStringConvertible {
        case http(Int, step: String)
        case notFound
        public var description: String {
            switch self { case .http(let c, let s): "http \(c) at \(s)"; case .notFound: "no-rpmsg-found" }
        }
    }

    public var base = URL(string: "https://graph.microsoft.com/v1.0/")!
    public var session: URLSession = .shared
    public var graphToken: @Sendable () async throws -> String

    public init(graphToken: @escaping @Sendable () async throws -> String) { self.graphToken = graphToken }

    public func fetch(id: String, mailbox: String = "me", kind: Kind = .message) async throws -> (data: Data, path: Path) {
        let root = mailbox == "me" ? "me" : "users/\(mailbox)"
        let item = "\(root)/\(kind.rawValue)/\(id)"
        struct Att: Decodable { var id: String; var name: String?; var contentType: String? }
        struct Page: Decodable { var value: [Att] }
        let (listData, listStatus) = try await get("\(item)/attachments", query: ["$select": "id,name,contentType,size"])
        if listStatus == 200, let page = try? JSONDecoder().decode(Page.self, from: listData),
           let att = page.value.first(where: { RPMSG.isRPMSGAttachment(name: $0.name, contentType: $0.contentType) }) {
            let (raw, st) = try await get("\(item)/attachments/\(att.id)/$value")
            guard st == 200 else { throw FetchError.http(st, step: "attachment-value") }
            return (raw, .attachment)
        }
        guard kind == .message else {
            if listStatus != 200 { throw FetchError.http(listStatus, step: "attachments") }
            throw FetchError.notFound
        }
        let (mime, st) = try await get("\(item)/$value")
        guard st == 200 else { throw FetchError.http(st, step: "mime") }
        guard let data = RPMSG.extract(fromMIME: mime) else { throw FetchError.notFound }
        return (data, .mime)
    }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> (Data, Int) {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(try await graphToken())", forHTTPHeaderField: "Authorization")
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        // Don't let URLSession cache protected payloads on disk.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cfgSession: URLSession = session === URLSession.shared ? Self.ephemeral : session
        let (d, r) = try await cfgSession.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// No URL cache, no cookie store on disk.
    static let ephemeral: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        return URLSession(configuration: c)
    }()
}
