import Foundation
import CalendarCore
import MailCore
import ProtectedContent

/// Purview label policy (default / mandatory / downgrade justification), msip_labels shape, protected-label send
/// gating and protected-attachment rights. Offline: stub policy values, no bridge, no tenant.
struct StubLabelPolicyProvider: LabelPolicyProvider {
    var settings: LabelPolicySettings
    func loadPolicy() async throws -> LabelPolicySettings { settings }
    func plan(labelId: String?, existingHeader: String?, privileged: Bool, justification: String?,
              contentId: String, commit: Bool) async throws -> LabelPlan {
        let md = labelId.flatMap { LabelMetadata.build(labelId: $0, tenantId: settings.tenantId, privileged: privileged,
                                                       setDate: Date(timeIntervalSince1970: 0)) }
        let needs = settings.justificationRequired && justification == nil && labelId == nil
        return LabelPlan(metadata: md ?? LabelMetadata(entries: []), needsJustification: needs,
                         committed: commit && !needs)
    }
}

@MainActor func runPurviewTests() async {
    section("Purview label policy: default, mandatory, downgrade justification, msip_labels, encrypt gate, attachments")
    let general = SensitivityLabel(id: "11111111-1111-1111-1111-111111111111", name: "General", priority: 1)
    let conf = SensitivityLabel(id: "22222222-2222-2222-2222-222222222222", name: "Confidential", priority: 3)
    let secret = SensitivityLabel(id: "33333333-3333-3333-3333-333333333333", name: "Secret", priority: 5, hasProtection: true)
    let tree = LabelTree([general, conf, secret])
    let tid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let policy = LabelPolicySettings(defaultLabelId: conf.id.uppercased(), mandatory: true, justificationRequired: true,
                                     tenantId: tid, source: .mipPolicy)

    // Default label preselect
    let new = LabelGate.initialLabel(floorLabelId: nil, settings: policy, tree: tree)
    check(new.id == conf.id && new.isDefault, "new mail preselects the policy default (Standard)")
    let reply = LabelGate.initialLabel(floorLabelId: secret.id, settings: policy, tree: tree)
    check(reply.id == secret.id && !reply.isDefault, "reply keeps the original's label over the default")
    check(LabelGate.initialLabel(floorLabelId: nil, settings: .graphFallback, tree: tree).id == nil,
          "Graph fallback: no default invented")
    let foreign = LabelPolicySettings(defaultLabelId: "99999999-9999-9999-9999-999999999999")
    check(LabelGate.initialLabel(floorLabelId: nil, settings: foreign, tree: tree).id == nil,
          "a default the user can't apply isn't preselected")

    // Mandatory blocks send
    check(LabelGate.sendBlock(labelId: nil, baseline: nil, justification: nil, settings: policy, tree: tree) == .labelRequired,
          "mandatory labelling blocks an unlabelled send")
    check(LabelGate.sendBlock(labelId: nil, baseline: nil, justification: nil, settings: .graphFallback, tree: tree) == nil,
          "no policy: unlabelled mail may go")
    check(LabelGate.sendBlock(labelId: general.id, baseline: nil, justification: nil, settings: policy, tree: tree) == nil,
          "mandatory satisfied by any appliable label")

    // Downgrade justification
    check(LabelGate.isDowngrade(from: conf.id, to: general.id, tree: tree), "lowering is a downgrade")
    check(LabelGate.isDowngrade(from: conf.id, to: nil, tree: tree), "removing is a downgrade")
    check(!LabelGate.isDowngrade(from: general.id, to: conf.id, tree: tree), "raising isn't")
    check(!LabelGate.isDowngrade(from: nil, to: general.id, tree: tree), "first label isn't")
    check(LabelGate.sendBlock(labelId: general.id, baseline: conf.id, justification: nil, settings: policy, tree: tree)
          == .justificationNeeded, "downgrade without a reason is blocked when the policy requires one")
    check(LabelGate.sendBlock(labelId: general.id, baseline: conf.id, justification: "  ", settings: policy, tree: tree)
          == .justificationNeeded, "blank reason doesn't count")
    check(LabelGate.sendBlock(labelId: general.id, baseline: conf.id, justification: "Previous label was incorrect",
                              settings: policy, tree: tree) == nil, "justified downgrade may send")
    var noJust = policy; noJust.justificationRequired = false
    check(LabelGate.sendBlock(labelId: general.id, baseline: conf.id, justification: nil, settings: noJust, tree: tree) == nil,
          "no justification policy: downgrade may send")
    let stub = StubLabelPolicyProvider(settings: policy)
    let loaded = try? await stub.loadPolicy()
    check(loaded == policy && loaded?.defaultLabelId == conf.id, "provider seam returns the policy (ids lower-cased)")
    let plan = try? await stub.plan(labelId: nil, existingHeader: nil, privileged: true, justification: nil,
                                    contentId: "x", commit: true)
    check(plan?.needsJustification == true && plan?.committed == false, "removal without reason isn't committed")

    // Protected-label send gating (no Outlook-compatible rpmsg writer → refuse, never send clear)
    if case .encrypts(let n)? = LabelGate.sendBlock(labelId: secret.id, baseline: nil, justification: nil, settings: policy, tree: tree) {
        check(n == "Secret", "encrypting label blocks send with its name")
    } else { check(false, "encrypting label blocks send") }
    var dnf = policy; dnf.protection = LabelPolicySettings.parseProtection("\(general.id)\t2\n\(conf.id)\t0\n")
    check(LabelGate.protection(of: general.id, settings: dnf, tree: tree) == .doNotForward,
          "policy protection kind (Do Not Forward) parsed from the bridge lines")
    check(LabelGate.sendBlock(labelId: general.id, baseline: nil, justification: nil, settings: dnf, tree: tree) != nil,
          "Do Not Forward label blocks send even when Graph says unprotected")
    check(LabelGate.sendBlock(labelId: secret.id, baseline: nil, justification: nil, settings: .graphFallback, tree: tree)
          == .encrypts(labelName: "Secret"), "Graph fallback: hasProtection blocks too")
    check(LabelSendBlock.encrypts(labelName: "Secret").message.contains("send it from Outlook"),
          "block message points at Outlook")

    // msip_labels header shape (concept-mip-metadata#email)
    let at = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
    let md = LabelMetadata.build(labelId: conf.id.uppercased(), tenantId: tid.uppercased(), privileged: true, setDate: at)
    let p = "MSIP_Label_\(conf.id)_"
    let expected = "\(p)Enabled=true; \(p)SetDate=2023-11-14T22:13:20+0000; \(p)Method=Privileged; \(p)SiteId=\(tid); \(p)ContentBits=0"
    check(md?.headerValue == expected, "msip_labels: Enabled, SetDate, Method, SiteId, ContentBits; \"; \"-delimited, lower-case ids")
    check(MIPMetadata.activeLabelId(in: md?.headerValue ?? "", homeTenant: tid) == conf.id, "stamp round-trips through the reader's parser")
    check(LabelMetadata.build(labelId: conf.id, tenantId: tid, privileged: false, setDate: at)?.headerValue.contains("Method=Standard") == true,
          "default label stamps Method=Standard")
    check(LabelMetadata.build(labelId: conf.id, tenantId: nil, privileged: true, setDate: at) == nil,
          "no tenant → no stamp (SiteId is mandatory)")
    check(!expected.contains("ContentBits=8"), "ContentBits never claims encryption")
    let sdk = LabelMetadata.parse(lines: "\(p)Enabled=true\n\(p)SiteId=\(tid)\n\(p)Name=Confidential=x\n")
    check(sdk.entries.count == 3 && sdk.entries[2].value == "Confidential=x", "SDK metadata lines parsed (value may hold '=')")
    check(LabelMetadata.lines(fromHeader: expected).split(separator: "\n").count == 5, "header → bridge lines")

    // New meeting: header only on POST
    var ev = EventDraft(calendarId: "c", start: at, end: at.addingTimeInterval(1800))
    ev.labelId = conf.id; ev.labelHeader = md?.headerValue
    let post = ev.graphJSON()
    let props = post["singleValueExtendedProperties"] as? [[String: String]]
    check(props?.first?["id"] == MIPMetadata.extendedPropertyId && props?.first?["value"] == expected,
          "new meeting POST carries the msip_labels extended property")
    var ev2 = ev; ev2.subject = "x"
    check(ev2.graphJSON(changedFrom: ev)["singleValueExtendedProperties"] == nil, "PATCH never rewrites the label")

    // Mail draft: older encodings without labelHeader still decode
    var d = MailDraft(subject: "s", labelId: conf.id); d.labelHeader = expected
    if let data = try? JSONEncoder().encode(d), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((try? JSONDecoder().decode(MailDraft.self, from: data))?.labelHeader == expected, "draft keeps its stamp")
        obj["labelHeader"] = nil
        let old = try? JSONSerialization.data(withJSONObject: obj)
        check(old.flatMap { try? JSONDecoder().decode(MailDraft.self, from: $0) }?.labelHeader == nil, "old draft encoding decodes")
    } else { check(false, "draft encodes") }

    // Protected attachments: licence rights gate preview / save
    let viewOnly = ProtectedAttachmentGate.allowed(.viewOnly)
    check(viewOnly.preview && !viewOnly.save && !viewOnly.print, "VIEW only: in-memory preview, no save / print")
    let extract = ProtectedAttachmentGate.allowed(UsageRights.fromLicence(["VIEW", "EXTRACT"]))
    check(extract.save, "EXTRACT allows saving")
    let export = ProtectedAttachmentGate.allowed(UsageRights.fromLicence(["VIEW", "EXPORT", "PRINT"]))
    check(export.save && export.print, "EXPORT allows saving, PRINT printing")
    check(ProtectedAttachmentGate.allowed(UsageRights.fromLicence(["OWNER"])).save, "OWNER allows everything")
    let none = ProtectedAttachmentGate.allowed(UsageRights.fromLicence([]))
    check(!none.preview && !none.save, "empty licence: nothing")
    let pdf = ProtectedAttachment(id: 0, name: "Q3.pdf", contentId: nil, data: Data([1]))
    let nested = ProtectedAttachment(id: 1, name: "plan.ppdf", contentId: nil, data: Data([1]))
    check(pdf.preview == .pdf && !pdf.isItselfProtected && nested.isItselfProtected, "preview kind / nested protection detected")
    check(!ProtectedContentService.supportsAttachments || ProtectedContentService.supportsLabelPolicy,
          "bridge symbols resolve together (or not at all)")
}


/// Wire check: `GraphMailService.saveDraft` writes the computed stamp as the msip_labels extended property, nothing
/// without it, and refuses a stamp that no longer matches the draft's label (floor bump).
@MainActor func runPurviewWireTests() async {
    section("Purview: msip_labels stamp on the draft POST")
    MailStub.lock.withLock { MailStub.log = [] }
    MailStub.handler = { req, _ in
        req.httpMethod == "POST" && req.url!.path == "/v1.0/me/messages" ? (201, [:], #"{"id":"d1"}"#) : (404, [:], "{}")
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    let lid = "22222222-2222-2222-2222-222222222222", tid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let header = LabelMetadata.build(labelId: lid, tenantId: tid, privileged: true, setDate: Date(timeIntervalSince1970: 0))!.headerValue
    func posted(_ d: MailDraft) async -> [String: Any]? {
        MailStub.lock.withLock { MailStub.log = [] }
        _ = try? await svc.saveDraft(d, mailbox: "me")
        guard let b = MailStub.captured().first(where: { $0.method == "POST" })?.body else { return nil }
        return try? JSONSerialization.jsonObject(with: b) as? [String: Any]
    }
    var d = MailDraft(to: [EmailAddress(name: "A", address: "a@example.com")], subject: "s", labelId: lid)
    d.labelHeader = header
    let p1 = (await posted(d))?["singleValueExtendedProperties"] as? [[String: String]]
    check(p1?.first?["id"] == MIPMetadata.extendedPropertyId && p1?.first?["value"] == header,
          "labelled draft POST carries the full msip_labels value")
    var bare = d; bare.labelHeader = nil
    check((await posted(bare))?["singleValueExtendedProperties"] == nil, "no stamp → no extended property (kill switch / no tenant)")
    var stale = d; stale.labelId = "33333333-3333-3333-3333-333333333333"
    check((await posted(stale))?["singleValueExtendedProperties"] == nil, "stamp for another label isn't written")
    MailStub.handler = nil
}


/// Graph rejects the msip_labels property: one retry without it, success, remembered for the session.
@MainActor func runPurviewStampRejectionTests() async {
    section("Purview: a rejected msip_labels stamp never breaks saving")
    LabelStampGuard.resetForSession()
    let hits = StubCounter()
    LabelStampGuard.onRejected = { _ in hits.hit() }
    MailStub.lock.withLock { MailStub.log = [] }
    MailStub.handler = { req, body in
        guard req.httpMethod == "POST", req.url!.path == "/v1.0/me/messages" else { return (404, [:], "{}") }
        let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
        if text.contains("singleValueExtendedProperties") {
            return (400, [:], #"{"error":{"code":"ErrorInvalidProperty","message":"The extended property attribute combination is invalid."}}"#)
        }
        return (201, [:], #"{"id":"d2"}"#)
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let svc = GraphMailService(token: { "t" }, session: URLSession(configuration: cfg))
    let lid = "22222222-2222-2222-2222-222222222222"
    var d = MailDraft(to: [EmailAddress(name: "A", address: "a@example.com")], subject: "s", labelId: lid)
    d.labelHeader = LabelMetadata.build(labelId: lid, tenantId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", privileged: true,
                                        setDate: Date(timeIntervalSince1970: 0))!.headerValue
    let saved = try? await svc.saveDraft(d, mailbox: "me")
    let posts = MailStub.captured().filter { $0.method == "POST" }
    func stamped(_ c: MailStub.Captured) -> Bool {
        String(data: c.body ?? Data(), encoding: .utf8)?.contains("singleValueExtendedProperties") == true
    }
    check(saved?.id == "d2", "400 on the stamped POST → the draft is still saved")
    check(posts.count == 2 && stamped(posts[0]) && !stamped(posts[1]), "exactly one retry, without the property")
    check(LabelStampGuard.isRejected && hits.count == 1, "rejection remembered for the session, app told once (toast)")
    MailStub.lock.withLock { MailStub.log = [] }
    _ = try? await svc.saveDraft(d, mailbox: "me")
    let later = MailStub.captured().filter { $0.method == "POST" }
    check(later.count == 1 && !stamped(later[0]), "later saves skip the stamp straight away")
    check(!LabelStampGuard.isRejection(status: 400, message: "ErrorInvalidRecipients") &&
          !LabelStampGuard.isRejection(status: 500, message: "extendedProperty"),
          "only 400/422 naming the property count as a stamp rejection")
    MailStub.handler = nil
    LabelStampGuard.onRejected = nil
    LabelStampGuard.resetForSession()
}
