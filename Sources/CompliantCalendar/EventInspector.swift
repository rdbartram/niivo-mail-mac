import SwiftUI
import AppKit
import CalendarCore
import ProtectedContent

/// Detail pane. Every control here is driven by `ContentPolicy` — the view never inspects labels itself.
struct EventInspector: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent

    var body: some View {
        let p = PurviewEventPolicy.adjusted(model.policy(for: event), eventId: event.id)   // PURVIEW-HOOK: rpmsg invites
        let cal = model.calendar(for: event)

        VStack(spacing: 0) {
          // Join lives OUTSIDE the text-selectable region: on macOS, textSelection(.enabled) on a container
          // swallows clicks on buttons inside it.
          if !p.redactDetails, let url = event.onlineMeetingURL {
              HStack {
                  Button { MeetingLauncher.join(url) } label: {
                      NLabel("Join \(MeetingProvider(url: url).displayName)", systemImage: "video.fill").frame(maxWidth: .infinity)
                  }
                  .modifier(BrandButton(kind: .primary, prominent: true))
                  .keyboardShortcut("j", modifiers: [.command])
                  .help("Opens in \(MeetingLauncher.handlerName(for: url)) (⌘J)")
              }
              .padding([.horizontal, .top], 18)
          }
          if model.canEdit(event) || model.canRemove(event) {
              HStack(spacing: 8) {
                  if model.canEdit(event) {
                      // niivo: edit title / time / location right here; pop out to the full editor from there.
                      Button { if model.theme.brand { InlineEventEdit.shared.begin(event) } else { model.edit(event) } } label: { NLabel("Edit", systemImage: "pencil") }
                          .modifier(BrandButton()).help(model.theme.brand ? "Edit here — ⇧⌘P for the full editor" : "Edit (⌘E)")
                  }
                  EventRSVPButtons(event: event)   // READER2-HOOK: accept / tentative / propose (ReaderActions2.swift)
                  if model.canRemove(event) {
                      let mode = model.removeMode(for: event)
                      Button(role: .destructive) { model.askRemove(event) } label: {
                          NLabel(mode == .cancel ? "Cancel Meeting" : (mode == .decline ? "Decline" : "Delete"),
                                 systemImage: mode == .delete ? "trash" : "xmark.circle")
                      }
                      .modifier(BrandButton(kind: .danger)).help("⌘⌫")
                  }
                  Spacer()
                  if event.pendingSync { NLabel("Waiting to sync", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange) }
              }
              .controlSize(.small)
              .padding(.horizontal, 18).padding(.top, 10)
          }
          if model.theme.brand, InlineEventEdit.shared.eventId == event.id, model.canEdit(event) {
              InlineEventEditor(event: event).padding(.horizontal, 18).padding(.top, 10)
          }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabelBanner(policy: p)
                if let h = LabelDisplay.visibleMarking(p, origin: nil) { HeaderMarking(text: h, color: p.label.map { Color(hex: $0.hexColor, fallback: .red) }) }

                VStack(alignment: .leading, spacing: 6) {
                    Text(p.redactDetails ? "Private appointment" : event.subject)
                        .font(.title2.weight(.semibold))
                    Text(timeRange).foregroundStyle(.secondary)
                    if let cal {
                        HStack(spacing: 6) {
                            OwnerBadge(calendar: cal, tint: model.tint(cal), size: 18)
                            Text(cal.access == .own || cal.name == cal.ownerName ? cal.name : "\(cal.name) · \(cal.ownerName)")
                            if cal.access == .delegated { Tag("Delegate") }
                            if !cal.canEdit { Tag("View only") }
                            if event.seriesMasterId != nil { Tag("Repeats") }
                        }
                        .font(.callout)
                    }
                }

                if !p.redactDetails {
                    if let loc = event.location { row("mappin.and.ellipse", loc) }
                    if let org = event.organizer { row("person.crop.circle", "Organiser: \(org)") }
                }

                Divider()
                bodySection(p)

                if !event.attendees.isEmpty && !p.redactDetails {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Attendees").font(.headline)
                        ForEach(event.attendees, id: \.address) { a in
                            HStack {
                                NSymbol(icon(for: a.response)).foregroundStyle(.secondary)
                                Text(a.name)
                                PresenceDot(address: a.address)   // PEOPLE-HOOK
                            }.font(.callout)
                        }
                    }
                } else if !p.allowOfflineDetails && !p.redactDetails {
                    Text("Attendees aren't stored on this Mac for this label.").font(.caption).foregroundStyle(.secondary)
                }

                ControlsSummary(policy: p)

                if let f = p.footerMarking { FooterMarking(text: f) }
            }
            .padding(18)
            // Copy enforcement: selection off and ⌘C swallowed when the label forbids it.
            .modifier(Selectable(enabled: p.allowCopy))
            .onCopyCommand { p.allowCopy ? [NSItemProvider(object: event.subject as NSString)] : [] }
        }
        }
        .overlay { if let w = p.watermark { Watermark(text: w) } }
    }

    @ViewBuilder private func bodySection(_ p: ContentPolicy) -> some View {
        if p.redactDetails {
            Notice(icon: "lock.fill", text: "Marked private by the owner. Details are hidden for delegates and shared viewers.")
        } else if p.bodyIsProtected {
            let pc = model.protectedContent, id = event.id
            let cal = model.calendars.first { $0.id == event.calendarId }
            let mb = cal.map { $0.access == .own ? "me" : $0.ownerAddress } ?? "me"
            ProtectedBodyView(state: ProtectedBodyStore.shared.state(for: id), outlookLink: event.webLink,
                              allowCopy: p.allowCopy, allowPrint: p.allowPrint, allowExport: p.allowExport,
                              onRetry: pc.map { pc in { pc.retry(itemId: id, mailbox: mb, kind: .event) } },
                              onGrantAccess: pc.map { pc in { pc.requestAccess(itemId: id, mailbox: mb, kind: .event) } })
                .frame(minHeight: 60)
                // MIP: protected invites open like protected mail (UNVERIFIED for events, docs/MIP.md).
                .task(id: "\(id)|\(model.protectedDecryptEnabled)|\(model.protectedEpoch)") { pc?.open(itemId: id, mailbox: mb, kind: .event) }
            if case .decrypted = ProtectedBodyStore.shared.state(for: id) {   // PURVIEW-HOOK
                ProtectedAttachmentsSection(itemId: id, mailbox: mb, kind: .event, coordinator: pc, allowCopyOut: model.trust.effectivePolicy.allowCopyOut)
            }
        } else if let b = event.bodyPreview, !b.isEmpty {
            Text(b).font(.callout)
                .task(id: event.id) { await PurviewEventPolicy.probe(event, model: model) }   // PURVIEW-HOOK
        } else if case .unknown = p.labelState {
            Notice(icon: "questionmark.diamond", text: "This item's label isn't in your synced policy. Content is restricted until policy syncs.")
        }
    }

    private var timeRange: String {
        if event.isAllDay { return event.start.formatted(.dateTime.weekday(.wide).day().month()) + " · all day" }
        return event.start.formatted(.dateTime.weekday(.wide).day().month().hour().minute())
            + " – " + event.end.formatted(.dateTime.hour().minute())
    }

    private func row(_ icon: String, _ text: String) -> some View {
        NLabel(text, systemImage: icon).font(.callout)
    }

    private func icon(for r: String) -> String {
        switch r { case "accepted": "checkmark.circle.fill"; case "declined": "xmark.circle"; case "tentativelyAccepted": "questionmark.circle"; default: "circle.dashed" }
    }
}

/// Sensitivity banner. niivo keeps every classic signal (label colour fill 0.14, name semibold, red unknown state) and
/// adds a 4 pt leading bar in the label colour, a 1 pt border and a mono eyebrow: louder, never subtler.
struct LabelBanner: View {
    @Environment(\.skin) private var skin
    var policy: ContentPolicy
    /// Provenance of the item's label (mail only). nil = not proven ours: an id outside our tree then shows as a quiet
    /// "External label" line, never as one of our labels (LabelProvenance.swift).
    var origin: LabelOrigin? = nil
    var body: some View {
        let display = LabelDisplay.decide(policy, origin: origin)
        if let note = display.noticeText {
            HStack(spacing: 6) {
                NSymbol(display == .protectedElsewhere ? "lock.shield" : "building.2", size: 10).foregroundStyle(.secondary)
                Text(skin.caps(note)).font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption)
                    .tracking(skin.track(NV.Size.labelSm)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(display == .protectedElsewhere
                  ? "Encrypted by another organisation. Its rights still apply; its label isn't one of ours."
                  : "This item carries a sensitivity label that isn't in your organisation's policy. It's handled as restricted.")
            .accessibilityElement(children: .combine)
        } else {
            banner
        }
    }

    @ViewBuilder private var banner: some View {
        switch policy.labelState {
        case .unlabeled:
            HStack { NSymbol("shield"); Text(skin.caps("No sensitivity label")) }
                .font(skin.brand ? skin.mono(NV.Size.labelSm) : .caption).tracking(skin.track(NV.Size.labelSm)).foregroundStyle(.secondary)
        case .labeled(let l):
            let c = Color(hex: l.hexColor, fallback: .gray)
            if skin.brand {
                // Slim single-line bar (Ryan 2026-11-19): colour tick, mono label name, encrypted mark. No fill block.
                HStack(spacing: 8) {
                    Rectangle().fill(c).frame(width: 2, height: 12)
                    MonoLabel("Sensitivity", size: 8.5)
                    Text(l.name).font(skin.mono(9, .medium)).foregroundStyle(skin.ink).lineLimit(1).truncationMode(.tail)
                    if l.hasProtection {
                        HStack(spacing: 3) { NSymbol("lock.fill", size: 7.5); MonoLabel("Encrypted", size: 8.5, color: skin.ink) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(c.opacity(0.5)).frame(height: 1) }
                .help(l.tooltip ?? l.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sensitivity: \(l.name)\(l.hasProtection ? ", encrypted" : "")")
            } else {
                HStack(spacing: 8) {
                    LabelGlyph(label: l)
                    Text(l.name).font(.callout.weight(.semibold))
                    Spacer()
                    if l.hasProtection { Tag("Encrypted") }
                }
                .padding(10)
                .background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .help(l.tooltip ?? "")
            }
        case .unknown(let id):
            if skin.brand {
                HStack(spacing: 8) {
                    NSymbol("questionmark.diamond.fill", size: 10).font(.system(size: 10)).foregroundStyle(skin.danger)
                    Text("Unknown label — restricted").font(skin.mono(NV.Size.labelSm, .semibold)).foregroundStyle(skin.danger).lineLimit(1)
                    Text(id).font(skin.mono(9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().strokeBorder(skin.danger, lineWidth: 1))
                .help("This label isn't in your synced policy: the message is treated as restricted. Label id \(id)")
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 8) {
                    NSymbol("questionmark.diamond.fill").foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("Unknown label — restricted").font(.callout.weight(.semibold))
                        Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Purview header marking ("HIGHLY CONFIDENTIAL"). Shared by reader and composer. The tenant's text is shown verbatim.
/// Purview header marking: the tenant's text verbatim, rendered like Outlook does — one plain line, no box.
/// Graph's label definitions don't carry the marking's font size/colour, so: caption size (10 pt, Purview's default)
/// in the label colour; red only when there's no label colour (e.g. the "label unavailable — restricted" marking).
struct HeaderMarking: View {
    @Environment(\.skin) private var skin
    var text: String
    var color: Color? = nil
    var boxed = false   // kept for call-site compatibility; markings are never boxed now
    var body: some View {
        Text(text)
            .font(skin.brand ? skin.sans(10, .semibold) : .system(size: 10, weight: .semibold))
            .foregroundStyle(color ?? (skin.brand ? skin.danger : .red))
            .lineLimit(2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 3)
            .accessibilityLabel("Header marking: \(text)")
    }
}

/// Purview footer marking. niivo: 10.5 pt (classic 10) in the ink-muted grey over a hairline. Text verbatim.
struct FooterMarking: View {
    @Environment(\.skin) private var skin
    var text: String
    var body: some View {
        if skin.brand {
            Text(text).font(skin.sans(10)).foregroundStyle(skin.muted)
                .frame(maxWidth: .infinity).padding(5)
                .hairline(skin, edge: .top)
        } else {
            Text(text).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(6)
        }
    }
}

struct ControlsSummary: View {
    @Environment(\.skin) private var skin
    var policy: ContentPolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if skin.brand { MonoLabel("Protection in effect", bracket: true) }
            else { Text("Protection in effect").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            // Copy / print / export / forward come from the label's usage rights, not an app rule.
            item("doc.on.doc", "Copy", policy.allowCopy)
            item("printer", "Print", policy.allowPrint)
            item("square.and.arrow.up", "Export / share", policy.allowExport)
            item("arrowshape.turn.up.right", "Forward", policy.allowForward)
            item("internaldrive", "Details cached offline", policy.allowOfflineDetails)
            item("camera.viewfinder", "Screen capture", !policy.preventScreenCapture)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.brand ? AnyShapeStyle(skin.soft) : AnyShapeStyle(.quaternary.opacity(0.5)), in: skin.rounded)
    }
    private func item(_ icon: String, _ name: String, _ allowed: Bool) -> some View {
        HStack {
            NSymbol(icon).frame(width: 16)
            Text(name)
            Spacer()
            NSymbol(allowed ? "checkmark" : "nosign").foregroundStyle(allowed ? .green : .red)
        }.font(.caption)
    }
}

struct Notice: View {
    @Environment(\.skin) private var skin
    var icon: String, text: String
    var body: some View {
        if skin.brand {
            HStack(alignment: .top, spacing: 12) {
                NSymbol(icon, size: 18).font(.title3.weight(.light)).foregroundStyle(skin.ink)
                Text(text).font(skin.sans(NV.Size.body)).foregroundStyle(skin.ink)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(FocusFrame(arm: 10).stroke(skin.ink, lineWidth: 1.5))
        } else {
            HStack(alignment: .top, spacing: 10) {
                NSymbol(icon, size: 18).font(.title3).foregroundStyle(.secondary)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct Tag: View {
    @Environment(\.skin) private var skin
    var text: String
    init(_ t: String) { text = t }
    var body: some View {
        if skin.brand {
            Text(text.uppercased()).font(skin.mono(9.5, .medium)).tracking(0.9).padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(skin.ink).overlay(Rectangle().strokeBorder(skin.ink.opacity(0.8), lineWidth: 1))
        } else {
            Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

/// Diagonal tiled watermark, as Purview's "watermark" content marking would render in Office.
/// niivo: JetBrains Mono bold 15 pt at the same 0.07 red opacity (0.10 in Dark Mode, where 0.07 reads fainter).
struct Watermark: View {
    @Environment(\.skin) private var skin
    @Environment(\.colorScheme) private var scheme
    var text: String
    var body: some View {
        // Text verbatim; lighter and sparser (Ryan 2026-11-19).
        let font = skin.brand ? skin.mono(14, .medium) : .system(size: 14, weight: .semibold)
        let ink: Color = skin.brand ? skin.danger.opacity(scheme == .dark ? 0.065 : 0.045) : .red.opacity(0.05)
        Canvas { ctx, size in
            ctx.rotate(by: .degrees(-30))
            let t = ctx.resolve(Text(text).font(font).foregroundStyle(ink))
            for y in stride(from: -size.height, to: size.height * 2, by: 120) {
                for x in stride(from: -size.width, to: size.width * 2, by: 340) {
                    ctx.draw(t, at: CGPoint(x: x + (y.truncatingRemainder(dividingBy: 240) == 0 ? 0 : 170), y: y))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Selectable: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
