import Foundation

// The Desk (docs/SUITE.md, wireframes v0 / v0-2): a rail of surfaces and one to four tiles. Pure state only: which
// surfaces exist, the rail order, the tile layouts, which surface sits in which slot, and the UserDefaults encoding.
// Every surface runs off a shared model, so a surface sits in at most one slot: `slots` is always a permutation of
// all surfaces, the visible tiles are its prefix, and showing a surface that is elsewhere swaps it into place.

public enum DeskSurface: String, CaseIterable, Sendable, Codable {
    case signal, loops, when, deep, people, notes, mail, calendar

    /// Rail order, top to bottom: the work flow (Signal → Loop → When → Deep), then People and Notes, then the classic
    /// Mail list and Calendar. ⌘1…⌘8 follow this order.
    public static let railOrder: [DeskSurface] = [.signal, .loops, .when, .deep, .people, .notes, .mail, .calendar]

    /// ⌘-digit for this surface (1-based rail position).
    public var shortcutDigit: Int { (Self.railOrder.firstIndex(of: self) ?? 0) + 1 }

    /// Surface for a ⌘-digit, nil outside 1…8.
    public static func forDigit(_ d: Int) -> DeskSurface? { (1...railOrder.count).contains(d) ? railOrder[d - 1] : nil }

    /// Built surfaces mount real views; the others show a placeholder tile until their builder lands.
    public var isBuilt: Bool {
        switch self {
        case .when, .deep, .notes: false
        case .signal, .loops, .people, .mail, .calendar: true
        }
    }

    public var title: String {
        switch self {
        case .signal: "Signal"
        case .loops: "Loops"
        case .when: "When"
        case .deep: "Deep"
        case .people: "People"
        case .notes: "Notes"
        case .mail: "Mail"
        case .calendar: "Calendar"
        }
    }

    /// SF Symbol for the rail.
    public var symbol: String {
        switch self {
        case .signal: "scope"
        case .loops: "circle.dashed"
        case .when: "clock"
        case .deep: "square.stack.3d.down.right"
        case .people: "person"
        case .notes: "note.text"
        case .mail: "tray"
        case .calendar: "calendar"
        }
    }
}

/// The v0-2 Mac layouts. "One + three" has four slots (one large, three beside it), as drawn.
public enum DeskLayout: String, CaseIterable, Sendable, Codable {
    case one, two, onePlusTwo, onePlusThree

    public var slotCount: Int {
        switch self {
        case .one: 1
        case .two: 2
        case .onePlusTwo: 3
        case .onePlusThree: 4
        }
    }

    public var title: String {
        switch self {
        case .one: "One tile"
        case .two: "Two tiles"
        case .onePlusTwo: "One + two"
        case .onePlusThree: "One + three"
        }
    }

    public func cycled(forward: Bool = true) -> DeskLayout {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + (forward ? 1 : all.count - 1)) % all.count]
    }
}

public struct DeskState: Equatable, Sendable {
    public static let defaultsKey = "desk.state"
    /// The Desk is the default main-window layout; off = the classic Mail / Calendar shells.
    public static let enabledKey = "desk.enabled"
    public static let enabledDefault = true

    public private(set) var layout: DeskLayout
    /// A permutation of every surface: the first `layout.slotCount` are the visible tiles, the rest are the order
    /// in which hidden surfaces come back when the layout grows.
    public private(set) var slots: [DeskSurface]
    /// The focused tile (index into the visible slots).
    public private(set) var focus: Int

    public static let `default` = DeskState(layout: .one, slots: [.mail, .calendar, .signal, .people, .loops, .when, .deep, .notes], focus: 0)

    public init(layout: DeskLayout, slots: [DeskSurface], focus: Int) {
        self.layout = layout
        self.slots = Self.normalised(slots)
        self.focus = min(max(focus, 0), layout.slotCount - 1)
    }

    public var visible: [DeskSurface] { Array(slots.prefix(layout.slotCount)) }
    public var focused: DeskSurface { slots[focus] }
    public func isVisible(_ s: DeskSurface) -> Bool { visible.contains(s) }

    /// Bring `s` forward: focus its tile when visible, otherwise swap it into the focused tile (the surface it
    /// replaces takes its old slot, so nothing is lost and no surface is mounted twice).
    public mutating func show(_ s: DeskSurface) {
        guard let i = slots.firstIndex(of: s) else { return }
        if i < layout.slotCount { focus = i; return }
        slots.swapAt(i, focus)
    }

    /// Bring `s` forward *beside* the focused tile (a loop chip clicked in Mail must not replace Mail): focus it when
    /// visible, otherwise swap it into the last visible tile that isn't focused and focus that. Returns false in the
    /// one-tile layout when `s` isn't showing (the caller opens a window or falls back to `show`).
    @discardableResult public mutating func reveal(_ s: DeskSurface) -> Bool {
        guard let i = slots.firstIndex(of: s) else { return false }
        if i < layout.slotCount { focus = i; return true }
        guard let target = (0..<layout.slotCount).last(where: { $0 != focus }) else { return false }
        slots.swapAt(i, target)
        focus = target
        return true
    }

    /// Put `s` into tile `slot` (a drop on a tile); swaps with wherever `s` was.
    public mutating func place(_ s: DeskSurface, inSlot slot: Int) {
        guard slot >= 0, slot < layout.slotCount, let i = slots.firstIndex(of: s) else { return }
        slots.swapAt(i, slot)
        focus = slot
    }

    public mutating func setFocus(_ slot: Int) { focus = min(max(slot, 0), layout.slotCount - 1) }

    public mutating func setLayout(_ l: DeskLayout) {
        layout = l
        focus = min(focus, l.slotCount - 1)
    }

    public mutating func cycleLayout(forward: Bool = true) { setLayout(layout.cycled(forward: forward)) }

    // MARK: Persistence ("layout|s1,s2,…|focus")

    public var encoded: String { "\(layout.rawValue)|\(slots.map(\.rawValue).joined(separator: ","))|\(focus)" }

    /// Decodes a stored state; anything malformed falls back to the default, unknown or duplicate surfaces are
    /// dropped and missing ones appended in rail order.
    public static func decode(_ s: String?) -> DeskState {
        guard let s else { return .default }
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let layout = DeskLayout(rawValue: parts[0]), let focus = Int(parts[2]) else { return .default }
        let slots = parts[1].split(separator: ",").compactMap { DeskSurface(rawValue: String($0)) }
        guard !slots.isEmpty else { return .default }
        return DeskState(layout: layout, slots: slots, focus: focus)
    }

    static func normalised(_ s: [DeskSurface]) -> [DeskSurface] {
        var seen = Set<DeskSurface>(), out: [DeskSurface] = []
        for x in s where seen.insert(x).inserted { out.append(x) }
        for x in DeskSurface.railOrder where !seen.contains(x) { out.append(x) }
        return out
    }
}
