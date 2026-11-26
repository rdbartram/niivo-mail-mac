import Foundation
import CalendarCore
import MailCore

/// Find a time: the Graph client's request shape against a stub (never the real tenant).
@MainActor func org2FindClientStub(from: Date, to: Date) async {
    let flags = Flags()
    MailStub.handler = { req, body in
        if req.httpMethod == "POST", req.url?.path == "/v1.0/me/findMeetingTimes" {
            if req.value(forHTTPHeaderField: "Prefer") == "outlook.timezone=\"UTC\"" { flags.hit("prefer") }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer cal" { flags.hit("tok") }
            if (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["meetingDuration"] as? String == "PT30M" { flags.hit("body") }
            return (200, [:], #"{"emptySuggestionsReason":"attendeesUnavailable","meetingTimeSuggestions":[]}"#)
        }
        return (404, [:], "{}")
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MailStub.self]
    let c = FindMeetingTimesClient(token: { "cal" }, session: URLSession(configuration: cfg))
    do {
        let r = try await c.suggest(attendees: ["a@contoso.example"], from: from, to: to, minutes: 30)
        check(flags.count("prefer") == 1 && flags.count("tok") == 1 && flags.count("body") == 1 && r.emptyReason == "attendeesUnavailable",
              "client: POST /me/findMeetingTimes, calendar token, Prefer outlook.timezone=UTC (stub only)")
    } catch { check(false, "findMeetingTimes client threw \(error)") }
    MailStub.handler = nil
}
