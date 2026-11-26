import Foundation
import CryptoKit
import CalendarCore
import MailCore

/// URLProtocol stub with response headers (Retry-After) and request-body capture.
final class MailStub: URLProtocol {
    struct Captured: Sendable { var method: String; var path: String; var query: String; var body: Data? }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, [String: String], String))?
    nonisolated(unsafe) static var log: [Captured] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); body = d
        }
        let u = request.url!
        Self.lock.withLock {
            Self.log.append(Captured(method: request.httpMethod ?? "GET", path: u.path, query: u.query ?? "", body: body))
        }
        let (status, headers, text) = Self.handler?(request, body) ?? (500, [:], "{}")
        let resp = HTTPURLResponse(url: u, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func captured() -> [Captured] { lock.withLock { log } }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var fired = Set<String>()
    func first(_ k: String) -> Bool { lock.withLock { fired.insert(k).inserted } }
}

func gmsg(_ id: String, folder: String, extra: String = "") -> String {
    """
    {"id":"\(id)","subject":"S-\(id)","from":{"emailAddress":{"name":"A","address":"a@contoso.example"}},
     "toRecipients":[{"emailAddress":{"name":"B","address":"b@contoso.example"}}],"receivedDateTime":"2026-11-18T09:00:00Z",
     "bodyPreview":"secret preview","isRead":false,"isDraft":false,"importance":"normal","inferenceClassification":"focused",
     "flag":{"flagStatus":"notFlagged"},"categories":[],"hasAttachments":false,"conversationId":"cv-\(id)","changeKey":"ck",
     "parentFolderId":"\(folder)" \(extra)}
    """
}

@MainActor
func runMailGraphStubTests() async {
    section("Mail Graph client against canned JSON (delta, @removed, msip_labels, 429, rules, send-as)")
    let guid = FixtureCalendarService.labels[3].id
    let once = Once()
    let host = "https://graph.microsoft.com/v1.0"
    MailStub.handler = { req, body in
        let path = req.url!.path, q = req.url!.query ?? "", m = req.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/v1.0/me/mailFolders"):
            if once.first("429") { return (429, ["Retry-After": "0"], #"{"error":{"code":"TooManyRequests"}}"#) }
            return (200, [:], #"{"value":[{"id":"inbox-id","displayName":"Inbox","parentFolderId":"root","unreadItemCount":7,"totalItemCount":42,"childFolderCount":0},{"id":"sent-id","displayName":"Sent Items","parentFolderId":"root","unreadItemCount":0,"totalItemCount":3,"childFolderCount":0}]}"#)
        case ("POST", "/v1.0/$batch") where (body.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("msip_labels"):   // JSON escapes "/" as "\/"
            // Label/private enrichment after delta: answer per sub-request (m1 labelled, m2 private, rest none).
            let reqs = ((try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any])?["requests"] as? [[String: Any]] ?? []
            let out = reqs.map { r -> String in
                let id = r["id"] as? String ?? "0", u = r["url"] as? String ?? ""
                let props: String
                if u.contains("/messages/m1?") { props = #"[{"id":"String {00020386-0000-0000-c000-000000000046} Name msip_labels","value":"MSIP_Label_\#(guid)_Enabled=true; MSIP_Label_\#(guid)_SiteId=t"}]"# }
                else if u.contains("/messages/m2?") { props = #"[{"id":"Integer 0x36","value":"2"}]"# }
                else { props = "[]" }
                return #"{"id":"\#(id)","status":200,"body":{"id":"x","singleValueExtendedProperties":\#(props)}}"#
            }
            return (200, [:], #"{"responses":[\#(out.joined(separator: ","))]}"#)
        case ("POST", "/v1.0/$batch") where (body.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("messages\\/m3"):
            return (200, [:], #"{"responses":[{"id":"0","status":200,"body":\#(gmsg("m3", folder: "inbox-id"))}]}"#)
        case ("POST", "/v1.0/$batch"):
            return (200, [:], #"{"responses":[{"id":"0","status":200,"body":{"id":"inbox-id"}},{"id":"2","status":200,"body":{"id":"sent-id"}},{"id":"4","status":404,"body":{"error":{"code":"ErrorFolderNotFound"}}}]}"#)
        case ("GET", "/v1.0/me/mailFolders/inbox-id/messages/delta"):
            if q.contains("skiptoken=p2") {
                return (200, [:], #"{"value":[{"id":"m3","isRead":true},\#(gmsg("m2", folder: "inbox-id", extra: #","singleValueExtendedProperties":[{"id":"Integer 0x36","value":"2"}]"#))],"@odata.deltaLink":"\#(host)/me/mailFolders/inbox-id/messages/delta?$deltatoken=d1"}"#)
            }
            if q.contains("deltatoken=d1") && once.first("410") { return (410, [:], #"{"error":{"code":"SyncStateNotFound"}}"#) }
            let labelled = gmsg("m1", folder: "inbox-id", extra: #","singleValueExtendedProperties":[{"id":"String {00020386-0000-0000-c000-000000000046} Name msip_labels","value":"MSIP_Label_\#(guid)_Enabled=true; MSIP_Label_\#(guid)_SiteId=t"}]"#)
            return (200, [:], #"{"value":[\#(labelled),{"id":"gone","@removed":{"reason":"deleted"}}],"@odata.nextLink":"\#(host)/me/mailFolders/inbox-id/messages/delta?$skiptoken=p2"}"#)
        case ("GET", "/v1.0/me/mailFolders/sent-id/messages/delta"):
            return (200, [:], #"{"value":[],"@odata.deltaLink":"\#(host)/me/mailFolders/sent-id/messages/delta?$deltatoken=s1"}"#)
        case ("GET", _) where path.hasSuffix("/messages") && path.contains("mailFolders"):
            return (200, [:], #"{"value":[]}"#)
        case ("GET", "/v1.0/me/messages"):
            let lab = #","singleValueExtendedProperties":[{"id":"String {00020386-0000-0000-c000-000000000046} Name msip_labels","value":"MSIP_Label_\#(guid)_Enabled=true"}]"#
            return (200, [:], #"{"value":[\#(gmsg("s1", folder: "inbox-id", extra: lab))]}"#)
        case ("PATCH", "/v1.0/me/messages/m1"):
            return (200, [:], gmsg("m1", folder: "inbox-id", extra: #","isRead":true,"body":{"contentType":"html","content":"<p>secret body</p>"}"#))
        case ("POST", "/v1.0/me/messages/m2/move"):
            return (201, [:], gmsg("m2new", folder: "sent-id"))
        case ("PATCH", "/v1.0/me/messages/m2new"):
            return (200, [:], gmsg("m2new", folder: "sent-id"))
        case ("PATCH", "/v1.0/me/mailFolders/inbox/messageRules/r1"):
            return (200, [:], String(data: body ?? Data(), encoding: .utf8)!.replacingOccurrences(of: "{\"actions\"", with: "{\"id\":\"r1\",\"actions\""))
        case ("POST", "/v1.0/me/messages/d1/send"):
            return (403, [:], #"{"error":{"code":"ErrorSendAsDenied","message":"The user account which was used to submit this request does not have the right to send mail on behalf of the specified sending account."}}"#)
        case ("POST", "/v1.0/me/messages/orig/createReply"):
            return (201, [:], #"{"id":"rd1","body":{"contentType":"html","content":"<html><body><div>quoted history</div></body></html>"},"conversationId":"cv-orig","parentFolderId":"drafts-id"}"#)
        case ("PATCH", "/v1.0/me/messages/rd1"):
            let o = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            let content = ((o?["body"] as? [String: Any])?["content"] as? String) ?? ""
            let enc = String(data: try! JSONSerialization.data(withJSONObject: ["c": content]), encoding: .utf8)!
            return (200, [:], #"{"id":"rd1","isDraft":true,"conversationId":"cv-orig","parentFolderId":"drafts-id","body":{"contentType":"html","content":\#(enc.dropFirst(5).dropLast())}}"#)
        default:
            return (404, [:], #"{"error":{"code":"unexpected"}}"#)
        }
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let monitor = ThrottleMonitor()
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg), throttle: monitor)
    do {
        let store = try mailStore()
        try store.replace(folders: [MailFolder(id: "inbox-id", displayName: "Inbox", wellKnown: .inbox)], mailbox: "me")
        try store.upsert(message: MailMessage(id: "gone", folderId: "inbox-id", conversationId: "c", subject: "old", from: nil, received: Date()))
        let sync = MailSync(service: svc, store: store, compliance: mailEngine(), throttle: monitor, onChange: { _ in })
        await sync.syncNow()
        let st = await sync.status
        check(st.phase == .idle, "Graph path sync completes (\(st.phase))")
        check(monitor.events >= 1 && st.throttledUntil["me"] != nil, "429 Retry-After honoured, throttling reported in status")
        let folders = try store.folders(mailbox: "me")
        check(folders.first { $0.id == "inbox-id" }?.wellKnown == .inbox && folders.first { $0.id == "sent-id" }?.wellKnown == .sentitems,
              "well-known folders resolved via $batch (failed sub-request tolerated)")
        check(folders.first { $0.id == "inbox-id" }?.unreadCount == 7 && folders.first { $0.id == "inbox-id" }?.totalCount == 42,
              "server unread/total counts used")
        let m1 = try store.message(id: "m1"), m2 = try store.message(id: "m2")
        check(m1 != nil && m2 != nil, "delta paging: nextLink followed")
        check(try store.message(id: "gone") == nil, "@removed deleted from cache")
        check(m1?.labelId == guid, "msip_labels parsed from $expand on delta")
        check(m1?.preview == nil && m1?.toRecipients.isEmpty == true, "labelled (protected) delta item: preview/recipients not persisted")
        let m3 = try store.message(id: "m3")
        check(m3?.received == ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z"),
              "delta item without dates is re-fetched whole (not stored as 1970)")
        check(m2?.isPrivate == true && m1?.isPrivate == false, "private flag from PR_SENSITIVITY (Integer 0x36 = 2), not a $select field")
        let deltaExpands = MailStub.captured().filter { $0.path.hasSuffix("/messages/delta") && !$0.query.contains("token=") }
            .compactMap { URLComponents(string: "x:?\($0.query)")?.queryItems?.first { $0.name == "$expand" }?.value }
        check(deltaExpands.isEmpty, "message delta carries no $expand (Graph 400s on it); labels come via $batch")
        // Real Graph 400s the whole request on an unknown $select field (message has no `sensitivity`; found live 2026-11-19).
        let messageProps: Set<String> = ["id", "subject", "from", "sender", "toRecipients", "ccRecipients", "bccRecipients", "replyTo",
            "receivedDateTime", "sentDateTime", "createdDateTime", "lastModifiedDateTime", "bodyPreview", "body", "uniqueBody", "isRead",
            "isDraft", "importance", "inferenceClassification", "flag", "categories", "hasAttachments", "conversationId",
            "conversationIndex", "changeKey", "webLink", "parentFolderId", "internetMessageId", "isReadReceiptRequested",
            "isDeliveryReceiptRequested", "internetMessageHeaders"]
        let selects = MailStub.captured().compactMap { c in URLComponents(string: "x:?\(c.query)")?.queryItems?.first { $0.name == "$select" }?.value
            .map { (c.path, $0) } }.filter { $0.0.contains("/messages") }
        let bad = Set(selects.flatMap { $0.1.split(separator: ",").map(String.init) }).subtracting(messageProps)
        check(!selects.isEmpty && bad.isEmpty, "message $select only uses real Graph message properties (bad: \(bad.sorted()))")
        check(m2?.preview == "secret preview" && m2?.received == ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z"), "unlabelled item keeps details; date parsed")
        let firstDelta = MailStub.captured().first { $0.path.hasSuffix("inbox-id/messages/delta") }
        check(firstDelta.map { $0.query.contains("$filter=receivedDateTime%20ge") || $0.query.contains("receivedDateTime ge") } == true
              && firstDelta?.query.contains("msip_labels") == false
              && MailStub.captured().contains { $0.path == "/v1.0/$batch" && String(data: $0.body ?? Data(), encoding: .utf8)?.contains("msip_labels") == true },
              "initial delta carries the window filter; labels fetched by $batch")
        check(try store.value(for: "mdelta:inbox-id")?.contains("deltatoken=d1") == true, "deltaLink persisted")
        MailStub.lock.withLock { MailStub.log.removeAll() }
        await sync.syncNow()
        let restarted = MailStub.captured().filter { $0.path.hasSuffix("inbox-id/messages/delta") }
        check(restarted.contains { $0.query.contains("deltatoken=d1") } && restarted.contains { $0.query.contains("receivedDateTime") },
              "410 on stale deltaLink → initial round restarted")

        // Action responses must not override the local header (no label on PATCH responses, body present).
        try await sync.perform(.markRead(true), on: "m1")
        let r1 = try store.message(id: "m1")
        check(try r1?.isRead == true && r1?.labelId == guid && r1?.preview == nil && r1?.toRecipients.isEmpty == true
              && store.body(messageId: "m1") == nil && r1?.pendingSync == false,
              "markRead on protected item: label kept, response body/preview not persisted")
        check(try store.search("m1").isEmpty, "protected subject not indexed after action round-trip")
        // Offline move then markRead: the move's new id re-keys the queued follow-up.
        MailStub.lock.withLock { MailStub.log.removeAll() }
        try store.enqueue(messageId: "m2", mailbox: "me", op: .action(.move(toFolderId: "sent-id")))
        try store.enqueue(messageId: "m2", mailbox: "me", op: .action(.markRead(true)))
        await sync.flush()
        let calls = MailStub.captured().map { "\($0.method) \($0.path)" }
        check(calls.contains("POST /v1.0/me/messages/m2/move") && calls.contains("PATCH /v1.0/me/messages/m2new")
              && !calls.contains("PATCH /v1.0/me/messages/m2"), "move returned a new id → queued markRead sent to the new id")
        check(try store.message(id: "m2") == nil && (try store.message(id: "m2new"))?.folderId == "sent-id"
              && (try store.outbox()).isEmpty, "row re-keyed, no ghost, outbox drained")

        // Rule PATCH body shape.
        let rule = MailRule(id: "r1", displayName: "Move Mia", sequence: 2,
                            conditions: RuleConditions(fromAddresses: [.init(name: "Mia", address: "mia@fabrikam.example")], hasAttachments: true),
                            actions: RuleActions(moveToFolder: "folder-x", markAsRead: true, stopProcessingRules: true))
        let saved = try await svc.saveRule(rule, mailbox: "me")
        let patch = MailStub.captured().last { $0.method == "PATCH" && $0.path.hasSuffix("messageRules/r1") }
        let o = patch?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let cond = o?["conditions"] as? [String: Any], act = o?["actions"] as? [String: Any]
        let fromAddr = ((cond?["fromAddresses"] as? [[String: Any]])?.first?["emailAddress"] as? [String: Any])?["address"] as? String
        check(fromAddr == "mia@fabrikam.example" && cond?["hasAttachments"] as? Bool == true, "rule PATCH: conditions.fromAddresses[].emailAddress.address")
        check(act?["moveToFolder"] as? String == "folder-x" && act?["stopProcessingRules"] as? Bool == true && act?["forwardTo"] == nil,
              "rule PATCH: actions.moveToFolder, empty collections omitted")
        check(o?["sequence"] as? Int == 2 && o?["isEnabled"] as? Bool == true && saved.id == "r1"
              && saved.conditions.fromAddresses.first?.address == "mia@fabrikam.example", "rule round-trips through DTO")

        // $search quoting.
        _ = try await svc.search(#"say "hi" \ now"#, mailbox: "me", top: 10)
        let sq = MailStub.captured().last { $0.path == "/v1.0/me/messages" }
        let sv = sq.flatMap { URLComponents(string: "x:?\($0.query)")?.queryItems?.first { $0.name == "$search" }?.value }
        check(sv == #""say \"hi\" \\ now""#, "$search double-quoted, quotes/backslashes escaped")
        check(sq.flatMap { URLComponents(string: "x:?\($0.query)")?.queryItems?.contains { $0.name == "$filter" } } == false,
              "no top-level $filter alongside $search")
        let hits = try await svc.search("x", mailbox: "me", top: 5)
        check(hits.first?.labelId == guid && AIAccessPolicy(engine: mailEngine()).level(for: hits[0]) == .metadataOnly,
              "server search hits carry their label (AI gate applies)")

        // Send-as denied mapping.
        do { try await svc.send(draftId: "d1", mailbox: "me", sendAt: nil); check(false, "should throw") }
        catch MailServiceError.sendAsDenied { check(true, "ErrorSendAsDenied → .sendAsDenied") }

        // Reply: createReply then PATCH with user HTML before quoted history.
        let r = try await svc.saveDraft(MailDraft(kind: .reply, replyTo: "orig", bodyHTML: "<p>Thanks</p>"), mailbox: "me")
        let b = r.body ?? ""
        check(b.contains("<body><p>Thanks</p><div>quoted history") , "reply body: user HTML inserted above quoted history")
        check(MailStub.captured().contains { $0.path.hasSuffix("orig/createReply") }, "reply uses createReply (threading kept)")
    } catch { check(false, "mail graph stub threw \(error)") }
    MailStub.handler = nil
}

// MARK: - Benchmark (CC_BENCH=1)

@MainActor
func runMailBenchmark() async {
    guard ProcessInfo.processInfo.environment["CC_BENCH"] == "1" else { return }
    section("Mail benchmark: 500k headers (temp DB, deleted afterwards) — timings on stderr")
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    do {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mailbench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "bench.sqlite")
        let store = try MailStore(url: url, key: SymmetricKey(size: .bits256))
        store.setPersistPolicy { m, mb in MailContentPolicy.policy(for: m, mailbox: mb, engine: mailEngine()) }
        let folders = (0..<20).map { MailFolder(id: "f\($0)", displayName: "F\($0)", wellKnown: $0 == 0 ? .inbox : nil) }
        try store.replace(folders: folders, mailbox: "me")
        let words = ["budget", "review", "migration", "contract", "network", "invoice", "roadmap", "pilot", "backup", "security",
                     "planning", "workshop", "onboarding", "licence", "travel", "offsite", "renewal", "baseline", "timeline", "agenda"]
        let n = 500_000
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var batch: [MailMessage] = []
        batch.reserveCapacity(10_000)
        var start = Date()
        var rnd: UInt64 = 42
        func r(_ k: Int) -> Int { rnd = rnd &* 6364136223846793005 &+ 1442695040888963407; return Int((rnd >> 33) % UInt64(k)) }
        for i in 0..<n {
            let subj = "\(words[r(20)]) \(words[r(20)]) \(i % 997)"
            batch.append(MailMessage(id: "AAMkAD\(String(format: "%010d", i))", folderId: "f\(i % 20 == 0 ? 0 : r(20))",
                                     conversationId: "conv\(i / 4)", subject: subj,
                                     from: .init(name: "Person \(i % 500)", address: "p\(i % 500)@contoso.example"),
                                     toRecipients: [.init(name: "You", address: "you@contoso.example")],
                                     received: t0.addingTimeInterval(Double(i) * 300), preview: "Notes on \(words[r(20)]) and \(words[r(20)]) for team \(i % 50)",
                                     isRead: r(3) > 0))
            if batch.count == 10_000 { try store.upsert(messages: batch); batch.removeAll(keepingCapacity: true) }
        }
        try store.upsert(messages: batch)
        let insert = Date().timeIntervalSince(start)
        store.checkpoint()
        var bytes = 0
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let tokens = try store.tokenRowCount()

        func timed(_ k: Int, _ body: () throws -> Void) rethrows -> (Double, Double) {
            var ts: [Double] = []
            for _ in 0..<k { let s = Date(); try body(); ts.append(Date().timeIntervalSince(s) * 1000) }
            ts.sort(); return (ts[ts.count / 2], ts[min(ts.count - 1, ts.count * 95 / 100)])
        }
        var got = 0
        let page = try timed(50) { got = try store.messages(folderId: "f0", limit: 50).count }
        let mid = try store.messages(folderId: "f0", limit: 50)
        let cursor = MailCursor(received: mid.last!.received, id: mid.last!.id)
        let page2 = try timed(50) { _ = try store.messages(folderId: "f3", before: cursor, limit: 50) }
        var hits = 0
        let search = try timed(30) { hits = try store.search("migration roadmap", mailbox: "me", limit: 50).count }
        let prefix = try timed(30) { _ = try store.search("offs", mailbox: "me", limit: 50) }
        let conv = try timed(50) { _ = try store.conversation(id: "conv\(r(n / 4))") }
        start = Date()
        err(String(format: "  [bench] bulk insert %d headers: %.1f s (%.0f/s); %d index tokens", n, insert, Double(n) / insert, tokens))
        err(String(format: "  [bench] first page of 50 (folder): p50 %.2f ms, p95 %.2f ms (%d rows)", page.0, page.1, got))
        err(String(format: "  [bench] keyset next page: p50 %.2f ms", page2.0))
        err(String(format: "  [bench] token search (2 terms, %d hits): p50 %.2f ms, p95 %.2f ms", hits, search.0, search.1))
        err(String(format: "  [bench] prefix search: p50 %.2f ms, p95 %.2f ms", prefix.0, prefix.1))
        err(String(format: "  [bench] conversation fetch: p50 %.2f ms", conv.0))
        err(String(format: "  [bench] on disk: %.1f MB → %.0f bytes/header incl. index tokens", Double(bytes) / 1e6, Double(bytes) / Double(n)))
        check(page.1 < 50, "first page of 50 < 50 ms at 500k rows (p95 \(String(format: "%.2f", page.1)) ms)")
        check(search.1 < 100, "token search < 100 ms at 500k rows (p95 \(String(format: "%.2f", search.1)) ms)")
    } catch { check(false, "benchmark threw \(error)") }
}
