import Foundation

extension MailSync {
    /// Apply a plan's steps. Each `perform` queues its intent and joins the running flush, so N steps cost one
    /// outbox drain rather than N sequential round trips.
    public func apply(_ steps: [BulkStep]) async -> (done: Int, failed: Int) {
        await withTaskGroup(of: Bool.self) { g in
            for s in steps { g.addTask { (try? await self.perform(s.action, on: s.messageId)) != nil } }
            var done = 0, failed = 0
            for await ok in g { if ok { done += 1 } else { failed += 1 } }
            return (done, failed)
        }
    }

    /// Undo steps recorded with the id each message had at the time. Ids are resolved through server-move remaps
    /// (`currentId`) first, so ⌘Z after a flushed Graph move targets the moved message, not a 404.
    public func undo(_ steps: [BulkStep]) async -> (done: Int, failed: Int) {
        await apply(steps.map { BulkStep(messageId: currentId($0.messageId), action: $0.action) })
    }
}
