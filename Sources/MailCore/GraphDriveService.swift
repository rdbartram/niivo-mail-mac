import Foundation
import CalendarCore

// MARK: - OneDrive "cloud attachments" for the composer (Outlook's "Share link" / "Upload and share")
//
// Checked on learn.microsoft.com (2026-11-19):
//  * `POST /me/drive/items/{id}/createLink` {type: view|edit, scope: anonymous|organization|users}: delegated
//    Files.ReadWrite least privilege. An omitted `scope` gives the TENANT DEFAULT (may be anonymous), so `scope` is
//    always sent. 201 = new link, 200 = an existing one. "Anonymous link support may be disabled by an administrator."
//  * `PUT /me/drive/items/{parent}:/{name}:/content` for small files (returns the driveItem);
//    `POST …:/{name}:/createUploadSession` {item: {"@microsoft.graph.conflictBehavior": "rename"}} for large ones,
//    then sequential PUTs to `uploadUrl`, each fragment a multiple of 320 KiB, < 60 MiB; the last answers 200/201
//    with the driveItem.
//  * `POST /drives/{d}/items/{i}/extractSensitivityLabels` → {labels: [{sensitivityLabelId, assignmentMethod,
//    tenantId}]}: delegated least privilege Files.Read.All (NOT Files.ReadWrite); both are in `Auth.driveScopes`.
//  * `GET /me/drive/sharedWithMe` is DEPRECATED ("degraded until November 2026, after which it will stop returning
//    data"); items carry `remoteItem`. Kept as a tab that may come back empty.
// UNVERIFIED (not on the fetched pages):
//  * `@microsoft.graph.conflictBehavior=rename` as a query parameter on the small-file PUT;
//  * no `Authorization` header on `uploadUrl` / `@microsoft.graph.downloadUrl` (pre-authenticated URLs);
//  * `POST /items/{id}/invite` {recipients, roles, requireSignIn: true, sendInvitation: false} granting access
//    without a notification mail (documented shape, not exercised against a tenant);
//  * `/me/drive/recent` and `root/search(q=…)` result shapes for remote items (`remoteItem.parentReference.driveId`).
//
// Nothing is persisted: listings, links and labels live in memory; file bytes only go through the existing
// attachment path (sealed draft storage) when the user picks "Attach a copy".

public struct DriveItem: Sendable, Hashable, Identifiable {
    /// The item id in its own drive (for remote items: `remoteItem.id`).
    public var id: String
    /// Owning drive (nil = the signed-in user's drive, addressed as `/me/drive`).
    public var driveId: String?
    public var name: String
    public var size: Int
    public var isFolder: Bool
    public var mimeType: String?
    public var webUrl: String?
    public var lastModified: Date?
    public var childCount: Int?
    public init(id: String, driveId: String? = nil, name: String, size: Int, isFolder: Bool = false, mimeType: String? = nil,
                webUrl: String? = nil, lastModified: Date? = nil, childCount: Int? = nil) {
        self.id = id; self.driveId = driveId; self.name = name; self.size = size; self.isFolder = isFolder
        self.mimeType = mimeType; self.webUrl = webUrl; self.lastModified = lastModified; self.childCount = childCount
    }
}

public struct DrivePage: Sendable {
    public var items: [DriveItem]
    public var nextLink: URL?
    public init(items: [DriveItem], nextLink: URL? = nil) { self.items = items; self.nextLink = nextLink }
}

public enum ShareLinkType: String, Sendable, Hashable, CaseIterable { case view, edit }

/// Ordered from narrowest to widest.
public enum ShareScope: String, Sendable, Hashable, CaseIterable {
    case users, organization, anonymous
    public var title: String {
        switch self { case .users: "Specific people"; case .organization: "People in your organisation"; case .anonymous: "Anyone with the link" }
    }
    /// The next narrower scope a refused request may fall back to (never wider). Only anonymous narrows on its own:
    /// "specific people" needs recipients, so an organisation refusal is reported, not silently changed.
    public var fallback: ShareScope? { self == .anonymous ? .organization : nil }
}

public struct SharingLink: Sendable, Hashable {
    public var url: String
    public var type: ShareLinkType
    public var scope: ShareScope
    public var permissionId: String?
    public init(url: String, type: ShareLinkType, scope: ShareScope, permissionId: String? = nil) {
        self.url = url; self.type = type; self.scope = scope; self.permissionId = permissionId
    }
}

/// What createLink actually granted (the server may hand back an existing link of another scope).
public struct ShareResult: Sendable, Hashable {
    public var link: SharingLink
    public var requested: ShareScope
    /// Set when the requested scope was refused and a narrower one was used instead.
    public var narrowedFrom: ShareScope?
    public var notice: String? {
        if let n = narrowedFrom {
            return "Your organisation doesn't allow “\(n.title)” links, so a “\(link.scope.title)” link was created instead."
        }
        if link.scope != requested { return "OneDrive returned a “\(link.scope.title)” link." }
        return nil
    }
}

public enum DriveFileLabel: Sendable, Hashable {
    case none
    case label(String)
    /// Couldn't be read (no consent, unsupported file, error) → warn, never "fine".
    case unknown
}

public enum DriveError: Error, Sendable, Equatable {
    case linkRefused(ShareScope)
    case tooLarge(String)
    case blocked(String)
    public var message: String {
        switch self {
        case .linkRefused(let s): "OneDrive refused a “\(s.title)” link for this file: your organisation may not allow it, or you may not be allowed to share this file."
        case .tooLarge(let m), .blocked(let m): m
        }
    }
}

public protocol DriveService: Sendable {
    /// nil = the root of the signed-in user's OneDrive.
    func children(of folder: DriveItem?) async throws -> DrivePage
    func recent() async throws -> DrivePage
    func sharedWithMe() async throws -> DrivePage
    func search(_ query: String) async throws -> DrivePage
    func nextPage(_ url: URL) async throws -> DrivePage
    /// File bytes. Refuses (before downloading) a file larger than `maxSize`.
    func download(_ item: DriveItem, maxSize: Int) async throws -> Data
    func createLink(_ item: DriveItem, type: ShareLinkType, scope: ShareScope) async throws -> SharingLink
    /// Grants named people access without a notification mail (requireSignIn, sendInvitation=false).
    func invite(_ item: DriveItem, emails: [String], type: ShareLinkType) async throws
    func deletePermission(_ item: DriveItem, permissionId: String) async throws
    /// Uploads into OneDrive › Attachments (renamed on conflict). Progress via `AttachmentProgress` under `progressId`.
    func upload(name: String, data: Data, progressId: UUID?) async throws -> DriveItem
    func sensitivityLabel(_ item: DriveItem) async -> DriveFileLabel
}

public extension DriveService {
    /// createLink with the scope rule: a refused anonymous link narrows to organisation (said out loud via
    /// `ShareResult.notice`); nothing ever widens.
    func share(_ item: DriveItem, type: ShareLinkType, scope: ShareScope) async throws -> ShareResult {
        var s = scope
        var narrowed: ShareScope?
        while true {
            do {
                let link = try await createLink(item, type: type, scope: s)
                return ShareResult(link: link, requested: scope, narrowedFrom: narrowed)
            } catch MailServiceError.forbidden {
                guard let f = s.fallback else { throw DriveError.linkRefused(s) }
                if narrowed == nil { narrowed = s }
                s = f
            }
        }
    }
}

// MARK: - Pure helpers

public enum DriveNames {
    /// OneDrive-safe file name: no path separators or reserved characters, no leading/trailing dots or spaces.
    public static func sanitise(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#%").union(.controlCharacters)
        var s = String(String.UnicodeScalarView(raw.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        if s.isEmpty { s = "attachment" }
        return String(s.prefix(200))
    }

    /// OData string literal inside `search(q='…')`: single quotes doubled.
    public static func searchLiteral(_ q: String) -> String { q.replacingOccurrences(of: "'", with: "''") }
}

public enum DriveUpload {
    /// Below this a single PUT …/content; at or above, an upload session.
    public static let simpleLimit = 4 * 1024 * 1024
    /// 16 × 320 KiB = 5 MiB, inside the documented 5–10 MiB recommendation, a multiple of 320 KiB.
    public static let chunkSize = 16 * 320 * 1024
    public static let folder = "Attachments"
    /// Typical Exchange Online message size limit; local attachments above it are offered "Upload and share".
    public static let messageLimitHint = 25 * 1024 * 1024
    public static func usesSession(_ size: Int) -> Bool { size >= simpleLimit }
    /// A local attachment should rather go as a OneDrive link.
    public static func suggestsCloud(size: Int) -> Bool { size >= messageLimitHint }
}

/// The body chip: "📄 Name · View" as rich-text link runs (the body is a `RichDoc`, so no raw HTML).
public enum CloudLinkChip {
    public static let icon = "📄"
    public static func verb(_ t: ShareLinkType) -> String { t == .edit ? "Edit" : "View" }

    /// nil when the URL isn't a safe https link.
    public static func block(name: String, link: SharingLink) -> RichBlock? {
        guard let url = RichHTML.safeLink(link.url), url.lowercased().hasPrefix("https://") else { return nil }
        return RichBlock(runs: [
            RichRun(icon + " "),
            RichRun(name, RichStyle(bold: true, link: url)),
            RichRun(" · "),
            RichRun(verb(link.type), RichStyle(link: url)),
        ])
    }

    public static func doc(name: String, link: SharingLink) -> RichDoc? { block(name: name, link: link).map { RichDoc([$0]) } }
}

/// File label vs mail label, using the reply floor's ranks (`LabelTree.floorRank`: sub-labels compare on the parent).
public enum CloudLabelCheck {
    public enum Outcome: Sendable, Equatable {
        case ok
        /// The file is labelled higher: offer to raise the mail to `labelId` (selectable).
        case raise(labelId: String, message: String)
        /// Higher, but its label can't be applied to mail as is (a group header): tell the user to pick one.
        case pickHigher(message: String)
        /// The file's label couldn't be read or isn't in the synced policy.
        case unknown(message: String)
    }

    public static func evaluate(file: DriveFileLabel, fileName: String, mailLabelId: String?, tree: LabelTree) -> Outcome {
        switch file {
        case .none: return .ok
        case .unknown:
            return .unknown(message: "The sensitivity label of “\(fileName)” couldn't be read. Check it before sending.")
        case .label(let id):
            guard let fileRank = tree.floorRank(id), let path = tree.path(id) else {
                return .unknown(message: "“\(fileName)” has a label that isn't in your synced label policy. Check it before sending.")
            }
            let mine = (mailLabelId?.isEmpty == false) ? tree.floorRank(mailLabelId) : nil
            if let mine, mine >= fileRank { return .ok }
            let msg = "“\(fileName)” is labelled “\(path)”, higher than this message's label."
            if tree.isSelectable(id) { return .raise(labelId: id, message: msg) }
            return .pickHigher(message: msg + " Choose a label at least as high.")
        }
    }

    /// Encrypted file + recipients outside the organisation (or an "Anyone" link): they may not be able to open it.
    public static func externalWarning(file: DriveFileLabel, tree: LabelTree, scope: ShareScope, hasExternalRecipients: Bool) -> String? {
        guard case .label(let id) = file, let l = tree.label(id), l.hasProtection else { return nil }
        guard hasExternalRecipients || scope == .anonymous else { return nil }
        return "“\(l.name)” encrypts this file: people outside your organisation may not be able to open it, and the label still controls who can."
    }
}

/// A shared OneDrive file shown as a chip under the editor and as a link in the body.
public struct CloudAttachment: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var item: DriveItem
    public var link: SharingLink
    public var label: DriveFileLabel
    public var notice: String?
    public init(id: UUID = UUID(), item: DriveItem, link: SharingLink, label: DriveFileLabel, notice: String? = nil) {
        self.id = id; self.item = item; self.link = link; self.label = label; self.notice = notice
    }
}

// MARK: - Graph implementation

public final class GraphDriveService: DriveService, @unchecked Sendable {
    private let http: GraphHTTP
    private let labels: GraphHTTP?
    private let session: URLSession
    static let select = "id,name,size,file,folder,webUrl,lastModifiedDateTime,parentReference,remoteItem"

    /// `token`: the drive set (Files.ReadWrite + Files.Read.All). `labelToken`: used for extractSensitivityLabels; nil → labels unknown.
    public init(token: @escaping GraphHTTP.TokenProvider, labelToken: GraphHTTP.TokenProvider?, session: URLSession = .shared) {
        http = GraphHTTP(token: token, session: session)
        labels = labelToken.map { GraphHTTP(token: $0, session: session) }
        self.session = session
    }

    func itemPath(_ i: DriveItem) -> String {
        if let d = i.driveId, !d.isEmpty { return "drives/\(d)/items/\(i.id)" }
        return "me/drive/items/\(i.id)"
    }

    func page(_ u: URL) async throws -> DrivePage {
        let p: GHPage<GDItem> = try await http.get(u)
        return DrivePage(items: p.value.compactMap { $0.model() }, nextLink: p.nextLink.flatMap(URL.init(string:)))
    }

    public func children(of folder: DriveItem?) async throws -> DrivePage {
        let path = folder.map { "\(itemPath($0))/children" } ?? "me/drive/root/children"
        return try await page(http.url(path, ["$top": "100", "$select": Self.select]))
    }
    public func recent() async throws -> DrivePage { try await page(http.url("me/drive/recent")) }
    public func sharedWithMe() async throws -> DrivePage { try await page(http.url("me/drive/sharedWithMe")) }
    public func search(_ query: String) async throws -> DrivePage {
        try await page(http.url("me/drive/root/search(q='\(DriveNames.searchLiteral(query))')", ["$top": "100"]))
    }
    public func nextPage(_ url: URL) async throws -> DrivePage {
        // Only follow Graph's own nextLink (the bearer must never go to another host).
        guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw MailServiceError.http(400, "foreign nextLink") }
        return try await page(url)
    }

    public func download(_ item: DriveItem, maxSize: Int) async throws -> Data {
        let meta: GDDownload = try await http.get(http.url(itemPath(item)))
        let size = meta.size ?? item.size
        if size > maxSize { throw DriveError.tooLarge("\(item.name) is larger than \(AttachmentUpload.formattedSize(maxSize)).") }
        guard let s = meta.downloadUrl, let u = URL(string: s), u.scheme == "https" else { throw MailServiceError.http(500, "no downloadUrl") }
        var req = URLRequest(url: u)   // pre-authenticated: no bearer
        req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw status == 403 ? MailServiceError.forbidden : MailServiceError.http(status, "download") }
        if data.count > maxSize { throw DriveError.tooLarge("\(item.name) is larger than \(AttachmentUpload.formattedSize(maxSize)).") }
        return data
    }

    static func createLinkJSON(type: ShareLinkType, scope: ShareScope) -> [String: Any] { ["type": type.rawValue, "scope": scope.rawValue] }

    public func createLink(_ item: DriveItem, type: ShareLinkType, scope: ShareScope) async throws -> SharingLink {
        let body = try JSONSerialization.data(withJSONObject: Self.createLinkJSON(type: type, scope: scope), options: [.sortedKeys])
        let data = try await http.send(http.url("\(itemPath(item))/createLink"), method: "POST", body: body, idempotent: false)
        guard let p = try? JSONDecoder().decode(GDPermission.self, from: data), let url = p.link?.webUrl else {
            throw MailServiceError.http(200, "decode")
        }
        // What was actually granted, not what was asked.
        return SharingLink(url: url, type: p.link?.type.flatMap(ShareLinkType.init(rawValue:)) ?? type,
                           scope: p.link?.scope.flatMap(ShareScope.init(rawValue:)) ?? scope, permissionId: p.id)
    }

    static func inviteJSON(emails: [String], type: ShareLinkType) -> [String: Any] {
        ["recipients": emails.map { ["email": $0] }, "roles": [type == .edit ? "write" : "read"],
         "requireSignIn": true, "sendInvitation": false]
    }

    public func invite(_ item: DriveItem, emails: [String], type: ShareLinkType) async throws {
        guard !emails.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: Self.inviteJSON(emails: emails, type: type), options: [.sortedKeys])
        try await http.send(http.url("\(itemPath(item))/invite"), method: "POST", body: body, idempotent: false)
    }

    public func deletePermission(_ item: DriveItem, permissionId: String) async throws {
        try await http.send(http.url("\(itemPath(item))/permissions/\(permissionId)"), method: "DELETE", body: nil, idempotent: true)
    }

    public func upload(name raw: String, data: Data, progressId: UUID?) async throws -> DriveItem {
        let name = DriveNames.sanitise(raw)
        let target = "me/drive/root:/\(DriveUpload.folder)/\(name):"
        if !DriveUpload.usesSession(data.count) {
            let out = try await http.send(http.url("\(target)/content", ["@microsoft.graph.conflictBehavior": "rename"]),
                                          method: "PUT", body: data, headers: ["Content-Type": "application/octet-stream"],
                                          idempotent: false)
            if let id = progressId { AttachmentProgress.shared.report(id, sent: data.count, total: data.count) }
            guard let item = (try? JSONDecoder().decode(GDItem.self, from: out))?.model() else { throw MailServiceError.http(200, "decode") }
            return item
        }
        let body = try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "rename", "name": name]],
                                              options: [.sortedKeys])
        let s = try JSONDecoder().decode(GMUploadSession.self,
                                         from: try await http.send(http.url("\(target)/createUploadSession"), method: "POST",
                                                                   body: body, idempotent: false))
        guard let up = URL(string: s.uploadUrl), up.scheme == "https" else { throw MailServiceError.http(500, "bad uploadUrl") }
        let total = data.count
        var last = Data()
        for r in AttachmentUpload.chunks(total: total, chunk: DriveUpload.chunkSize) {
            var req = URLRequest(url: up)   // pre-authenticated: no bearer
            req.httpMethod = "PUT"
            req.httpBody = data.subdata(in: r)
            req.setValue(AttachmentUpload.contentRange(r, total: total), forHTTPHeaderField: "Content-Range")
            req.setValue("\(r.count)", forHTTPHeaderField: "Content-Length")
            req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
            var attempt = 0
            while true {
                try Task.checkCancellation()
                let (d, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { last = d; break }
                if status >= 500 && attempt < 2 { attempt += 1; try await Task.sleep(for: .milliseconds(200 << attempt)); continue }
                switch status {
                case 401, 403: throw MailServiceError.forbidden
                case 404: throw MailServiceError.notFound
                case 409: throw MailServiceError.conflict
                default: throw MailServiceError.http(status, "upload \(AttachmentUpload.contentRange(r, total: total))")
                }
            }
            if let id = progressId { AttachmentProgress.shared.report(id, sent: r.upperBound, total: total) }
        }
        guard let item = (try? JSONDecoder().decode(GDItem.self, from: last))?.model() else { throw MailServiceError.http(200, "decode") }
        return item
    }

    public func sensitivityLabel(_ item: DriveItem) async -> DriveFileLabel {
        guard let labels else { return .unknown }
        guard let data = try? await labels.send(labels.url("\(itemPath(item))/extractSensitivityLabels"), method: "POST", body: nil,
                                                idempotent: true),
              let r = try? JSONDecoder().decode(GDLabels.self, from: data) else { return .unknown }
        let ids = (r.labels ?? []).compactMap(\.sensitivityLabelId).filter { !$0.isEmpty }
        return ids.first.map { .label($0) } ?? .none
    }
}

// MARK: - DTOs

struct GDRef: Decodable { var driveId: String? }
struct GDFile: Decodable { var mimeType: String? }
struct GDFolder: Decodable { var childCount: Int? }
struct GDRemote: Decodable {
    var id: String?; var name: String?; var size: Int?; var file: GDFile?; var folder: GDFolder?; var webUrl: String?
    var parentReference: GDRef?
}
struct GDItem: Decodable {
    var id: String?; var name: String?; var size: Int?; var file: GDFile?; var folder: GDFolder?; var webUrl: String?
    var lastModifiedDateTime: String?; var parentReference: GDRef?; var remoteItem: GDRemote?

    func model() -> DriveItem? {
        if let r = remoteItem, let rid = r.id {
            let folder = r.folder ?? self.folder
            return DriveItem(id: rid, driveId: r.parentReference?.driveId, name: r.name ?? name ?? "", size: r.size ?? size ?? 0,
                             isFolder: folder != nil, mimeType: (r.file ?? file)?.mimeType, webUrl: r.webUrl ?? webUrl,
                             lastModified: GraphMailService.parseISO(lastModifiedDateTime), childCount: folder?.childCount)
        }
        guard let id else { return nil }
        return DriveItem(id: id, driveId: parentReference?.driveId, name: name ?? "", size: size ?? 0, isFolder: folder != nil,
                         mimeType: file?.mimeType, webUrl: webUrl, lastModified: GraphMailService.parseISO(lastModifiedDateTime),
                         childCount: folder?.childCount)
    }
}
struct GDDownload: Decodable {
    var size: Int?; var downloadUrl: String?
    enum CodingKeys: String, CodingKey { case size, downloadUrl = "@microsoft.graph.downloadUrl" }
}
struct GDPermission: Decodable {
    struct L: Decodable { var webUrl: String?; var type: String?; var scope: String? }
    var id: String?; var link: L?
}
struct GDLabels: Decodable {
    struct A: Decodable { var sensitivityLabelId: String? }
    var labels: [A]?
}

// MARK: - Fixtures (synthetic, never the network)

public final class FixtureDriveService: DriveService, @unchecked Sendable {
    private let lock = NSLock()
    private var uploaded: [DriveItem] = []
    /// Synthetic label ids from the fixture label set (FixtureCalendarService.labels).
    static let confidential = "a1f0c4e2-0000-4000-8000-000000000003"
    static let highly = "a1f0c4e2-0000-4000-8000-000000000004"

    public init() {}

    static let folders = [DriveItem(id: "f-projects", name: "Projects", size: 0, isFolder: true, childCount: 2),
                          DriveItem(id: "f-attach", name: "Attachments", size: 0, isFolder: true, childCount: 0)]
    static let rootFiles = [
        DriveItem(id: "d-plan", name: "Q4 plan.docx", size: 182_000, mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                  webUrl: "https://contoso-my.sharepoint.example/personal/you/Q4%20plan.docx"),
        DriveItem(id: "d-budget", name: "Budget 2027.xlsx", size: 96_000, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                  webUrl: "https://contoso-my.sharepoint.example/personal/you/Budget%202027.xlsx"),
        DriveItem(id: "d-board", name: "Board pack (encrypted).pdf", size: 2_400_000, mimeType: "application/pdf",
                  webUrl: "https://contoso-my.sharepoint.example/personal/you/Board.pdf"),
    ]
    static let projectFiles = [
        DriveItem(id: "d-arch", name: "Architecture.pptx", size: 5_600_000, mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                  webUrl: "https://contoso-my.sharepoint.example/personal/you/Projects/Architecture.pptx"),
        DriveItem(id: "d-video", name: "Walkthrough.mp4", size: 180_000_000, mimeType: "video/mp4",
                  webUrl: "https://contoso-my.sharepoint.example/personal/you/Projects/Walkthrough.mp4"),
    ]

    public func children(of folder: DriveItem?) async throws -> DrivePage {
        switch folder?.id {
        case nil: return DrivePage(items: Self.folders + Self.rootFiles)
        case "f-projects": return DrivePage(items: Self.projectFiles)
        case "f-attach": return DrivePage(items: lock.withLock { uploaded })
        default: return DrivePage(items: [])
        }
    }
    public func recent() async throws -> DrivePage { DrivePage(items: [Self.rootFiles[0], Self.projectFiles[0]]) }
    public func sharedWithMe() async throws -> DrivePage {
        DrivePage(items: [DriveItem(id: "r-handbook", driveId: "b!partner", name: "Partner handbook.pdf", size: 830_000, mimeType: "application/pdf",
                                    webUrl: "https://contoso.sharepoint.example/sites/hr/Handbook.pdf")])
    }
    public func search(_ query: String) async throws -> DrivePage {
        let q = query.lowercased()
        return DrivePage(items: (Self.rootFiles + Self.projectFiles).filter { $0.name.lowercased().contains(q) })
    }
    public func nextPage(_ url: URL) async throws -> DrivePage { DrivePage(items: []) }
    public func download(_ item: DriveItem, maxSize: Int) async throws -> Data {
        if item.size > maxSize { throw DriveError.tooLarge("\(item.name) is larger than \(AttachmentUpload.formattedSize(maxSize)).") }
        return Data("Synthetic fixture content of \(item.name)\n".utf8)
    }
    public func createLink(_ item: DriveItem, type: ShareLinkType, scope: ShareScope) async throws -> SharingLink {
        if scope == .anonymous { throw MailServiceError.forbidden }   // the fixture tenant disallows "Anyone" links
        return SharingLink(url: "https://contoso-my.sharepoint.example/s/\(item.id)-\(type.rawValue)-\(scope.rawValue)",
                           type: type, scope: scope, permissionId: "perm-\(item.id)-\(type.rawValue)-\(scope.rawValue)")
    }
    public func invite(_ item: DriveItem, emails: [String], type: ShareLinkType) async throws {}
    public func deletePermission(_ item: DriveItem, permissionId: String) async throws {}
    public func upload(name: String, data: Data, progressId: UUID?) async throws -> DriveItem {
        let n = DriveNames.sanitise(name)
        let item = DriveItem(id: "u-\(UUID().uuidString.prefix(8))", name: n, size: data.count,
                             webUrl: "https://contoso-my.sharepoint.example/personal/you/Attachments/\(n)")
        lock.withLock { uploaded.append(item) }
        if let id = progressId { AttachmentProgress.shared.report(id, sent: data.count, total: data.count) }
        return item
    }
    public func sensitivityLabel(_ item: DriveItem) async -> DriveFileLabel {
        switch item.id {
        case "d-budget": .label(Self.confidential)
        case "d-board": .label(Self.highly)
        case "r-handbook": .unknown
        default: .none
        }
    }
}
