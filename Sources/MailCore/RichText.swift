import Foundation

// Composer document model: pure Swift (no AppKit) so the HTML / Markdown conversions are testable in CoreSelfTest.
// The app bridges it to NSAttributedString (RichTextBridge.swift). Only what the user set is stored: no theme fonts or
// colours, so sent mail never inherits dark-mode display attributes.

public enum RichSize: String, Codable, Sendable, Hashable { case small, large }

public struct RichStyle: Codable, Sendable, Hashable {
    public var bold = false, italic = false, underline = false, strike = false, code = false
    public var size: RichSize?
    /// "#RRGGBB" only (validated on the way in).
    public var color: String?
    public var highlight: String?
    /// http(s) / mailto / tel only.
    public var link: String?
    public init(bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false, code: Bool = false,
                size: RichSize? = nil, color: String? = nil, highlight: String? = nil, link: String? = nil) {
        self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike; self.code = code
        self.size = size; self.color = color; self.highlight = highlight; self.link = link
    }
    public static let plain = RichStyle()
}

/// Inline image, referenced as `<img src="cid:…">` (the bytes travel as an inline attachment).
public struct RichImage: Codable, Sendable, Hashable {
    public var cid: String
    public var alt: String
    public var width: Int?
    public init(cid: String, alt: String = "", width: Int? = nil) { self.cid = cid; self.alt = alt; self.width = width }
}

public struct RichRun: Codable, Sendable, Hashable {
    public var text: String
    public var style: RichStyle
    public var image: RichImage?
    public init(_ text: String, _ style: RichStyle = .plain, image: RichImage? = nil) {
        self.text = image == nil ? text : RichRun.objectReplacement; self.style = style; self.image = image
    }
    /// U+FFFC: the attachment character NSTextView uses for images.
    public static let objectReplacement = "\u{FFFC}"
    /// U+2028: a line break inside a paragraph (`<br>`).
    public static let lineBreak = "\u{2028}"
}

public enum RichBlockKind: String, Codable, Sendable, Hashable, CaseIterable {
    case paragraph, heading1, heading2, heading3, quote, bullet, number, code
    /// Horizontal rule (`<hr>`): an empty paragraph drawn as a line.
    case rule
    /// One row of a simple grid: cells separated by tab characters. Consecutive rows form one `<table>`.
    case table
    public var isList: Bool { self == .bullet || self == .number }
    /// Separates table cells inside a `.table` block.
    public static let cellSeparator: Character = "\t"
}

public enum RichAlign: String, Codable, Sendable, Hashable { case left, center, right, justify }

public struct RichBlock: Codable, Sendable, Hashable {
    public var kind: RichBlockKind
    /// List nesting (0 = top level). Ignored for non-list blocks.
    public var level: Int
    public var align: RichAlign
    public var runs: [RichRun]
    /// Part of the inserted signature (replaced as a unit when the signature is switched).
    public var signature: Bool
    public init(_ kind: RichBlockKind = .paragraph, level: Int = 0, align: RichAlign = .left, runs: [RichRun] = [], signature: Bool = false) {
        self.kind = kind; self.level = max(0, min(level, 8)); self.align = align; self.runs = runs; self.signature = signature
    }
    public var text: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
}

public struct RichDoc: Codable, Sendable, Hashable {
    public var blocks: [RichBlock]
    public init(_ blocks: [RichBlock] = []) { self.blocks = blocks }

    /// Plain text as the editor stores it (paragraphs joined by "\n").
    public var plainText: String { blocks.map(\.text).joined(separator: "\n") }
    public var images: [RichImage] { blocks.flatMap { $0.runs.compactMap(\.image) } }
    public var isEmpty: Bool { blocks.allSatisfy(\.isEmpty) }

    /// Merges neighbouring runs with the same style; drops empty runs.
    public func normalised() -> RichDoc {
        RichDoc(blocks.map { b in
            var out: [RichRun] = []
            for r in b.runs where !r.text.isEmpty {
                if r.image == nil, let last = out.last, last.image == nil, last.style == r.style { out[out.count - 1].text += r.text }
                else { out.append(r) }
            }
            var nb = b; nb.runs = out
            return nb
        })
    }

    public static func plain(_ s: String) -> RichDoc {
        RichDoc(s.components(separatedBy: "\n").map { RichBlock(runs: $0.isEmpty ? [] : [RichRun($0)]) })
    }
}

// MARK: - Signatures in the document

public enum SignaturePlacement {
    /// Replaces any signature blocks with `signature` (nil removes it). The signature goes at the end of the user's
    /// content, i.e. above the quoted history (which Exchange adds below our HTML on reply/forward), separated by one
    /// empty paragraph.
    public static func apply(_ signature: RichDoc?, to doc: RichDoc) -> RichDoc {
        var blocks = doc.blocks.filter { !$0.signature }
        guard let sig = signature, !sig.isEmpty else { return RichDoc(blocks) }
        if blocks.isEmpty { blocks = [RichBlock(), RichBlock()] }
        else if !(blocks.last?.isEmpty ?? true) { blocks.append(RichBlock()) }
        blocks += sig.blocks.map { var b = $0; b.signature = true; return b }
        return RichDoc(blocks)
    }
}
