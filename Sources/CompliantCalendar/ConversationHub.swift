import SwiftUI
import AppKit
import CalendarCore
import MailCore

// THREAD-HOOK: conversation view state — expanded cards, focus (n / p), per-message reader states, Gmail keys.
// Every member renders through its own per-message ReaderState from the existing fail-closed loaders
// (MailModel.loadReader / standaloneReader): private, protected / rpmsg, unknown label, capture and copy rights are
// decided per message, never merged across bodies. Only the pane-wide capture shield and screen policy use the
// strictest member (MailThreads.strictest).

@MainActor @Observable final class ConversationHub {
    static let shared = ConversationHub()

    private(set) var conversationId: String?
    /// Display order of the open conversation.
    private(set) var memberIds: [String] = []
    var expanded: Set<String> = []
    /// Card that n / p, clicks and reply keys act on (nil = the latest message).
    var focusedId: String?
    var showQuoted: Set<String> = []
    var heights: [String: CGFloat] = [:]
    /// Per-message reader states for expanded members other than the pane's own `mail.reader`.
    private(set) var readers: [String: ReaderState] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// The conversation reader is on screen.
    var active = false
    var newestOnTop: Bool = MailThreadPreferences.load().newestOnTop {
        didSet { UserDefaults.standard.set(newestOnTop, forKey: MailThreadPreferences.Key.newestOnTop) }
    }

    func attach(_ r: ReaderState, mail: MailModel) {
        let members = ordered(r.thread)
        if conversationId != r.header.conversationId {
            conversationId = r.header.conversationId
            readers = [:]; loading = []; heights = [:]; showQuoted = []; focusedId = nil
            expanded = MailThreads.initiallyExpanded(r.thread).union([r.header.id])
        } else {
            // New arrivals in the open thread open up (unread or newest); what the user collapsed stays collapsed.
            let fresh = r.thread.filter { !memberIds.contains($0.id) }
            expanded.formUnion(MailThreads.initiallyExpanded(fresh))
            if !fresh.isEmpty { expanded.insert(r.header.id) }
        }
        memberIds = members.map(\.id)
        for id in expanded { load(id, mail: mail) }
    }

    func ordered(_ thread: [MailMessage]) -> [MailMessage] {
        let asc = thread.sorted { ($0.received, $0.id) < ($1.received, $1.id) }
        return newestOnTop ? asc.reversed() : asc
    }

    func state(for id: String, mail: MailModel) -> ReaderState? {
        if let r = mail.reader, r.header.id == id { return r }
        return readers[id]
    }

    func load(_ id: String, mail: MailModel) {
        guard mail.reader?.header.id != id, readers[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        let conv = conversationId
        Task { @MainActor [weak mail] in
            guard let mail else { return }
            let r = await mail.standaloneReader(id: id)   // same fail-closed rules as the pane's reader
            loading.remove(id)
            guard conversationId == conv, let r else { return }
            readers[id] = r
        }
    }

    func toggle(_ id: String, mail: MailModel) {
        focusedId = id
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id); load(id, mail: mail) }
    }

    func expandAll(mail: MailModel) { expanded = Set(memberIds); for id in memberIds { load(id, mail: mail) } }
    func collapseAll(mail: MailModel) { expanded = latestId(mail: mail).map { [$0] } ?? [] }

    func latestId(mail: MailModel) -> String? {
        guard let r = mail.reader else { return nil }
        return MailThreads.replyTarget(r.thread, me: mail.meAddresses)?.id ?? r.header.id
    }

    /// n / p: move the focus card, expanding it.
    func move(_ delta: Int, mail: MailModel) {
        guard !memberIds.isEmpty else { return }
        let cur = focusedId ?? latestId(mail: mail)
        let i = cur.flatMap { memberIds.firstIndex(of: $0) } ?? (delta > 0 ? -1 : memberIds.count)
        let j = min(max(i + delta, 0), memberIds.count - 1)
        focusedId = memberIds[j]
        expanded.insert(memberIds[j]); load(memberIds[j], mail: mail)
    }

    /// Reply / Reply all / Forward target: the focused card, else the latest message. nil outside a conversation.
    func replyTarget(mail: MailModel) -> String? {
        guard active, let r = mail.reader, r.header.conversationId == conversationId, r.thread.count > 1 else { return nil }
        if let f = focusedId, memberIds.contains(f) { return f }
        return MailThreads.replyTarget(r.thread, me: mail.meAddresses)?.id
    }

    /// Strictest live policy over the open conversation: header policies of every member (each in its own mailbox)
    /// plus the post-fetch policies of loaded members (rpmsg detection, licence rights).
    func livePolicy(mail: MailModel) -> ContentPolicy {
        guard active, let r = mail.reader, r.header.conversationId == conversationId else { return .open }
        return policy(over: r, mail: mail)
    }

    /// Same, without the on-screen check (the view computes its shield before `active` flips).
    func policy(over r: ReaderState, mail: MailModel) -> ContentPolicy {
        var ps = r.thread.map { mail.policy(for: $0, mailbox: mail.store?.mailbox(forFolder: $0.folderId) ?? r.mailbox) }
        ps.append(r.policy)
        if r.header.conversationId == conversationId { ps += readers.values.map(\.policy) }
        return MailThreads.strictest(ps)
    }

    /// MIP-HOOK pass-through: licence rights for one member changed.
    func refreshPolicy(itemId: String, mail: MailModel) {
        guard let r = readers[itemId] else { return }
        readers[itemId]?.policy = mail.reprotected(r)
    }

    func refreshProtectedPolicies(mail: MailModel) {
        for (id, r) in readers where r.policy.bodyIsProtected { readers[id]?.policy = mail.reprotected(r) }
    }

    /// Gmail-only keys (Settings → Keyboard shortcuts → Gmail). Returns true when handled.
    func gmailKey(_ key: MailKeymap.Key, mail: MailModel) -> Bool {
        guard MailListUI.shared.keymap == .gmail else { return false }
        let inThread = active && mail.reader.map { $0.thread.count > 1 && $0.header.conversationId == conversationId } == true
        switch key {
        case .returnKey:
            guard inThread, let id = focusedId ?? latestId(mail: mail) else { return false }
            toggle(id, mail: mail); return true
        case .character(let c):
            guard let a = GmailThreadKey.action(for: c) else { return false }
            switch a {
            case .nextMessage: guard inThread else { return false }; move(1, mail: mail)
            case .previousMessage: guard inThread else { return false }; move(-1, mail: mail)
            case .expand:
                guard inThread, let id = focusedId ?? latestId(mail: mail) else { return false }
                toggle(id, mail: mail)
            case .toggleSelect:
                guard let id = mail.selectedMessageId else { return false }
                let chrome = MailChrome.shared
                if chrome.marked.contains(id) { chrome.marked.remove(id) } else { chrome.marked.insert(id) }
                chrome.anchor = id
            case .backToList:
                mail.selectedMessageId = nil
                mail.focusListToken += 1
            }
            return true
        default: return false
        }
    }
}

/// THREAD-HOOK: View menu — Group by Conversation (persisted, default on) and the reader order.
struct ConversationViewCommands: View {
    var model: AppModel
    var body: some View {
        let mail = model.mail
        let hub = ConversationHub.shared
        Divider()
        Toggle(L("Group by Conversation"), isOn: Binding(get: { mail.groupConversations }, set: { mail.groupConversations = $0 }))
        Toggle(L("Newest Message on Top"), isOn: Binding(get: { hub.newestOnTop }, set: { hub.newestOnTop = $0 }))
            .disabled(!mail.groupConversations)
        Divider()
    }
}
