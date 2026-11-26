import SwiftUI
import AppKit
import CalendarCore
import MailCore

// SEARCHBOX: state + views for the main mail-list search box (logic in MailCore/MailSearchBox.swift).
// Wired by `// SEARCHBOX-HOOK` lines only: MailModel (search run), MailShell (field, keys, dropdown), MailViews
// (results header sort toggle, row highlight, classic `.searchable` suggestions). No @State: all state lives here.

@MainActor @Observable
final class SearchBoxState {
    static let shared = SearchBoxState()

    /// The current box result (both orders); nil while no box search is shown (empty box, AI results).
    var result: MailBoxResult?
    var sort: MailSearchSort = .bestMatch { didSet { if oldValue != sort { mail?.applySearchOrder() } } }
    private(set) var suggestions: [SearchSuggestion] = []
    /// Highlighted suggestion (↓ / ↑); nil = the field itself.
    var highlighted: Int?
    var dropdownOpen = false
    /// Folded words to mark in the list (free words, phrase words, `subject:` words).
    private(set) var terms: [String] = []
    @ObservationIgnored weak var mail: MailModel?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var accepting = false

    /// Called on every change of the box text (MailModel.scheduleSearch).
    func textChanged(_ text: String, mail: MailModel) {
        self.mail = mail
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { sort = .bestMatch }
        else if lastText.trimmingCharacters(in: .whitespaces).isEmpty { sort = .bestMatch }   // a new query starts on Best match
        lastText = text
        terms = trimmed.isEmpty ? [] : SearchHighlight.terms(text)
        refreshSuggestions(text, mail: mail)
        if accepting { accepting = false; dropdownOpen = false }
    }

    func refreshSuggestions(_ text: String, mail: MailModel) {
        let ui = MailListUI.shared
        ui.ensureMemory(mail)
        let people = mail.search.people.prefix(200).map { (name: $0.displayName, address: $0.address) }
        suggestions = SearchSuggest.items(for: text, recent: ui.memory.recent, people: Array(people))
        highlighted = nil
        dropdownOpen = !suggestions.isEmpty && !text.isEmpty
    }

    /// Lock / sign-out / wipe: drop every decrypted result, suggestion and term.
    func reset() {
        result = nil; suggestions = []; terms = []; highlighted = nil; dropdownOpen = false; lastText = ""; accepting = false
        KnowledgeHub.shared.reset()   // PEOPLE-HOOK: no decrypted answer card kept
        LoopsModel.shared.reset(); SignalModel.shared.reset()   // LOOPS-HOOK: no loop titles / proposals kept
        WorkModel.shared.reset()   // WHEN-HOOK / DEEP-HOOK: no work titles, pending block or timer kept
    }

    /// Focus without text: offer recent searches.
    func focused(_ mail: MailModel) {
        self.mail = mail
        if mail.searchText.isEmpty { refreshSuggestions("", mail: mail); dropdownOpen = !suggestions.isEmpty }
    }

    func move(_ d: Int) -> Bool {
        guard dropdownOpen, !suggestions.isEmpty else { return false }
        highlighted = SearchSuggest.move(highlighted, by: d, count: suggestions.count)
        return true
    }

    /// ↩ with a highlighted suggestion: put its completion in the box. Returns false when nothing was highlighted.
    func acceptHighlighted() -> Bool {
        guard dropdownOpen, let i = highlighted, suggestions.indices.contains(i) else { return false }
        accept(suggestions[i])
        return true
    }

    func accept(_ s: SearchSuggestion) {
        guard let mail else { return }
        if mail.searchText != s.completion { accepting = true; mail.searchText = s.completion }
        dropdownOpen = false
        if s.kind == .recent { mail.submitSearch() }
    }

    /// esc: close the dropdown first; returns false when it was already closed.
    func dismiss() -> Bool {
        guard dropdownOpen else { return false }
        dropdownOpen = false; highlighted = nil
        return true
    }

    /// Subject / snippet with the query's words marked (only while a box search is shown).
    func marked(_ text: String, skin: Skin) -> AttributedString {
        var a = AttributedString(text)
        guard result != nil, !terms.isEmpty else { return a }
        for r in SearchHighlight.ranges(in: text, terms: terms) {
            guard let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = skin.brand ? skin.accentSoft : Color.yellow.opacity(0.35)
            a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }
}

// MARK: - Dropdown

/// Suggestions under the niivo search field: recent searches, people, operators. Click or ↓ / ↑ + ↩.
struct SearchSuggestionsDropdown: View {
    @Environment(\.skin) private var skin
    var box = SearchBoxState.shared
    var body: some View {
        if box.dropdownOpen, !box.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(box.suggestions.enumerated()), id: \.element.id) { i, s in
                    Button { box.accept(s) } label: {
                        HStack(spacing: 8) {
                            NSymbol(Self.symbol(s.kind), size: 11).foregroundStyle(skin.muted).frame(width: 14)
                            Text(s.title).font(s.kind == .operator ? skin.mono(NV.Size.bodySm) : skin.sans(NV.Size.bodySm))
                                .foregroundStyle(skin.ink).lineLimit(1)
                            Text(s.detail).font(skin.sans(11)).foregroundStyle(skin.muted).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(box.highlighted == i ? skin.accentSoft : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.kindLabel(s.kind)): \(s.title)")
                    .accessibilityAddTraits(box.highlighted == i ? .isSelected : [])
                }
            }
            .frame(width: 320, alignment: .leading)
            .background(skin.card)
            .overlay { Rectangle().strokeBorder(skin.hair2, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search suggestions")
        }
    }
    static func symbol(_ k: SearchSuggestion.Kind) -> String {
        switch k { case .recent: "clock.arrow.circlepath"; case .person: "person"; case .operator: "line.3.horizontal.decrease" }
    }
    static func kindLabel(_ k: SearchSuggestion.Kind) -> String {
        switch k { case .recent: "Recent search"; case .person: "Person"; case .operator: "Search operator" }
    }
}

// MARK: - Sort toggle

/// Best match / Newest in the results header (only for a box search: AI results keep their own order).
struct SearchSortToggle: View {
    @Environment(\.skin) private var skin
    var box = SearchBoxState.shared
    var body: some View {
        if box.result != nil {
            HStack(spacing: 6) {
                ForEach(MailSearchSort.allCases) { s in
                    Button(s.title) { box.sort = s }
                        .buttonStyle(.borderless)
                        .fontWeight(box.sort == s ? .semibold : .regular)
                        .foregroundStyle(box.sort == s ? (skin.brand ? skin.ink : Color.primary) : Color.secondary)
                        .accessibilityAddTraits(box.sort == s ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sort results")
        }
    }
}
