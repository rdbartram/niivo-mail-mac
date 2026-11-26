import AppKit
import SwiftUI
import MailCore

/// NSTextView-based mail editor (TextKit 1 on the model-owned storage). Spell check, dictation and the emoji picker
/// come with NSTextView.
struct MailRichEditor: NSViewRepresentable {
    var state: ComposerEditorState
    /// AI-HOOK: the selection in `plain` (ComposerState.body) for Rewrite.
    var selection: Binding<TextSelection?>?
    /// The text the AI hooks see / write (ComposerState.body).
    var plain: String
    var attachBlockReason: String?
    var brand: Bool
    var minHeight: CGFloat = 240

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        RichTextBridge.brandFont = brand
        let layout = ComposerLayoutManager()
        state.storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = ComposerTextView(frame: .zero, textContainer: container)
        tv.editorState = state
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.usesFindBar = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: minHeight)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        tv.typingAttributes = state.storage.length > 0
            ? state.storage.attributes(at: 0, effectiveRange: nil).filter { $0.key != .attachment && $0.key != .nvCID }
            : RichTextBridge.typing(block: RichBlock())
        tv.registerForDraggedTypes([.fileURL, .png, .tiff, .html, .rtf, .string])
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.parent = self
        state.textView = tv
        RichTextBridge.restyle(state.storage, NSRange(location: 0, length: state.storage.length))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        state.attachBlockReason = attachBlockReason
        if let tv = scroll.documentView as? ComposerTextView, state.textView !== tv { state.textView = tv }
        if plain != state.storage.string { state.reconcile(plain) }   // AI-HOOK: draft / rewrite / undo wrote the body
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tv = scroll.documentView as? ComposerTextView, let lm = tv.layoutManager else { return }
        if tv.editorState?.textView === tv { tv.editorState?.textView = nil }
        tv.editorState?.storage.removeLayoutManager(lm)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MailRichEditor?

        func textDidChange(_ n: Notification) {
            guard let s = parent?.state else { return }
            if let tv = n.object as? NSTextView { s.normaliseParagraphs(tv.selectedRange()) }
            s.textChanged()
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let p = parent, let tv = n.object as? NSTextView else { return }
            p.state.refreshActive()
            // AI-HOOK: map the selection onto ComposerState.body (the same string as the storage).
            let body = p.state.storage.string
            if let sel = p.selection, let r = Range(tv.selectedRange(), in: body) {
                let ts = r.isEmpty ? TextSelection(insertionPoint: r.lowerBound) : TextSelection(range: r)
                DispatchQueue.main.async { sel.wrappedValue = ts }
            }
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }   // edit, don't open
    }
}

/// Key handling, live Markdown, paste and drop.
final class ComposerTextView: NSTextView {
    weak var editorState: ComposerEditorState?
    private var converting = false

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, let s = editorState else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (mods, key) {
        case ([.command], "b"): s.toggle(.nvBold); return true
        case ([.command], "i"): s.toggle(.nvItalic); return true
        case ([.command], "u"): s.toggle(.nvUnderline); return true
        case ([.command], "k"): s.beginLink(); return true
        case ([.command, .shift], "v"), ([.command, .shift, .option], "v"): pasteAsPlainText(nil); return true
        case ([.command, .shift], "x"): s.toggle(.nvStrike); return true
        default:
            // ⇧⌘7 / ⇧⌘8 by key position (charactersIgnoringModifiers keeps Shift on many layouts).
            if mods == [.command, .shift], e.keyCode == 26 { s.setBlock(.number); return true }
            if mods == [.command, .shift], e.keyCode == 28 { s.setBlock(.bullet); return true }
            return super.performKeyEquivalent(with: e)
        }
    }

    // MARK: Lists, quotes, headings

    override func insertNewline(_ sender: Any?) {
        guard let s = editorState else { return super.insertNewline(sender) }
        let b = s.activeBlock
        let pr = s.paragraphRange(selectedRange())
        let text = (string as NSString).substring(with: pr).trimmingCharacters(in: .newlines)
        if b.kind != .paragraph && b.kind != .code && text.isEmpty {
            s.setBlock(.paragraph, toggle: false)   // Enter on an empty item leaves the list / quote
            return
        }
        super.insertNewline(sender)
        if b.kind == .heading1 || b.kind == .heading2 || b.kind == .heading3 { s.setBlock(.paragraph, toggle: false) }
    }

    override func insertTab(_ sender: Any?) {
        if let s = editorState, s.activeBlock.kind.isList { s.indent(1); return }
        // `;shortcut` + Tab expands a template (the tab itself is not kept).
        if let s = editorState, selectedRange().length == 0, s.expandTemplateTrigger(cursor: selectedRange().location, delimiterLength: 0) { return }
        super.insertTab(sender)   // in a table row: the next cell
    }

    // Spell-check language of this draft (NSSpellChecker is app-wide): set on focus, automatic again on blur.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let s = editorState { DispatchQueue.main.async { s.applySpellLanguage() } }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, editorState?.effectiveLanguage != nil { ComposerEditorState.setSpellLanguage(nil) }
        return ok
    }

    override func insertBacktab(_ sender: Any?) {
        if let s = editorState, s.activeBlock.kind.isList {
            if s.activeBlock.level == 0 { s.setBlock(.paragraph, toggle: false) } else { s.indent(-1) }
            return
        }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        // Backspace at the start of a list item / quote / heading turns it back into a paragraph first.
        if let s = editorState, s.activeBlock.kind != .paragraph, selectedRange().length == 0 {
            let pr = s.paragraphRange(selectedRange())
            if selectedRange().location == pr.location {
                if s.activeBlock.kind.isList && s.activeBlock.level > 0 { s.indent(-1) } else { s.setBlock(.paragraph, toggle: false) }
                return
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: Live Markdown

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        // `;shortcut` + Space expands a template (Markdown on or off).
        if !converting, let s = editorState, (string as? String) == " ", !hasMarkedText(), selectedRange().length == 0 {
            converting = true
            let done = s.expandTemplateTrigger(cursor: selectedRange().location, delimiterLength: 1)
            converting = false
            if done { return }
        }
        guard !converting, let s = editorState, s.liveMarkdown, let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1, !hasMarkedText() else { return }
        converting = true; defer { converting = false }
        let cursor = selectedRange().location
        let ns = self.string as NSString
        let pr = ns.paragraphRange(for: NSRange(location: max(0, cursor - 1), length: 0))
        guard cursor >= pr.location else { return }
        let before = ns.substring(with: NSRange(location: pr.location, length: cursor - pr.location))
        if typed == " ", s.activeBlock.kind == .paragraph, let t = RichMarkdown.blockTrigger(before) {
            let r = NSRange(location: pr.location, length: (before as NSString).length)
            guard shouldChangeText(in: r, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: pr.location, length: 0))
            s.setBlock(t.kind, toggle: false)
            return
        }
        if s.activeBlock.kind != .code, let m = RichMarkdown.inlineMatch(before) {
            let r = NSRange(location: cursor - m.utf16Length, length: m.utf16Length)
            var attrs = textStorage?.attributes(at: r.location, effectiveRange: nil) ?? typingAttributes
            attrs = attrs.filter { $0.key != .attachment && $0.key != .nvCID }
            if m.bold { attrs[.nvBold] = true }
            if m.italic { attrs[.nvItalic] = true }
            if m.strike { attrs[.nvStrike] = true }
            if m.code { attrs[.nvCode] = true }
            if let l = m.link { attrs[.nvLink] = l }
            let rep = NSAttributedString(string: m.text, attributes: attrs)
            guard shouldChangeText(in: r, replacementString: m.text) else { return }
            textStorage?.replaceCharacters(in: r, with: rep)
            RichTextBridge.restyle(textStorage!, NSRange(location: r.location, length: rep.length))
            didChangeText()
            setSelectedRange(NSRange(location: r.location + rep.length, length: 0))
            // Continue typing unformatted.
            var t = attrs
            for k in [NSAttributedString.Key.nvBold, .nvItalic, .nvStrike, .nvCode, .nvLink] where (k == .nvBold && m.bold) || (k == .nvItalic && m.italic)
                || (k == .nvStrike && m.strike) || (k == .nvCode && m.code) || (k == .nvLink && m.link != nil) { t.removeValue(forKey: k) }
            for k in [NSAttributedString.Key.backgroundColor, .underlineStyle, .strikethroughStyle, .link] { t.removeValue(forKey: k) }
            t.merge(RichTextBridge.display(t)) { $1 }
            typingAttributes = t
            s.refreshActive()
        }
    }

    // MARK: Paste

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.niivoDoc, .fileURL, .html, .rtf, .png, .tiff, .string] + super.readablePasteboardTypes
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.niivoDoc] + super.writablePasteboardTypes }

    /// Copy / cut / drag also write the selection as a RichDoc, so lists, headings, quotes and inline images survive
    /// within niivo (RTF would flatten them).
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let ok = super.writeSelection(to: pboard, types: types.filter { $0 != .niivoDoc })
        let r = selectedRange()
        guard r.length > 0, let ts = textStorage, NSMaxRange(r) <= ts.length,
              let data = try? JSONEncoder().encode(RichTextBridge.doc(ts.attributedSubstring(from: r))) else { return ok }
        pboard.addTypes([.niivoDoc], owner: nil)
        return pboard.setData(data, forType: .niivoDoc) || ok
    }

    /// Internal drag-move / services read of our own type (NSTextView has already placed the selection).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .niivoDoc, let s = editorState, let d = pboard.data(forType: .niivoDoc), let doc = try? JSONDecoder().decode(RichDoc.self, from: d) {
            s.insert(doc, at: rangeForUserTextChange); return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func paste(_ sender: Any?) {
        if !pasteRich(NSPasteboard.general, at: selectedRange()) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let s = editorState, let text = NSPasteboard.general.string(forType: .string) else { return }
        s.insert(RichDoc.plain(text.replacingOccurrences(of: "\r\n", with: "\n")), at: selectedRange())
    }

    /// Files → attachments (images inline), image data → inline image, HTML → cleaned, RTF → inferred,
    /// text → Markdown when it looks like it (and live Markdown is on), else plain.
    @discardableResult
    func pasteRich(_ pb: NSPasteboard, at range: NSRange) -> Bool {
        guard let s = editorState else { return false }
        if let d = pb.data(forType: .niivoDoc), let doc = try? JSONDecoder().decode(RichDoc.self, from: d) {
            s.insert(doc, at: range); return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            setSelectedRange(range)
            s.attach(urls: urls, inlineImages: true, at: range)
            return true
        }
        let bitmap = [NSPasteboard.PasteboardType.png, .tiff].first { pb.data(forType: $0) != nil }
        if let html = pb.string(forType: .html), case let p = RichHTML.parse(html),
           !(bitmap != nil && p.doc.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && p.dataImages.isEmpty) {   // browser "Copy Image": use the bitmap
            if s.attachBlockReason == nil {
                for i in p.dataImages {
                    s.inlineImages[i.cid] = OutgoingAttachment(name: "image.\(i.mime.split(separator: "/").last ?? "png")", contentType: i.mime,
                                                               data: i.data, isInline: true, contentId: i.cid)
                }
            }
            var doc = p.doc
            if s.attachBlockReason != nil {   // label gate: drop the images rather than smuggle them in
                doc.blocks = doc.blocks.map { b in var b = b; b.runs.removeAll { $0.image != nil }; return b }
                if !p.dataImages.isEmpty { s.notice = s.attachBlockReason }
            }
            s.insert(doc, at: range)
            return true
        }
        if let rtf = pb.data(forType: .rtf), let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            s.insert(RichTextBridge.infer(a), at: range); return true
        }
        if let type = bitmap, pb.string(forType: .string) == nil || pb.string(forType: .html) != nil, let data = pb.data(forType: type) {
            s.insertImage(data, mime: type == .png ? "image/png" : "image/tiff", name: "Pasted image.png", at: range); return true
        }
        if let text = pb.string(forType: .string) {
            let t = text.replacingOccurrences(of: "\r\n", with: "\n")
            if s.liveMarkdown, RichMarkdown.looksLikeMarkdown(t) { s.insert(RichMarkdown.parse(t), at: range) }
            else { s.insert(RichDoc.plain(t), at: range) }
            return true
        }
        return false
    }

    // MARK: Drop

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if (sender.draggingSource as? NSTextView) === self { return super.performDragOperation(sender) }   // move: readSelection handles our type
        let pb = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        let idx = characterIndexForInsertion(at: point)
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.data(forType: .niivoDoc) != nil || pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil || pb.string(forType: .html) != nil {
            window?.makeFirstResponder(self)
            return pasteRich(pb, at: NSRange(location: min(idx, (string as NSString).length), length: 0))
        }
        return super.performDragOperation(sender)
    }
}

/// Draws list markers, quote bars and code backgrounds (the storage holds only the text).
final class ComposerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        // Empty last paragraph (no characters yet): its block lives in the typing attributes.
        let extra = extraLineFragmentRect
        if extra != .zero, let tv = container.textView {
            let a = tv.typingAttributes
            let b = RichTextBridge.block(a)
            if b.kind.isList {
                let ps = a[.paragraphStyle] as? NSParagraphStyle
                let font = (a[.font] as? NSFont) ?? .systemFont(ofSize: 14)
                let n = b.kind == .number ? Self.number(storage, storage.string as NSString, NSRange(location: storage.length, length: 0), b) : 0
                let m = NSAttributedString(string: b.kind == .bullet ? ["•", "◦", "▪"][b.level % 3] : "\(n).",
                                           attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                m.draw(at: NSPoint(x: (ps?.firstLineHeadIndent ?? 0) + origin.x + container.lineFragmentPadding - m.size().width - 6,
                                   y: extra.minY + origin.y + (extra.height - m.size().height) / 2 - 0.5))
            }
        }
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var loc = ns.paragraphRange(for: NSRange(location: chars.location, length: 0)).location
        while loc < NSMaxRange(chars), loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let a = storage.attributes(at: pr.location, effectiveRange: nil)
            let b = RichTextBridge.block(a)
            if b.kind != .paragraph && !b.kind.isHeading {
                let gr = glyphRange(forCharacterRange: pr, actualCharacterRange: nil)
                var rect = boundingRect(forGlyphRange: gr, in: container)
                rect.origin.x += origin.x; rect.origin.y += origin.y
                let firstLine = lineFragmentRect(forGlyphAt: max(gr.location, 0), effectiveRange: nil)
                let ps = a[.paragraphStyle] as? NSParagraphStyle
                let indent = (ps?.firstLineHeadIndent ?? 0) + origin.x + container.lineFragmentPadding
                switch b.kind {
                case .bullet, .number:
                    let marker = b.kind == .bullet ? (["•", "◦", "▪"][b.level % 3]) : "\(Self.number(storage, ns, pr, b))."
                    let font = (a[.font] as? NSFont) ?? .systemFont(ofSize: 14)
                    let m = NSAttributedString(string: marker, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    let w = m.size().width
                    m.draw(at: NSPoint(x: indent - w - 6, y: firstLine.minY + origin.y + (firstLine.height - m.size().height) / 2 - 0.5))
                case .quote:
                    NSColor.tertiaryLabelColor.setFill()
                    NSRect(x: origin.x + container.lineFragmentPadding + 2, y: rect.minY, width: 3, height: rect.height).fill()
                case .rule:
                    NSColor.separatorColor.setFill()
                    NSRect(x: origin.x + container.lineFragmentPadding, y: firstLine.midY + origin.y - 0.5,
                           width: container.size.width - 2 * container.lineFragmentPadding, height: 1).fill()
                case .table:
                    // One row: outer box + a divider before every column after the first (cells = tab-separated).
                    let text = ns.substring(with: pr)
                    let cols = max(1, text.filter { $0 == "\t" }.count + 1)
                    let x0 = origin.x + container.lineFragmentPadding
                    let w = CGFloat(cols) * RichTextBridge.tableColumn + RichTextBridge.tableInset - 4
                    let box = NSRect(x: x0, y: rect.minY - 2, width: w, height: max(rect.height, firstLine.height) + 4)
                    NSColor.separatorColor.setStroke()
                    let path = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                    NSColor.separatorColor.setFill()
                    for c in 1..<cols {
                        let x = x0 + RichTextBridge.tableInset + CGFloat(c) * RichTextBridge.tableColumn - 5
                        NSRect(x: x, y: box.minY, width: 1, height: box.height).fill()
                    }
                case .code:
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.3).setFill()
                    NSRect(x: origin.x + container.lineFragmentPadding, y: rect.minY, width: container.size.width - 2 * container.lineFragmentPadding,
                           height: max(rect.height, firstLine.height)).fill()
                default: break
                }
            }
            loc = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
    }

    /// 1-based position of a numbered item among consecutive items at its level.
    static func number(_ s: NSTextStorage, _ ns: NSString, _ pr: NSRange, _ b: RichBlock) -> Int {
        var n = 1
        var loc = pr.location
        while loc > 0 {
            let prev = ns.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            guard prev.location < s.length else { break }
            let pb = RichTextBridge.block(s.attributes(at: prev.location, effectiveRange: nil))
            if pb.kind.isList && pb.level > b.level { loc = prev.location; continue }
            guard pb.kind == .number, pb.level == b.level else { break }
            n += 1; loc = prev.location
        }
        return n
    }
}

extension NSPasteboard.PasteboardType {
    static let niivoDoc = NSPasteboard.PasteboardType("ai.niivo.mail.richdoc")
}

extension RichBlockKind {
    var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }
}
