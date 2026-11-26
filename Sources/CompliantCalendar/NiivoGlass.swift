import SwiftUI
import AppKit

// Liquid Glass for niivo (docs/NIIVO-THEME.md §8). Glass is the control layer that floats above content: the Desk
// rail, tile headers, action strips, floating bars, chips. Content (mail bodies, lists, pages) stays solid.
//
// Rules: real Liquid Glass on macOS 26+, `.regularMaterial` before that, solid `skin.card` when Reduce Transparency
// or Increase Contrast is on. Tints are neutral or ink, never `accentFill` (the one cyan element per view stays
// a solid). Glass may be rounded: it is a floating control, not a niivo content surface (radius 0 stays for content).

enum NiivoGlass {
    /// Solid instead of glass: Reduce Transparency or Increase Contrast (A11Y-HOOK).
    @MainActor static var solid: Bool {
        NMotion.reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    /// Corner radius of glass panels (rail, strips, tile headers) and of glass keys.
    static let panelRadius: CGFloat = 14
    static let keyRadius: CGFloat = 9
}

extension View {
    /// The base glass surface in `shape`. `tint` washes the glass lightly (ink or neutral; never cyan fill).
    @ViewBuilder func niivoGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NiivoGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// A floating glass panel: rounded rect, hairline edge in the solid fallback.
    func niivoGlassCard(radius: CGFloat = NiivoGlass.panelRadius, tint: Color? = nil) -> some View {
        niivoGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// A glass capsule (chips, compact bars).
    func niivoGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        niivoGlass(in: Capsule(), tint: tint, interactive: interactive)
    }
}

private struct NiivoGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.skin) private var skin
    @Environment(\.colorSchemeContrast) private var contrast
    var shape: S
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if NiivoGlass.solid || contrast == .increased {
            content
                .background(shape.fill(skin.brand ? skin.card : Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(skin.hair2, lineWidth: 1))
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(.regularMaterial))
                .background(shape.fill(tint?.opacity(0.10) ?? .clear))
                .overlay(shape.stroke(skin.hair.opacity(0.8), lineWidth: 0.5))
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.14)) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups glass shapes so they blend and morph together (`GlassEffectContainer` on macOS 26+, a plain stack before).
struct NiivoGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content
    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) { self.spacing = spacing; self.content = content }
    var body: some View {
        if #available(macOS 26, *), !NiivoGlass.solid {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Glass keys (action strips 1 / 2 / 3)

/// A key in a glass action strip: title, optional numbered key cap, primary = ink-tinted prominent glass.
/// Pre-26 and with Reduce Transparency / Increase Contrast it is the solid niivo key the strips had before.
struct NiivoGlassKeyStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { Key(configuration: configuration, primary: primary) }

    private struct Key: View {
        @Environment(\.skin) private var skin
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        let configuration: Configuration
        let primary: Bool
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: NiivoGlass.keyRadius, style: .continuous)
            let solid = NiivoGlass.solid || contrast == .increased
            let label = configuration.label
                // Solid primary = card-on-ink (onAccent is near-black in both appearances: unreadable on light ink).
                .foregroundStyle(primary && enabled && (solid || !glassAvailable) ? skin.card : skin.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.7 : 1)
            Group {
                if solid || !glassAvailable {
                    label.background(shape.fill(primary && enabled ? skin.ink : skin.soft))
                } else if #available(macOS 26, *) {
                    label.glassEffect(primary && enabled ? Glass.regular.tint(skin.ink.opacity(0.22)).interactive() : Glass.regular.interactive(), in: shape)
                }
            }
            .opacity(enabled ? 1 : 0.5)
        }
        private var glassAvailable: Bool { if #available(macOS 26, *) { true } else { false } }
    }
}

extension View {
    /// Glass button style for toolbar-like controls: `.glass` / `.glassProminent` on 26+, the niivo button before.
    @ViewBuilder func niivoGlassButton(_ skin: Skin, prominent: Bool = false) -> some View {
        if #available(macOS 26, *), !NiivoGlass.solid {
            if prominent { self.buttonStyle(.glassProminent).tint(skin.ink) } else { self.buttonStyle(.glass) }
        } else {
            self.nvButton(skin, prominent ? .primary : .ghost)
        }
    }
}

/// A numbered key cap ("1", "2", "3") used inside glass keys.
struct NiivoKeyCap: View {
    @Environment(\.skin) private var skin
    var key: String
    var body: some View {
        Text(key).font(skin.mono(NV.Size.labelSm)).padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(skin.muted, lineWidth: 0.8))
    }
}
