import Foundation
import CalendarCore

// NOTES-HOOK: "Log a note" on a person page → a OneNote page through Microsoft Graph (owner decision 2026-11-20:
// notes live in M365; Loop has no mature Graph API for page content).
//
// Placement: one notebook "niivo" in the user's OneDrive (found by name, created when missing), one section per
// organisation (or "People" without one), one page per note titled "<Person> · <yyyy-MM-dd>", simple HTML body.
//
// Graph (OneNote API, from the Learn reference as remembered; UNVERIFIED against a tenant):
//  * `GET /me/onenote/notebooks?$filter=displayName eq '…'`, `POST /me/onenote/notebooks {displayName}`
//    (name ≤ 128 chars, no ? * \ / : < > | ' ").
//  * `GET /me/onenote/notebooks/{id}/sections?$filter=displayName eq '…'`, `POST …/sections {displayName}`
//    (name ≤ 50 chars, no ? * \ / : < > | & # ' % ~).
//  * `POST /me/onenote/sections/{id}/pages` with `Content-Type: text/html`; the page title is the HTML `<title>`;
//    the 201 response carries `id` and `links.oneNoteClientUrl.href` / `links.oneNoteWebUrl.href`.
//  * Delegated Notes.ReadWrite (`Auth.notesScopes`, own incremental consent set).
//
// LABELS: OneNote pages carry no per-page sensitivity label. The notebook lives in the user's OneDrive, so it follows
// that location's policy (a default library label / DLP if the tenant set one). The UI says so quietly.
// Locally only the page id, the person's address, the title, the time and the links are kept, sealed per account in
// the knowledge tables (`KnowledgeEngine.putNote`); the note text is never stored on the Mac.

public struct OneNotePageRef: Sendable, Hashable {
    public var id: String
    public var webUrl: URL?
    public var clientUrl: URL?
    public init(id: String, webUrl: URL? = nil, clientUrl: URL? = nil) { self.id = id; self.webUrl = webUrl; self.clientUrl = clientUrl }
}

public protocol OneNoteService: Sendable {
    func findNotebook(named: String) async throws -> String?
    func createNotebook(named: String) async throws -> String
    func findSection(named: String, notebookId: String) async throws -> String?
    func createSection(named: String, notebookId: String) async throws -> String
    func createPage(sectionId: String, html: String) async throws -> OneNotePageRef
}

public struct PeopleNoteRecord: Codable, Sendable, Hashable, Identifiable {
    public var pageId: String
    public var address: String
    public var title: String
    public var at: Date
    public var webUrl: String?
    public var clientUrl: String?
    public var id: String { pageId }
    public init(pageId: String, address: String, title: String, at: Date, webUrl: String? = nil, clientUrl: String? = nil) {
        self.pageId = pageId; self.address = address.lowercased(); self.title = title; self.at = at
        self.webUrl = webUrl; self.clientUrl = clientUrl
    }
}

public enum PeopleNotes {
    public static let notebookName = "niivo"
    public static let defaultSection = "People"

    /// A legal section name: forbidden characters dropped, whitespace collapsed, ≤ 50 characters.
    public static func sectionName(org: String?) -> String {
        let bad = Set("?*\\/:<>|&#'%~\"")
        let s = (org ?? "").filter { !bad.contains($0) }
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return s.isEmpty ? defaultSection : String(s.prefix(50)).trimmingCharacters(in: .whitespaces)
    }

    public static func pageTitle(person: String, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return person + " · " + String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    public static func escape(_ s: String) -> String {
        var o = ""
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(ch)
            }
        }
        return o
    }

    /// Simple page HTML: title, created time, one paragraph per line, and who it is about.
    public static func html(title: String, text: String, address: String, at: Date) -> String {
        let created = ISO8601DateFormatter().string(from: at)
        let paras = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { "<p>\(escape($0))</p>" }.joined()
        return "<!DOCTYPE html><html><head><title>\(escape(title))</title><meta name=\"created\" content=\"\(created)\" /></head>"
            + "<body>\(paras)<p style=\"color:#888\">\(escape(address))</p></body></html>"
    }

    /// Finds or creates the notebook and section, then creates the page. Nothing is retried blindly: a create that
    /// failed after the server accepted it would duplicate the page.
    public static func log(_ service: OneNoteService, person: String, address: String, org: String?, text: String,
                           at: Date = Date(), calendar: Calendar = .current) async throws -> PeopleNoteRecord {
        let nb: String
        if let id = try await service.findNotebook(named: notebookName) { nb = id } else { nb = try await service.createNotebook(named: notebookName) }
        let sName = sectionName(org: org)
        let sec: String
        if let id = try await service.findSection(named: sName, notebookId: nb) { sec = id } else { sec = try await service.createSection(named: sName, notebookId: nb) }
        let title = pageTitle(person: person, date: at, calendar: calendar)
        let page = try await service.createPage(sectionId: sec, html: html(title: title, text: text, address: address, at: at))
        return PeopleNoteRecord(pageId: page.id, address: address, title: title, at: at,
                                webUrl: page.webUrl?.absoluteString, clientUrl: page.clientUrl?.absoluteString)
    }

    /// OData string literal: single quotes doubled.
    static func odata(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
}

// MARK: - Graph implementation

public final class GraphOneNoteService: OneNoteService, @unchecked Sendable {
    private let http: GraphHTTP

    /// `token`: Notes.ReadWrite (`Auth.notesScopes`), silent only; the app asks for consent ("Connect OneNote").
    public init(token: @escaping GraphHTTP.TokenProvider, session: URLSession = .shared) {
        http = GraphHTTP(token: token, session: session)
    }

    struct Named: Decodable { var id: String; var displayName: String? }
    struct Page: Decodable {
        struct Link: Decodable { var href: String? }
        struct Links: Decodable { var oneNoteClientUrl: Link?; var oneNoteWebUrl: Link? }
        var id: String; var links: Links?
    }

    public func findNotebook(named: String) async throws -> String? {
        let p: GHPage<Named> = try await http.get(http.url("me/onenote/notebooks", ["$filter": "displayName eq \(PeopleNotes.odata(named))", "$select": "id,displayName"]))
        return p.value.first { $0.displayName == named }?.id
    }

    public func createNotebook(named: String) async throws -> String {
        let d = try await http.send(http.url("me/onenote/notebooks"), method: "POST",
                                    body: try JSONSerialization.data(withJSONObject: ["displayName": named]), idempotent: false)
        do { return try JSONDecoder().decode(GHId.self, from: d).id } catch { throw MailServiceError.http(201, "decode") }
    }

    public func findSection(named: String, notebookId: String) async throws -> String? {
        let p: GHPage<Named> = try await http.get(http.url("me/onenote/notebooks/\(notebookId)/sections",
                                                          ["$filter": "displayName eq \(PeopleNotes.odata(named))", "$select": "id,displayName"]))
        return p.value.first { $0.displayName == named }?.id
    }

    public func createSection(named: String, notebookId: String) async throws -> String {
        let d = try await http.send(http.url("me/onenote/notebooks/\(notebookId)/sections"), method: "POST",
                                    body: try JSONSerialization.data(withJSONObject: ["displayName": named]), idempotent: false)
        do { return try JSONDecoder().decode(GHId.self, from: d).id } catch { throw MailServiceError.http(201, "decode") }
    }

    public func createPage(sectionId: String, html: String) async throws -> OneNotePageRef {
        let d = try await http.send(http.url("me/onenote/sections/\(sectionId)/pages"), method: "POST", body: Data(html.utf8),
                                    headers: ["Content-Type": "text/html"], idempotent: false)
        guard let p = try? JSONDecoder().decode(Page.self, from: d) else { throw MailServiceError.http(201, "decode") }
        return OneNotePageRef(id: p.id, webUrl: p.links?.oneNoteWebUrl?.href.flatMap(URL.init(string:)),
                              clientUrl: p.links?.oneNoteClientUrl?.href.flatMap(URL.init(string:)))
    }
}
