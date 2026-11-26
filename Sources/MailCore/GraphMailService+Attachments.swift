import Foundation

/// Outgoing attachments on drafts.
///
/// Fetched from learn.microsoft.com (2026-11-19) and followed:
///  * < 3 MB: `POST /messages/{id}/attachments` with a `#microsoft.graph.fileAttachment` (name, contentType,
///    contentBytes base64, isInline, contentId).
///  * 3–150 MB: `POST /messages/{id}/attachments/createUploadSession` with `AttachmentItem` {attachmentType: "file",
///    name, size, contentType, isInline, contentId} → `uploadUrl`; then sequential `PUT uploadUrl` with
///    `Content-Range: bytes a-b/total`; the last chunk answers 201.
///  * Inline images: `isInline: true` + `contentId`, referenced in the body as `<img src="cid:…">`.
/// UNVERIFIED (not on the fetched pages, following the "attach large files" guide from memory):
///  * no `Authorization` header on the uploadUrl PUTs (the URL carries its own token; a bearer header is said to 401);
///  * the chunk size (`AttachmentUpload.chunkSize`, ≤ 4 MB, 320 KiB multiple);
///  * small attachments embedded in the create-message POST (see `saveDraft`).
extension GraphMailService {
    static func fileAttachmentJSON(_ a: OutgoingAttachment) -> [String: Any] {
        var o: [String: Any] = ["@odata.type": "#microsoft.graph.fileAttachment", "name": a.name, "contentType": a.contentType,
                                "contentBytes": a.data.base64EncodedString(), "isInline": a.isInline]
        if let cid = a.contentId { o["contentId"] = cid }
        return o
    }

    static func uploadItemJSON(_ a: OutgoingAttachment) -> [String: Any] {
        var item: [String: Any] = ["attachmentType": "file", "name": a.name, "size": a.size, "contentType": a.contentType,
                                   "isInline": a.isInline]
        if let cid = a.contentId { item["contentId"] = cid }
        return ["AttachmentItem": item]
    }

    public func addAttachment(_ a: OutgoingAttachment, toDraft draftId: String, mailbox: String) async throws -> AttachmentInfo {
        if let why = AttachmentUpload.invalidReason(size: a.size, name: a.name) { throw MailServiceError.http(413, why) }
        let base = "\(p(mailbox))/messages/\(draftId)/attachments"
        if AttachmentUpload.isSmall(a) {
            let r: GMAttachment = try await send(url(base), method: "POST", mailbox: mailbox, json: Self.fileAttachmentJSON(a))
            AttachmentProgress.shared.report(a.id, sent: a.size, total: a.size)
            return r.info(fallback: a)
        }
        let s: GMUploadSession = try await send(url("\(base)/createUploadSession"), method: "POST", mailbox: mailbox,
                                                json: Self.uploadItemJSON(a))
        guard let upload = URL(string: s.uploadUrl) else { throw MailServiceError.http(500, "bad uploadUrl") }
        try await putChunks(a, to: upload)
        // The final PUT answers 201 without a usable body for our purposes; report what we sent.
        return AttachmentInfo(id: "", name: a.name, contentType: a.contentType, size: a.size, isInline: a.isInline)
    }

    /// Sequential chunk PUTs. Retries a chunk up to 3 times on 5xx / network loss; a 4xx aborts the upload.
    func putChunks(_ a: OutgoingAttachment, to upload: URL) async throws {
        let total = a.size
        for r in AttachmentUpload.chunks(total: total) {
            var req = URLRequest(url: upload)
            req.httpMethod = "PUT"
            req.httpBody = a.data.subdata(in: r)
            req.setValue(AttachmentUpload.contentRange(r, total: total), forHTTPHeaderField: "Content-Range")
            req.setValue("\(r.count)", forHTTPHeaderField: "Content-Length")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue("niivo-mail/0.1", forHTTPHeaderField: "User-Agent")
            var attempt = 0
            while true {
                try Task.checkCancellation()
                let status: Int
                do {
                    let (_, resp) = try await session.data(for: req)
                    status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
                    if attempt >= 2 { throw MailServiceError.offline }
                    attempt += 1; continue
                }
                if (200..<300).contains(status) { break }
                if status >= 500 && attempt < 2 { attempt += 1; try await Task.sleep(for: .milliseconds(200 << attempt)); continue }
                switch status {
                case 401, 403: throw MailServiceError.forbidden
                case 404: throw MailServiceError.notFound
                default: throw MailServiceError.http(status, "upload chunk \(AttachmentUpload.contentRange(r, total: total))")
                }
            }
            AttachmentProgress.shared.report(a.id, sent: r.upperBound, total: total)
        }
    }
}

struct GMAttachment: Decodable {
    var id: String?; var name: String?; var contentType: String?; var size: Int?; var isInline: Bool?
    func info(fallback a: OutgoingAttachment) -> AttachmentInfo {
        AttachmentInfo(id: id ?? "", name: name ?? a.name, contentType: contentType ?? a.contentType, size: size ?? a.size,
                       isInline: isInline ?? a.isInline)
    }
}

struct GMUploadSession: Decodable { var uploadUrl: String }
