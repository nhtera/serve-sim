import Foundation
import XCTest

/// XCTest failures recorded while a command runs (main thread only).
enum IssueSink {
    private(set) static var active = false
    private(set) static var issues: [String] = []

    static func begin() {
        active = true
        issues = []
    }

    static func end() {
        active = false
    }

    /// Keep `issue` for the command running now; false when none runs.
    static func take(_ issue: String) -> Bool {
        guard active, Thread.isMainThread else { return false }
        issues.append(issue)
        return true
    }
}

/// What a command did: its reply's `data`, and whether its app had to be
/// brought back to the front first.
struct Done {
    var data: Any = [String: Any]()
    var reactivated = false
}

/// Every command, from a request body to a reply body. Mutating commands are
/// answered once per `commandId` (the `Journal`); XCTest work runs on the
/// main thread through the `MainThreadGate`, under an exception guard.
final class Commands: @unchecked Sendable {
    static let springboard = "com.apple.springboard"

    private let journal = Journal()
    private let gate = MainThreadGate()
    private let onShutdown: @Sendable () -> Void

    init(onShutdown: @escaping @Sendable () -> Void) {
        self.onShutdown = onShutdown
    }

    func handle(_ body: Data) -> Data {
        let command: RunnerCommand
        switch RunnerCommand.decode(body) {
        case .success(let decoded): command = decoded
        case .failure(let error): return Envelope.failure(error)
        }
        switch command.name {
        case "status":
            return status(command)
        case "shutdown":
            // The reply first: the run ends right after.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: onShutdown)
            return Envelope.ok()
        default:
            break
        }
        guard command.isMutating, let id = command.id else {
            return reply(gate.run(timeout: Self.deadline(command)) { Self.perform(command) })
        }
        switch journal.begin(id) {
        case .done(let earlier): return earlier
        case .pending: return Envelope.failure(.inProgress)
        case .fresh: break
        }
        let journal = self.journal
        let outcome = gate.run(timeout: Self.deadline(command), late: { journal.finish(id, $0) }) { Self.perform(command) }
        switch outcome {
        case .finished(let reply): journal.finish(id, reply)
        // Never ran: the same id may come again.
        case .busy: journal.release(id)
        // Still running: its real reply is kept when it ends (`late`).
        case .wedged: break
        }
        return reply(outcome)
    }

    private func reply(_ outcome: MainThreadGate.Outcome) -> Data {
        switch outcome {
        case .finished(let reply): reply
        case .busy: Envelope.failure(.busy)
        case .wedged: Envelope.failure(.wedged)
        }
    }

    /// The protocol, and what became of an earlier command: `done` with its
    /// reply, `pending` while it runs, or `null` when unknown here.
    private func status(_ command: RunnerCommand) -> Data {
        var data: [String: Any] = ["protocol": RunnerProtocol.name, "version": RunnerProtocol.version]
        if let id = command.string("statusCommandId") {
            switch journal.entry(id) {
            case .pending?: data["command"] = ["state": "pending"]
            case .done(let reply)?:
                data["command"] = ["state": "done", "reply": (try? JSONSerialization.jsonObject(with: reply)) ?? NSNull()]
            case nil: data["command"] = NSNull()
            }
        }
        return Envelope.ok(data)
    }

    /// How long a command may hold the main thread: its own length (a drag's
    /// time, ~50 ms a typed character), plus room.
    static func deadline(_ command: RunnerCommand) -> TimeInterval {
        let ms = ["durationMs", "holdMs", "settle"].reduce(0) { $0 + max(0, command.number($1) ?? 0) }
        let typing = Double(command.string("text")?.count ?? 0) * 50
        return 30 + min(ms + typing, 300_000) / 1000
    }

    // Main thread.
    private static func perform(_ command: RunnerCommand) -> Data {
        var outcome: Result<Done, RunnerError> = .failure(.xctest("the command did not run"))
        // XCTest records most failures (no keyboard focus, an element gone)
        // instead of throwing them: collected here, they are this command's
        // error — recorded as the test's, one would end the runner.
        IssueSink.begin()
        defer { IssueSink.end() }
        let exception = OXRunCatchingException {
            do {
                outcome = .success(try run(command))
            } catch let error as RunnerError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.xctest("\(error)"))
            }
        }
        if let exception {
            return Envelope.failure(.xctest(exception.reason ?? exception.name.rawValue))
        }
        if let issue = IssueSink.issues.first {
            return Envelope.failure(.xctest(issue))
        }
        switch outcome {
        case .success(let done): return Envelope.ok(done.data, reactivated: done.reactivated)
        case .failure(let error): return Envelope.failure(error)
        }
    }

    // Main thread.
    private static func run(_ command: RunnerCommand) throws -> Done {
        switch command.name {
        case "viewport": return try Snapshot.viewport(command)
        case "snapshot": return try Snapshot.tree(command)
        case "screenshot": return Snapshot.screenshot()
        case "tap": return try Gestures.tap(command)
        case "longPress": return try Gestures.longPress(command)
        case "drag": return try Gestures.drag(command)
        case "button": return try Gestures.button(command)
        case "type": return try TextEntry.type(command)
        case "keyboardReturn": return try TextEntry.typeReturn(command)
        case "keyboardDelete": return try TextEntry.delete(command)
        default: throw RunnerError(code: "UNKNOWN_COMMAND", message: "no command `\(command.name)`", hint: nil)
        }
    }

    /// The app a command addresses (`app`, default the home screen). A
    /// gesture brings it to the front when it is not (and says so); reading
    /// one that is not in front is refused instead.
    static func target(_ command: RunnerCommand, gesture: Bool) throws -> (XCUIApplication, reactivated: Bool) {
        let bundle = command.string("app") ?? springboard
        let app = XCUIApplication(bundleIdentifier: bundle)
        // The home screen and system dialogs are always there to address.
        if bundle == springboard || app.state == .runningForeground {
            return (app, false)
        }
        // One just opened (a tap on its icon) may still be on its way in.
        if app.wait(for: .runningForeground, timeout: 1) {
            return (app, false)
        }
        guard gesture else { throw RunnerError.backgrounded(bundle) }
        app.activate()
        return (app, true)
    }

    /// `(x, y)` in points from the app's top-left, as XCTest addresses it
    /// (whichever way the phone is turned).
    static func coordinate(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
}
