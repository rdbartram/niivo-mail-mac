import SwiftUI
import CalendarCore

/// Calendar colours people can tell apart. Graph often returns "" or the same "auto" colour for several
/// calendars, so we resolve: user override → Graph colour if present and unique → stable palette slot.
enum CalendarPalette {
    static let swatches: [(name: String, hex: String)] = [
        ("Blue", "#3A7DFF"), ("Teal", "#14A3A3"), ("Purple", "#9B5CFF"), ("Orange", "#FF7A2F"),
        ("Pink", "#E5457B"), ("Green", "#2FA84F"), ("Indigo", "#5856D6"), ("Gold", "#D9A400"),
        ("Red", "#E0383E"), ("Graphite", "#7D8794"),
    ]

    static func resolve(_ cals: [CalendarInfo], overrides: [String: String]) -> [String: Color] {
        var out: [String: Color] = [:], used = Set<String>()
        // Overrides first, then calendars with a distinct Graph colour, then fill the rest from the palette.
        for c in cals { if let o = overrides[c.id] { out[c.id] = Color(hex: o); used.insert(o.uppercased()) } }
        let graph = Dictionary(grouping: cals.compactMap { c -> (String, String)? in
            guard out[c.id] == nil, let h = c.hexColor, h.count >= 7 else { return nil }; return (h.uppercased(), c.id)
        }, by: \.0)
        for (hex, ids) in graph where ids.count == 1 && !used.contains(hex) { out[ids[0].1] = Color(hex: hex); used.insert(hex) }
        for c in cals where out[c.id] == nil {
            let start = Int(stableHash(c.id) % UInt64(swatches.count))
            let pick = (0..<swatches.count).map { swatches[($0 + start) % swatches.count].hex }.first { !used.contains($0) }
                ?? swatches[start].hex
            out[c.id] = Color(hex: pick); used.insert(pick)
        }
        return out
    }

    /// FNV-1a — stable across launches (Swift's hashValue is seeded per process).
    static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}

extension CalendarInfo {
    /// The person (or resource) the calendar belongs to, for "whose is this?" everywhere.
    var ownerDisplay: String { access == .own ? "You" : (ownerName.isEmpty ? name : ownerName) }
    var initials: String {
        if access == .own { return "Me" }
        let parts = ownerDisplay.split(whereSeparator: { $0 == " " || $0 == "(" }).prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Small owner badge: initials on the calendar's colour. Used on event blocks, schedule rows, inspector.
struct OwnerBadge: View {
    var calendar: CalendarInfo
    var tint: Color
    var size: CGFloat = 16
    var body: some View {
        Text(calendar.initials)
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.gradient))
            .help("\(calendar.ownerDisplay) · \(calendar.name)")
    }
}
