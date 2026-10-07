import XCTest

/// Touch and hardware buttons, one XCTest call per gesture (a call takes
/// ~0.4 s on a phone, so a gesture is never split into points).
enum Gestures {
    static let minVelocity = 60.0
    static let maxVelocity = 5000.0

    static func tap(_ command: RunnerCommand) throws -> Done {
        let (x, y) = (try command.require(command.number("x"), "x"), try command.require(command.number("y"), "y"))
        let taps = Int(command.number("taps") ?? 1)
        guard (1...3).contains(taps) else { throw RunnerError.badRequest("`taps` is 1, 2 or 3") }
        let (app, reactivated) = try Commands.target(command, gesture: true)
        let point = Commands.coordinate(app, x, y)
        if taps == 2 {
            point.doubleTap()
        } else {
            for _ in 0..<taps { point.tap() }
        }
        return Done(reactivated: reactivated)
    }

    static func longPress(_ command: RunnerCommand) throws -> Done {
        let (x, y) = (try command.require(command.number("x"), "x"), try command.require(command.number("y"), "y"))
        let seconds = max(0.1, min(command.number("durationMs") ?? 800, 10_000) / 1000)
        let (app, reactivated) = try Commands.target(command, gesture: true)
        Commands.coordinate(app, x, y).press(forDuration: seconds)
        return Done(reactivated: reactivated)
    }

    /// A press at `from`, a move to `to` over `durationMs`, then `holdMs` at
    /// the end (a drop), then `settle` ms for what it set moving.
    static func drag(_ command: RunnerCommand) throws -> Done {
        let from = try command.require(command.point("from"), "from")
        let to = try command.require(command.point("to"), "to")
        let duration = max(0.05, min(command.number("durationMs") ?? 300, 10_000) / 1000)
        let hold = max(0, min(command.number("holdMs") ?? 0, 10_000) / 1000)
        let (app, reactivated) = try Commands.target(command, gesture: true)
        let distance = hypot(to.x - from.x, to.y - from.y)
        let velocity = max(minVelocity, min(distance / duration, maxVelocity))
        Commands.coordinate(app, from.x, from.y).press(
            forDuration: 0.05,
            thenDragTo: Commands.coordinate(app, to.x, to.y),
            withVelocity: XCUIGestureVelocity(rawValue: velocity),
            thenHoldForDuration: hold)
        if let settle = command.number("settle"), settle > 0 {
            Thread.sleep(forTimeInterval: min(settle, 5000) / 1000)
        }
        return Done(reactivated: reactivated)
    }

    static func button(_ command: RunnerCommand) throws -> Done {
        let name = try command.require(command.string("name"), "name")
        let device = XCUIDevice.shared
        switch name {
        case "home":
            device.press(.home)
        #if !targetEnvironment(simulator)
        case "volumeUp":
            device.press(.volumeUp)
        case "volumeDown":
            device.press(.volumeDown)
        #endif
        case "action":
            // An iPhone without one: XCTest raises, the guard reports it.
            guard #available(iOS 17.0, *) else { throw unsupported(name) }
            device.press(.action)
        default:
            throw unsupported(name)
        }
        return Done()
    }

    private static func unsupported(_ name: String) -> RunnerError {
        RunnerError(code: "UNSUPPORTED", message: "this iPhone has no `\(name)` button to press", hint: nil)
    }
}
