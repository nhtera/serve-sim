import Foundation

/// Send-once: each mutating command's reply, by its `commandId`. A command
/// sent again (its reply was lost on the way back) is answered from here, not
/// done twice; `status{statusCommandId}` reads it. An id is taken before its
/// command runs, so a second copy arriving meanwhile is told it is still
/// running. Bounded: the oldest finished replies go first.
final class Journal: @unchecked Sendable {
    enum Entry: Equatable {
        case pending
        case done(Data)
    }

    enum Begin: Equatable {
        /// Yours to run.
        case fresh
        case pending
        case done(Data)
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// Take `id` for a command about to run, unless it already ran or runs.
    func begin(_ id: String) -> Begin {
        lock.lock(); defer { lock.unlock() }
        switch entries[id] {
        case .pending?: return .pending
        case .done(let reply)?: return .done(reply)
        case nil:
            entries[id] = .pending
            order.append(id)
            trim()
            return .fresh
        }
    }

    /// The command `id` finished with `reply`.
    func finish(_ id: String, _ reply: Data) {
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(.done(reply), forKey: id) == nil {
            order.append(id)
            trim()
        }
    }

    /// The command `id` never ran (the runner was busy): it may be sent again.
    func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if entries[id] == .pending {
            entries[id] = nil
            order.removeAll { $0 == id }
        }
    }

    func entry(_ id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    /// Called with `lock` held. A command still running is never dropped.
    private func trim() {
        while order.count > capacity, let oldest = order.firstIndex(where: { entries[$0] != .pending }) {
            entries[order.remove(at: oldest)] = nil
        }
    }
}
