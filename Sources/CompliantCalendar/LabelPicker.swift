import SwiftUI
import AppKit
import CalendarCore

// MARK: - Sensitivity label picker (Outlook structure)

/// One row of the label picker. Built from a `LabelTree`, so the order, grouping and floor match Microsoft's.
struct LabelPickerRow: Identifiable {
    enum Kind { case none, header, label }
    /// Label GUID (rows are never keyed by title: the same sub-label name can sit under two parents).
    var id: String
    var kind: Kind
    var title: String
    var indent = false
    var hexColor: String?
    var tooltip: String?
    var isProtected = false
    var checked = false
    /// Why the row can't be picked (below the reply floor). Shown as visible text, not only on hover.
    var disabledReason: String?
    var disabled: Bool { kind == .header || disabledReason != nil }

    static func rows(tree: LabelTree, currentId: String?, floorLabelId: String?) -> [LabelPickerRow] {
        let current = currentId?.lowercased()
        let floorPath = tree.path(floorLabelId)
        func reason(_ id: String) -> String? {
            guard floorLabelId != nil, !tree.meetsFloor(id, floor: floorLabelId) else { return nil }
            return floorPath.map { "below “\($0)”" } ?? "not allowed on a reply"
        }
        func row(_ l: SensitivityLabel, indent: Bool) -> LabelPickerRow {
            LabelPickerRow(id: l.id, kind: .label, title: l.name, indent: indent, hexColor: l.hexColor, tooltip: l.tooltip,
                           isProtected: l.hasProtection, checked: l.id.lowercased() == current, disabledReason: reason(l.id))
        }
        var out = [LabelPickerRow(id: "none", kind: .none, title: "No label", checked: currentId == nil,
                                  disabledReason: floorLabelId != nil ? "a reply keeps the original's label" : nil)]
        for n in tree.nodes {
            if n.isHeader {
                out.append(LabelPickerRow(id: n.label.id, kind: .header, title: n.label.name, hexColor: n.label.hexColor,
                                          tooltip: n.label.tooltip))
                out += n.children.map { row($0, indent: true) }
            } else {
                out.append(row(n.label, indent: false))
            }
        }
        return out
    }
}

/// The composer's label control. Brand skin: outline button + keyboard-driven popover (headers, indented
/// sub-labels, swatches, lock for encrypted labels, reasons inline). Classic theme: a native menu with a section
/// per parent label.
struct SensitivityLabelPicker: View {
    @Environment(\.skin) private var skin
    var tree: LabelTree
    var currentId: String?
    var floorLabelId: String?
    /// COMPOSE-LAYOUT: render as a small pill (composer header) instead of the full "Sensitivity: …" button.
    var compact = false
    var onPick: (String?) -> Void

    private var key: String { "menu:sensitivity-label" }
    private var chip: String {
        tree.path(currentId) ?? (currentId == nil ? "Sensitivity: none" : "Sensitivity: unknown label")
    }
    private var help: String {
        let base = floorLabelId == nil ? "Sensitivity label" : "Replies can't go below the original message's label"
        return tree.label(currentId)?.tooltip.map { "\(base). \($0)" } ?? base
    }

    var body: some View {
        let rows = LabelPickerRow.rows(tree: tree, currentId: currentId, floorLabelId: floorLabelId)
        let current = tree.label(currentId)
        if skin.brand {
            Button { NUI.shared.binding(key).wrappedValue.toggle() } label: {
                if compact { pill(current) } else {
                    HStack(spacing: 6) {
                        if let current { LabelSwatch(hex: current.hexColor, size: 8) }
                        else { NSymbol("shield.lefthalf.filled", size: 11).font(.system(size: 11, weight: .light)) }
                        Text(chip)
                        if current?.hasProtection == true { NSymbol("lock.fill", size: 9) }
                        Text("▾").font(skin.mono(9))
                    }
                }
            }
            .modifier(PickerChrome(skin: skin, compact: compact))
            .nFocusRing()
            .popover(isPresented: NUI.shared.binding(key), arrowEdge: .bottom) {
                LabelPopoverList(key: key, rows: rows, onPick: onPick).skinned(skin)
            }
            .help(help)
            .accessibilityLabel("Sensitivity label: \(chip)")
            .accessibilityHint("Opens a menu")
        } else {
            Menu {
                ForEach(sections(rows), id: \.id) { s in
                    if let header = s.header {
                        Section(header.title) { ForEach(s.rows) { nativeItem($0) } }
                    } else {
                        ForEach(s.rows) { nativeItem($0) }
                    }
                }
            } label: {
                if compact { pill(current) }
                else { Label(chip, systemImage: current?.hasProtection == true ? "lock.shield" : "shield.lefthalf.filled") }
            }
            .menuIndicator(compact ? .hidden : .automatic)
            .fixedSize()
            .help(help)
            .accessibilityLabel("Sensitivity label: \(chip)")
        }
    }

    private func pill(_ current: SensitivityLabel?) -> some View {
        LabelPill(policy: .open, draftMode: true, draftLabel: current, draftId: currentId,
                  draftUnavailable: tree.appliable.isEmpty, interactive: true)
    }

    /// Native menu groups: consecutive top-level rows share an untitled section; each parent gets its own.
    private struct MenuSection { var id: String; var header: LabelPickerRow?; var rows: [LabelPickerRow] }
    private func sections(_ rows: [LabelPickerRow]) -> [MenuSection] {
        var out: [MenuSection] = []
        for r in rows {
            if r.kind == .header { out.append(MenuSection(id: r.id, header: r, rows: [])) }
            else if r.indent, !out.isEmpty, out[out.count - 1].header != nil { out[out.count - 1].rows.append(r) }
            else if out.last.map({ $0.header == nil }) == true { out[out.count - 1].rows.append(r) }
            else { out.append(MenuSection(id: "top-" + r.id, header: nil, rows: [r])) }
        }
        return out
    }

    @ViewBuilder private func nativeItem(_ r: LabelPickerRow) -> some View {
        let title = r.disabledReason.map { "\(r.title) — \($0)" } ?? r.title
        Toggle(isOn: Binding(get: { r.checked }, set: { _ in onPick(r.kind == .none ? nil : r.id) })) {
            if r.kind == .none { Text(title) }
            else { Label { Text(title) } icon: { Image(nsImage: LabelSwatch.menuImage(hex: r.hexColor, locked: r.isProtected)) } }
        }
        .disabled(r.disabled)
        .help(r.tooltip ?? "")
    }
}

/// Brand chrome for the picker button: the ghost button normally, bare (the pill draws its own border) when compact.
private struct PickerChrome: ViewModifier {
    var skin: Skin
    var compact: Bool
    func body(content: Content) -> some View {
        if compact { content.buttonStyle(.plain) } else { content.nvButton(skin, .ghost) }
    }
}

/// Square colour swatch (the label colour; grey when the label has none).
struct LabelSwatch: View {
    var hex: String?
    var size: CGFloat = 8
    var body: some View {
        Rectangle().fill(Color(hex: hex, fallback: .gray)).frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Non-template image for native menu items: swatch, plus a lock for encrypted labels.
    @MainActor static func menuImage(hex: String?, locked: Bool) -> NSImage {
        let nsColour = NSColor(Color(hex: hex, fallback: .gray))
        let img = NSImage(size: NSSize(width: locked ? 24 : 10, height: 10), flipped: false) { rect in
            nsColour.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 1, width: 8, height: 8)).fill()
            if locked, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted") {
                let tinted = lock.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? lock
                tinted.draw(in: NSRect(x: 13, y: 0, width: 10, height: 10))
            }
            _ = rect
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Brand popover for the label picker: like `NPopoverList`, but with group headers and indented sub-labels.
/// ↑/↓ and hover skip headers and disabled rows; ↩ picks; esc closes.
private struct LabelPopoverList: View {
    @Environment(\.skin) private var skin
    var key: String
    var rows: [LabelPickerRow]
    var onPick: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let ui = NUI.shared
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if r.kind == .header {
                    HStack(spacing: 8) {
                        Text(" ").frame(width: 8)
                        LabelSwatch(hex: r.hexColor, size: 8)
                        MonoLabel(r.title.uppercased(), size: NV.Size.labelSm, color: skin.muted)
                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
                    .help(r.tooltip ?? "")
                    .accessibilityAddTraits(.isHeader)
                } else {
                    let on = i == ui.popoverIndex && !r.disabled
                    Button { pick(r) } label: {
                        HStack(spacing: 8) {
                            Text(r.checked ? "ı" : " ").font(skin.mono(NV.Size.label, .bold)).foregroundStyle(skin.accentInk).frame(width: 8)
                            if r.indent { Spacer().frame(width: 14) }
                            if r.kind == .label { LabelSwatch(hex: r.hexColor, size: 8).opacity(r.disabled ? 0.4 : 1) }
                            Text(r.title).font(skin.sans(NV.Size.body))
                            if r.isProtected { NSymbol("lock.fill", size: 10).accessibilityLabel("Encrypted") }
                            Spacer(minLength: 16)
                            if let why = r.disabledReason { MonoLabel(why, size: NV.Size.labelSm, color: skin.guide) }
                        }
                        .foregroundStyle(r.disabled ? skin.guide : skin.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? skin.accentSoft : Color.clear)
                        .overlay(alignment: .leading) { if on { Rectangle().fill(skin.accentFill).frame(width: 3) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(r.disabled)
                    .onHover { if $0, !r.disabled { ui.popoverIndex = i } }
                    .help(r.tooltip ?? "")
                    .accessibilityAddTraits(r.checked ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 260)
        .background(skin.card)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear {
            focused = true
            ui.popoverIndex = rows.firstIndex { $0.checked && !$0.disabled } ?? rows.firstIndex { !$0.disabled } ?? 0
        }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.return) { if rows.indices.contains(ui.popoverIndex) { pick(rows[ui.popoverIndex]) }; return .handled }
        .onKeyPress(.escape) { ui.openPopover = nil; return .handled }
    }

    private func step(_ d: Int) -> KeyPress.Result {
        let ui = NUI.shared
        guard rows.contains(where: { !$0.disabled }) else { return .handled }
        var i = ui.popoverIndex
        for _ in rows.indices { i = (i + d + rows.count) % rows.count; if !rows[i].disabled { break } }
        ui.popoverIndex = i
        return .handled
    }

    private func pick(_ r: LabelPickerRow) {
        guard !r.disabled else { return }
        NUI.shared.openPopover = nil
        onPick(r.kind == .none ? nil : r.id)
    }
}
