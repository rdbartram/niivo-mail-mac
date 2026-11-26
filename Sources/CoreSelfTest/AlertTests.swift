import Foundation
import CalendarCore

@MainActor
func runAlertTests() {
    section("Alert text is built from policy")
    let eng = CachedLabelPolicyEngine()
    let hc = SensitivityLabel(id: "hc", name: "Highly Confidential", priority: 3, hasProtection: true)
    eng.update(labels: [hc], synced: true)
    func pol(_ e: CalendarEvent, _ access: CalendarAccess = .own) -> ContentPolicy {
        eng.policy(for: e, context: .init(calendarAccess: access))
    }
    let base = CalendarEvent(id: "a", calendarId: "c", subject: "Acquisition of Contoso", start: .now, end: .now.addingTimeInterval(1800),
                             location: "Room Eiger")
    var labelled = base; labelled.labelId = "hc"
    var unknown = base; unknown.labelId = "not-in-policy"
    var priv = base; priv.legacySensitivity = .private

    let open = AlertComposer.compose(subject: base.subject, location: base.location, provider: "Zoom", ownerName: nil,
                                     minutes: 5, policy: pol(base), surface: .system)
    check(open.title == "Acquisition of Contoso" && open.body.contains("Zoom") && !open.restricted, "unlabelled → subject + provider")

    let l = AlertComposer.compose(subject: labelled.subject, location: labelled.location, provider: nil, ownerName: "Sam Rivera",
                                  minutes: 5, policy: pol(labelled), surface: .system)
    check(l.restricted && !l.title.contains("Contoso") && !l.body.contains("Eiger"), "encrypted label → no subject/location on lock screen")
    check(l.title == "Confidential meeting in 5 min", "encrypted label → generic title (\(l.title))")

    let u = AlertComposer.compose(subject: unknown.subject, location: nil, provider: nil, ownerName: nil,
                                  minutes: 1, policy: pol(unknown), surface: .system)
    check(u.restricted && !u.title.contains("Contoso"), "unknown label → fail closed in notification")

    let p = AlertComposer.compose(subject: priv.subject, location: priv.location, provider: nil, ownerName: "Sam Rivera",
                                  minutes: 0, policy: pol(priv, .delegated), surface: .inApp)
    check(p.title == "Private appointment now" && !p.body.contains("Contoso"), "private (delegate view) hidden even in-app")

    let inApp = AlertComposer.compose(subject: labelled.subject, location: nil, provider: nil, ownerName: nil,
                                      minutes: 3, policy: pol(labelled), surface: .inApp)
    check(inApp.title == "Acquisition of Contoso", "in-app banner may show what the grid already shows")
}

@MainActor
func runFreeTimeTests() {
    section("Everyone-free gaps")
    let cal = Calendar.current
    let day = cal.startOfDay(for: .now)
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: day)! }
    let a = CalendarEvent(id: "a", calendarId: "x", subject: "", start: at(9), end: at(10))
    let b = CalendarEvent(id: "b", calendarId: "y", subject: "", start: at(9, 30), end: at(11))
    var f = CalendarEvent(id: "f", calendarId: "y", subject: "", start: at(12), end: at(13)); f.showAs = .free
    let g = FreeTime.gaps([a, b, f], day: day, from: 8 * 60, to: 14 * 60)
    check(g.count == 2 && g[0] == (480, 540) && g[1] == (660, 840), "overlapping busy merged, 'free' doesn't block (\(g))")
    var oof = CalendarEvent(id: "o", calendarId: "z", subject: "", start: day, end: at(24), isAllDay: true); oof.showAs = .oof
    check(FreeTime.gaps([a, oof], day: day, from: 480, to: 840).isEmpty, "all-day OOF → nobody-free day")
    var hol = oof; hol.showAs = .free
    check(FreeTime.gaps([hol], day: day, from: 480, to: 840).count == 1, "all-day 'free' (e.g. holiday marker) doesn't block")
    let short = CalendarEvent(id: "s", calendarId: "x", subject: "", start: at(8, 10), end: at(14))
    check(FreeTime.gaps([short], day: day, from: 480, to: 840).isEmpty, "gaps under 15 min dropped")
}
