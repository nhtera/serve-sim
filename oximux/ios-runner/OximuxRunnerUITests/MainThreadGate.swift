import Foundation

/// XCTest is driven from the main thread, one call at a time. Commands arrive
/// on server threads: each runs on the main thread through here, with a
/// deadline. A second command while one runs is `RUNNER_BUSY`; one that
/// overruns its deadline is `RUNNER_WEDGED` (and the gate stays busy until
/// it does finish).
final class MainThreadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func run(timeout: TimeInterval, _ body: @escaping () -> Data) -> Data {
        lock.lock()
        if running {
            lock.unlock()
            return Envelope.failure(.busy)
        }
        running = true
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        DispatchQueue.main.async {
            let reply = body()
            self.lock.lock()
            result.value = reply
            self.running = false
            self.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return Envelope.failure(.wedged) }
        lock.lock(); defer { lock.unlock() }
        return result.value ?? Envelope.failure(.wedged)
    }

    private final class Box: @unchecked Sendable {
        var value: Data?
    }
}
