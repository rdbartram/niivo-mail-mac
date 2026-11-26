import SwiftUI

/// Visual language for the whole app. Themes differ in density, shape and fill, not just colour,
/// so "Outlook people" and "Google people" both feel at home.
struct Theme: Identifiable, Hashable {
    enum Fill: Hashable { case glass, tinted, solid, outlined }

    var id: String
    var name: String
    var symbol: String
    var hourHeight: CGFloat
    var corner: CGFloat
    var fill: Fill
    var leadingBar: CGFloat            // 0 = none
    var titleWeight: Font.Weight
    var design: Font.Design
    var gridLine: Double
    var accent: Color
    var todayFill: Color               // today's date capsule
    var todayColumn: Color             // subtle wash on today's column(s)
    var gridBackground: AnyShapeStyle
    var blockShadow: Double
    /// The niivo brand theme (paper/carbon, Instrument Sans + JetBrains Mono, radius 0). See docs/NIIVO-THEME.md.
    var brand: Bool = false
    /// Text on `todayFill`.
    var todayText: Color = .white

    /// niivo: paper-first, squared, one cyan element (today's date) per view.
    static let niivo = Theme(
        id: "niivo", name: "niivo", symbol: "square.split.2x1", hourHeight: 52, corner: 0, fill: .tinted, leadingBar: 3,
        titleWeight: .medium, design: .default, gridLine: 0.10, accent: NV.accentInk, todayFill: NV.accentFill,
        todayColumn: NV.accentSoft.opacity(0.35), gridBackground: AnyShapeStyle(NV.ground), blockShadow: 0,
        brand: true, todayText: NV.onAccent)

    static let glass = Theme(
        id: "glass", name: "Glass", symbol: "sparkles", hourHeight: 56, corner: 10, fill: .glass, leadingBar: 0,
        titleWeight: .semibold, design: .rounded, gridLine: 0.07, accent: .pink, todayFill: .pink,
        todayColumn: .pink.opacity(0.035),
        gridBackground: AnyShapeStyle(LinearGradient(colors: [Color.indigo.opacity(0.06), Color.pink.opacity(0.05), Color.teal.opacity(0.04)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)),
        blockShadow: 0.12)

    static let outlook = Theme(
        id: "outlook", name: "Outlook", symbol: "square.grid.3x3", hourHeight: 44, corner: 2, fill: .tinted, leadingBar: 4,
        titleWeight: .semibold, design: .default, gridLine: 0.13, accent: Color(hex: "#0F6CBD"), todayFill: Color(hex: "#0F6CBD"),
        todayColumn: Color(hex: "#0F6CBD").opacity(0.06), gridBackground: AnyShapeStyle(Color(nsColor: .textBackgroundColor)),
        blockShadow: 0)

    static let google = Theme(
        id: "google", name: "Google", symbol: "circle.grid.2x2", hourHeight: 52, corner: 8, fill: .solid, leadingBar: 0,
        titleWeight: .medium, design: .default, gridLine: 0.08, accent: Color(hex: "#1A73E8"), todayFill: Color(hex: "#1A73E8"),
        todayColumn: .clear, gridBackground: AnyShapeStyle(Color(nsColor: .textBackgroundColor)), blockShadow: 0.08)

    static let classic = Theme(
        id: "classic", name: "Classic", symbol: "calendar", hourHeight: 54, corner: 5, fill: .tinted, leadingBar: 3,
        titleWeight: .semibold, design: .default, gridLine: 0.09, accent: .red, todayFill: .red, todayColumn: .clear,
        gridBackground: AnyShapeStyle(Color(nsColor: .textBackgroundColor)), blockShadow: 0)

    static let all: [Theme] = [.niivo, .glass, .outlook, .google, .classic]

    /// Event and header text: Instrument Sans in the brand, the system face in the theme's design otherwise.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        brand ? NiivoFonts.sans(size, weight) : .system(size: size, weight: weight, design: design)
    }
    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension View {
    /// Floating chrome (day header) — real Liquid Glass on macOS 26+, only for the Glass theme.
    @ViewBuilder func themedChrome(_ t: Theme) -> some View {
        // Glass sits in a background layer, inset from the edges, so the header's column geometry stays
        // identical to the grid below (padding the content itself would shift every day label).
        if t.fill == .glass {
            self.background {
                if NMotion.reduceTransparency {   // A11Y-HOOK: Reduce Transparency → solid
                    RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)).padding(.horizontal, 4).padding(.vertical, 3)
                } else if #available(macOS 26, *) {
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(.horizontal, 4).padding(.vertical, 3)
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).padding(.horizontal, 4).padding(.vertical, 3)
                }
            }
            .padding(.vertical, 3)
        } else {
            self
        }
    }

    /// Event-block surface for the active theme. Glass uses Liquid Glass on macOS 26+, material before that.
    @ViewBuilder func eventSurface(_ t: Theme, tint: Color, selected: Bool, tentative: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.corner, style: .continuous)
        switch t.fill {
        case .glass:
            // Frosted, colour-forward: the calendar colour must read at a glance (Liquid Glass over a light grid
            // renders grey), so tint a gradient over material and add a specular edge.
            self
                .background(LinearGradient(colors: [tint.opacity(selected ? 0.62 : (tentative ? 0.16 : 0.40)),
                                                    tint.opacity(selected ? 0.45 : (tentative ? 0.08 : 0.24))],
                                           startPoint: .top, endPoint: .bottom), in: shape)
                .background(NMotion.reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial), in: shape)   // A11Y-HOOK
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        case .tinted where t.brand:
            // niivo: square card, calendar-colour wash + the 3 pt left bar (leadingBar); selection = 1 pt ink frame.
            self.background(tint.opacity(selected ? 0.24 : (tentative ? 0.05 : 0.13))).background(NV.card)
                .overlay { if selected { Rectangle().strokeBorder(NV.ink, lineWidth: 1) } }
        case .tinted:
            self.background(tint.opacity(selected ? 0.42 : (tentative ? 0.10 : 0.20)), in: shape).background(.background, in: shape)
        case .solid:
            self.background(tentative ? tint.opacity(0.25) : tint.opacity(selected ? 1 : 0.88), in: shape)
        case .outlined:
            self.background(.background, in: shape).overlay(shape.strokeBorder(tint, lineWidth: selected ? 2 : 1))
        }
    }
}
