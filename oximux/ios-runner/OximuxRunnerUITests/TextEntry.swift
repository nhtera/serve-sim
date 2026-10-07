import XCTest

/// Typing into whatever has the keyboard focus.
enum TextEntry {
    static let maxText = 4000

    static func type(_ command: RunnerCommand) throws -> Done {
        let text = try command.require(command.string("text"), "text")
        guard !text.isEmpty, text.count <= maxText else { throw RunnerError.badRequest("`text` is 1–\(maxText) characters") }
        let (app, reactivated) = try Commands.target(command, gesture: true)
        app.typeText(text)
        return Done(reactivated: reactivated)
    }

    static func typeReturn(_ command: RunnerCommand) throws -> Done {
        let (app, reactivated) = try Commands.target(command, gesture: true)
        app.typeText("\n")
        return Done(reactivated: reactivated)
    }

    static func delete(_ command: RunnerCommand) throws -> Done {
        let count = Int(command.number("count") ?? 1)
        guard (1...500).contains(count) else { throw RunnerError.badRequest("`count` is 1–500") }
        let (app, reactivated) = try Commands.target(command, gesture: true)
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        return Done(reactivated: reactivated)
    }
}
