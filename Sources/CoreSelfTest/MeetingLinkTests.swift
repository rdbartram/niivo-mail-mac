import Foundation
import CalendarCore

@MainActor
func runMeetingLinkTests() {
    section("Meeting links (Teams, Zoom, Meet, Webex, GoTo)")
    let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d"
    check(MeetingLink.extract(joinUrl: teams, location: "https://zoom.us/j/1", body: nil)?.absoluteString == teams,
          "Graph joinUrl wins over anything in location")
    let z = MeetingLink.extract(joinUrl: nil, location: "https://contoso.zoom.us/j/81234567890?pwd=abc", body: nil)
    check(z.map(MeetingProvider.init(url:)) == .zoom, "Zoom link found in location")
    check(z.flatMap(MeetingLink.nativeURL(for:))?.absoluteString == "zoommtg://contoso.zoom.us/join?action=join&confno=81234567890&pwd=abc",
          "Zoom → zoommtg: with confno + pwd")
    let w = MeetingLink.extract(joinUrl: nil, location: nil,
        body: #"<p>Download Webex: <a href="https://www.webex.com/downloads.html">app</a>. Join <a href="https://contoso.webex.com/meet/jordan.lee">here</a>.</p>"#)
    check(w?.absoluteString == "https://contoso.webex.com/meet/jordan.lee", "Webex join link from HTML body; download link skipped")
    let m = MeetingLink.extract(joinUrl: nil, location: "Google Meet", body: "Join: https://meet.google.com/abc-defg-hij.\nDial in…")
    check(m?.absoluteString == "https://meet.google.com/abc-defg-hij", "Meet link, trailing punctuation trimmed")
    check(MeetingLink.extract(joinUrl: nil, location: nil, body: "Agenda https://contoso.sharepoint.com/doc and https://example.com")
          == nil, "non-meeting links ignored")
    let amp = MeetingLink.extract(joinUrl: nil, location: nil, body: "https://zoom.us/j/99?pwd=a&amp;uname=b")
    check(amp?.absoluteString == "https://zoom.us/j/99?pwd=a&uname=b", "HTML &amp; decoded in extracted links")
    let g = MeetingLink.extract(joinUrl: nil, location: nil, body: "From your computer: https://meet.goto.com/123456789")
    check(g.map(MeetingProvider.init(url:)) == .goTo && g.flatMap(MeetingLink.nativeURL(for:)) == nil, "GoTo found; opens via https")
    check(MeetingLink.nativeURL(for: URL(string: teams)!)?.scheme == "msteams", "Teams → msteams:")
}
