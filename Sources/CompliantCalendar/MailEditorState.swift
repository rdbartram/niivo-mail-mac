import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MailCore

/// The composer's rich text, owned by the model (not the view): it survives popping the composer in and out and is
/// still there when the draft is saved after the window closed. `ComposerState.body` stays the exact plain-text
/// mirror of `storage.string`, so the AI hooks (draft / rewrite / pre-send) keep working on a String.
@MainActor @Observable
final class ComposerEditorState {
    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored weak var textView: ComposerTextView?
    /// Called with the new plain text after every edit (→ ComposerState.body).
    @ObservationIgnored var onText: ((String) -> Void)?
    /// Called after formatting-only edits (→ autosave).
    @ObservationIgnored var onFormat: (() -> Void)?
    /// Set by the composer view: why attachments are refused right now (label gate), nil = allowed.
    @ObservationIgnored var attachBlockReason: String?
    @ObservationIgnored var inlineImages: [String: OutgoingAttachment] = [:]
    /// Reopened draft: HTML before/after our region, sent back verbatim (e.g. Exchange's quoted history).
    @ObservationIgnored var carried: (prefix: String, suffix: String)?
    /// COMPOSE2: the quoted history as a document for the collapsed, read-only view (never edited or re-serialised:
    /// the bytes that go out are `carried` or the service's own copy). nil = none known (yet).
    var historyHTML: String?
    var historyExpanded = false
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    @ObservationIgnored private var mirror = ""
    @ObservationIgnored var preparedFor: UUID?

    /// File attachments (chips). Inline images live in the body.
    var attachments: [OutgoingAttachment] = []
    var progress: [UUID: Double] = [:]
    /// OneDrive links in the body (DrivePicker.swift), with their permission + file label.
    var cloud: [CloudAttachment] = []
    /// Local files over 150 MB: refused as attachments, offered "Upload to OneDrive and share".
    var oversize: [URL] = []
    /// Labels of OneDrive files attached as a copy (by name), for the label warning.
    var cloudCopyLabels: [String: DriveFileLabel] = [:]
    var notice: String?
    /// Reopened draft: attachments already on the server (chips; kept, never re-uploaded).
    var serverAttachments: [DraftServerAttachment] = []
    /// Reopened draft: OneDrive link chips found in the body (CloudChipScan).
    var restoredLinks: [CloudChipRef] = []
    /// Spell-check language chosen for this draft (nil = detect) and the detected one (ComposerAssistModel.swift).
    var spellChoice: DraftLanguage?
    var detectedLanguage: DraftLanguage?
    /// `;shortcut` → template (set per composer by MailModel.wireTemplates).
    @ObservationIgnored var templateLookup: ((String) -> RichDoc?)?
    var signatureId: UUID?
    /// The signature is the identity's default (switching From swaps it); false once the user picks one.
    var signatureIsDefault = true
    var liveMarkdown = true
    /// Formatting at the cursor (toolbar state).
    var active = RichStyle()
    var activeBlock = RichBlock()
    var showLink = false
    var linkText = ""
    var linkURL = ""
    @ObservationIgnored var linkRange = NSRange(location: 0, length: 0)

    // MARK: Saves

    /// Runs saves one after another in an unstructured task (not cancelled with the caller).
    func serialSave(_ work: @escaping @MainActor () async -> Bool) async -> Bool {
        let prev = inFlight
        let t = Task { @MainActor in
            _ = await prev?.value
            return await work()
        }
        inFlight = t
        return await t.value
    }

    func waitForSave() async { _ = await inFlight?.value }

    // MARK: Content

    var doc: RichDoc { RichTextBridge.doc(storage) }

    /// Outgoing HTML. `plain` = ComposerState.body: an external write (AI) is applied first.
    func html(reconciling plain: String) -> String {
        reconcile(plain)
        let h = RichHTML.html(doc)
        if let c = carried { return c.prefix + h + c.suffix }
        return h
    }

    /// Files + the inline images still referenced from the body.
    func outgoing() -> [OutgoingAttachment] {
        let used = Set(doc.images.map(\.cid))
        return attachments + inlineImages.values.filter { $0.contentId.map(used.contains) ?? false }.sorted { $0.name < $1.name }
    }

    /// No user content (a signature alone doesn't make a draft).
    /// No text the user wrote and nothing they attached (a forward's original attachments and the signature don't count).
    var userTextIsEmpty: Bool { attachments.isEmpty && doc.blocks.filter { !$0.signature }.allSatisfy(\.isEmpty) }

    var contentIsEmpty: Bool { attachments.isEmpty && serverAttachments.isEmpty && doc.blocks.filter { !$0.signature }.allSatisfy(\.isEmpty) }

    func load(_ d: RichDoc) {
        storage.setAttributedString(RichTextBridge.attributed(d, images: inlineImages))
        if let tv = textView {   // the old undo steps refer to text that is gone
            tv.undoManager?.removeAllActions(withTarget: tv)
            tv.undoManager?.removeAllActions(withTarget: storage)
        }
        textChanged(format: true)
    }

    /// Plain text of the signature blocks (as in `storage.string`), "" when there is none.
    var signaturePlain: String { doc.blocks.filter(\.signature).map(\.text).joined(separator: "\n") }

    /// Every paragraph carries one block kind: after joins / mid-paragraph pastes, spread the first character's
    /// paragraph attributes over the paragraph (what `doc` reads is then what's displayed and sent).
    func normaliseParagraphs(_ r: NSRange) {
        guard storage.length > 0 else { return }
        let loc = min(r.location, storage.length - 1)
        let pr = paragraphRange(NSRange(location: loc, length: min(r.length, storage.length - loc)))
        let ns = storage.string as NSString
        var p = pr.location
        storage.beginEditing()
        while p < NSMaxRange(pr) {
            let one = ns.paragraphRange(for: NSRange(location: p, length: 0))
            let first = storage.attributes(at: one.location, effectiveRange: nil)
            var mixed = false
            for k in NSAttributedString.Key.nvParagraph {
                var eff = NSRange()
                let v = storage.attribute(k, at: one.location, longestEffectiveRange: &eff, in: one)
                if eff.length < one.length || (v == nil) != (first[k] == nil) { mixed = true; break }
            }
            if mixed {
                for k in NSAttributedString.Key.nvParagraph {
                    if let v = first[k] { storage.addAttribute(k, value: v, range: one) } else { storage.removeAttribute(k, range: one) }
                }
                RichTextBridge.restyle(storage, one)
            }
            p = NSMaxRange(one)
            if one.length == 0 { break }
        }
        storage.endEditing()
    }

    /// Reopened draft: our region becomes editable, the rest is carried verbatim; data: images become inline.
    func load(html: String, isHTML: Bool) {
        guard isHTML else { load(RichDoc.plain(html)); return }
        // COMPOSE2: our marker, else Outlook's reply header, starts the history (carried, shown collapsed).
        var parts = RichHTML.split(html)
        if let h = DraftCarry.split(html) {
            parts = (h.carry.prefix, h.editable, h.carry.suffix)
            if h.carry.hasHistory { historyHTML = h.carry.historyDocument }
        }
        let parsed = RichHTML.parse(parts.editable)
        for i in parsed.dataImages {
            inlineImages[i.cid] = OutgoingAttachment(name: "image.\(i.mime.split(separator: "/").last ?? "png")", contentType: i.mime,
                                                     data: i.data, isInline: true, contentId: i.cid)
        }
        if !parts.prefix.isEmpty || !parts.suffix.isEmpty { carried = (parts.prefix, parts.suffix) }
        restoredLinks = CloudChipScan.links(in: parsed.doc)
        load(parsed.doc)
    }

    /// After every storage change: refresh the plain mirror and tell the composer.
    func textChanged(format: Bool = false) {
        let s = storage.string
        if s != mirror { mirror = s; onText?(s) } else if format { onFormat?() }
        refreshActive()
    }

    /// Applies an external change of the plain text (AI draft/rewrite/undo) as a minimal replacement, so formatting
    /// outside the changed span survives.
    func reconcile(_ incoming: String) {
        let old = storage.string
        guard incoming != old else { return }
        // AI drafts replace the whole body: keep the signature below the new text instead of deleting it.
        var plain = incoming
        let sig = signaturePlain
        if !sig.isEmpty, old.hasSuffix(sig), !incoming.contains(sig) {
            plain = incoming.trimmingCharacters(in: .newlines) + "\n\n" + sig
        }
        guard plain != old else { let s = plain; DispatchQueue.main.async { [weak self] in self?.onText?(s) }; return }
        let o = Array(old.utf16), n = Array(plain.utf16)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var sfx = 0
        while sfx < o.count - p, sfx < n.count - p, o[o.count - 1 - sfx] == n[n.count - 1 - sfx] { sfx += 1 }
        let range = NSRange(location: p, length: o.count - p - sfx)
        let middle = String(utf16CodeUnits: Array(n[p..<(n.count - sfx)]), count: n.count - p - sfx)
        var attrs: [NSAttributedString.Key: Any] = RichTextBridge.typing(block: RichBlock())
        if storage.length > 0 {
            let at = min(max(0, range.location == 0 ? 0 : range.location - 1), storage.length - 1)
            attrs = storage.attributes(at: at, effectiveRange: nil).filter { $0.key != .attachment && $0.key != .nvCID }
        }
        if let tv = textView, tv.shouldChangeText(in: range, replacementString: middle) {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: middle, attributes: attrs))
            tv.didChangeText()
        } else {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: middle, attributes: attrs))
        }
        mirror = storage.string
        restyleParagraphs(NSRange(location: range.location, length: (middle as NSString).length))
        if mirror != incoming { let s = mirror; DispatchQueue.main.async { [weak self] in self?.onText?(s) } }
    }

    // MARK: Selection / toolbar state

    var selection: NSRange { textView?.selectedRange() ?? NSRange(location: storage.length, length: 0) }

    func refreshActive() {
        let sel = selection
        let attrs: [NSAttributedString.Key: Any]
        if sel.length == 0, let tv = textView { attrs = tv.typingAttributes }
        else if storage.length > 0 { attrs = storage.attributes(at: min(sel.location, storage.length - 1), effectiveRange: nil) }
        else { attrs = [:] }
        let s = RichTextBridge.style(attrs), b = RichTextBridge.block(attrs)
        if s != active { active = s }
        if b != activeBlock { activeBlock = b }
        if sel.length != selectionLength { selectionLength = sel.length }   // COMPOSE-LAYOUT: floating format bar
    }

    /// COMPOSE-LAYOUT: length of the current selection (the floating format mini-bar shows while it is > 0).
    var selectionLength = 0

    // MARK: Editing helpers

    /// `replacement`: the new characters when the edit changes text (nil = attributes only), for correct undo.
    func edit(_ range: NSRange, replacement: String? = nil, _ body: () -> Void) {
        let tv = textView
        if let tv, !tv.shouldChangeText(in: range, replacementString: replacement) { return }
        storage.beginEditing(); body(); storage.endEditing()
        tv?.didChangeText()
        textChanged(format: true)
    }

    func paragraphRange(_ r: NSRange) -> NSRange { (storage.string as NSString).paragraphRange(for: r) }

    func restyleParagraphs(_ r: NSRange) {
        guard storage.length > 0 else { return }
        let pr = paragraphRange(NSRange(location: min(r.location, storage.length), length: max(0, min(r.length, storage.length - min(r.location, storage.length)))))
        RichTextBridge.restyle(storage, pr)
    }

    /// Toggle / set an inline attribute on the selection, or on the typing attributes when nothing is selected.
    func setInline(_ key: NSAttributedString.Key, _ value: Any?) {
        let sel = selection
        if sel.length == 0 {
            guard let tv = textView else { return }
            var t = tv.typingAttributes
            if let value { t[key] = value } else { t.removeValue(forKey: key) }
            if key == .nvCode, value != nil { t.removeValue(forKey: .nvLink) }
            t.merge(RichTextBridge.display(t)) { $1 }
            if value == nil { for k in [NSAttributedString.Key.backgroundColor, .underlineStyle, .strikethroughStyle, .link] where RichTextBridge.display(t)[k] == nil { t.removeValue(forKey: k) } }
            tv.typingAttributes = t
            refreshActive()
            return
        }
        edit(sel) {
            if let value { storage.addAttribute(key, value: value, range: sel) } else { storage.removeAttribute(key, range: sel) }
            RichTextBridge.restyle(storage, sel)
        }
    }

    func toggle(_ key: NSAttributedString.Key) {
        let on: Bool
        switch key {
        case .nvBold: on = active.bold
        case .nvItalic: on = active.italic
        case .nvUnderline: on = active.underline
        case .nvStrike: on = active.strike
        case .nvCode: on = active.code
        default: on = false
        }
        setInline(key, on ? nil : true)
    }

    func clearFormatting() {
        let sel = selection
        if sel.length == 0, let tv = textView {
            tv.typingAttributes = RichTextBridge.typing(block: activeBlock.kind == .paragraph ? activeBlock : RichBlock())
            refreshActive(); return
        }
        edit(sel) {
            for k in NSAttributedString.Key.nvInline { storage.removeAttribute(k, range: sel) }
            let pr = paragraphRange(sel)
            storage.addAttributes([.nvBlock: RichBlockKind.paragraph.rawValue, .nvLevel: 0, .nvAlign: RichAlign.left.rawValue], range: pr)
            RichTextBridge.restyle(storage, pr)
        }
    }

    /// Paragraph attributes for the paragraphs touching the selection.
    func setBlock(_ kind: RichBlockKind? = nil, level: Int? = nil, align: RichAlign? = nil, toggle: Bool = true) {
        let pr = paragraphRange(selection)
        var newKind = kind
        if let k = kind, toggle, activeBlock.kind == k { newKind = .paragraph }
        if pr.length == 0, let tv = textView {   // empty last paragraph: typing attributes only
            var b = activeBlock
            if let newKind { b.kind = newKind; if !newKind.isList { b.level = 0 } }
            if let level { b.level = max(0, min(level, 8)) }
            if let align { b.align = align }
            tv.typingAttributes = RichTextBridge.typing(block: b, style: active)
            refreshActive(); tv.needsDisplay = true; return
        }
        edit(pr) {
            if let newKind {
                storage.addAttribute(.nvBlock, value: newKind.rawValue, range: pr)
                if !newKind.isList { storage.addAttribute(.nvLevel, value: 0, range: pr) }
            }
            if let level {
                storage.enumerateAttribute(.nvLevel, in: pr) { v, r, _ in
                    storage.addAttribute(.nvLevel, value: max(0, min(level == Int.max ? (v as? Int ?? 0) + 1 : level == Int.min ? (v as? Int ?? 0) - 1 : level, 8)), range: r)
                }
            }
            if let align { storage.addAttribute(.nvAlign, value: align.rawValue, range: pr) }
            RichTextBridge.restyle(storage, pr)
        }
        if let tv = textView {
            var t = tv.typingAttributes
            for k in NSAttributedString.Key.nvParagraph { t[k] = storage.length > 0 ? storage.attribute(k, at: min(pr.location, storage.length - 1), effectiveRange: nil) : nil }
            t.merge(RichTextBridge.display(t)) { $1 }
            tv.typingAttributes = t
            tv.needsDisplay = true
        }
    }

    func indent(_ delta: Int) { setBlock(level: delta > 0 ? Int.max : Int.min, toggle: false) }

    // MARK: Links

    func beginLink() {
        var sel = selection
        if sel.length == 0, sel.location < storage.length, storage.attribute(.nvLink, at: sel.location, effectiveRange: nil) != nil {
            var eff = NSRange(); _ = storage.attribute(.nvLink, at: sel.location, longestEffectiveRange: &eff, in: NSRange(location: 0, length: storage.length))
            sel = eff
        }
        linkRange = sel
        linkText = (storage.string as NSString).substring(with: sel)
        linkURL = sel.length > 0 && sel.location < storage.length ? (storage.attribute(.nvLink, at: sel.location, effectiveRange: nil) as? String ?? "") : ""
        showLink = true
    }

    /// Returns an error message, nil on success.
    func commitLink() -> String? {
        var raw = linkURL.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, !raw.contains(":") { raw = raw.contains("@") ? "mailto:" + raw : "https://" + raw }
        guard let url = RichHTML.safeLink(raw) else { return "Use an http(s), mailto or tel link." }
        let text = linkText.isEmpty ? raw : linkText
        let r = NSRange(location: min(linkRange.location, storage.length), length: min(linkRange.length, storage.length - min(linkRange.location, storage.length)))
        let base = storage.length > 0 ? storage.attributes(at: max(0, min(r.location, storage.length - 1)), effectiveRange: nil) : RichTextBridge.typing(block: activeBlock)
        let attrs = base.filter { $0.key != .attachment && $0.key != .nvCID }.merging([.nvLink: url]) { $1 }
        edit(r, replacement: text) {
            storage.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: attrs))
            RichTextBridge.restyle(storage, NSRange(location: r.location, length: (text as NSString).length))
        }
        textView?.setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
        if let tv = textView { var t = tv.typingAttributes; t.removeValue(forKey: .nvLink); t.merge(RichTextBridge.display(t)) { $1 }; t.removeValue(forKey: .link); t.removeValue(forKey: .underlineStyle); tv.typingAttributes = t }
        showLink = false
        return nil
    }

    func removeLink() {
        let r = linkRange
        showLink = false
        guard r.length > 0, NSMaxRange(r) <= storage.length else { return }
        edit(r) { storage.removeAttribute(.nvLink, range: r); RichTextBridge.restyle(storage, r) }
    }

    // MARK: Paste

    func insert(_ doc: RichDoc, at range: NSRange) {
        var d = doc
        // A one-paragraph paste merges into the current paragraph (keeps its block).
        if d.blocks.count == 1, storage.length > 0 || textView != nil {
            let b = RichTextBridge.block(storage.length > 0 ? storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil) : [:])
            d.blocks[0].kind = b.kind; d.blocks[0].level = b.level; d.blocks[0].align = b.align
        }
        let s = RichTextBridge.attributed(d, images: inlineImages)
        edit(range, replacement: s.string) { storage.replaceCharacters(in: range, with: s) }
        textView?.setSelectedRange(NSRange(location: range.location + s.length, length: 0))
        normaliseParagraphs(NSRange(location: range.location, length: s.length))
        restyleParagraphs(NSRange(location: range.location, length: s.length))
    }

    // MARK: Attachments

    /// Adds files: images with `inline` go into the body, the rest become chips. Returns false if refused.
    @discardableResult
    func attach(urls: [URL], inlineImages asInline: Bool, at range: NSRange? = nil) -> Bool {
        if let why = attachBlockReason { notice = why; return false }
        var ok = true
        for u in urls {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > AttachmentUpload.maxSize, !oversize.contains(u) { oversize.append(u) }   // ONEDRIVE: offer upload + share
            if let why = AttachmentUpload.invalidReason(size: size, name: u.lastPathComponent) { notice = why; ok = false; continue }
            guard let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { notice = "Couldn't read \(u.lastPathComponent)."; ok = false; continue }
            let type = UTType(filenameExtension: u.pathExtension)
            let mime = type?.preferredMIMEType ?? AttachmentUpload.mimeType(forExtension: u.pathExtension)
            if asInline, type?.conforms(to: .image) == true, data.count < AttachmentUpload.smallLimit * 2 {
                insertImage(data, mime: mime, name: u.lastPathComponent, at: range)
            } else {
                add(OutgoingAttachment(name: u.lastPathComponent, contentType: mime, data: data))
            }
        }
        return ok
    }

    func add(_ a: OutgoingAttachment) {
        attachments.append(a)
        let id = a.id
        AttachmentProgress.shared.observe(id) { [weak self] s, t in
            Task { @MainActor in self?.progress[id] = t > 0 ? Double(s) / Double(t) : 1 }
        }
        notice = nil
        onFormat?()
    }

    func remove(_ id: UUID) {
        if let n = attachments.first(where: { $0.id == id })?.name { cloudCopyLabels.removeValue(forKey: n) }
        attachments.removeAll { $0.id == id }
        progress.removeValue(forKey: id)
        AttachmentProgress.shared.stop(id)
        onFormat?()
    }

    /// Inline image at the cursor (paste / drop). Becomes `<img src="cid:…">` + an inline attachment.
    @discardableResult
    func insertImage(_ data: Data, mime: String, name: String, at range: NSRange? = nil) -> Bool {
        if let why = attachBlockReason { notice = why; return false }
        if let why = AttachmentUpload.invalidReason(size: data.count, name: name) { notice = why; return false }
        var data = data, mime = mime, name = name
        if mime == "image/tiff", let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            data = png; mime = "image/png"; name = (name as NSString).deletingPathExtension + ".png"
        }
        let cid = UUID().uuidString.lowercased() + "@niivo"
        inlineImages[cid] = OutgoingAttachment(name: name, contentType: mime, data: data, isInline: true, contentId: cid)
        insert(RichDoc([RichBlock(runs: [RichRun("", image: RichImage(cid: cid, alt: name))])]), at: range ?? selection)
        notice = nil
        return true
    }

    // MARK: Signatures

    func applySignature(_ sig: MailSignature?, byUser: Bool) {
        for a in sig?.inlineAttachments ?? [] { if let c = a.contentId { inlineImages[c] = a } }
        let sel = selection
        load(SignaturePlacement.apply(sig?.doc, to: doc))
        signatureId = sig?.id
        if byUser { signatureIsDefault = false }
        textView?.setSelectedRange(NSRange(location: min(sel.location, firstSignatureLocation ?? storage.length), length: 0))
    }

    private var firstSignatureLocation: Int? {
        var loc: Int?
        storage.enumerateAttribute(.nvSignature, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            if v as? Bool == true { loc = max(0, r.location - 1); stop.pointee = true }
        }
        return loc
    }
}
