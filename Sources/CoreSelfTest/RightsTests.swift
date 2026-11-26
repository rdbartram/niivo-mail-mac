import Foundation
import CalendarCore
import MailCore

/// Stand-in for the MIP SDK's per-item licence (no production conformer exists yet).
struct StubItemRights: ItemRightsProvider {
    var byItem: [String: UsageRights]
    func rights(itemId: String, labelId: String?) -> UsageRights? { byItem[itemId] }
}

/// Usage-rights matrix: copy/print/export/forward/reply follow the Purview label's rights, not label priority.
@MainActor
func runRightsTests() {
    section("Usage rights (Purview) matrix")
    let L = FixtureCalendarService.labels
    let eng = CachedLabelPolicyEngine(labels: L, synced: true)
    func pol(_ label: String?, item: String = "i", priv: Bool = false, access: CalendarAccess = .own,
             engine: CachedLabelPolicyEngine? = nil) -> ContentPolicy {
        (engine ?? eng).policy(labelId: label, isPrivate: priv, access: access, itemId: item)
    }
    func msg(_ label: String?, id: String = "x") -> MailMessage {
        MailMessage(id: id, folderId: "f", conversationId: "c", subject: "S", from: .init(name: "A", address: "a@contoso.example"),
                    toRecipients: [.init(name: "B", address: "b@contoso.example")], received: Date(), preview: "p", body: "b",
                    labelId: label)
    }

    // Parsing Graph's usageRightsIncluded.value.
    check(UsageRights.parse("docEdit, edit, forward, print, reply, replyAll, view, extract, viewRightsData, objModel")
          == [.docEdit, .edit, .forward, .print, .reply, .replyAll, .view, .extract, .viewRightsData, .objModel],
          "parses the documented comma-separated value (case-insensitive)")
    check(UsageRights.parse(["view", "print"]) == [.view, .print], "parses a string-array value")
    check(UsageRights.parse(["owner"]) == .all, "OWNER (Full Control) expands to every right")
    check(UsageRights.parse("accessDenied") == nil && UsageRights.parse(["labelNotFoundException", "bogus"]) == nil,
          "error sentinels / unknown tokens grant nothing")
    check(UsageRights.parse("view, comment, unknownFutureValue") == [.view, .comment], "unknown tokens ignored alongside known ones")

    // 1. Unlabelled.
    let u = pol(nil)
    check(u.rights == .all && u.allowCopy && u.allowPrint && u.allowExport && u.allowForward && u.allowReply && u.allowReplyAll
          && !u.preventScreenCapture, "unlabelled → all rights, capture allowed")

    // 2. Unencrypted Confidential: copy allowed now (was blocked by our own priority rule).
    let c = pol(L[2].id)
    check(c.allowCopy && c.allowPrint && c.allowExport && c.allowForward && !c.preventScreenCapture && c.rightsSource == .unencrypted,
          "unencrypted Confidential → copy/print/export/forward allowed (no usage restrictions without encryption)")
    check(c.headerMarking == L[2].headerText && c.footerMarking == L[2].footerText && c.allowOfflineDetails,
          "unencrypted Confidential → markings still applied, details cacheable")

    // 3. Encrypted, VIEW only (Graph returned the rights).
    let v = pol(L[4].id)
    check(v.rights.contains(.view) && !v.allowCopy && !v.allowPrint && !v.allowExport && !v.allowForward && !v.allowReply
          && v.rightsSource == .label, "encrypted VIEW-only → no copy/print/export/forward/reply")
    check(v.preventScreenCapture && v.bodyIsProtected && !v.allowOfflineDetails, "encrypted without EXTRACT → capture blocked, not cached")

    // 4. Encrypted, VIEW + EXTRACT + PRINT.
    let cp = pol(L[5].id)
    check(cp.allowCopy && cp.allowPrint && !cp.allowExport && cp.allowForward && !cp.preventScreenCapture,
          "encrypted VIEW+EXTRACT+PRINT → copy & print allowed, export not, capture allowed")
    check(cp.bodyIsProtected && !cp.allowOfflineDetails, "rights never loosen caching: encrypted body still not cached")

    // 5. Encrypted without FORWARD (Do Not Forward).
    let d = pol(L[6].id)
    check(!d.allowForward && d.allowReply && d.allowReplyAll && !d.allowCopy && !d.allowPrint,
          "Do Not Forward → forward blocked, reply / reply all allowed, no copy/print")
    check(!MailActionRights.allows(.forward, policy: d) && MailActionRights.allows(.reply, policy: d)
          && MailActionRights.allows(.replyAll, policy: d) && MailActionRights.allows(.new, policy: d),
          "mail action gate: forward refused, reply/reply all/new allowed")
    check(MailActionRights.help(.forward, policy: d, otherwise: "Forward (F)") == "Not allowed by the sensitivity label"
          && MailActionRights.help(.reply, policy: d, otherwise: "Reply (R)") == "Reply (R)", "tooltip explains the label refusal")
    let dm = MailContentPolicy.policy(for: msg(L[6].id), engine: eng)
    check(!dm.allowForward && dm.rights == d.rights, "MailContentPolicy uses the same rights as calendar items")

    // Encrypted, rights unknown (Graph rights not fetched / 403) → VIEW only.
    let hc = pol(L[3].id)
    check(hc.rights == .viewOnly && hc.rightsSource == .encryptedUnknown && hc.preventScreenCapture && !hc.allowForward,
          "encrypted with unknown rights → fail closed to VIEW only")

    // 6. Unknown label.
    let x = pol(FixtureCalendarService.orphanLabelId)
    check(!x.allowCopy && !x.allowExport && !x.allowPrint && x.preventScreenCapture && !x.allowOfflineDetails
          && x.allowReply && x.allowForward && x.rightsSource == .unknownLabel,
          "unknown label → fail closed as before: no copy/export/print, capture blocked, not cached; reply/forward kept")

    // Per-item licence beats label rights.
    let withItem = CachedLabelPolicyEngine(labels: L, synced: true,
                                           itemRights: StubItemRights(byItem: ["lic": [.view, .reply], "irm": [.view]]))
    let li = pol(L[5].id, item: "lic", engine: withItem)
    check(li.rightsSource == .itemLicence && !li.allowCopy && li.allowReply && li.preventScreenCapture,
          "per-item licence rights (MIP hook) take precedence over the label's Graph rights")
    let irm = pol(nil, item: "irm", engine: withItem)
    check(irm.bodyIsProtected && !irm.allowCopy && irm.preventScreenCapture, "unlabelled but item-encrypted (IRM) → licence honoured")
    check(pol(L[5].id, item: "other", engine: withItem).rightsSource == .label, "no licence for the item → label rights")

    // Legacy private on a shared calendar: redaction drops copy/export only, doesn't trip the capture rule.
    let pv = pol(nil, priv: true, access: .shared)
    check(pv.redactDetails && !pv.allowCopy && !pv.allowExport && pv.allowPrint && !pv.preventScreenCapture,
          "legacy private (shared) → redacted, no copy/export, capture unaffected")

    // 7. Optional admin overlay (old priority rule), off by default.
    check(EnforcementSettings().extraRestrictions == nil, "extraRestrictions is nil by default")
    let strict = CachedLabelPolicyEngine(labels: L, synced: true,
                                         settings: .init(extraRestrictions: .init(restrictCopyAtPriority: 2, blockCaptureAtPriority: 3)))
    let sc = pol(L[2].id, engine: strict)
    check(!sc.allowCopy && !sc.allowExport && sc.allowPrint && sc.allowForward && !sc.preventScreenCapture,
          "overlay on: Confidential (priority 2) loses copy/export, keeps print/forward")
    check(pol(L[1].id, engine: strict).allowCopy, "overlay on: General below threshold → unaffected")
    let scp = pol(L[5].id, engine: strict)
    check(!scp.allowCopy && scp.allowPrint && scp.preventScreenCapture, "overlay on: priority ≥ capture threshold → capture blocked on top of rights")

    // Merge keeps the intersection of rights.
    let mg = cp.merged(with: d)
    check(!mg.allowForward && !mg.allowCopy && !mg.allowPrint && mg.allowReply,
          "merge intersects rights")

    // 8. AI gate: Copilot's VIEW + EXTRACT rule for encrypted items; aiMaxPriority still applies to every label.
    check(!v.aiMayReadContent && cp.aiMayReadContent && c.aiMayReadContent && u.aiMayReadContent,
          "aiMayReadContent: encrypted needs VIEW+EXTRACT; unencrypted always")
    check(sc.aiMayReadContent, "overlay stripping EXTRACT from an unencrypted label doesn't change AI access")
    let ai = AIAccessPolicy(engine: eng, aiMaxPriority: 99)
    check(ai.level(for: msg(L[5].id)) == .full && ai.redactForAI(msg(L[5].id))?.body == "b",
          "AI: encrypted with EXTRACT (and below aiMaxPriority) → content")
    let noX = ai.redactForAI(msg(L[4].id))
    check(ai.level(for: msg(L[4].id)) == .metadataOnly && noX?.body == nil && noX?.subject == AIAccessPolicy.protectedSubject,
          "AI: encrypted without EXTRACT → metadata only, subject withheld")
    check(ai.level(for: msg(L[3].id)) == .metadataOnly, "AI: encrypted with unknown rights → metadata only")
    let aiDefault = AIAccessPolicy(engine: eng)
    let cpMeta = aiDefault.redactForAI(msg(L[5].id))
    check(aiDefault.level(for: msg(L[5].id)) == .metadataOnly && cpMeta?.body == nil && cpMeta?.subject == "S",
          "AI: EXTRACT granted but priority ≥ aiMaxPriority → metadata only (admin setting), subject kept")
    let aiItem = AIAccessPolicy(engine: withItem, aiMaxPriority: 99)
    check(aiItem.level(for: msg(L[5].id, id: "lic")) == .metadataOnly, "AI: per-item licence without EXTRACT overrides label EXTRACT")
}
