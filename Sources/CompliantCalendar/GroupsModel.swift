import Foundation
import Observation
import CalendarCore
import MailCore

/// Thread shown in the group reader: posts in memory only, each with its own label policy, plus the strictest
/// policy over all of them (capture shield, watermark, copy/print of the shared web view).
struct GroupThreadState: Equatable {
    var conversation: GroupConversation
    var posts: [GroupPost] = []
    var policies: [String: ContentPolicy] = [:]
    var merged: ContentPolicy = .open
    var replyThreadId: String?
    /// Why Reply is unavailable (labelled thread, rights) — nil when allowed.
    var replyRefusal: String?
    var loading = true
    var error: String?
}

@MainActor @Observable
final class GroupComposerState: Identifiable {
    enum Kind: Equatable { case reply(threadId: String), new }
    let id = UUID()
    let groupId: String
    let kind: Kind
    var topic = ""
    var body = ""
    var error: String?
    init(groupId: String, kind: Kind) { self.groupId = groupId; self.kind = kind }
    var canSend: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind != .new || !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// Microsoft 365 Groups in Mail: membership list, conversations, a read view, reply / new conversation.
/// Nothing is persisted. Sending follows the mail rule: an explicit Send, then a 10 s undo window, then one POST.
@MainActor @Observable
final class GroupsModel {
    enum LoadState: Equatable { case idle, loading, ready, needsConsent(String), failed(String) }

    @ObservationIgnored weak var mail: MailModel?
    @ObservationIgnored private var service: GroupsService?
    /// Live only: interactive consent (`write` = Group.ReadWrite.All for posting, else the read set).
    @ObservationIgnored var grant: ((_ write: Bool) async throws -> Void)?
    static let undoSeconds = 10

    private(set) var state: LoadState = .idle
    private(set) var groups: [M365Group] = []
    var expanded: Bool = UserDefaults.standard.object(forKey: "mail.groupsExpanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(expanded, forKey: "mail.groupsExpanded") }
    }
    private(set) var selectedGroupId: String?
    private(set) var conversations: [GroupConversation] = []
    private(set) var conversationsLoading = false
    private(set) var conversationsError: String?
    private(set) var selectedConversationId: String?
    private(set) var thread: GroupThreadState?
    var composer: GroupComposerState?
    /// A post waiting out its undo window.
    private(set) var pendingPost: (id: UUID, deadline: Date, text: String)?
    private(set) var notice: String?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingComposer: GroupComposerState?
    @ObservationIgnored private var heldComposer: GroupComposerState?
    private(set) var needsWriteConsent = false

    var isConfigured: Bool { service != nil }
    /// Read-only access for the list search's Groups toggle (MailBulk.swift).
    var searchService: GroupsService? { service }
    /// The group view replaces the message list + reader while a group is selected and no mail folder is.
    var isActive: Bool { selectedGroupId != nil && mail?.selectedFolderId == nil }
    var selectedGroup: M365Group? { groups.first { $0.id == selectedGroupId } }

    func configure(service: GroupsService, grant: ((_ write: Bool) async throws -> Void)? = nil) {
        self.service = service
        self.grant = grant
        state = .idle
    }

    func reset() {
        pendingTask?.cancel(); pendingTask = nil; pendingPost = nil; pendingComposer = nil; heldComposer = nil
        groups = []; conversations = []; thread = nil; composer = nil
        selectedGroupId = nil; selectedConversationId = nil
        state = .idle
        service = nil
    }

    // MARK: Load

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard let service else { return }
        state = .loading
        do {
            var gs = try await service.myGroups()
            state = .ready
            groups = gs
            // Unread (unseen) counts: one small GET per group, best effort, 4 at a time.
            let ids = gs.map(\.id)
            let counts = await withTaskGroup(of: (String, Int?).self) { group -> [String: Int] in
                var out: [String: Int] = [:]
                var queue = ids[...]
                for _ in 0..<4 { if let id = queue.popFirst() { group.addTask { (id, try? await service.unseenCount(groupId: id)) } } }
                while let (id, n) = await group.next() {
                    if let n { out[id] = n }
                    if let next = queue.popFirst() { group.addTask { (next, try? await service.unseenCount(groupId: next)) } }
                }
                return out
            }
            for i in gs.indices { gs[i].unseenCount = counts[gs[i].id] }
            groups = gs
        } catch {
            state = Self.loadState(for: error)
        }
    }

    static func loadState(for error: Error) -> LoadState {
        switch error as? MailServiceError {
        case .forbidden?, .http(401, _)?:
            return .needsConsent("Groups need the Group-Conversation.Read.All permission. Your organisation's admin may have to consent to it first.")
        case .offline?: return .failed("You're offline.")
        case .some(let e): return .failed("Groups couldn't be loaded (\(String(describing: e).prefix(60))).")
        case nil:
            // MSAL interaction-required (scope not yet consented) and other token errors land here.
            return .needsConsent("Groups need the Group-Conversation.Read.All permission. Your organisation's admin may have to consent to it first.")
        }
    }

    func grantRead() async {
        guard let grant else { return }
        do { try await grant(false); state = .idle; await loadIfNeeded() }
        catch { state = .needsConsent("Permission wasn't granted. An admin can consent Group-Conversation.Read.All for the organisation.") }
    }

    // MARK: Selection

    func select(_ g: M365Group) {
        guard let mail else { return }
        mail.selectedMessageId = nil
        mail.selectedFolderId = nil
        selectedGroupId = g.id
        selectedConversationId = nil; thread = nil
        if let held = heldComposer, held.groupId == g.id, case .new = held.kind { composer = held; heldComposer = nil }
        else if heldComposer?.groupId == g.id { notice = "A reply wasn't posted because you left the group. Open the conversation and reply again."; heldComposer = nil }
        Task { await loadConversations() }
    }

    func loadConversations() async {
        guard let service, let gid = selectedGroupId else { return }
        conversationsLoading = true; conversationsError = nil
        defer { conversationsLoading = false }
        do {
            let c = try await service.conversations(groupId: gid, top: 50)
            guard selectedGroupId == gid else { return }
            conversations = c
            if let i = groups.firstIndex(where: { $0.id == gid }) { groups[i].unseenCount = 0 }   // visited
        } catch {
            guard selectedGroupId == gid else { return }
            conversations = []
            conversationsError = Self.message(for: error)
        }
    }

    func open(_ c: GroupConversation) {
        selectedConversationId = c.id
        thread = GroupThreadState(conversation: c)
        Task { await loadThread(c) }
    }

    func loadThread(_ c: GroupConversation) async {
        guard let service, let gid = selectedGroupId, let mail else { return }
        do {
            let threads = try await service.threads(groupId: gid, conversationId: c.id)
            var posts: [GroupPost] = []
            for t in threads { posts += try await service.posts(groupId: gid, threadId: t.id) }
            guard selectedConversationId == c.id else { return }
            var st = GroupThreadState(conversation: c, posts: posts, loading: false)
            var merged = ContentPolicy.open
            for p in posts {
                let pol = GroupPostPolicy.policy(for: p, engine: mail.compliance)
                st.policies[p.id] = pol
                merged = merged.merged(with: pol)
            }
            st.merged = merged
            st.replyThreadId = threads.last?.id
            st.replyRefusal = st.replyThreadId == nil ? "This conversation has no thread to reply to."
                : GroupPostPolicy.replyRefusal(posts: posts, engine: mail.compliance)
            thread = st
        } catch {
            guard selectedConversationId == c.id else { return }
            thread?.loading = false
            thread?.error = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        switch error as? MailServiceError {
        case .forbidden?: "You don't have access to this group's conversations."
        case .notFound?: "This group or conversation no longer exists."
        case .offline?: "You're offline."
        default: "Couldn't load the conversation."
        }
    }

    // MARK: Compose + send (explicit Send → 10 s undo → one POST)

    func startReply() {
        guard let gid = selectedGroupId, let t = thread, t.replyRefusal == nil, let tid = t.replyThreadId else { return }
        composer = GroupComposerState(groupId: gid, kind: .reply(threadId: tid))
    }

    func startNewConversation() {
        guard let gid = selectedGroupId else { return }
        composer = GroupComposerState(groupId: gid, kind: .new)
    }

    /// The Send button. Nothing leaves the Mac until the undo window has passed.
    func send(_ c: GroupComposerState) {
        guard c.canSend, pendingPost == nil else { return }
        if case .reply = c.kind, let refusal = thread?.replyRefusal { c.error = refusal; return }
        let token = UUID()
        let deadline = Date().addingTimeInterval(TimeInterval(Self.undoSeconds))
        pendingPost = (token, deadline, c.kind == .new ? "Posting new conversation…" : "Posting reply…")
        pendingComposer = c
        composer = nil
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, let self, self.pendingPost?.id == token else { return }
            // The undo bar is only on screen in this group's view. Left it during the window → don't post; the text
            // comes back when the group is opened again.
            guard self.isActive, self.selectedGroupId == c.groupId else {
                self.pendingPost = nil; self.pendingComposer = nil
                c.error = "Not posted: you left the group before the undo time ended. Send again to post."
                self.heldComposer = c
                return
            }
            await self.deliver(c, token: token)
        }
    }

    func undoPending() {
        guard pendingPost != nil else { return }
        pendingTask?.cancel(); pendingTask = nil
        pendingPost = nil
        composer = pendingComposer   // back to editing, nothing was sent
        pendingComposer = nil
    }

    private func deliver(_ c: GroupComposerState, token: UUID) async {
        guard let service else { return }
        let html = MailHTML.fromComposer(c.body)
        do {
            switch c.kind {
            case .reply(let tid): try await service.reply(groupId: c.groupId, threadId: tid, html: html)
            case .new: try await service.newConversation(groupId: c.groupId, topic: c.topic.trimmingCharacters(in: .whitespacesAndNewlines), html: html)
            }
            pendingPost = nil; pendingComposer = nil; needsWriteConsent = false
            notice = c.kind == .new ? "Conversation posted" : "Reply posted"
            await loadConversations()
            if let open = conversations.first(where: { $0.id == selectedConversationId }) { await loadThread(open) }
        } catch {
            pendingPost = nil
            pendingComposer = nil
            // Not sent: put the text back so nothing is lost.
            composer = c
            switch error as? MailServiceError {
            case .forbidden?, .http(401, _)?, nil:
                needsWriteConsent = true
                c.error = "Posting needs the Group.ReadWrite.All permission (admin consent). Nothing was sent."
            case .offline?: c.error = "You're offline. Nothing was sent."
            case .some(.http(let code, _)) where code == 503 || code == 504:
                c.error = "Exchange didn't answer in time. Check the conversation before posting again — it may have gone through."
            default: c.error = "The post was refused. Nothing was sent."
            }
        }
    }

    func grantWrite() async {
        guard let grant else { return }
        do { try await grant(true); needsWriteConsent = false; composer?.error = nil }
        catch { composer?.error = "Permission wasn't granted. An admin can consent Group.ReadWrite.All for the organisation." }
    }

    func clearNotice() { notice = nil }
}
