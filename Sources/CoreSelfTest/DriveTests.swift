import Foundation
import CalendarCore
import MailCore

/// OneDrive cloud attachments: GraphDriveService against the URLProtocol stub + the pure label / chip rules.
@MainActor
func runDriveTests() async {
    section("OneDrive attachments: browse, share links, upload, link chip, label check (stub)")
    let headers = HeaderLog()
    MailStub.log = []
    MailStub.handler = { req, body in
        let u = req.url!, path = u.path, q = u.query ?? ""
        headers.add((u.host ?? "") + path, req.allHTTPHeaderFields ?? [:])
        switch (req.httpMethod ?? "GET", u.host ?? "", path) {
        case ("GET", _, "/v1.0/me/drive/root/children"):
            if q.contains("skiptoken=p2") {
                return (200, [:], #"{"value":[{"id":"c3","name":"c.txt","size":3,"file":{"mimeType":"text/plain"}}]}"#)
            }
            return (200, [:], #"{"value":[{"id":"f1","name":"Docs","folder":{"childCount":1}},{"id":"c1","name":"a.docx","size":10,"file":{}}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=p2"}"#)
        case ("GET", _, "/v1.0/me/drive/items/f1/children"):
            return (200, [:], #"{"value":[{"id":"c2","name":"b.pdf","size":5,"file":{"mimeType":"application/pdf"}}]}"#)
        case ("GET", _, "/v1.0/me/drive/recent"):
            return (200, [:], #"{"value":[{"id":"local-r","name":"r.xlsx","remoteItem":{"id":"rem1","name":"r.xlsx","size":9,"file":{},"parentReference":{"driveId":"b!other"}}}]}"#)
        case ("GET", _, "/v1.0/me/drive/root/search(q='it''s')"):
            return (200, [:], #"{"value":[{"id":"s1","name":"it's.txt","size":1,"file":{}}]}"#)
        case ("POST", _, "/v1.0/drives/b!other/items/rem1/createLink"),
             ("POST", _, "/v1.0/me/drive/items/c1/createLink"):
            let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
            if o["scope"] as? String == "anonymous" { return (403, [:], #"{"error":{"code":"accessDenied","message":"secret"}}"#) }
            return (201, [:], #"{"id":"perm1","link":{"type":"\#(o["type"] as? String ?? "")","scope":"\#(o["scope"] as? String ?? "")","webUrl":"https://contoso-my.sharepoint.example/:w:/g/abc"}}"#)
        case ("POST", _, "/v1.0/me/drive/items/c2/createLink"):
            return (403, [:], #"{"error":{"code":"accessDenied"}}"#)
        case ("POST", _, "/v1.0/me/drive/items/c1/invite"):
            return (200, [:], #"{"value":[]}"#)
        case ("PUT", _, "/v1.0/me/drive/root:/Attachments/small_name.txt:/content"):
            return (201, [:], #"{"id":"up-s","name":"small_name.txt","size":5,"file":{}}"#)
        case ("POST", _, "/v1.0/me/drive/root:/Attachments/big.bin:/createUploadSession"):
            return (200, [:], #"{"uploadUrl":"https://upload.example/up/sess1"}"#)
        case ("PUT", "upload.example", "/up/sess1"):
            let range = req.value(forHTTPHeaderField: "Content-Range") ?? ""
            if range.hasSuffix("-\(DriveUpload.chunkSize + 99)/\(DriveUpload.chunkSize + 100)") {
                return (201, [:], #"{"id":"up-b","name":"big.bin","size":\#(DriveUpload.chunkSize + 100),"file":{}}"#)
            }
            return (202, [:], #"{"nextExpectedRanges":["x-"]}"#)
        case ("GET", _, "/v1.0/me/drive/items/c1"):
            return (200, [:], #"{"id":"c1","size":10,"@microsoft.graph.downloadUrl":"https://download.example/dl/c1"}"#)
        case ("GET", _, "/v1.0/me/drive/items/huge"):
            return (200, [:], #"{"id":"huge","size":999999999,"@microsoft.graph.downloadUrl":"https://download.example/dl/huge"}"#)
        case ("GET", "download.example", "/dl/c1"):
            return (200, [:], "0123456789")
        case ("POST", _, "/v1.0/me/drive/items/c1/extractSensitivityLabels"):
            return (200, [:], #"{"labels":[{"sensitivityLabelId":"a1f0c4e2-0000-4000-8000-000000000003","assignmentMethod":"standard","tenantId":"t"}]}"#)
        case ("POST", _, "/v1.0/me/drive/items/c2/extractSensitivityLabels"):
            return (403, [:], #"{"error":{"code":"accessDenied"}}"#)
        default:
            return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let session = URLSession(configuration: cfg)
    let svc = GraphDriveService(token: { "drive-t" }, labelToken: { "label-t" }, session: session)

    // Browse + paging
    do {
        let p1 = try await svc.children(of: nil)
        check(p1.items.count == 2 && p1.items[0].isFolder && p1.items[0].childCount == 1 && p1.nextLink != nil, "root children: folder + file, nextLink kept")
        let p2 = try await svc.nextPage(p1.nextLink!)
        check(p2.items.map(\.id) == ["c3"] && p2.nextLink == nil, "nextLink followed to the last page")
        let sub = try await svc.children(of: p1.items[0])
        check(sub.items.first?.name == "b.pdf" && sub.items.first?.mimeType == "application/pdf", "folder navigation lists its children")
        check(MailStub.captured().contains { $0.path == "/v1.0/me/drive/root/children" && $0.query.contains("select=") && $0.query.contains("top=100") },
              "children asked with $top + $select")
        let rec = try await svc.recent()
        check(rec.items.first?.id == "rem1" && rec.items.first?.driveId == "b!other", "recent: remote item addressed by remoteItem.id + its driveId")
        let found = try await svc.search("it's")
        check(found.items.first?.id == "s1", "search(q='…') with the quote doubled")
    } catch { check(false, "browse threw \(error)") }
    do { _ = try await svc.nextPage(URL(string: "https://evil.example/v1.0/x")!); check(false, "foreign nextLink should throw") }
    catch { check(!headers.all.contains { $0.0.hasPrefix("evil.example") }, "a nextLink to another host is refused (bearer never leaves Graph)") }

    // createLink shape + scope fallback
    let remote = DriveItem(id: "rem1", driveId: "b!other", name: "r.xlsx", size: 9)
    do {
        let r = try await svc.share(remote, type: .view, scope: .organization)
        let sent = MailStub.captured().last { $0.path == "/v1.0/drives/b!other/items/rem1/createLink" }
        let o = (try? JSONSerialization.jsonObject(with: sent?.body ?? Data())) as? [String: Any] ?? [:]
        check(o["type"] as? String == "view" && o["scope"] as? String == "organization" && o.count == 2,
              "createLink body: type + explicit scope (never the tenant default)")
        check(r.link.url.hasPrefix("https://") && r.link.scope == .organization && r.link.permissionId == "perm1" && r.notice == nil,
              "link read back from the response (scope, permission id)")
    } catch { check(false, "share threw \(error)") }
    let file = DriveItem(id: "c1", name: "a.docx", size: 10)
    do {
        let r = try await svc.share(file, type: .edit, scope: .anonymous)
        let scopes = MailStub.captured().filter { $0.path == "/v1.0/me/drive/items/c1/createLink" }
            .compactMap { ((try? JSONSerialization.jsonObject(with: $0.body ?? Data())) as? [String: Any])?["scope"] as? String }
        check(scopes == ["anonymous", "organization"] && r.narrowedFrom == .anonymous && r.link.scope == .organization && r.link.type == .edit,
              "403 on an Anyone link → narrowed to organisation, never widened (\(scopes))")
        check(r.notice?.contains("doesn't allow") == true && r.notice?.contains("secret") == false, "narrowing said out loud; server message text not shown")
    } catch { check(false, "anonymous fallback threw \(error)") }
    do { _ = try await svc.share(DriveItem(id: "c2", name: "b.pdf", size: 5), type: .view, scope: .organization); check(false, "org 403 should throw") }
    catch { check(error as? DriveError == .linkRefused(.organization), "403 on an organisation link → clear refusal, no silent change") }
    do {
        try await svc.invite(file, emails: ["guest@partner.example"], type: .view)
        let o = (try? JSONSerialization.jsonObject(with: MailStub.captured().last { $0.path.hasSuffix("/invite") }?.body ?? Data())) as? [String: Any] ?? [:]
        check(o["requireSignIn"] as? Bool == true && o["sendInvitation"] as? Bool == false && (o["roles"] as? [String]) == ["read"]
              && ((o["recipients"] as? [[String: String]])?.first?["email"]) == "guest@partner.example",
              "invite: requireSignIn, no Microsoft notification mail, read role, recipient email")
    } catch { check(false, "invite threw \(error)") }

    // Upload: small PUT vs session
    do {
        let id = UUID()
        let prog = ProgressBox()
        AttachmentProgress.shared.observe(id) { s, t in prog.set(s, t) }
        let small = try await svc.upload(name: "small/name.txt", data: Data("hello".utf8), progressId: id)
        AttachmentProgress.shared.stop(id)
        let put = MailStub.captured().last { $0.method == "PUT" && $0.path.hasSuffix(":/content") }
        check(small.id == "up-s" && put?.path == "/v1.0/me/drive/root:/Attachments/small_name.txt:/content"
              && put?.query.contains("conflictBehavior=rename") == true && put?.body == Data("hello".utf8),
              "< 4 MB: one PUT into OneDrive › Attachments, name sanitised, rename on conflict")
        check(prog.value == (5, 5), "small upload reports progress")
        let bigData = Data(count: DriveUpload.chunkSize + 100)
        let big = try await svc.upload(name: "big.bin", data: bigData, progressId: nil)
        let puts = MailStub.captured().filter { $0.method == "PUT" && $0.path == "/up/sess1" }
        let sess = MailStub.captured().last { $0.path.hasSuffix(":/createUploadSession") }
        let so = (try? JSONSerialization.jsonObject(with: sess?.body ?? Data())) as? [String: [String: String]]
        check(big.id == "up-b" && puts.count == 2 && so?["item"]?["@microsoft.graph.conflictBehavior"] == "rename",
              "≥ 4 MB: createUploadSession (rename on conflict) + chunked PUTs; driveItem read from the last chunk")
        check(DriveUpload.chunkSize % (320 * 1024) == 0, "fragment size is a multiple of 320 KiB")
        let upHeaders = headers.all.filter { $0.0 == "upload.example/up/sess1" }
        check(!upHeaders.isEmpty && upHeaders.allSatisfy { $0.1["Authorization"] == nil }, "uploadUrl PUTs carry no bearer")
    } catch { check(false, "upload threw \(error)") }

    // Download (attach a copy)
    do {
        let d = try await svc.download(file, maxSize: AttachmentUpload.maxSize)
        let dl = headers.all.filter { $0.0 == "download.example/dl/c1" }
        check(d == Data("0123456789".utf8) && !dl.isEmpty && dl.allSatisfy { $0.1["Authorization"] == nil },
              "attach a copy: bytes via @microsoft.graph.downloadUrl without a bearer")
    } catch { check(false, "download threw \(error)") }
    do { _ = try await svc.download(DriveItem(id: "huge", name: "huge.iso", size: 1), maxSize: AttachmentUpload.maxSize); check(false, "too large should throw") }
    catch {
        let dlHuge = headers.all.contains { $0.0 == "download.example/dl/huge" }
        check({ if case .tooLarge? = error as? DriveError { return true }; return false }() && !dlHuge, "over 150 MB → refused before downloading")
    }

    // Labels
    let lab = await svc.sensitivityLabel(file)
    check(lab == .label("a1f0c4e2-0000-4000-8000-000000000003"), "extractSensitivityLabels → the file's label id")
    check(headers.all.last { $0.0.hasSuffix("/c1/extractSensitivityLabels") }?.1["Authorization"] == "Bearer label-t",
          "label read uses its own token (Files.Read.All set)")
    check(await svc.sensitivityLabel(DriveItem(id: "c2", name: "b", size: 1)) == .unknown, "label read refused → unknown (warned, not 'fine')")
    let noLabels = GraphDriveService(token: { "drive-t" }, labelToken: nil, session: session)
    check(await noLabels.sensitivityLabel(file) == .unknown, "no label consent → unknown")

    let tree = LabelTree(FixtureCalendarService.labels)
    let general = "a1f0c4e2-0000-4000-8000-000000000002", conf = "a1f0c4e2-0000-4000-8000-000000000003"
    let highly = "a1f0c4e2-0000-4000-8000-000000000004"
    if case .raise(let to, let msg) = CloudLabelCheck.evaluate(file: .label(conf), fileName: "a.docx", mailLabelId: general, tree: tree) {
        check(to == conf && msg.contains("Confidential"), "file labelled higher than the mail → offer to raise to the file's label")
    } else { check(false, "raise expected") }
    if case .raise = CloudLabelCheck.evaluate(file: .label(conf), fileName: "a", mailLabelId: nil, tree: tree) { check(true, "unlabelled mail + labelled file → raise offered") }
    else { check(false, "unlabelled mail should be raised") }
    check(CloudLabelCheck.evaluate(file: .label(conf), fileName: "a", mailLabelId: highly, tree: tree) == .ok, "mail already higher → no warning (never lowered)")
    check(CloudLabelCheck.evaluate(file: .label(conf), fileName: "a", mailLabelId: conf, tree: tree) == .ok, "same label → fine")
    check(CloudLabelCheck.evaluate(file: .none, fileName: "a", mailLabelId: nil, tree: tree) == .ok, "unlabelled file → fine")
    if case .unknown = CloudLabelCheck.evaluate(file: .unknown, fileName: "a", mailLabelId: highly, tree: tree) { check(true, "unreadable label → warning") }
    else { check(false, "unknown expected") }
    if case .unknown = CloudLabelCheck.evaluate(file: .label("not-in-policy"), fileName: "a", mailLabelId: nil, tree: tree) { check(true, "label outside the synced policy → warning") }
    else { check(false, "unknown expected for foreign label") }
    check(CloudLabelCheck.externalWarning(file: .label(highly), tree: tree, scope: .organization, hasExternalRecipients: true) != nil
          && CloudLabelCheck.externalWarning(file: .label(highly), tree: tree, scope: .anonymous, hasExternalRecipients: false) != nil
          && CloudLabelCheck.externalWarning(file: .label(highly), tree: tree, scope: .organization, hasExternalRecipients: false) == nil
          && CloudLabelCheck.externalWarning(file: .label(conf), tree: tree, scope: .anonymous, hasExternalRecipients: true) == nil,
          "encrypted file shared outside the organisation → warning; unencrypted / internal → none")

    // Link chip
    let link = SharingLink(url: "https://contoso-my.sharepoint.example/:w:/g/abc?e=1&x=2", type: .edit, scope: .organization)
    if let d = CloudLinkChip.doc(name: "Q4 <plan>.docx", link: link) {
        let html = RichHTML.html(d)
        check(html.contains("<a href=\"https://contoso-my.sharepoint.example/:w:/g/abc?e=1&amp;x=2\"><b>Q4 &lt;plan&gt;.docx</b></a>")
              && html.contains(">Edit</a>") && html.contains(CloudLinkChip.icon), "link chip HTML: icon + bold linked name + 'Edit', escaped")
        check(RichHTML.parse(html).doc == d.normalised(), "link chip survives a reopened draft (HTML round trip)")
    } else { check(false, "chip doc nil") }
    check(CloudLinkChip.doc(name: "x", link: SharingLink(url: "javascript:alert(1)", type: .view, scope: .organization)) == nil
          && CloudLinkChip.doc(name: "x", link: SharingLink(url: "http://plain.example/x", type: .view, scope: .organization)) == nil,
          "only https links become chips")
    let clean = DriveNames.sanitise(" ../a:b*?.txt ")
    check(!clean.contains("/") && !clean.contains(":") && !clean.hasPrefix("."), "file names sanitised for OneDrive paths (\(clean))")
    check(DriveUpload.suggestsCloud(size: 30 * 1024 * 1024) && !DriveUpload.suggestsCloud(size: 2 * 1024 * 1024), "≥ 25 MB local attachment → 'Upload and share' offered")

    // Fixtures
    let fx = FixtureDriveService()
    let root = (try? await fx.children(of: nil))?.items ?? []
    check(root.contains { $0.isFolder } && root.contains { !$0.isFolder }, "fixture drive: synthetic folders and files")
    if let f = root.first(where: { !$0.isFolder }) {
        let fr = try? await fx.share(f, type: .view, scope: .anonymous)
        check(fr?.narrowedFrom == .anonymous && fr?.link.scope == .organization, "fixture tenant refuses Anyone links → organisation")
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: (Int, Int) = (0, 0)
    func set(_ s: Int, _ t: Int) { lock.withLock { v = (s, t) } }
    var value: (Int, Int) { lock.withLock { v } }
}
