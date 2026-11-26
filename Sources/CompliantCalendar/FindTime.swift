import SwiftUI
import CalendarCore

// Calendar editor "Find a time": Graph findMeetingTimes over the next 5 working days for the draft's attendees and
// duration; on any error / empty answer → local free slots in the organiser's own cached calendar (FreeTime.gaps).
// Free/busy only — nothing about other people's meetings is shown or stored.

@MainActor @Observable final class FindTimeHub {
    static let shared = FindTimeHub()
    @ObservationIgnored var client: FindMeetingTimesClient?
    var result: MeetingTimeResult?
    var loading = false
    var note: String?

    /// Calendar token (Calendars.ReadWrite.Shared ⊇ Calendars.Read.Shared, the documented least privilege).
    func configure(auth: Auth) { client = FindMeetingTimesClient(token: { try await auth.token(for: .calendar) }) }

    func find(_ app: AppModel) {
        let d = app.editorDraft
        let minutes = max(15, Int(d.end.timeIntervalSince(d.start) / 60))
        let from = max(Date(), Calendar.current.startOfDay(for: d.start))
        let to = Calendar.current.date(byAdding: .day, value: 7, to: from) ?? from
        let attendees = d.attendees.map(\.address)
        loading = true; note = nil; result = nil
        Task { @MainActor in
            defer { loading = false }
            if let client, let r = try? await client.suggest(attendees: attendees, from: from, to: to, minutes: minutes), !r.suggestions.isEmpty {
                result = r; return
            }
            let local = FindMeetingTimes.localSlots(events: app.aiOwnBusyEvents(from: from, to: to), from: from, days: 7, minutes: minutes)
            result = MeetingTimeResult(suggestions: local, emptyReason: nil, isLocalFallback: true)
            note = attendees.isEmpty ? "From your calendar." : "Outlook's suggestions weren't available — showing times free in your own calendar only."
        }
    }

    func apply(_ s: MeetingTimeSuggestion, _ app: AppModel) {
        app.editorDraft.start = s.start
        app.editorDraft.end = s.end
        result = nil
    }
}

struct FindTimeSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let hub = FindTimeHub.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Find a Time") { hub.find(app) }.disabled(hub.loading)
                if hub.loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let r = hub.result {
                if r.suggestions.isEmpty { Text("No free time found in the next week.").font(.caption).foregroundStyle(.secondary) }
                ForEach(r.suggestions.prefix(6), id: \.self) { s in
                    Button { hub.apply(s, app) } label: {
                        HStack {
                            Text(s.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                            Text("– " + s.end.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                            Spacer()
                            if !r.isLocalFallback { Text("\(Int(s.confidence))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(s.reason ?? "Use this time")
                }
            }
            if let n = hub.note { Text(n).font(.caption2).foregroundStyle(.tertiary) }
        }
        .onDisappear { hub.result = nil; hub.note = nil }   // never carried into the next editor
    }
}
