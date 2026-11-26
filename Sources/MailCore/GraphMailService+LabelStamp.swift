import Foundation
import CalendarCore

// PURVIEW-HOOK: draft writes that may carry the msip_labels stamp. A Graph rejection of the property never breaks
// saving / sending: one retry without it, remembered for the session (`LabelStampGuard`).
extension GraphMailService {
    func sendStamped<T: Decodable>(_ u: URL, method: String, mailbox: String, fields: [String: Any],
                                   prefer: [String] = []) async throws -> T {
        var f = fields
        if f["singleValueExtendedProperties"] != nil, LabelStampGuard.isRejected { f["singleValueExtendedProperties"] = nil }
        do {
            return try await send(u, method: method, mailbox: mailbox, json: f, prefer: prefer)
        } catch MailServiceError.http(let s, let m) where f["singleValueExtendedProperties"] != nil
                    && LabelStampGuard.isRejection(status: s, message: m) {
            LabelStampGuard.noteRejected(status: s)
            f["singleValueExtendedProperties"] = nil
            return try await send(u, method: method, mailbox: mailbox, json: f, prefer: prefer)
        }
    }
}
