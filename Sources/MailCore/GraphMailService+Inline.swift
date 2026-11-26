import Foundation

// Attachment content for the reader (inline cid: images, open / save). Bytes stay in memory; see `rawGET`.
//
// UNVERIFIED against a tenant: `contentId` is a `fileAttachment` property, so it isn't $select'ed on the collection
// (the list in `message(id:)` already carries `isInline`); each inline candidate is fetched on its own instead:
//   GET /messages/{id}/attachments/{attachmentId}         → fileAttachment JSON incl. contentId + contentBytes
//   GET /messages/{id}/attachments/{attachmentId}/$value  → raw bytes
// https://learn.microsoft.com/graph/api/attachment-get?view=graph-rest-1.0
extension GraphMailService: MailAttachmentFetching {
    private static let graphBase = URL(string: "https://graph.microsoft.com/v1.0")!

    private func attachmentURL(_ messageId: String, _ attachmentId: String, mailbox: String, value: Bool) -> URL {
        let root = mailbox == "me" ? "me" : "users/\(mailbox)"
        return Self.graphBase.appending(path: "\(root)/messages/\(messageId)/attachments/\(attachmentId)\(value ? "/$value" : "")")
    }

    public func inlineAttachment(messageId: String, attachmentId: String, mailbox: String) async throws -> AttachmentContent {
        let data = try await rawGET(attachmentURL(messageId, attachmentId, mailbox: mailbox, value: false), mailbox: mailbox)
        guard let a = try? JSONDecoder().decode(GMFileAttachment.self, from: data) else { throw MailServiceError.http(500, "decode") }
        guard let b64 = a.contentBytes, let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
            throw MailServiceError.notFound   // item / reference attachment: no bytes to inline
        }
        return AttachmentContent(id: a.id ?? attachmentId, name: a.name ?? "", contentType: a.contentType ?? "",
                                 contentId: a.contentId, isInline: a.isInline ?? false, data: bytes)
    }

    public func attachmentBytes(messageId: String, attachmentId: String, mailbox: String) async throws -> Data {
        try await rawGET(attachmentURL(messageId, attachmentId, mailbox: mailbox, value: true), mailbox: mailbox)
    }
}

struct GMFileAttachment: Decodable {
    var id: String?
    var name: String?
    var contentType: String?
    var contentId: String?
    var isInline: Bool?
    var contentBytes: String?
}

// MARK: - Fixtures

extension FixtureMailService: MailAttachmentFetching {
    /// 1×1 PNG (teal), for fixture inline images.
    public static let fixturePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNgYPj/HwADAgH/eL9GtQAAAABJRU5ErkJggg==")!

    public func inlineAttachment(messageId: String, attachmentId: String, mailbox: String) async throws -> AttachmentContent {
        AttachmentContent(id: attachmentId, name: "\(attachmentId).png", contentType: "image/png", contentId: attachmentId,
                          isInline: true, data: Self.fixturePNG)
    }

    public func attachmentBytes(messageId: String, attachmentId: String, mailbox: String) async throws -> Data {
        Data("Synthetic fixture attachment \(attachmentId). No real content.\n".utf8)
    }
}
