import SwiftUI
import AppKit
import CoreText

// niivo brand tokens and components. Every value is sourced in docs/NIIVO-THEME.md (file:line per token).
// Light = the brand's paper surface, dark = its carbon surface.

// MARK: - Palette

enum NV {
    /// A colour that follows the window's appearance (paper ↔ carbon).
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark, .accessibilityHighContrastAqua,
                                              .accessibilityHighContrastDarkAqua]).map { $0.rawValue.lowercased().contains("dark") } ?? false
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    static let ground     = dyn(0xF2F1EF, 0x0C0C0C)   // paper / carbon
    static let card       = dyn(0xFFFFFF, 0x111111)
    static let soft       = dyn(0xE9E8E4, 0x161614)
    static let ink        = dyn(0x111111, 0xF2F1EF)
    static let muted      = dyn(0x6E6E6A, 0x8A8A86)
    static let guide      = dyn(0x9D9C9B, 0x6D6C6B)
    static let hair       = dyn(0xD8D7D3, 0x2A2A28)
    static let hair2      = dyn(0xC9C8C4, 0x3A3A38)
    static let accentInk  = dyn(0x006E88, 0x00D0FF)   // accent text + strokes: never raw cyan on paper
    static let accentFill = dyn(0x00D0FF, 0x00D0FF)   // the one solid per view
    static let accentSoft = dyn(0xCEECF1, 0x0A272E)
    static let onAccent   = dyn(0x0C0C0C, 0x0C0C0C)
    static let danger     = dyn(0xE7000B, 0xFF6467)   // niivo-website globals.css --destructive (the CI has no red)

    /// UI type scale (family web scale × ~0.8 for macOS points; see docs §1.2).
    enum Size {
        static let display: CGFloat = 34, title: CGFloat = 22, bodyLg: CGFloat = 16, body: CGFloat = 13
        static let bodySm: CGFloat = 12, label: CGFloat = 10.5, labelSm: CGFloat = 9.5
    }
    static let lean = 11.03 * Double.pi / 180      // the mark's and cursor's lean
    static let blinkPeriod = 1.06                   // stepped, on for 0–55 %
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Fonts

/// Registers the bundled Instrument Sans + JetBrains Mono (OFL 1.1) for this process. Never uses `Bundle.module`
/// (it traps when the resource bundle is missing, e.g. an .app assembled without it): falls back to system faces.
enum NiivoFonts {
    static let bundleName = "CompliantOffice_CompliantCalendar.bundle"
    static let files = ["instrument-sans-latin.woff2", "jetbrains-mono-latin.woff2"]

    /// Evaluated once (thread-safe static init): true when both faces resolve by PostScript name.
    static let available: Bool = register()

    static var fontsDirectory: URL? {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { roots.append(exe) }
        for root in roots {
            let b = root.appendingPathComponent(bundleName)
            for sub in ["Fonts", "Contents/Resources/Fonts"] {
                let d = b.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: d.appendingPathComponent(files[0]).path) { return d }
            }
        }
        return nil
    }

    private static func register() -> Bool {
        guard let dir = fontsDirectory else {
            FileHandle.standardError.write(Data("[niivo] font bundle \(bundleName) not found: using system fonts\n".utf8))
            return false
        }
        for f in files {
            var err: Unmanaged<CFError>?
            let url = dir.appendingPathComponent(f) as CFURL
            if !CTFontManagerRegisterFontsForURL(url, .process, &err) {
                // Already registered (second call in one process) is fine; anything else is logged.
                let e = err?.takeRetainedValue()
                if let e, CFErrorGetCode(e) != CTFontManagerError.alreadyRegistered.rawValue {
                    FileHandle.standardError.write(Data("[niivo] couldn't register \(f): \(CFErrorCopyDescription(e) as String)\n".utf8))
                }
            }
        }
        let ok = NSFont(name: "InstrumentSans-Regular", size: 12) != nil && NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
        if !ok { FileHandle.standardError.write(Data("[niivo] brand fonts didn't resolve: using system fonts\n".utf8)) }
        return ok
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard available, let f = nsFont(family: "Instrument Sans", size: size, weight: weight) else {
            return .system(size: size, weight: weight)
        }
        return Font(f as CTFont)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard available, let f = nsFont(family: "JetBrains Mono", size: size, weight: weight) else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return Font(f as CTFont)
    }

    static func nsFont(family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
        let w: NSFont.Weight = switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold, .heavy, .black: .bold
        case .light, .thin, .ultraLight: .light
        default: .regular
        }
        let d = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue]])
        return NSFont(descriptor: d, size: size)
    }
}

// MARK: - Skin: the resolved look for the active theme

/// What views read to style themselves. niivo resolves to the brand tokens; the other themes resolve to system values
/// (their previous look), so one code path serves every theme.
struct Skin: Sendable {
    var brand: Bool
    var ground: Color, card: Color, soft: Color, ink: Color, muted: Color, guide: Color, hair: Color, hair2: Color
    var accentInk: Color, accentFill: Color, accentSoft: Color, onAccent: Color, danger: Color
    var corner: CGFloat
    var design: Font.Design

    static let niivo = Skin(brand: true, ground: NV.ground, card: NV.card, soft: NV.soft, ink: NV.ink, muted: NV.muted,
                            guide: NV.guide, hair: NV.hair, hair2: NV.hair2, accentInk: NV.accentInk,
                            accentFill: NV.accentFill, accentSoft: NV.accentSoft, onAccent: NV.onAccent,
                            danger: NV.danger, corner: 0, design: .default)

    init(brand: Bool, ground: Color, card: Color, soft: Color, ink: Color, muted: Color, guide: Color, hair: Color,
         hair2: Color, accentInk: Color, accentFill: Color, accentSoft: Color, onAccent: Color, danger: Color,
         corner: CGFloat, design: Font.Design) {
        self.brand = brand; self.ground = ground; self.card = card; self.soft = soft; self.ink = ink; self.muted = muted
        self.guide = guide; self.hair = hair; self.hair2 = hair2; self.accentInk = accentInk; self.accentFill = accentFill
        self.accentSoft = accentSoft; self.onAccent = onAccent; self.danger = danger; self.corner = corner; self.design = design
    }

    init(theme t: Theme) {
        if t.brand { self = .niivo; return }
        self.init(brand: false, ground: Color(nsColor: .windowBackgroundColor), card: Color(nsColor: .textBackgroundColor),
                  soft: Color.primary.opacity(0.05), ink: .primary, muted: .secondary,
                  guide: Color(nsColor: .tertiaryLabelColor), hair: Color(nsColor: .separatorColor),
                  hair2: Color(nsColor: .separatorColor), accentInk: t.accent, accentFill: t.accent,
                  accentSoft: t.accent.opacity(0.16), onAccent: .white, danger: .red, corner: max(t.corner, 4), design: t.design)
    }

    /// Human text: Instrument Sans (brand) or the system face in the theme's design.
    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        brand ? NiivoFonts.sans(size, weight) : .system(size: size, weight: weight, design: design)
    }
    /// Chrome: JetBrains Mono (brand) or SF Mono.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        brand ? NiivoFonts.mono(size, weight) : .system(size: size, weight: weight, design: .monospaced)
    }
    /// Labels are ALL CAPS in the brand; other themes keep the original casing.
    func caps(_ s: String) -> String { brand ? s.uppercased() : s }
    /// Tracking for mono caps labels (.10 em; `wide` = .16 em).
    func track(_ size: CGFloat, wide: Bool = false) -> CGFloat { brand ? size * (wide ? 0.16 : 0.10) : 0 }
    /// Title tracking (−0.02 em) for Instrument Sans display text.
    func titleTrack(_ size: CGFloat) -> CGFloat { brand ? -size * 0.02 : 0 }
    var shape: Rectangle { Rectangle() }
    var rounded: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }
}

private struct SkinKey: EnvironmentKey { static let defaultValue = Skin.niivo }
extension EnvironmentValues {
    var skin: Skin {
        get { self[SkinKey.self] }
        set { self[SkinKey.self] = newValue }
    }
}

extension View {
    /// Applies a skin to a subtree: environment value, control tint and (brand) default font.
    @ViewBuilder func skinned(_ s: Skin) -> some View {
        if s.brand {
            self.environment(\.skin, s).tint(s.accentInk).font(s.sans(NV.Size.body))
        } else {
            self.environment(\.skin, s)
        }
    }
}

// MARK: - The mark, the cursor, the cut

/// The ıı: two leaning slabs with a 24-unit band (niivo-ci-study.md §4.1). `solid` drops the hole (≤ 64 px rule).
struct NiivoMark: Shape {
    var solid = false
    func path(in r: CGRect) -> Path {
        let sx = r.width / 238, sy = r.height / 236
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var p = Path()
        for dx in [CGFloat(0), 116] {
            p.addLines([pt(0 + dx, 236), pt(76 + dx, 236), pt(122 + dx, 0), pt(46 + dx, 0)]); p.closeSubpath()
            if !solid {
                p.addLines([pt(29.13 + dx, 212), pt(56.23 + dx, 212), pt(92.87 + dx, 24), pt(65.77 + dx, 24)]); p.closeSubpath()
            }
        }
        return p
    }
}

/// A square leaning 11.03° to the right, bottom edge on the baseline: the cursor (and, thin, the cut `ı`).
struct LeanBlock: Shape {
    func path(in r: CGRect) -> Path {
        let s = r.height * CGFloat(tan(NV.lean))
        var p = Path()
        p.addLines([CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX - s, y: r.maxY),
                    CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX + s, y: r.minY)])
        p.closeSubpath()
        return p
    }
}

/// The leaning cyan cursor. Blinks on a 1.06 s step (on 0–55 %); still when Reduce Motion is on or `blinks` is false.
struct NiivoCursor: View {
    var size: CGFloat
    var blinks = true
    var color: Color = NV.accentFill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if blinks && !reduceMotion && !ThemePreview.isRunning {
            TimelineView(.periodic(from: .now, by: NV.blinkPeriod * 0.55)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: NV.blinkPeriod) / NV.blinkPeriod
                LeanBlock().fill(color).frame(width: size, height: size).opacity(phase < 0.56 ? 1 : 0)
            }
            .frame(width: size, height: size)
        } else {
            LeanBlock().fill(color).frame(width: size, height: size)
        }
    }
}

/// The cut `ı`: the brand's bullet (and the unread marker).
struct NiivoCut: View {
    var height: CGFloat = 10
    var color: Color = NV.ink
    var body: some View { LeanBlock().fill(color).frame(width: height * 0.22 + height * CGFloat(tan(NV.lean)), height: height) }
}

/// `n` + ıı + `vo` + cursor, per the niivo brand guidelines (wordmark rules).
struct NiivoWordmark: View {
    var size: CGFloat
    var blinks = true
    var color: Color = NV.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("n")
            NiivoMark(solid: size * 0.529 < 20)   // small-size rule: no hole when tiny
                .fill(color, style: FillStyle(eoFill: true))
                .frame(width: size * 0.533, height: size * 0.529)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - size * 0.0125 }
                .padding(.leading, size * 0.03).padding(.trailing, size * 0.04)
            Text("vo")
            NiivoCursor(size: size * 0.15, blinks: blinks)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
                .padding(.leading, size * 0.07)
        }
        .font(NiivoFonts.sans(size))
        .tracking(-size * 0.02)
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("niivo")
    }
}

// MARK: - Devices

/// Mono caps label, optionally bracketed: `[ 01 — POSTFACH ]`.
struct MonoLabel: View {
    @Environment(\.skin) private var skin
    var text: String
    var size: CGFloat = NV.Size.label
    var color: Color? = nil
    var bracket = false
    var wide = false
    var weight: Font.Weight = .regular
    init(_ text: String, size: CGFloat = NV.Size.label, color: Color? = nil, bracket: Bool = false, wide: Bool = false,
         weight: Font.Weight = .regular) {
        self.text = text; self.size = size; self.color = color; self.bracket = bracket; self.wide = wide; self.weight = weight
    }
    var body: some View {
        let t = skin.caps(text)
        Text(bracket && skin.brand ? "[ \(t) ]" : t)
            .font(skin.mono(size, weight)).tracking(skin.track(size, wide: wide))
            .foregroundStyle(color ?? skin.muted)
    }
}

/// Four corner brackets: the brand's focus frame (never a full box around content).
struct FocusFrame: Shape {
    var arm: CGFloat = 14
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = min(arm, r.width / 3, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + a)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + a, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - a, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + a))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - a)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - a, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + a, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - a))
        return p
    }
}

/// Empty state in the brand: bracketed eyebrow, a sentence ending in a full stop, an optional hint. Other themes get
/// the previous symbol + title layout.
struct BrandEmptyState: View {
    @Environment(\.skin) private var skin
    var symbol: String
    var eyebrow: String
    var title: String
    var hint: String? = nil
    var body: some View {
        if skin.brand {
            VStack(alignment: .leading, spacing: 10) {
                MonoLabel(eyebrow, bracket: true)
                Text(title).font(skin.sans(20)).tracking(skin.titleTrack(20)).foregroundStyle(skin.ink)
                if let hint { MonoLabel(hint, size: NV.Size.labelSm, color: skin.muted) }
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
            .overlay(FocusFrame(arm: 12).stroke(skin.ink, lineWidth: 1.5))
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 40, weight: .thin))
                Text(title)
                if let hint { Text(hint).font(.caption) }
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Squared mono-caps buttons (niivo-ci-study.md §5.4): `.primary` = ink fill / paper text («ALLOW»),
/// `.ghost` = 1.5 pt ink border («DENY»), `.quiet` = label only. Non-brand themes fall back to system styles at the call site.
struct NVButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, quiet, danger }
    var kind: Kind = .primary
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledButton(configuration: configuration, kind: kind, large: large) }

    private struct StyledButton: View {
        @Environment(\.isEnabled) private var enabled
        @Environment(\.skin) private var skin
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        var body: some View {
            let size: CGFloat = large ? 11.5 : NV.Size.label
            let fg: Color = switch kind {
            case .primary: skin.ground
            case .danger: .white
            case .ghost, .quiet: enabled ? skin.ink : skin.guide
            }
            configuration.label
                .labelStyle(.titleOnly)
                .font(skin.mono(size, .medium)).tracking(skin.track(size))
                .textCase(.uppercase)
                .foregroundStyle(fg)
                .padding(.horizontal, kind == .quiet ? 6 : (large ? 20 : 12)).padding(.vertical, large ? 9 : 5)
                .background {
                    switch kind {
                    case .primary: Rectangle().fill(enabled ? skin.ink : skin.guide)
                    case .danger: Rectangle().fill(enabled ? skin.danger : skin.guide)
                    case .ghost: Rectangle().strokeBorder(enabled ? skin.ink : skin.guide, lineWidth: 1.5)
                    case .quiet: Color.clear
                    }
                }
                .opacity(configuration.isPressed ? 0.72 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// Brand button style for niivo, the given native style otherwise.
    @ViewBuilder func nvButton(_ skin: Skin, _ kind: NVButtonStyle.Kind, large: Bool = false) -> some View {
        if skin.brand {
            self.buttonStyle(NVButtonStyle(kind: kind, large: large))
        } else {
            switch kind {
            case .primary: self.buttonStyle(.borderedProminent)
            case .danger: self.buttonStyle(.borderedProminent).tint(.red)
            case .ghost: self.buttonStyle(.bordered)
            case .quiet: self.buttonStyle(.borderless)
            }
        }
    }

    /// 1 pt hairline under a view.
    func hairline(_ skin: Skin, edge: Edge = .bottom) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : (edge == .top ? .top : (edge == .leading ? .leading : .trailing))) {
            if edge == .top || edge == .bottom { Rectangle().fill(skin.hair).frame(height: 1) }
            else { Rectangle().fill(skin.hair).frame(width: 1) }
        }
    }
}

/// Mono-caps tab bar with an ink underline under the selection (replaces the segmented Picker in the brand).
/// Each tab is a button with the selected trait; ←/→ move between tabs when the bar has focus.
struct NVTabBar<T: Hashable>: View {
    @Environment(\.skin) private var skin
    var title: String
    var items: [T]
    @Binding var selection: T
    var label: (T) -> String
    var count: (T) -> Int
    var divider = true
    var horizontalPadding: CGFloat = 14
    @FocusState private var focused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(spacing: 18, size: NV.Size.label)
            tabs(spacing: 12, size: NV.Size.labelSm)
            ScrollView(.horizontal, showsIndicators: false) { tabs(spacing: 12, size: NV.Size.labelSm) }
        }
        .padding(.horizontal, horizontalPadding)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(skin.hair).frame(height: 1) } }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay { if focused { Rectangle().strokeBorder(skin.accentInk, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func tabs(spacing: CGFloat, size: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items, id: \.self) { it in
                let on = it == selection
                let n = count(it)
                Button { selection = it } label: {
                    HStack(spacing: 5) {
                        Text(skin.caps(label(it)))
                        if n > 0 { Text("\(n)").foregroundStyle(on ? skin.accentInk : skin.muted) }
                    }
                    .font(skin.mono(size, on ? .medium : .regular)).tracking(skin.track(size))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(on ? skin.ink : skin.muted)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? skin.ink : .clear).frame(height: 2) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(n > 0 ? "\(label(it)), \(n)" : label(it))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func move(_ d: Int) -> KeyPress.Result {
        guard let i = items.firstIndex(of: selection) else { return .ignored }
        selection = items[(i + d + items.count) % items.count]
        return .handled
    }
}
