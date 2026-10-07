import Foundation

/// XCTest is driven from the main thread, one call at a time. Commands arrive
/// on server threads: each runs on the main thread through here, with a
/// deadline. A second command while one runs is turned away (`busy`); one
/// that overruns its deadline is `wedged` — the gate stays busy until it does
/// end, and its real reply then goes to `late`.
final class MainThreadGate: @unchecked Sendable {
    enum Outcome {
        case finished(Data)
        case busy
        case wedged
    }

    private let lock = NSLock()
    private var running = false

    func run(timeout: TimeInterval, late: @escaping @Sendable (Data) -> Void = { _ in }, _ body: @escaping () -> Data) -> Outcome {
        lock.lock()
        if running {
            lock.unlock()
            return .busy
        }
        running = true
        lock.unlock()
        let state = State()
        DispatchQueue.main.async {
            let reply = body()
            self.lock.lock()
            self.running = false
            state.reply = reply
            let abandoned = state.abandoned
            self.lock.unlock()
            if abandoned { late(reply) }
            state.done.signal()
        }
        let finished = state.done.wait(timeout: .now() + timeout) == .success
        lock.lock(); defer { lock.unlock() }
        if finished, let reply = state.reply {
            return .finished(reply)
        }
        if let reply = state.reply {
            // Finished between the wait and the lock.
            return .finished(reply)
        }
        state.abandoned = true
        return .wedged
    }

    private final class State: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var reply: Data?
        var abandoned = false
    }
}
