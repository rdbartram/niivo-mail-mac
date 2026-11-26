import SwiftUI
import PDFKit
import CalendarCore
import ProtectedContent

/// Decrypted attachments of protected mail / invites. Memory only: cleared with the protected bodies on sign-out,
/// lock or switching decryption off (`ProtectedContentCoordinator.reset`). Never written to a file, never handed to
/// QuickLook (it needs a file URL); previews render from `Data` (PDFKit / NSImage / text).
@MainActor @Observable
final class ProtectedAttachmentStore {
    static let shared = ProtectedAttachmentStore()
    enum State: Equatable { case loading, loaded(ProtectedAttachments), failed(String) }
    var states: [String: State] = [:]
    /// Unlabelled events whose attachments include a message.rpmsg (protected invite without a label).
    var rpmsgEvents: Set<String> = []
    var probedEvents: Set<String> = []
    func removeAll() { states.removeAll(); rpmsgEvents.removeAll(); probedEvents.removeAll() }
}

/// "Attachments (protected)" section under a decrypted body. Loads on demand; licence rights gate save/print.
struct ProtectedAttachmentsSection: View {
    @Environment(\.skin) private var skin
    var itemId: String
    var mailbox: String = "me"
    var kind: RPMSGFetcher.Kind = .message
    var coordinator: ProtectedContentCoordinator?
    /// Device trust policy (copy-out): ANDed with the licence, like the reader's export gate.
    var allowCopyOut: Bool = false
    var body: some View {
        let state = ProtectedAttachmentStore.shared.states[itemId]
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .none:
                if ProtectedContentService.supportsAttachments, let coordinator {
                    NButton("Show protected attachments", systemImage: "paperclip", kind: .quiet) {
                        coordinator.openAttachments(itemId: itemId, mailbox: mailbox, kind: kind)
                    }
                }
            case .loading?:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Decrypting attachments…").font(.caption) }
            case .failed(let code)?:
                NLabel("Couldn't open the attachments (\(code)). Open the message in Outlook.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            case .loaded(let a)?:
                if a.items.isEmpty {
                    Text("No attachments.").font(.caption).foregroundStyle(.secondary)
                } else {
                    var allowed = ProtectedAttachmentGate.allowed(a.rights)
                    let _ = (allowed.save = allowed.save && allowCopyOut)
                    if !allowed.save {
                        NLabel("View only: your rights don't allow saving or opening these files elsewhere.", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(a.items) { item in ProtectedAttachmentRow(itemId: itemId, item: item, allowed: allowed) }
                }
            }
        }
    }
}

@MainActor @Observable
final class ProtectedAttachmentPreviewState {
    var expanded: Set<String> = []
}

struct ProtectedAttachmentRow: View {
    @Environment(\.skin) private var skin
    var itemId: String
    var item: ProtectedAttachment
    var allowed: ProtectedAttachmentGate.Allowed
    private static let preview = ProtectedAttachmentPreviewState()
    private var key: String { "\(itemId)#\(item.id)" }
    var body: some View {
        let open = Self.preview.expanded.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                NSymbol(item.isItselfProtected ? "lock.doc" : "doc").foregroundStyle(.secondary)
                Text(item.name).font(.callout).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if allowed.preview && item.preview != .none {
                    NButton(open ? "Hide" : "Preview", kind: .quiet) {
                        if open { Self.preview.expanded.remove(key) } else { Self.preview.expanded.insert(key) }
                    }
                }
                if allowed.save { NButton("Save…", systemImage: "square.and.arrow.down", kind: .quiet) { save() } }
            }
            if item.isItselfProtected {
                Text("This file is protected itself — open it in Office.").font(.caption).foregroundStyle(.secondary)
            }
            if open && allowed.preview { ProtectedAttachmentPreview(item: item, canCopy: allowed.save).frame(height: 320) }
        }
    }

    /// Only with EXPORT/EXTRACT: the user chose to take a copy out (Outlook allows the same).
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? item.data.write(to: url, options: .atomic)
    }
}

/// In-memory preview; no selection / copy unless the licence allows saving (EXPORT/EXTRACT).
struct ProtectedAttachmentPreview: NSViewRepresentable {
    var item: ProtectedAttachment
    var canCopy: Bool
    func makeNSView(context: Context) -> NSView {
        switch item.preview {
        case .pdf:
            let v = GatedPDFView(); v.canCopy = canCopy; v.autoScales = true; v.document = PDFDocument(data: item.data); return v
        case .image:
            let v = NSImageView(); v.image = NSImage(data: item.data); v.imageScaling = .scaleProportionallyUpOrDown; return v
        case .text:
            let scroll = NSTextView.scrollableTextView()
            if let t = scroll.documentView as? NSTextView {
                t.string = String(decoding: item.data.prefix(512 * 1024), as: UTF8.self)
                t.isEditable = false; t.isSelectable = canCopy
            }
            return scroll
        case .none:
            return NSView()
        }
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// PDFView that refuses ⌘C / drag-out without EXTRACT/EXPORT.
final class GatedPDFView: PDFView {
    var canCopy = false
    override func copy(_ sender: Any?) { if canCopy { super.copy(sender) } else { NSSound.beep() } }
    override func mouseDragged(with event: NSEvent) { if canCopy { super.mouseDragged(with: event) } }
}


/// Protected meeting invites without a label: Graph lists the message.rpmsg on /events/{id}/attachments
/// (UNVERIFIED shape, docs/MIP.md). Once seen, the event is treated like rpmsg mail (VIEW only until the licence is
/// known, capture shielded, not cached) and opens through the same decryptor.
@MainActor
enum PurviewEventPolicy {
    static func adjusted(_ p: ContentPolicy, eventId: String) -> ContentPolicy {
        guard !p.bodyIsProtected, ProtectedAttachmentStore.shared.rpmsgEvents.contains(eventId) else { return p }
        return ProtectedPolicy.awaitingLicence(p)
    }

    static func probe(_ event: CalendarEvent, model: AppModel) async {
        guard event.labelId == nil, let pc = model.protectedContent else { return }
        let cal = model.calendars.first { $0.id == event.calendarId }
        let mb = cal.map { $0.access == .own ? "me" : $0.ownerAddress } ?? "me"
        await pc.probeEvent(itemId: event.id, mailbox: mb)
    }
}
