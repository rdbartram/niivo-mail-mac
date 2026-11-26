import Foundation

/// Finding the encrypted payload of a Purview/RMS-protected message.
///
/// A protected (IRM / sensitivity-label-encrypted) email is carried as an attachment named `message.rpmsg`
/// (Purview Message Encryption variants: `message_v2.rpmsg` … `message_v4.rpmsg`); the MIP File SDK decrypts exactly that
/// attachment for inspection — https://learn.microsoft.com/information-protection/develop/concept-email#file-sdk-operations-for-rpmsg-files.
/// Encrypted meeting invites "can be opened in the same way as encrypted email" —
/// https://learn.microsoft.com/purview/sensitivity-labels-meetings.
///
/// UNVERIFIED against a live tenant: how Graph surfaces it to a third-party app — as a fileAttachment in
/// `/messages/{id}/attachments` (name / contentType), only inside the MIME (`/messages/{id}/$value`), or both; and the
/// exact content type (commonly `application/x-microsoft-rpmsg-message`, item class `IPM.Note.rpmsg.Microsoft Exchange`,
/// MIME `Content-Class: rpmsg.message`). The detector therefore accepts every one of those signals.
public enum RPMSG {
    public static let contentType = "application/x-microsoft-rpmsg-message"

    /// `message.rpmsg`, `message_v2.rpmsg` … `message_v4.rpmsg` (case-insensitive).
    public static func isRPMSGName(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard n.hasSuffix(".rpmsg") else { return false }
        let stem = n.dropLast(".rpmsg".count)
        return stem == "message" || ["message_v2", "message_v3", "message_v4"].contains(String(stem))
    }

    public static func isRPMSGAttachment(name: String?, contentType: String?) -> Bool {
        if let name, isRPMSGName(name) { return true }
        let ct = (contentType ?? "").lowercased()
        return ct.hasPrefix(Self.contentType) || ct.contains("rpmsg")
    }

    /// Item class / content class markers seen on protected items (heuristic, UNVERIFIED for Graph).
    public static func isProtectedItemClass(_ s: String?) -> Bool {
        let v = (s ?? "").lowercased()
        return v.contains("rpmsg")
    }

    // MARK: MIME

    /// True when the MIME looks like an RMS-protected message: a `Content-Class: rpmsg.message` header, or any
    /// part that is an rpmsg attachment.
    public static func isProtectedMIME(_ mime: Data) -> Bool {
        guard let root = MIMEPart.parse(mime) else { return false }
        if isProtectedItemClass(root.header("content-class")) { return true }
        return root.flattened.contains { isRPMSGPart($0) }
    }

    /// The decoded bytes of the first rpmsg part, or nil.
    public static func extract(fromMIME mime: Data) -> Data? {
        guard let root = MIMEPart.parse(mime) else { return nil }
        return root.flattened.first(where: isRPMSGPart)?.decodedBody
    }

    static func isRPMSGPart(_ p: MIMEPart) -> Bool {
        let ct = p.header("content-type") ?? ""
        let name = p.parameter("filename", in: "content-disposition") ?? p.parameter("name", in: "content-type")
        return isRPMSGAttachment(name: name, contentType: ct.split(separator: ";").first.map(String.init))
    }
}

/// Minimal RFC 2045/2046 multipart reader: headers (with folding), boundaries, base64 / quoted-printable / 7bit.
/// Only what's needed to locate one attachment; it never interprets HTML and never writes anything to disk.
struct MIMEPart {
    var headers: [(String, String)]
    var body: Data
    var children: [MIMEPart]

    func header(_ name: String) -> String? {
        headers.first { $0.0 == name.lowercased() }?.1
    }

    /// `name="x"` style parameter of a structured header.
    func parameter(_ param: String, in headerName: String) -> String? {
        guard let h = header(headerName) else { return nil }
        for piece in h.split(separator: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == param.lowercased() else { continue }
            return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    var flattened: [MIMEPart] { [self] + children.flatMap(\.flattened) }

    var decodedBody: Data {
        switch (header("content-transfer-encoding") ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let cleaned = body.filter { !($0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09) }
            return Data(base64Encoded: cleaned) ?? Data()
        case "quoted-printable":
            return Self.decodeQP(body)
        default:
            return body
        }
    }

    static func parse(_ data: Data, depth: Int = 0) -> MIMEPart? {
        guard depth < 12 else { return nil }
        let bytes = [UInt8](data)
        // Header/body split at the first empty line (CRLFCRLF or LFLF).
        var split: Int?
        var bodyStart = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { split = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { split = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        guard let split else { return nil }
        // Drop CRs: "\r\n" is one Swift Character, so splitting on "\n" would otherwise leave "\r" in values.
        let headerText = String(decoding: bytes[0..<split].filter { $0 != 0x0D }, as: UTF8.self)
        var headers: [(String, String)] = []
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((line[..<colon].lowercased().trimmingCharacters(in: .whitespaces),
                                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        let body = Data(bytes[min(bodyStart, bytes.count)...])
        var part = MIMEPart(headers: headers, body: body, children: [])
        let ct = (part.header("content-type") ?? "").lowercased()
        if ct.hasPrefix("multipart/"), let boundary = part.parameter("boundary", in: "content-type"), !boundary.isEmpty {
            part.children = splitMultipart(body, boundary: boundary).compactMap { parse($0, depth: depth + 1) }
        }
        return part
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = [UInt8](("--" + boundary).utf8)
        let b = [UInt8](body)
        var marks: [(start: Int, end: Int)] = []   // delimiter line ranges
        var i = 0
        while i + delim.count <= b.count {
            let atLineStart = i == 0 || b[i - 1] == 0x0A
            if atLineStart, b[i] == 0x2D, Array(b[i..<(i + delim.count)]) == delim {
                var e = i + delim.count
                while e < b.count, b[e] != 0x0A { e += 1 }
                marks.append((i, min(e + 1, b.count)))
                i = e
            }
            i += 1
        }
        var parts: [Data] = []
        for k in 0..<max(0, marks.count - 1) {
            var s = marks[k].end, e = marks[k + 1].start
            if e > s, b[e - 1] == 0x0A { e -= 1 }
            if e > s, b[e - 1] == 0x0D { e -= 1 }
            if s > e { s = e }
            parts.append(Data(b[s..<e]))
        }
        return parts
    }

    static func decodeQP(_ d: Data) -> Data {
        let b = [UInt8](d)
        var out = [UInt8](); out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 0x30...0x39: c - 0x30; case 0x41...0x46: c - 0x37; case 0x61...0x66: c - 0x57; default: nil }
        }
        while i < b.count {
            if b[i] == 0x3D {
                if i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(b[i]); i += 1
        }
        return Data(out)
    }
}
