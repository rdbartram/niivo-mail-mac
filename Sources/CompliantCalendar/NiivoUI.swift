import SwiftUI
import AppKit

// niivo UI components. Reusable by every feature (the AI views included): read `\.skin`, never hard-code colours.
// Non-brand themes get the native control back from each component, so callers don't branch.
//
//   NButton("Send", kind: .primary) { … }            ink fill / outline / quiet / danger, squared, mono caps
//   NIconButton("archivebox", label: "Archive") { … } 28 pt square icon button (toggle with isOn:)
//   NTabs(title:, items:, selection:, label:, count:) mono tab strip (= NVTabBar)
//   NField("Search mail", text: $t, label: "Search")  underline (default) or .bordered text field
//   NToggle("Pinned", isOn: $b)                        square switch (or `.toggleStyle(NToggleStyle())`)
//   NPicker("Importance", selection: $x, options: […], label: { … })   popover select, ↑↓↩ esc
//   NMenuButton(label: "Send later", items: [NMenuItem(…)])           popover menu, ↑↓↩ esc
//   NChip("Confidential", tone: .label(color))        squared chip
//   .nRow(selected:, hoverKey:)                        list-row surface: hover soft, selection accentSoft + cyan bar
//   .nFocusRing()                                       2 pt deep-accent ring while keyboard-focused
//   NSectionHeader("Mailbox", index: 1)                [01] MAILBOX eyebrow over a hairline

typealias NButtonStyle = NVButtonStyle
typealias NTabs = NVTabBar

/// One shared observable for transient UI state that would otherwise need `@State` (a macro that needs Xcode's plugin):
/// hovered row, open popover. Views read only the key they compare against, so a hover change re-evaluates only the
/// small hover layers, never row content.
@MainActor @Observable final class NUI {
    static let shared = NUI()
    var hovered: AnyHashable?
    var openPopover: String?
    var popoverIndex = 0
    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.openPopover == key }, set: { if $0 { self.openPopover = key; self.popoverIndex = 0 } else if self.openPopover == key { self.openPopover = nil } })
    }
}

// MARK: Focus ring

private struct NFocusRing: ViewModifier {
    @Environment(\.skin) private var skin
    @Environment(\.isFocused) private var focused
    var inset: CGFloat
    func body(content: Content) -> some View {
        if skin.brand {
            content.overlay { if focused { Rectangle().strokeBorder(skin.accentInk, lineWidth: 2).padding(-inset) } }
        } else { content }
    }
}
extension View {
    /// Brand focus ring (2 pt deep accent, squared) for keyboard focus. System ring elsewhere.
    func nFocusRing(inset: CGFloat = 2) -> some View { modifier(NFocusRing(inset: inset)).focusEffectDisabled(true) }
}

// MARK: Buttons

struct NButton: View {
    @Environment(\.skin) private var skin
    var title: String
    var symbol: String?
    var kind: NVButtonStyle.Kind = .primary
    var large = false
    var role: ButtonRole?
    var action: () -> Void
    init(_ title: String, systemImage: String? = nil, kind: NVButtonStyle.Kind = .primary, large: Bool = false,
         role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = systemImage; self.kind = kind; self.large = large; self.role = role; self.action = action
    }
    var body: some View {
        Button(role: role, action: action) {
            if let symbol, !skin.brand { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .nvButton(skin, kind, large: large)
        .nFocusRing()
    }
}

/// Square icon button for the header and rows. `isOn` makes it a toggle (ink fill when on).
struct NIconButton: View {
    @Environment(\.skin) private var skin
    @Environment(\.isEnabled) private var enabled
    var symbol: String
    var label: String
    var help: String?
    var isOn: Bool?
    var size: CGFloat = 28
    var action: () -> Void
    init(_ symbol: String, label: String, help: String? = nil, isOn: Bool? = nil, size: CGFloat = 28, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.help = help; self.isOn = isOn; self.size = size; self.action = action
    }
    var body: some View {
        let key = "icon:" + label
        Button(action: action) {
            ZStack {
                NHoverFill(key: key, on: isOn == true)
                Group {
                    // niivo: the brand glyph for this symbol when one exists (NiivoGlyphs.swift), SF Symbol otherwise.
                    if skin.brand, let g = NGlyphKind(sf: symbol) { NGlyph(g, size: size * 0.55, label: "") }
                    else { Image(systemName: symbol).font(.system(size: size * 0.46, weight: .light)) }
                }
                .foregroundStyle(isOn == true ? skin.ground : (enabled ? skin.ink : skin.guide))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onHover { NUI.shared.hovered = $0 ? AnyHashable(key) : (NUI.shared.hovered == AnyHashable(key) ? nil : NUI.shared.hovered) }
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
        .nFocusRing(inset: 0)
    }
}

/// Hover / on fill for icon buttons (its own view so hover changes don't re-run the parent).
private struct NHoverFill: View {
    @Environment(\.skin) private var skin
    var key: String
    var on: Bool
    var body: some View {
        let hover = NUI.shared.hovered == AnyHashable(key)
        Rectangle().fill(on ? skin.ink : (hover ? skin.soft : Color.clear))
            .overlay { if hover && !on { Rectangle().strokeBorder(skin.hair2, lineWidth: 1) } }
    }
}

// MARK: Field

struct NField: View {
    enum Style { case underline, bordered }
    @Environment(\.skin) private var skin
    var prompt: String
    @Binding var text: String
    var label: String?
    var style: Style = .underline
    var symbol: String?
    var focus: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}
    init(_ prompt: String, text: Binding<String>, label: String? = nil, style: Style = .underline, symbol: String? = nil,
         focus: FocusState<Bool>.Binding? = nil, onSubmit: @escaping () -> Void = {}) {
        self.prompt = prompt; self._text = text; self.label = label; self.style = style; self.symbol = symbol
        self.focus = focus; self.onSubmit = onSubmit
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { MonoLabel(label, size: NV.Size.labelSm) }
            HStack(spacing: 8) {
                if let symbol { NSymbol(symbol, size: 12).font(.system(size: 12, weight: .light)).foregroundStyle(skin.muted) }
                field.textFieldStyle(.plain).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).onSubmit(onSubmit)
                if !text.isEmpty {
                    Button { text = "" } label: { Text("✕").font(skin.mono(NV.Size.labelSm)).foregroundStyle(skin.muted) }
                        .buttonStyle(.plain).accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, style == .bordered ? 10 : 0).padding(.vertical, style == .bordered ? 6 : 4)
            .background { if style == .bordered { Rectangle().fill(skin.card) } }
            .overlay {
                switch style {
                case .bordered: Rectangle().strokeBorder(isFocused ? skin.accentInk : skin.hair2, lineWidth: isFocused ? 2 : 1)
                case .underline: VStack { Spacer(); Rectangle().fill(isFocused ? skin.accentInk : skin.ink.opacity(0.6)).frame(height: isFocused ? 2 : 1) }
                }
            }
        }
    }
    private var isFocused: Bool { focus?.wrappedValue ?? false }
    @ViewBuilder private var field: some View {
        if let focus { TextField(prompt, text: $text).focused(focus).focusEffectDisabled() }
        else { TextField(prompt, text: $text).focusEffectDisabled() }
    }
}

// MARK: Toggle

/// Square switch: 30 × 16 box, ink knob that moves right and fills cyan-deep when on.
struct NToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { NToggleBody(configuration: configuration) }
}
private struct NToggleBody: View {
    @Environment(\.skin) private var skin
    @Environment(\.isEnabled) private var enabled
    let configuration: ToggleStyleConfiguration
    var body: some View {
        if skin.brand {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    configuration.label.font(skin.sans(NV.Size.body)).foregroundStyle(enabled ? skin.ink : skin.guide)
                    Spacer(minLength: 8)
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Rectangle().fill(configuration.isOn ? skin.accentInk : Color.clear)
                        Rectangle().strokeBorder(enabled ? skin.ink : skin.guide, lineWidth: 1.5)
                        Rectangle().fill(configuration.isOn ? skin.ground : (enabled ? skin.ink : skin.guide)).frame(width: 10, height: 10).padding(3)
                    }
                    .frame(width: 30, height: 16)
                    .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .nFocusRing()
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}
struct NToggle: View {
    var title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }
    var body: some View { Toggle(title, isOn: $isOn).toggleStyle(NToggleStyle()) }
}

// MARK: Popover menu + picker

struct NMenuItem: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String? = nil
    var hint: String? = nil
    var checked = false
    var disabled = false
    var destructive = false
    var action: () -> Void
}

/// A popover list: ↑/↓ move, ↩ picks, esc closes. Used by NMenuButton and NPicker.
struct NPopoverList: View {
    @Environment(\.skin) private var skin
    var key: String
    var items: [NMenuItem]
    @FocusState private var focused: Bool
    var body: some View {
        let ui = NUI.shared
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                let on = i == ui.popoverIndex && !it.disabled
                Button { pick(it) } label: {
                    HStack(spacing: 8) {
                        Text(it.checked ? "ı" : " ").font(skin.mono(NV.Size.label, .bold)).foregroundStyle(skin.accentInk).frame(width: 8)
                        if let s = it.symbol { NSymbol(s, size: 12).font(.system(size: 12, weight: .light)).frame(width: 16) }
                        Text(it.title).font(skin.sans(NV.Size.body))
                        Spacer(minLength: 16)
                        if let h = it.hint { MonoLabel(h, size: NV.Size.labelSm) }
                    }
                    .foregroundStyle(it.disabled ? skin.guide : (it.destructive ? skin.danger : skin.ink))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? skin.accentSoft : Color.clear)
                    .overlay(alignment: .leading) { if on { Rectangle().fill(skin.accentFill).frame(width: 3) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(it.disabled)
                .onHover { if $0 { ui.popoverIndex = i } }
                .accessibilityAddTraits(it.checked ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220)
        .background(skin.card)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; ui.popoverIndex = items.firstIndex { $0.checked } ?? items.firstIndex { !$0.disabled } ?? 0 }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.return) { if items.indices.contains(ui.popoverIndex) { pick(items[ui.popoverIndex]) }; return .handled }
        .onKeyPress(.escape) { ui.openPopover = nil; return .handled }
    }
    private func step(_ d: Int) -> KeyPress.Result {
        let ui = NUI.shared
        var i = ui.popoverIndex
        for _ in items.indices { i = (i + d + items.count) % items.count; if !items[i].disabled { break } }
        ui.popoverIndex = i
        return .handled
    }
    private func pick(_ it: NMenuItem) {
        guard !it.disabled else { return }
        NUI.shared.openPopover = nil
        it.action()
    }
}

/// Outline button that opens an NPopoverList. In non-brand themes it falls back to a native Menu.
struct NMenuButton: View {
    @Environment(\.skin) private var skin
    var label: String
    var symbol: String?
    var items: [NMenuItem]
    var kind: NVButtonStyle.Kind = .ghost
    var key: String { "menu:" + label }
    var body: some View {
        if skin.brand {
            Button { NUI.shared.binding(key).wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    if let symbol { NSymbol(symbol, size: 11).font(.system(size: 11, weight: .light)) }
                    Text(label)
                    Text("▾").font(skin.mono(9))
                }
            }
            .nvButton(skin, kind)
            .nFocusRing()
            .popover(isPresented: NUI.shared.binding(key), arrowEdge: .bottom) { NPopoverList(key: key, items: items).skinned(skin) }
            .accessibilityHint("Opens a menu")
        } else {
            Menu {
                ForEach(items) { it in Button(it.title) { it.action() }.disabled(it.disabled) }
            } label: { if let symbol { Label(label, systemImage: symbol) } else { Text(label) } }
            .fixedSize()
        }
    }
}

/// Select control: the current value in an outline square; a popover lists the options.
struct NPicker<T: Hashable>: View {
    @Environment(\.skin) private var skin
    var title: String
    @Binding var selection: T
    var options: [T]
    var label: (T) -> String
    var disabled: (T) -> Bool = { _ in false }
    init(_ title: String, selection: Binding<T>, options: [T], label: @escaping (T) -> String, disabled: @escaping (T) -> Bool = { _ in false }) {
        self.title = title; self._selection = selection; self.options = options; self.label = label; self.disabled = disabled
    }
    var body: some View {
        if skin.brand {
            let key = "picker:" + title
            HStack(spacing: 8) {
                MonoLabel(title, size: NV.Size.labelSm)
                Button { NUI.shared.binding(key).wrappedValue.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(label(selection)).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink).lineLimit(1)
                        Text("▾").font(skin.mono(9)).foregroundStyle(skin.muted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(skin.hair2, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nFocusRing()
                .accessibilityLabel(title).accessibilityValue(label(selection)).accessibilityHint("Opens a list")
                .popover(isPresented: NUI.shared.binding(key), arrowEdge: .bottom) {
                    NPopoverList(key: key, items: options.map { o in
                        NMenuItem(title: label(o), checked: o == selection, disabled: disabled(o)) { selection = o }
                    }).skinned(skin)
                }
            }
        } else {
            Picker(title, selection: $selection) { ForEach(options, id: \.self) { Text(label($0)).tag($0) } }.fixedSize()
        }
    }
}

// MARK: Chip, section header, row surface

struct NChip: View {
    enum Tone { case ink, muted, accent, danger, warning, label(Color) }
    @Environment(\.skin) private var skin
    var text: String
    var tone: Tone = .ink
    init(_ text: String, tone: Tone = .ink) { self.text = text; self.tone = tone }
    var body: some View {
        let c: Color = switch tone {
        case .ink: skin.ink
        case .muted: skin.muted
        case .accent: skin.accentInk
        case .danger: skin.danger
        case .warning: .orange
        case .label(let col): col
        }
        Text(skin.caps(text)).font(skin.mono(9.5, .medium)).tracking(skin.track(9.5)).lineLimit(1).fixedSize()
            .foregroundStyle(c).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.10)).overlay(Rectangle().strokeBorder(c.opacity(0.8), lineWidth: 1))
    }
}

struct NSectionHeader: View {
    @Environment(\.skin) private var skin
    var title: String
    var index: Int?
    init(_ title: String, index: Int? = nil) { self.title = title; self.index = index }
    var body: some View {
        HStack(spacing: 8) {
            if let index { MonoLabel(String(format: "%02d", index), color: skin.accentInk) }
            MonoLabel(title, color: skin.ink, wide: true, weight: .medium)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 6).hairline(skin)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Hover layer for a row: its own view, so moving the mouse re-evaluates only this, never the row content.
struct NRowHover: View {
    @Environment(\.skin) private var skin
    var key: AnyHashable
    var body: some View {
        Rectangle().fill(NUI.shared.hovered == key ? skin.soft : Color.clear)
    }
}

extension View {
    /// List-row surface. Selected = accentSoft face + 3 pt cyan bar; `marked` (multi-select) = accentSoft without the bar;
    /// hover = soft. 1 pt hairline below when `divider`.
    func nRow(selected: Bool, marked: Bool = false, hoverKey: AnyHashable, divider: Bool = true, skin: Skin) -> some View {
        self
            .background {
                ZStack {
                    NRowHover(key: hoverKey)
                    if selected || marked { Rectangle().fill(skin.accentSoft) }
                }
            }
            .overlay(alignment: .leading) { if selected { Rectangle().fill(skin.accentFill).frame(width: 3) } else if marked { Rectangle().fill(skin.accentInk).frame(width: 2) } }
            .overlay(alignment: .bottom) { if divider { Rectangle().fill(skin.hair).frame(height: 1) } }
            .onHover { inside in
                let ui = NUI.shared
                if inside { ui.hovered = hoverKey } else if ui.hovered == hoverKey { ui.hovered = nil }
            }
    }
}

/// Vertical drag handle between panes (1 pt hairline, 7 pt hit area, resize cursor).
struct NSplitHandle: View {
    @Environment(\.skin) private var skin
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    var body: some View {
        Rectangle().fill(skin.hair).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onDrag($0.translation.width) }
                        .onEnded { _ in onEnd() })
            }
            .accessibilityHidden(true)
    }
}

extension NGlyphKind {
    /// The brand glyph that stands in for an SF Symbol used at a call site (nil = keep the SF Symbol).
    init?(sf: String) {
        if let k = Self.extra[sf] { self = k; return }
        guard let k = NGlyphKind.allCases.first(where: { $0.sfFallback == sf }) else { return nil }
        self = k
    }

    /// SF names that aren't a glyph's own `sfFallback` (variants, .fill forms, duplicates of an existing glyph).
    /// Built once: `NSymbol` asks for every row it draws.
    private static let extra: [String: NGlyphKind] = [
        "sparkle.magnifyingglass": .ai, "bubble.left.and.bubble.right": .conversations,
        "arrow.triangle.2.circlepath": .syncing, "lock.fill": .lock, "trash.fill": .delete,
        // Mail folders (MailboxDisplay.folderSymbol): tray, doc, paperplane, trash, archivebox, xmark.bin,
        // tray.and.arrow.up and clock are fallbacks; "folder" is the project glyph (a folder outline).
        "folder": .project, "folder.fill": .project,
        "tray.fill": .inbox, "tray.full": .inbox, "tray.and.arrow.down": .inbox,
        "doc.fill": .drafts, "doc.text": .drafts, "paperplane.fill": .sent, "xmark.bin.fill": .junk,
        "tray.and.arrow.up.fill": .outbox, "archivebox.fill": .archive,
        // Time
        "clock.fill": .snooze, "clock.badge.checkmark": .snooze, "clock.badge.exclamationmark": .snooze,
        "clock.arrow.circlepath": .syncing, "arrow.down.circle": .syncing, "arrow.clockwise": .syncIdle,
        // Places and people
        "mappin": .location, "mappin.circle": .location, "location": .location, "location.fill": .location,
        "person.crop.circle.badge.questionmark": .organiser, "person.crop.circle.badge.exclamationmark": .organiser,
        "person.crop.circle.badge.xmark": .organiser, "person.crop.circle.badge.plus": .organiser,
        "person.crop.circle.badge.clock": .organiser,
        "person": .person, "person.fill": .person, "person.crop.circle.fill": .person,
        "person.2.fill": .people, "person.3": .people, "person.3.fill": .people, "person.2.crop.square.stack": .people,
        "building": .company, "building.2.fill": .company, "building.columns": .company,
        "globe": .globe, "network": .globe, "safari": .globe,
        // Actions
        "video.fill": .video, "doc.on.clipboard": .copy, "printer.fill": .print,
        "plus.circle": .plus, "plus.circle.fill": .plus, "minus": .minus, "minus.circle.fill": .minus,
        "xmark.circle": .close, "xmark.circle.fill": .close, "xmark.octagon": .close, "xmark.octagon.fill": .close,
        "checkmark.circle": .check, "checkmark.square": .boxChecked, "checkmark.square.fill": .boxChecked,
        "square": .box, "chevron.backward": .chevronLeft, "chevron.forward": .chevronRight,
        "arrow.uturn.left": .undo, "arrow.2.squarepath": .recurring, "wand.and.rays": .rewrite,
        "tag.fill": .tag, "photo.fill": .image, "photo.badge.exclamationmark": .image,
        "envelope.open": .mail, "envelope.badge": .mail, "envelope.fill": .mail, "flag.fill": .flag, "pin.fill": .pin,
        "testtube": .fixtures, "network.slash": .noNetwork,
        // Trust and state
        "shield": .shield, "shield.fill": .shield, "lock.shield.fill": .encrypted,
        "exclamationmark.shield.fill": .shieldAlert, "exclamationmark.octagon": .shieldAlert,
        "exclamationmark.octagon.fill": .shieldAlert,
        "key": .key, "key.fill": .key, "nosign": .forbidden, "hand.raised": .forbidden, "hand.raised.fill": .forbidden,
        "eye.fill": .eye, "info": .info, "info.circle.fill": .info,
        "questionmark": .unknown, "questionmark.circle": .unknown, "questionmark.diamond.fill": .unknown,
        "exclamationmark.triangle.fill": .alert, "exclamationmark.circle": .alert, "exclamationmark.circle.fill": .alert,
        "exclamationmark.bubble": .alert, "lock.trianglebadge.exclamationmark": .alert,
        "trash.slash.fill": .wiped,
    ]
}

/// Drop-in for `Image(systemName:)`: the niivo glyph for this SF Symbol under the brand theme (when one exists),
/// the SF Symbol otherwise. Sized from `size` (pt) so it sits with the text.
struct NSymbol: View {
    @Environment(\.skin) private var skin
    var name: String
    var size: CGFloat
    var label: String?
    init(_ name: String, size: CGFloat = 13, label: String? = nil) { self.name = name; self.size = size; self.label = label }
    var body: some View {
        if skin.brand, let g = NGlyphKind(sf: name) { NGlyph(g, size: size * 1.1, label: label ?? "") }
        else if let label { Image(systemName: name).font(.system(size: size)).accessibilityLabel(label) }
        else { Image(systemName: name).font(.system(size: size)).accessibilityHidden(true) }
    }
}

/// Drop-in for `Label(title, systemImage:)` using `NSymbol`.
struct NLabel: View {
    var title: String
    var symbol: String
    var size: CGFloat
    init(_ title: String, systemImage: String, size: CGFloat = 12) { self.title = title; self.symbol = systemImage; self.size = size }
    var body: some View {
        Label { Text(title) } icon: { NSymbol(symbol, size: size) }
    }
}
