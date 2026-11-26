import SwiftUI
import AppKit
import MailCore

// Message-list avatars + the contact hover card.
// Photos: memory only (never disk). Directory lookups only for internal addresses and only through PeopleHub's
// service on its silent token (passive UI never prompts); bytes come from PeopleHub's own memory cache. Callers
// pass nil for redacted rows, so a private / labelled-redacted row never gets initials, a photo or a card.

@MainActor @Observable final class AvatarCache {
    static let shared = AvatarCache()
    /// address → photo bytes (observed: a row re-renders when its photo arrives).
    private(set) var photos: [String: Data] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var none: Set<String> = []
    @ObservationIgnored private var directory: [String: DirectoryPerson] = [:]
    private let cap = 200

    func request(_ address: String) {
        let a = address.lowercased()
        guard photos[a] == nil, !none.contains(a), !inFlight.contains(a),
              PresenceHub.shared.isInternal(a), let svc = PeopleHub.shared.service else { return }
        inFlight.insert(a)
        Task { @MainActor [weak self] in
            defer { self?.inFlight.remove(a) }
            guard let d = try? await svc.directoryUser(address: a) else { self?.none.insert(a); return }
            self?.directory[a] = d
            guard let data = await PeopleHub.shared.photo(userId: d.id) else { self?.none.insert(a); return }
            guard let self else { return }
            if self.photos.count >= self.cap { self.photos.removeAll() }
            self.photos[a] = data
        }
    }

    /// Directory profile for the hover card (lookup on demand, internal only).
    func person(_ address: String) async -> DirectoryPerson? {
        let a = address.lowercased()
        if let d = directory[a] { return d }
        guard PresenceHub.shared.isInternal(a), let svc = PeopleHub.shared.service, let d = try? await svc.directoryUser(address: a) else { return nil }
        if directory.count >= cap { directory.removeAll() }
        directory[a] = d
        return d
    }

    func reset() { photos = [:]; inFlight = []; none = []; directory = [:] }

    static func initials(_ name: String, address: String) -> String {
        let words = name.split { $0 == " " || $0 == "," || $0 == "." }.filter { $0.first?.isLetter == true }
        if words.count >= 2 { return String(words[0].prefix(1) + words[words.count - 1].prefix(1)).uppercased() }
        if let w = words.first { return String(w.prefix(2)).uppercased() }
        return String(address.prefix(1)).uppercased()
    }

    /// Stable hue per address (no data leaves the Mac).
    static func hue(_ address: String) -> Double {
        Double(address.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
    }
}

struct SenderAvatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.skin) private var skin
    /// nil = redacted / no sender → a neutral blank disc.
    var who: EmailAddress?
    var size: CGFloat = 30
    var body: some View {
        let cache = AvatarCache.shared
        ZStack(alignment: .bottomTrailing) {
            if let who, !who.address.isEmpty {
                let a = who.address.lowercased()
                Group {
                    if let d = cache.photos[a], let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Text(AvatarCache.initials(who.name, address: who.address))
                            .font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(hue: AvatarCache.hue(a), saturation: 0.35, brightness: 0.62))
                    }
                }
                .frame(width: size, height: size)
                .clipShape(skin.brand ? AnyShape(Rectangle()) : AnyShape(Circle()))
                .onAppear { model.ensurePeopleHubs(); cache.request(a) }
                PresenceDot(address: a, size: max(7, size * 0.28)).offset(x: 2, y: 2)
            } else {
                (skin.brand ? AnyShape(Rectangle()) : AnyShape(Circle())).fill(Color.secondary.opacity(0.18)).frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hover card

@MainActor @Observable final class HoverCardModel {
    static let shared = HoverCardModel()
    /// Address whose card is showing (one at a time).
    var shown: String?
    var person: DirectoryPerson?
    @ObservationIgnored private var pending: Task<Void, Never>?

    func hover(_ address: String, _ inside: Bool) {
        let a = address.lowercased()
        pending?.cancel()
        if inside {
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.person = nil
                self.shown = a
                let p = await AvatarCache.shared.person(a)
                guard !Task.isCancelled, self.shown == a else { return }   // another card may be showing by now
                self.person = p
            }
        } else if shown == a {
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))   // let the pointer reach the card
                guard !Task.isCancelled else { return }
                self?.shown = nil
            }
        }
    }
    func keep() { pending?.cancel() }
}

extension View {
    /// Hover ~600 ms → compact contact card. nil (redacted / no sender) = nothing.
    func senderHoverCard(_ who: EmailAddress?) -> some View { modifier(SenderHoverCard(who: who)) }
}

private struct SenderHoverCard: ViewModifier {
    var who: EmailAddress?
    func body(content: Content) -> some View {
        if let who, !who.address.isEmpty {
            let m = HoverCardModel.shared
            let a = who.address.lowercased()
            content
                .onHover { m.hover(a, $0) }
                .popover(isPresented: Binding(get: { m.shown == a }, set: { if !$0, m.shown == a { m.shown = nil } }), arrowEdge: .bottom) {
                    HoverCardView(who: who).onHover { if $0 { m.keep() } else { m.hover(a, false) } }
                }
        } else { content }
    }
}

private struct HoverCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var who: EmailAddress
    var body: some View {
        let m = HoverCardModel.shared, a = who.address.lowercased()
        let d = m.person
        let org = MailOrg2.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SenderAvatar(who: who, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d?.displayName ?? (who.name.isEmpty ? who.address : who.name)).font(.headline).lineLimit(1)
                    if let t = d?.jobTitle, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if let p = PresenceHub.shared.values[a]?.label { Text(p).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(who.address).font(.caption).textSelection(.enabled)
            if let ph = d?.businessPhones.first ?? d?.mobilePhone { Text(ph).font(.caption).textSelection(.enabled) }
            HStack {
                Button(L("Open person")) {   // PEOPLE-HOOK: person page (KnowledgeViews.swift)
                    m.shown = nil
                    KnowledgeHub.shared.open(person: who.address, mail: model.mail, openWindow: openWindow)
                }
                Button("Open card") {
                    m.shown = nil
                    let hub = PeopleHub.shared
                    hub.app = model
                    hub.show(address: who.address, name: who.name)
                    openWindow(id: "people")
                }
                let vip = org.isVIP(a)
                Button(vip ? "Remove VIP" : "Add VIP") { org.setVIP(a, !vip) }
                FavouriteMenuButton(item: .person(address: a, name: who.name))
            }
            .controlSize(.small)
        }
        .padding(12).frame(width: 280, alignment: .leading)
    }
}

private struct FavouriteMenuButton: View {
    var item: FavouriteItem
    var body: some View {
        let on = MailOrg2.shared.favourites.contains(item)
        Button(on ? "Unpin" : "Pin to Favourites") { MailOrg2.shared.toggle(item) }
    }
}
