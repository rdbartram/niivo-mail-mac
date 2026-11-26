import Foundation
import CalendarCore
import MailCore

/// Purview label hierarchy: Graph parsing, Microsoft order, parents as headers, downgrade floor on parent rank.
@MainActor
func runLabelTreeTests() {
    section("Sensitivity labels: hierarchy, order, floor")

    // Shaped like the Graph beta list example: the parent appears only nested, inactive and not appliable, with the
    // same `sensitivity` as its sub-label; colours empty. Plus a plain top-level label and a second sub-label.
    let json = """
    {"value":[
      {"id":"c1","name":"Anyone (unrestricted)","description":"","color":"","sensitivity":7,"tooltip":"Child one",
       "isActive":true,"isAppliable":true,"hasProtection":false,
       "parent":{"id":"p1","name":"Highly Confidential","description":"","color":"#D2333F","sensitivity":7,
                 "tooltip":"Parent tip","isActive":false,"isAppliable":false,"hasProtection":false,"parent":null}},
      {"id":"g1","name":"General","color":"#3B7BD8","sensitivity":1,"isActive":true,"isAppliable":true},
      {"id":"c2","name":"Trusted People","color":"","sensitivity":7,"isActive":true,"isAppliable":true,"hasProtection":true,
       "parent":{"id":"p1","name":"Highly Confidential","color":"#D2333F","sensitivity":7,"isActive":false,"isAppliable":false}}
    ]}
    """
    do {
        let parsed = try GraphLabelMapper.decode(Data(json.utf8))
        check(parsed.count == 4, "nested parent synthesised once (\(parsed.count) labels)")
        let p = parsed.first { $0.id == "p1" }, c1 = parsed.first { $0.id == "c1" }, c2 = parsed.first { $0.id == "c2" }
        check(p?.isAppliable == false && p?.name == "Highly Confidential", "parent parsed from the nested object, not appliable")
        check(c1?.parentId == "p1" && c2?.parentId == "p1", "sub-labels carry the parent id")
        check(c1?.hexColor == "#D2333F", "sub-label without a colour inherits the parent's")
        check(c1?.tooltip == "Child one" && p?.tooltip == "Parent tip", "tooltips parsed")
        check((p?.displayOrder ?? 99) < (c1?.displayOrder ?? -1), "synthesised parent sits before its first sub-label")
        let tree = LabelTree(parsed)
        check(tree.nodes.map(\.id) == ["g1", "p1"], "top level in priority order; inactive parent kept as a header")
        check(tree.nodes.last?.children.map(\.id) == ["c1", "c2"], "sub-labels in response order under their parent")
        check(tree.path("c2") == "Highly Confidential › Trusted People", "chip path is Parent › Child")
        check(!tree.isSelectable("p1") && tree.isHeader("p1"), "parent with sub-labels is not selectable")
        check(tree.isSelectable("c1") && tree.isSelectable("g1"), "sub-labels and plain labels are selectable")
        check(!tree.appliable.contains { $0.id == "p1" }, "parent excluded from appliable labels")
    } catch { check(false, "Graph label JSON decodes (\(error))") }

    // Ordering is Microsoft's regardless of input order (fixtures shuffled).
    let fx = FixtureCalendarService.labels
    var shuffled = fx; shuffled.reverse(); shuffled.swapAt(0, 5); shuffled.swapAt(2, 8)
    let tree = LabelTree(shuffled)
    check(tree.flattened.map(\.id) == fx.map(\.id), "shuffled labels come back in Microsoft order")
    let eng = CachedLabelPolicyEngine(labels: shuffled, synced: true)
    check(eng.availableLabels().map(\.id) == fx.filter { $0.id != FixtureCalendarService.labelSecretGroup }.map(\.id),
          "availableLabels: Microsoft order, group header excluded")
    check(eng.labelTree().path(FixtureCalendarService.labelSecretSpecified) == "Secret › Specified People", "fixture sub-label path")

    // Direction: higher priority = more sensitive (Purview order number). A reply can't go below its original.
    func reply(original: String, draft: String?) -> String? {
        let orig = MailMessage(id: "m", folderId: "f", conversationId: "c", subject: "s", from: nil, received: t0, labelId: original)
        return MailLabelFloor.enforce(MailDraft(kind: .reply, replyTo: "m", labelId: draft), original: orig, engine: eng).labelId
    }
    let secretAll = FixtureCalendarService.labelSecretAllEmployees, secretSpec = FixtureCalendarService.labelSecretSpecified
    let general = fx[1].id, hc = fx[3].id
    check(reply(original: secretAll, draft: general) == secretAll, "top-level label below a sub-label original → bumped")
    check(reply(original: secretAll, draft: secretSpec) == secretSpec, "sibling sub-label swap is kept (same priority)")
    check(reply(original: hc, draft: secretAll) == secretAll, "higher sub-label on a reply is kept")
    check(reply(original: secretAll, draft: FixtureCalendarService.labelSecretGroup) == secretAll,
          "parent (group header) as the draft label is rejected")

    // A sub-label whose own number differs from its parent's still counts as the parent's tier.
    let odd: [SensitivityLabel] = [
        .init(id: "low", name: "General", priority: 1),
        .init(id: "mid", name: "Confidential", priority: 5),
        .init(id: "par", name: "Secret", priority: 8, isAppliable: false),
        .init(id: "k1", name: "Board", priority: 2, parentId: "par", displayOrder: 1),
        .init(id: "k2", name: "Legal", priority: 9, parentId: "par", displayOrder: 2),
    ]
    let oddTree = LabelTree(odd)
    check(oddTree.floorRank("k1") == 8, "sub-label floor rank is its parent's priority")
    check(oddTree.nodes.map(\.id) == ["low", "mid", "par"], "parents ordered by their own priority")
    let oddEng = CachedLabelPolicyEngine(labels: odd, synced: true)
    let o = MailMessage(id: "m", folderId: "f", conversationId: "c", subject: "s", from: nil, received: t0, labelId: "k2")
    check(MailLabelFloor.enforce(MailDraft(kind: .reply, replyTo: "m", labelId: "k1"), original: o, engine: oddEng).labelId == "k1",
          "sibling with a lower own number is still the same tier (kept)")
    check(MailLabelFloor.enforce(MailDraft(kind: .reply, replyTo: "m", labelId: "mid"), original: o, engine: oddEng).labelId == "k2",
          "top-level label below the parent tier → bumped")
    check(oddTree.meetsFloor("k1", floor: "mid") && !oddTree.meetsFloor("low", floor: "k1"), "meetsFloor follows the parent tier")
}
