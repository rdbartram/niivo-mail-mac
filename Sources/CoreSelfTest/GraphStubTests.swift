import Foundation
import CryptoKit
import CalendarCore

/// Intercepts URLSession traffic so the real GraphCalendarService code paths (DTO decoding, delta paging,
/// @removed, $batch, 410 recovery) run against canned Graph JSON.
final class GraphStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var log: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.append("\(request.httpMethod ?? "GET") \(request.url!.path)?\(request.url!.query ?? "")")
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let labelGuid = "a1f0c4e2-0000-4000-8000-000000000004"

func graphEvent(_ id: String, _ start: String, _ end: String, extra: String = "") -> String {
    """
    {"id":"\(id)","subject":"Subject \(id)","start":{"dateTime":"\(start)","timeZone":"UTC"},
     "end":{"dateTime":"\(end)","timeZone":"UTC"},"isAllDay":false,"showAs":"busy","sensitivity":"normal",
     "changeKey":"ck-\(id)","isCancelled":false,"bodyPreview":"secret agenda",
     "attendees":[{"emailAddress":{"name":"A","address":"a@x"},"status":{"response":"accepted"}}],
     "organizer":{"emailAddress":{"name":"O","address":"o@x"}},"location":{"displayName":"Room"} \(extra)}
    """
}

@MainActor
func runGraphStubTests() async {
    section("Graph client against canned JSON (delta, @removed, $batch, 410)")
    let deltaHost = "https://graph.microsoft.com/v1.0/me/calendarView/delta"
    let state = StubState()

    GraphStub.handler = { req in
        let path = req.url!.path, q = req.url!.query ?? ""
        switch (req.httpMethod ?? "GET", path) {
        case ("GET", "/v1.0/me"):
            return (200, #"{"displayName":"You","mail":"you@x"}"#)
        case ("GET", "/v1.0/me/calendars"):
            return (200, #"{"value":[{"id":"prim","name":"Calendar","isDefaultCalendar":true,"canEdit":true,"owner":{"name":"You","address":"you@x"}}]}"#)
        case ("GET", "/beta/me/security/informationProtection/sensitivityLabels"):
            return (200, #"{"value":[{"id":"\#(labelGuid)","name":"Highly Confidential","sensitivity":3,"hasProtection":true,"isActive":true}]}"#)
        case ("GET", "/v1.0/security/dataSecurityAndGovernance/sensitivityLabels/\(labelGuid)/rights"):
            return (200, #"{"id":"r1","value":"view, print, reply, replyAll, viewRightsData"}"#)
        case ("GET", "/v1.0/me/calendarView/delta"):
            if q.contains("deltatoken=d1") && state.bump410() { return (410, #"{"error":{"code":"SyncStateNotFound"}}"#) }
            if q.contains("skiptoken=p2") {
                return (200, #"{"value":[\#(graphEvent("ev2", "2026-11-18T13:00:00.0000000", "2026-11-18T14:00:00.0000000"))],"@odata.deltaLink":"\#(deltaHost)?$deltatoken=d1"}"#)
            }
            return (200, #"{"value":[\#(graphEvent("ev1", "2026-11-18T09:00:00.0000000", "2026-11-18T10:00:00.0000000")),{"id":"gone","@removed":{"reason":"deleted"}}],"@odata.nextLink":"\#(deltaHost)?$skiptoken=p2"}"#)
        case ("POST", "/v1.0/$batch"):
            let ev1 = #"{"id":"ev1","singleValueExtendedProperties":[{"id":"x","value":"MSIP_Label_\#(labelGuid)_Enabled=true; MSIP_Label_\#(labelGuid)_SiteId=t"}]}"#
            return (200, #"{"responses":[{"id":"0","status":200,"body":\#(ev1)},{"id":"1","status":404,"body":{"error":{"code":"ErrorItemNotFound","message":"gone"}}}]}"#)
        default:
            return (404, #"{"error":{"code":"unexpected \#(path)"}}"#)
        }
    }

    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [GraphStub.self]
    let svc = GraphCalendarService(token: { "test-token" }, session: URLSession(configuration: cfg))
    do {
        let store = try LocalStore(url: nil, cipher: AESGCMCipher(key: SymmetricKey(size: .bits256)))
        // Pre-existing cached item that the delta reports as removed.
        try store.upsert(events: [CalendarEvent(id: "gone", calendarId: "prim", subject: "old",
                                                start: .now, end: .now.addingTimeInterval(600))])
        let eng = CachedLabelPolicyEngine()
        let sync = SyncEngine(service: svc, store: store, compliance: eng, onChange: { _ in })

        await sync.syncNow()
        let st = await sync.status
        check({ if case .idle = st { return true }; return false }(), "live-path sync completed (status \(st))")
        let ev1 = try store.event(id: "ev1"), ev2 = try store.event(id: "ev2")
        check(ev1 != nil && ev2 != nil, "delta paging: nextLink followed, both pages applied")
        check(try store.event(id: "gone") == nil, "@removed item deleted from cache")
        check(ev1?.labelId == labelGuid, "label read from msip_labels via $batch (failed sub-response tolerated)")
        let hcLabel = try await svc.sensitivityLabels().first
        check(hcLabel?.rights == [.view, .print, .reply, .replyAll, .viewRightsData],
              "encrypted label's usage rights fetched from sensitivityLabels/{id}/rights and parsed")
        let p1 = ev1.map { eng.policy(for: $0, context: .init(calendarAccess: .own)) }
        check(p1?.rightsSource == .label && p1?.allowPrint == true && p1?.allowCopy == false && p1?.allowForward == false,
              "synced label rights drive the item policy (print yes, copy/forward no)")
        check(ev1?.bodyPreview == nil && ev1?.attendees.isEmpty == true, "protected label → body/attendees not persisted")
        check(ev2?.bodyPreview == "secret agenda" && ev2?.labelId == nil, "unlabelled item keeps details")
        check(ev1?.start == ISO8601DateFormatter().date(from: "2026-11-18T09:00:00Z"), "Graph 7-digit fractional UTC time decoded")
        let key = "delta:prim:\(Int(SyncEngine.syncWindow().start.timeIntervalSince1970))"
        check(try store.value(for: key)?.contains("deltatoken=d1") == true, "deltaLink persisted for next round")

        GraphStub.log.removeAll()
        await sync.syncNow()
        let st2 = await sync.status
        let usedDead = GraphStub.log.contains { $0.contains("deltatoken=d1") }
        let restarted = GraphStub.log.contains { $0.contains("calendarView/delta?endDateTime") || $0.contains("startDateTime") }
        check(usedDead && restarted, "410 on stale deltaLink → full round restarted")
        check({ if case .idle = st2 { return true }; return false }(), "410 recovery leaves status healthy (\(st2))")
    } catch { check(false, "graph stub threw \(error)") }

    // Real-tenant regression: the label list 403s for a normal user in a test tenant. Calendar sync must still complete,
    // and the labelled item must stay fail-closed.
    let inner = GraphStub.handler
    GraphStub.handler = { req in
        req.url!.path.contains("sensitivityLabels") ? (403, #"{"error":{"code":"UnknownError","message":""}}"#) : inner!(req)
    }
    do {
        let store = try LocalStore(url: nil, cipher: AESGCMCipher(key: SymmetricKey(size: .bits256)))
        let eng = CachedLabelPolicyEngine()
        let sync = SyncEngine(service: svc, store: store, compliance: eng, onChange: { _ in })
        await sync.syncNow()
        let st = await sync.status
        check({ if case .idle = st { return true }; return false }(), "label list 403 → calendar sync still completes (\(st))")
        check(await sync.labelSyncIssue != nil, "label failure reported for the UI")
        let ev1 = try store.event(id: "ev1")
        check(ev1 != nil && ev1?.bodyPreview == nil, "labelled item cached without details (unknown label → fail closed)")
        check(ev1.map { eng.policy(for: $0, context: .init(calendarAccess: .own)).allowCopy } == false,
              "labelled item still blocks copy (label unknown → fail closed)")
    } catch { check(false, "label-403 stub threw \(error)") }
    // Rights endpoint refused (e.g. SensitivityLabel.Read not consented): the label list still loads, rights stay nil
    // and the encrypted label fails closed to VIEW only.
    GraphStub.handler = { req in
        req.url!.path.hasSuffix("/rights") ? (403, #"{"error":{"code":"Forbidden","message":""}}"#) : inner!(req)
    }
    do {
        let ls = try await svc.sensitivityLabels()
        let eng = CachedLabelPolicyEngine(labels: ls, synced: true)
        let p = eng.policy(labelId: labelGuid, isPrivate: false, access: .own)
        check(ls.count == 1 && ls[0].rights == nil && p.rights == .viewOnly && p.rightsSource == .encryptedUnknown,
              "rights endpoint 403 → label list still loads, encrypted label falls back to VIEW only")
    } catch { check(false, "rights-403 stub threw \(error)") }
    GraphStub.handler = inner
}

final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var gone410 = false
    /// Returns true exactly once (first use of the stale token).
    func bump410() -> Bool { lock.withLock { if gone410 { return false }; gone410 = true; return true } }
}
