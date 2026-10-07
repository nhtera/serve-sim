import Foundation

/// Send-once: the reply to each mutating command, by its `commandId`. A
/// command sent again (the reply was lost on the way back) is answered from
/// here, not done twice; `status{statusCommandId}` reads it. Bounded: the
/// oldest replies go first.
final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: Data] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    func reply(for id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return replies[id]
    }

    func record(_ reply: Data, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if replies.updateValue(reply, forKey: id) == nil {
            order.append(id)
        }
        while order.count > capacity {
            replies.removeValue(forKey: order.removeFirst())
        }
    }
}
