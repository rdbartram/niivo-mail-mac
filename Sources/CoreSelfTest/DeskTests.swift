import Foundation
import MailCore

// DESK (docs/SUITE.md): rail order, layouts, slot assignment (single mount), cycling, persistence.
@MainActor
func runDeskTests() {
    section("Desk: rail, layouts, single mount, cycling, persistence")
    check(DeskSurface.railOrder.count == DeskSurface.allCases.count && Set(DeskSurface.railOrder) == Set(DeskSurface.allCases),
          "rail lists every surface once")
    check(DeskSurface.railOrder.prefix(4) == [.signal, .loops, .when, .deep], "rail starts with the flow Signal → Loop → When → Deep")
    check(DeskSurface.railOrder.map(\.shortcutDigit) == Array(1...8), "⌘1…⌘8 follow the rail")
    check(DeskSurface.forDigit(1) == .signal && DeskSurface.forDigit(8) == .calendar && DeskSurface.forDigit(0) == nil && DeskSurface.forDigit(9) == nil,
          "digit → surface, out of range is nil")
    check(DeskSurface.allCases.filter { !$0.isBuilt } == [.when, .deep, .notes], "When, Deep, Notes are placeholders")
    check(DeskLayout.allCases.map(\.slotCount) == [1, 2, 3, 4], "layouts one / two / one+two / one+three = 1…4 slots")
    check(DeskLayout.onePlusThree.cycled() == .one && DeskLayout.one.cycled(forward: false) == .onePlusThree, "layout cycling wraps")

    var s = DeskState.default
    check(s.visible == [.mail] && s.layout == .one && s.focus == 0, "default: one tile, Mail (a full mail shell needs the width)")
    var r1 = s
    check(!r1.reveal(.loops) && r1.visible == [.mail], "reveal in one tile: nothing replaced, caller opens a window")
    s.setLayout(.two)
    var r2 = s
    check(r2.reveal(.loops) && r2.visible == [.mail, .loops] && r2.focus == 1, "reveal puts the surface beside the focused tile, not over it")
    r2.setFocus(1)
    check(r2.reveal(.people) && r2.visible == [.people, .loops] && r2.focus == 0, "reveal from the second tile uses the first")
    check(r2.reveal(.loops) && r2.focus == 1 && r2.visible == [.people, .loops], "reveal of a visible surface just focuses it")
    check(s.visible == [.mail, .calendar] && s.focus == 0, "two tiles: Mail + Calendar, Mail focused")
    s.show(.calendar)
    check(s.focus == 1 && s.visible == [.mail, .calendar], "showing a visible surface focuses its tile")
    s.show(.signal)
    check(s.visible == [.mail, .signal] && s.focus == 1, "showing a hidden surface swaps it into the focused tile")
    check(s.slots.contains(.calendar) && Set(s.slots).count == DeskSurface.allCases.count, "the replaced surface is kept, no surface twice")
    s.place(.mail, inSlot: 1)
    check(s.visible == [.signal, .mail] && s.focus == 1, "placing a visible surface in another tile swaps the two")
    s.place(.people, inSlot: 5)
    check(s.visible == [.signal, .mail], "placing outside the visible tiles is ignored")
    s.setLayout(.onePlusThree)
    check(s.visible.count == 4 && Set(s.visible).count == 4, "four tiles, four distinct surfaces")
    s.setFocus(3)
    s.setLayout(.one)
    check(s.focus == 0 && s.visible.count == 1, "shrinking the layout clamps the focus")
    s.cycleLayout()
    check(s.layout == .two, "cycle forward: one → two")
    s.cycleLayout(forward: false); s.cycleLayout(forward: false)
    check(s.layout == .onePlusThree, "cycle back wraps to one + three")

    // Persistence.
    let round = DeskState.decode(s.encoded)
    check(round == s, "encode / decode round-trips")
    check(DeskState.decode(nil) == .default && DeskState.decode("garbage") == .default && DeskState.decode("two||0") == .default,
          "malformed state falls back to the default")
    let messy = DeskState.decode("onePlusTwo|people,people,bogus,mail|7")
    check(messy.visible == [.people, .mail, .signal] && messy.slots.count == 8 && Set(messy.slots).count == 8 && messy.focus == 2,
          "duplicates / unknown surfaces dropped, missing appended in rail order, focus clamped")
    check(DeskState.defaultsKey == "desk.state" && DeskState.enabledKey == "desk.enabled" && DeskState.enabledDefault,
          "persistence keys: desk.state, desk.enabled (default on)")
}
