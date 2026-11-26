import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MailCore

// COMPOSE-HOOK: recipient autocomplete (CommGraph + /me/people + /users + groups), MailTips banners. The rest
// (reply with attachments, reopened-draft chips, templates, spelling, table / rule) is in ComposerAssistModel.swift.
// Graph calls: MailCore/GraphMailService+Compose.swift. Pure logic: MailCore/ComposeAssist.swift.

/// Composer services and per-composer state that doesn't belong on `ComposerState` (kept out of MailModel.swift).
@MainActor @Observable
final class ComposeHub {
    static let shared = ComposeHub()
    @ObservationIgnored private(set) var service: ComposeService?
    /// MailTips per composer.
    var tips: [UUID: [MailTip]] = [:]
    /// Addresses known to be groups / distribution lists (from suggestions), for the token icon.
    var groupAddresses = Set<String>()
    /// Token being dragged between To / Cc / Bcc.
    @ObservationIgnored var dragging: (composer: UUID, address: EmailAddress)?
    @ObservationIgnored private var fields: [String: RecipientAutocomplete] = [:]

    func configure(service: ComposeService) { self.service = service }

    func autocomplete(_ c: ComposerState, _ f: RecipientFieldKind) -> RecipientAutocomplete {
        let k = "\(c.id)-\(f.rawValue)"
        if let a = fields[k] { return a }
        let a = RecipientAutocomplete()
        fields[k] = a
        return a
    }

    /// Local candidates: CommGraph people (decayed proximity) + addresses seen in synced mail.
    func localCandidates(_ q: String, mail: MailModel) -> [RecipientSuggestion] {
        let graph = RecipientRanker.recent(from: mail.store?.graph?.people() ?? [], query: q)
        let seen = mail.recentAddresses.values.lazy
            .filter { RecipientRanker.match(q, name: $0.name, address: $0.address) > 0 }
            .prefix(40).map { RecipientSuggestion(address: $0.address, name: $0.name, source: .recent, relevance: 0.1) }
        return graph + Array(seen)
    }
}

@MainActor
enum RecipientFieldKind: String, CaseIterable {
    case to, cc, bcc
    var title: String { switch self { case .to: "To"; case .cc: "Cc"; case .bcc: "Bcc" } }
    var tokens: ReferenceWritableKeyPath<ComposerState, [EmailAddress]> { switch self { case .to: \.to; case .cc: \.cc; case .bcc: \.bcc } }
    var text: ReferenceWritableKeyPath<ComposerState, String> { switch self { case .to: \.toText; case .cc: \.ccText; case .bcc: \.bccText } }
}

/// Suggestions for one recipient field: local first (instant), then Graph (debounced), merged and ranked.
@MainActor @Observable
final class RecipientAutocomplete {
    var items: [RecipientSuggestion] = []
    var highlighted = 0
    var dropTargeted = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastQuery = ""

    func update(_ text: String, excluding: [EmailAddress], mail: MailModel) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q != lastQuery else { return }
        lastQuery = q
        task?.cancel()
        guard !q.isEmpty else { items = []; return }
        let hub = ComposeHub.shared
        let local = hub.localCandidates(q, mail: mail)
        items = RecipientRanker.rank(q, candidates: local, excluding: excluding)
        highlighted = 0
        guard q.count >= 2, let svc = hub.service else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let remote = await svc.recipients(q)
            guard !Task.isCancelled, let self else { return }
            for r in remote where r.isGroup { hub.groupAddresses.insert(r.id) }
            let prev = self.items.indices.contains(self.highlighted) ? self.items[self.highlighted].id : nil
            self.items = RecipientRanker.rank(q, candidates: local + remote, excluding: excluding)
            self.highlighted = prev.flatMap { p in self.items.firstIndex { $0.id == p } } ?? 0
        }
    }

    func clear() { task?.cancel(); items = []; highlighted = 0; lastQuery = "" }
    func move(_ d: Int) { guard !items.isEmpty else { return }; highlighted = (highlighted + d + items.count) % items.count }
}

// MARK: - Recipient field (tokens, keyboard, paste, drag)

struct RecipientField: View {
    @Environment(AppModel.self) private var app
    var field: RecipientFieldKind
    var composer: ComposerState

    var body: some View {
        let hub = ComposeHub.shared
        @Bindable var auto = hub.autocomplete(composer, field)
        let domains = app.mail.settings.internalDomains
        let tokens = composer[keyPath: field.tokens]
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.skin.caps(field.title)).font(app.theme.brand ? app.skin.mono(NV.Size.labelSm) : .body).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tokens, id: \.address) { a in
                            token(a, external: !RecipientCheck.external([a], internalDomains: domains).isEmpty,
                                  group: hub.groupAddresses.contains(a.address.lowercased()))
                        }
                        input(auto)
                    }
                }
            }
            .padding(.vertical, 1)
            .background { if auto.dropTargeted { Rectangle().fill(Color.accentColor.opacity(0.10)) } }
            .onDrop(of: [.plainText], isTargeted: $auto.dropTargeted) { providers in drop(providers) }
            if !auto.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(auto.items.enumerated()), id: \.element.id) { i, s in
                        Button { add(s.emailAddress); auto.clear() } label: { row(s, highlighted: i == auto.highlighted, domains: domains) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.callout)
                .background(app.theme.brand ? AnyShapeStyle(app.skin.card) : AnyShapeStyle(.quaternary.opacity(0.4)), in: app.skin.rounded)
                .padding(.leading, 50)
                .help("↑ ↓ to choose, ↩ or Tab to add, Esc to close")
            }
        }
    }

    private func input(_ auto: RecipientAutocomplete) -> some View {
        TextField(composer[keyPath: field.tokens].isEmpty ? "Name or address" : "", text: Binding(
            get: { composer[keyPath: field.text] }, set: { composer[keyPath: field.text] = $0 }))
            .textFieldStyle(.plain).frame(minWidth: 180)
            .onSubmit { commit() }
            .onChange(of: composer[keyPath: field.text]) { _, t in
                // Typed separators or a pasted list ("a@x.ch; b@y.ch", one per line, space-separated) become tokens.
                if t.contains(where: { ",;\n\t".contains($0) }) || RecipientRanker.splitPasted(t).count > 1 { commit(); auto.clear() }
                else { auto.update(t, excluding: composer.allRecipients, mail: app.mail) }
            }
            .onKeyPress(.downArrow) { guard !auto.items.isEmpty else { return .ignored }; auto.move(1); return .handled }
            .onKeyPress(.upArrow) { guard !auto.items.isEmpty else { return .ignored }; auto.move(-1); return .handled }
            .onKeyPress(.return) { pickHighlighted(auto) ? .handled : .ignored }
            .onKeyPress(.tab) { pickHighlighted(auto) ? .handled : .ignored }
            .onKeyPress(.escape) { guard !auto.items.isEmpty else { return .ignored }; auto.clear(); return .handled }
            .onKeyPress(.delete) {   // ⌫ in an empty field removes the last token
                guard composer[keyPath: field.text].isEmpty, !composer[keyPath: field.tokens].isEmpty else { return .ignored }
                composer[keyPath: field.tokens].removeLast(); return .handled
            }
    }

    private func row(_ s: RecipientSuggestion, highlighted: Bool, domains: Set<String>) -> some View {
        let external = !RecipientCheck.external([s.emailAddress], internalDomains: domains).isEmpty
        return HStack(spacing: 6) {
            NSymbol(s.isGroup ? "person.3" : s.source == .recent ? "clock" : "person").font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(s.name.isEmpty ? s.address : s.name).lineLimit(1)
            if !s.name.isEmpty { Text(s.address).foregroundStyle(.secondary).lineLimit(1) }
            if external { NSymbol("globe").font(.caption2).foregroundStyle(.orange).help("Outside your organisation") }
            Spacer()
            Text(sourceTitle(s)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private func sourceTitle(_ s: RecipientSuggestion) -> String {
        if s.isGroup { return "Group" }
        switch s.source { case .recent: return "Recent"; case .people: return "People"; case .directory: return "Directory"; case .group: return "Group" }
    }

    private func token(_ a: EmailAddress, external: Bool, group: Bool) -> some View {
        HStack(spacing: 3) {
            if group { NSymbol("person.3").font(.caption2).foregroundStyle(.secondary) }
            if external { NSymbol("globe").font(.caption2).foregroundStyle(.orange) }
            Text(a.name.isEmpty ? a.address : a.name).lineLimit(1)
            Button { composer[keyPath: field.tokens].removeAll { $0.address == a.address } } label: { NSymbol("xmark").font(.caption2) }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background {
            if app.theme.brand {
                Rectangle().fill(external ? Color.orange.opacity(0.14) : app.skin.soft)
                    .overlay(Rectangle().strokeBorder(external ? Color.orange : app.skin.hair2, lineWidth: 1))
            } else {
                Capsule().fill((external ? Color.orange : Color.accentColor).opacity(0.14))
            }
        }
        .help((external ? "\(a.address) — outside your organisation" : a.address) + (group ? " (group)" : "") + " · drag to another field")
        .onDrag {
            ComposeHub.shared.dragging = (composer.id, a)
            return NSItemProvider(object: (a.name.isEmpty ? a.address : "\"\(a.name)\" <\(a.address)>") as NSString)
        }
    }

    private func pickHighlighted(_ auto: RecipientAutocomplete) -> Bool {
        guard auto.items.indices.contains(auto.highlighted) else { return false }
        add(auto.items[auto.highlighted].emailAddress)
        auto.clear()
        return true
    }

    private func add(_ a: EmailAddress) {
        if !composer[keyPath: field.tokens].contains(where: { $0.address.lowercased() == a.address.lowercased() }) {
            composer[keyPath: field.tokens].append(a)
        }
        composer[keyPath: field.text] = ""
    }

    private func commit() {
        let (valid, invalid) = RecipientRanker.parse(composer[keyPath: field.text])
        for a in valid { add(a) }
        composer[keyPath: field.text] = invalid.joined(separator: ", ")
    }

    /// A token from another field moves here; text dropped from elsewhere is parsed as addresses.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let hub = ComposeHub.shared
        if let d = hub.dragging, d.composer == composer.id {
            hub.dragging = nil
            for f in RecipientFieldKind.allCases where f != field {
                composer[keyPath: f.tokens].removeAll { $0.address.lowercased() == d.address.address.lowercased() }
            }
            add(d.address)
            return true
        }
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let target = field, c = composer
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            Task { @MainActor in
                for a in RecipientRanker.parse(s).valid where !c[keyPath: target.tokens].contains(where: { $0.address.lowercased() == a.address.lowercased() }) {
                    c[keyPath: target.tokens].append(a)
                }
            }
        }
        return true
    }
}

// MARK: - MailTips

struct MailTipsBanners: View {
    @Environment(AppModel.self) private var app
    var composer: ComposerState
    var body: some View {
        let hub = ComposeHub.shared
        let current = Set(composer.allRecipients.map { $0.address.lowercased() })
        let tips = (hub.tips[composer.id] ?? []).filter { current.contains($0.address.lowercased()) }
        let names = Dictionary(composer.allRecipients.map { ($0.address.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        // ComposerWarnings already flags external single recipients by domain; MailTips' external banner is kept
        // when no internal domains are configured, or for groups with external members (only Exchange knows those).
        let banners = MailTipAdvisor.banners(tips, names: names).filter {
            $0.kind != .external || app.mail.settings.internalDomains.isEmpty || tips.contains { ($0.externalMemberCount ?? 0) > 0 }
        }
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 0)   // keeps the view (and its .task) alive when there is nothing to show
            ForEach(banners) { b in
                HStack(alignment: .top, spacing: 8) {
                    NSymbol(symbol(b.kind)).foregroundStyle(colour(b.kind))
                    Text(b.text).font(.callout)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(colour(b.kind).opacity(0.10), in: app.skin.rounded)
                .overlay(alignment: .leading) { if app.theme.brand { Rectangle().fill(colour(b.kind)).frame(width: 3) } }
            }
        }
        // Debounced: restarts on every recipient change and asks Exchange 0.7 s after the last one.
        .task(id: MailTipsRequest.addresses(composer.allRecipients)) {
            let addrs = MailTipsRequest.addresses(composer.allRecipients)
            guard !addrs.isEmpty, let svc = hub.service else { hub.tips[composer.id] = []; return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if let t = try? await svc.mailTips(addrs, mailbox: "me"), !Task.isCancelled { hub.tips[composer.id] = t }
        }
    }

    private func symbol(_ k: MailTipBanner.Kind) -> String {
        switch k {
        case .invalid: "exclamationmark.octagon.fill"; case .mailboxFull: "tray.full"; case .restricted: "hand.raised"
        case .outOfOffice: "airplane"; case .external: "globe"; case .largeAudience: "person.3.sequence"
        }
    }
    private func colour(_ k: MailTipBanner.Kind) -> Color {
        switch k { case .invalid, .mailboxFull, .restricted: .red; case .outOfOffice: .blue; case .external, .largeAudience: .orange }
    }
}
