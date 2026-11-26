import Foundation
import CalendarCore

// MARK: - Microsoft To Do (flagged mail → tasks, task from a message)
//
// Checked on learn.microsoft.com (2026-11-20):
//  * `GET /me/todo/lists`: `wellknownListName` is `none` | `defaultList` (built-in Tasks) | `flaggedEmails` (built-in
//    "Flagged email" list: "Tasks from flagged emails are present in this list"). So flagging a message (MailAction
//    flag) already puts it in To Do; niivo creates nothing extra for a flag.
//  * `GET /me/todo/lists/{id}/tasks`, `POST …/tasks` (with `linkedResources` inline: webUrl, applicationName,
//    displayName, externalId), `PATCH …/tasks/{id}` (status, dueDateTime / reminderDateTime as dateTimeTimeZone,
//    isReminderOn), `DELETE …/tasks/{id}`: delegated Tasks.ReadWrite.
// UNVERIFIED against a tenant:
//  * that completing a task in the Flagged email list marks the message's flag complete (Exchange links them, but
//    the round trip isn't documented on the todoTask page);
//  * that a due date sent as local midnight with timeZone "UTC" shows as that calendar day in To Do clients.
//
// LABELS: a task is a server copy outside the message's label. Its title is the subject only when the message's
// policy allows offline details and doesn't redact; otherwise "Task from confidential message". No preview or body
// is ever copied into the task.

public struct TodoList: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case none, defaultList, flaggedEmails, other }
    public var id: String
    public var displayName: String
    public var kind: Kind
    public var isShared: Bool
    public init(id: String, displayName: String, kind: Kind, isShared: Bool = false) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.isShared = isShared
    }
}

public struct TodoLinkedResource: Sendable, Hashable {
    public var webUrl: URL?
    public var applicationName: String
    public var displayName: String
    public var externalId: String?
    public init(webUrl: URL?, applicationName: String, displayName: String, externalId: String?) {
        self.webUrl = webUrl; self.applicationName = applicationName; self.displayName = displayName; self.externalId = externalId
    }
    var json: [String: Any] {
        var o: [String: Any] = ["applicationName": applicationName, "displayName": displayName]
        if let webUrl { o["webUrl"] = webUrl.absoluteString }
        if let externalId { o["externalId"] = externalId }
        return o
    }
}

public struct TodoTask: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable { case notStarted, inProgress, completed, waitingOnOthers, deferred }
    public var id: String
    public var listId: String
    public var title: String
    public var status: Status
    public var importance: String
    public var due: Date?
    public var reminder: Date?
    public var isReminderOn: Bool
    public var created: Date?
    public var linked: [TodoLinkedResource]
    public init(id: String, listId: String, title: String, status: Status = .notStarted, importance: String = "normal",
                due: Date? = nil, reminder: Date? = nil, isReminderOn: Bool = false, created: Date? = nil,
                linked: [TodoLinkedResource] = []) {
        self.id = id; self.listId = listId; self.title = title; self.status = status; self.importance = importance
        self.due = due; self.reminder = reminder; self.isReminderOn = isReminderOn; self.created = created; self.linked = linked
    }
    public var isCompleted: Bool { status == .completed }
}

public struct TodoDraft: Sendable, Hashable {
    public var title: String
    public var due: Date?
    public var reminder: Date?
    public var linked: [TodoLinkedResource]
    public init(title: String, due: Date? = nil, reminder: Date? = nil, linked: [TodoLinkedResource] = []) {
        self.title = title; self.due = due; self.reminder = reminder; self.linked = linked
    }
}

/// Partial update. `.some(nil)` clears a date.
public struct TodoPatch: Sendable, Hashable {
    public var status: TodoTask.Status?
    public var title: String?
    public var due: Date??
    public var reminder: Date??
    public init(status: TodoTask.Status? = nil, title: String? = nil, due: Date?? = nil, reminder: Date?? = nil) {
        self.status = status; self.title = title; self.due = due; self.reminder = reminder
    }
}

public protocol TodoService: Sendable {
    func lists() async throws -> [TodoList]
    func tasks(listId: String) async throws -> [TodoTask]
    func create(listId: String, _ draft: TodoDraft) async throws -> TodoTask
    func update(listId: String, taskId: String, _ patch: TodoPatch) async throws -> TodoTask
    func delete(listId: String, taskId: String) async throws
}

// MARK: - Task from a message (label-aware)

public enum TodoFromMail {
    public static let confidentialTitle = "Task from confidential message"
    public static let applicationName = "niivo mail"

    /// The subject only when the label allows it to live outside the message; never for redacted (private) items.
    public static func title(subject: String, policy: ContentPolicy) -> String {
        guard policy.allowOfflineDetails, !policy.redactDetails else { return confidentialTitle }
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Follow up: (no subject)" : s
    }

    /// Draft for a message: same title on the task and on the link; the link carries the Outlook web link (if the
    /// message has one) and the message id. No preview, body, sender or recipients.
    public static func draft(for m: MailMessage, policy: ContentPolicy, due: Date? = nil, reminder: Date? = nil) -> TodoDraft {
        let t = title(subject: m.subject, policy: policy)
        return TodoDraft(title: t, due: due, reminder: reminder,
                         linked: [TodoLinkedResource(webUrl: m.webLink, applicationName: applicationName, displayName: t,
                                                     externalId: m.id)])
    }
}

// MARK: - Graph implementation

public final class GraphTodoService: TodoService, @unchecked Sendable {
    private let http: GraphHTTP
    static let taskSelect = "id,title,status,importance,dueDateTime,reminderDateTime,isReminderOn,createdDateTime"

    /// `token`: Tasks.ReadWrite (`Auth.todoScopes`), silent only.
    public init(token: @escaping GraphHTTP.TokenProvider, session: URLSession = .shared) {
        http = GraphHTTP(token: token, session: session)
    }

    public func lists() async throws -> [TodoList] {
        var out: [TodoList] = []
        var next: URL? = http.url("me/todo/lists")
        var n = 0
        while let u = next, n < 10 {
            let page: GHPage<GHTodoList> = try await http.get(u)
            out += page.value.map(\.model); next = page.nextLink.flatMap(URL.init(string:)); n += 1
        }
        return out
    }

    public func tasks(listId: String) async throws -> [TodoTask] {
        var out: [TodoTask] = []
        var next: URL? = http.url("me/todo/lists/\(listId)/tasks", ["$top": "100", "$select": Self.taskSelect])
        var n = 0
        while let u = next, n < 5 {
            let page: GHPage<GHTodoTask> = try await http.get(u)
            out += page.value.map { $0.model(listId: listId) }; next = page.nextLink.flatMap(URL.init(string:)); n += 1
        }
        return out
    }

    public func create(listId: String, _ d: TodoDraft) async throws -> TodoTask {
        var o: [String: Any] = ["title": d.title]
        if let due = d.due { o["dueDateTime"] = TodoDates.dueJSON(due) }
        if let r = d.reminder { o["reminderDateTime"] = TodoDates.instantJSON(r); o["isReminderOn"] = true }
        if !d.linked.isEmpty { o["linkedResources"] = d.linked.map(\.json) }
        let data = try await http.send(http.url("me/todo/lists/\(listId)/tasks"), method: "POST",
                                       body: try JSONSerialization.data(withJSONObject: o), idempotent: false)
        do { return try JSONDecoder().decode(GHTodoTask.self, from: data).model(listId: listId, linked: d.linked) }
        catch { throw MailServiceError.http(201, "decode") }
    }

    public func update(listId: String, taskId: String, _ p: TodoPatch) async throws -> TodoTask {
        let data = try await http.send(http.url("me/todo/lists/\(listId)/tasks/\(taskId)"), method: "PATCH",
                                       body: try JSONSerialization.data(withJSONObject: TodoDates.patchJSON(p)), idempotent: true)
        do { return try JSONDecoder().decode(GHTodoTask.self, from: data).model(listId: listId) }
        catch { throw MailServiceError.http(200, "decode") }
    }

    public func delete(listId: String, taskId: String) async throws {
        try await http.send(http.url("me/todo/lists/\(listId)/tasks/\(taskId)"), method: "DELETE", body: nil, idempotent: true)
    }
}

public enum TodoDates {
    static func fmt(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'.0000000'"
        return f
    }
    /// A due DATE: the local calendar day at midnight, labelled UTC (To Do stores due as a date).
    public static func dueJSON(_ d: Date, calendar: Calendar = .current) -> [String: String] {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        let s = String(format: "%04d-%02d-%02dT00:00:00.0000000", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return ["dateTime": s, "timeZone": "UTC"]
    }
    /// An instant (reminder) in UTC.
    public static func instantJSON(_ d: Date) -> [String: String] {
        ["dateTime": fmt(TimeZone(identifier: "UTC")!).string(from: d), "timeZone": "UTC"]
    }
    public static func patchJSON(_ p: TodoPatch) -> [String: Any] {
        var o: [String: Any] = [:]
        if let s = p.status { o["status"] = s.rawValue }
        if let t = p.title { o["title"] = t }
        if let due = p.due { o["dueDateTime"] = due.map { dueJSON($0) as Any } ?? NSNull() }
        if let r = p.reminder {
            if let r { o["reminderDateTime"] = instantJSON(r); o["isReminderOn"] = true }
            else { o["reminderDateTime"] = NSNull(); o["isReminderOn"] = false }
        }
        return o
    }
    /// Parses Graph's dateTimeTimeZone (fractional seconds optional). Non-UTC zones fall back to the zone id when
    /// Foundation knows it, else UTC.
    static func parse(_ v: GHDateTimeTZ?) -> Date? {
        guard let v, let s = v.dateTime else { return nil }
        let tz = v.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let base = String(s.prefix(19))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: base)
    }
}

// MARK: DTOs

struct GHDateTimeTZ: Decodable { var dateTime: String?; var timeZone: String? }
struct GHTodoList: Decodable {
    var id: String; var displayName: String?; var wellknownListName: String?; var isShared: Bool?
    var model: TodoList {
        TodoList(id: id, displayName: displayName ?? "", kind: TodoList.Kind(rawValue: wellknownListName ?? "none") ?? .other,
                 isShared: isShared ?? false)
    }
}
struct GHTodoTask: Decodable {
    var id: String; var title: String?; var status: String?; var importance: String?
    var dueDateTime: GHDateTimeTZ?; var reminderDateTime: GHDateTimeTZ?; var isReminderOn: Bool?; var createdDateTime: String?
    func model(listId: String, linked: [TodoLinkedResource] = []) -> TodoTask {
        TodoTask(id: id, listId: listId, title: title ?? "", status: TodoTask.Status(rawValue: status ?? "") ?? .notStarted,
                 importance: importance ?? "normal", due: TodoDates.parse(dueDateTime), reminder: TodoDates.parse(reminderDateTime),
                 isReminderOn: isReminderOn ?? false, created: createdDateTime.flatMap { ISO8601DateFormatter().date(from: $0) },
                 linked: linked)
    }
}

// MARK: - Fixtures

public final class FixtureTodoService: TodoService, @unchecked Sendable {
    private let lock = NSLock()
    private var tasksByList: [String: [TodoTask]]
    private var next = 0
    public init() {
        tasksByList = [
            "l-tasks": [TodoTask(id: "t-1", listId: "l-tasks", title: "Draft the quarterly review", due: Date().addingTimeInterval(86_400 * 2))],
            "l-flagged": [TodoTask(id: "t-2", listId: "l-flagged", title: "Reply about the workshop agenda")],
            "l-home": [TodoTask(id: "t-3", listId: "l-home", title: "Book the boiler service", status: .completed)],
        ]
    }
    public func lists() async throws -> [TodoList] {
        [TodoList(id: "l-tasks", displayName: "Tasks", kind: .defaultList),
         TodoList(id: "l-flagged", displayName: "Flagged email", kind: .flaggedEmails),
         TodoList(id: "l-home", displayName: "Home", kind: .none)]
    }
    public func tasks(listId: String) async throws -> [TodoTask] { lock.withLock { tasksByList[listId] ?? [] } }
    public func create(listId: String, _ d: TodoDraft) async throws -> TodoTask {
        lock.withLock {
            next += 1
            let t = TodoTask(id: "t-new-\(next)", listId: listId, title: d.title, due: d.due, reminder: d.reminder,
                             isReminderOn: d.reminder != nil, created: Date(), linked: d.linked)
            tasksByList[listId, default: []].append(t); return t
        }
    }
    public func update(listId: String, taskId: String, _ p: TodoPatch) async throws -> TodoTask {
        try lock.withLock {
            guard let i = tasksByList[listId]?.firstIndex(where: { $0.id == taskId }) else { throw MailServiceError.notFound }
            var t = tasksByList[listId]![i]
            if let s = p.status { t.status = s }
            if let title = p.title { t.title = title }
            if let d = p.due { t.due = d }
            if let r = p.reminder { t.reminder = r; t.isReminderOn = r != nil }
            tasksByList[listId]![i] = t; return t
        }
    }
    public func delete(listId: String, taskId: String) async throws {
        lock.withLock { tasksByList[listId]?.removeAll { $0.id == taskId } }
    }
}
