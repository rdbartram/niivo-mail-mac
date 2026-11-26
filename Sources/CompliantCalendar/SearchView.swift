import SwiftUI
import CalendarCore

/// ⌘F results. Matching happens in memory over decrypted payloads loaded for the sync window — there is no
/// search index on disk (it would be a plaintext copy of subjects). Items the policy redacts are not findable.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.searchResults) { Calendar.current.startOfDay(for: $0.start) }
        // Upcoming first (soonest at top), then past (most recent first) — what people search for is usually next.
        let today = Calendar.current.startOfDay(for: .now)
        let days = groups.keys.filter { $0 >= today }.sorted() + groups.keys.filter { $0 < today }.sorted(by: >)
        Group {
            if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                List {
                    ForEach(days, id: \.self) { d in
                        Section {
                            ForEach(groups[d]!.sorted { $0.start < $1.start }) { e in
                                SearchRow(event: e)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.reveal(e) }
                            }
                        } header: {
                            Text(d, format: .dateTime.weekday(.wide).day().month(.wide).year())
                                .font(.headline)
                                .foregroundStyle(Calendar.current.isDateInToday(d) ? model.theme.accent : .primary)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(model.theme.gridBackground)
        .safeAreaInset(edge: .top) {
            HStack {
                Text("\(model.searchResults.count) results across \(model.visibleCalendars.count) calendars")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Searched in memory · nothing indexed on disk").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }
}

struct SearchRow: View {
    @Environment(AppModel.self) private var model
    var event: CalendarEvent
    var body: some View {
        let cal = model.calendar(for: event)
        let p = model.policy(for: event)
        HStack(spacing: 12) {
            if let cal { OwnerBadge(calendar: cal, tint: model.tint(cal), size: 26) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let l = p.label { LabelGlyph(label: l) }
                    Text(event.subject).font(.body.weight(.semibold)).lineLimit(1)
                }
                Text([event.isAllDay ? "All day" : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))",
                      event.location, cal.map { "\($0.ownerDisplay) · \($0.name)" }].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let url = event.onlineMeetingURL {
                Button { MeetingLauncher.join(url) } label: {
                    NLabel(MeetingProvider(url: url).displayName, systemImage: "video.fill", size: 11)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}
