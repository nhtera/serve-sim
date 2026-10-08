import Foundation

/// The runner's protocol, `oximux-runner/1` (see ../PROTOCOL.md): one JSON
/// command per HTTP request, one JSON envelope per reply. Pure Foundation, so
/// the fork's macOS tests check it without a phone.
enum RunnerProtocol {
    static let name = "oximux-runner/1"
    static let version = "0.1.1"
    /// The largest request body accepted (413 beyond).
    static let maxBody = 2 << 20
    /// Most connections served at once (503 beyond).
    static let maxConnections = 4
    /// Most nodes a `snapshot` returns.
    static let maxNodes = 2000
}

/// Why a command failed: a stable code, words for a person, and what to do.
struct RunnerError: Error, Equatable {
    var code: String
    var message: String
    var hint: String?

    static func badRequest(_ message: String) -> Self {
        Self(code: "BAD_REQUEST", message: message, hint: nil)
    }

    static let busy = Self(code: "RUNNER_BUSY", message: "another command is still running", hint: "retry when it has finished")
    static let inProgress = Self(code: "IN_PROGRESS", message: "this command is still running", hint: "ask `status` with its commandId")
    static let wedged = Self(code: "RUNNER_WEDGED", message: "a command did not finish in time", hint: "restart the runner")
    static let noKeyboardFocus = Self(code: "NO_KEYBOARD_FOCUS", message: "nothing on the screen has the keyboard focus", hint: "tap the text field first")

    static func backgrounded(_ app: String) -> Self {
        Self(code: "APP_BACKGROUNDED", message: "\(app) is not in front", hint: "a gesture brings it back; reading does not")
    }

    /// XCTest's complaint: its first line only (it goes on with a dump of
    /// the whole element tree), at most 300 characters.
    static func xctest(_ message: String) -> Self {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let short = line.count > 300 ? String(line.prefix(300)) + "…" : line
        let hint = short.contains("keyboard focus") ? "tap the text field first" : nil
        return Self(code: "XCTEST_FAILED", message: short, hint: hint)
    }
}

/// One decoded command: its id (for the send-once journal), its name, and the
/// rest of its fields.
struct RunnerCommand {
    /// Commands that change the phone: answered once per id.
    static let mutating: Set<String> = ["tap", "longPress", "drag", "type", "keyboardReturn", "keyboardDelete", "button"]

    var id: String?
    var name: String
    var fields: [String: Any]

    var isMutating: Bool { Self.mutating.contains(name) }

    static func decode(_ body: Data) -> Result<RunnerCommand, RunnerError> {
        guard let object = try? JSONSerialization.jsonObject(with: body), let fields = object as? [String: Any] else {
            return .failure(.badRequest("the body is not a JSON object"))
        }
        guard let name = fields["command"] as? String, !name.isEmpty else {
            return .failure(.badRequest("`command` is missing"))
        }
        let id = fields["commandId"] as? String
        if let id, id.isEmpty || id.count > 128 {
            return .failure(.badRequest("`commandId` must be 1–128 characters"))
        }
        return .success(RunnerCommand(id: id, name: name, fields: fields))
    }

    func string(_ key: String) -> String? { fields[key] as? String }

    func number(_ key: String) -> Double? {
        guard let n = fields[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let value = n.doubleValue
        return value.isFinite ? value : nil
    }

    /// A whole number in `range`, `fallback` when absent; anything else (a
    /// fraction, out of range, not a number) is a bad request — never a
    /// conversion that traps.
    func integer(_ key: String, in range: ClosedRange<Int>, fallback: Int) throws -> Int {
        guard fields[key] != nil else { return fallback }
        guard let value = number(key), value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw RunnerError.badRequest("`\(key)` is a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(value)
    }

    func point(_ key: String) -> (x: Double, y: Double)? {
        guard let p = fields[key] as? [String: Any], let x = (p["x"] as? NSNumber)?.doubleValue,
              let y = (p["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw RunnerError.badRequest("`\(what)` is missing or not valid") }
        return value
    }
}

/// A reply's body.
enum Envelope {
    static func ok(_ data: Any = [String: Any](), reactivated: Bool = false) -> Data {
        var object: [String: Any] = ["ok": true, "data": data]
        if reactivated { object["reactivated"] = true }
        return encode(object)
    }

    static func failure(_ error: RunnerError) -> Data {
        var detail: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { detail["hint"] = hint }
        return encode(["ok": false, "error": detail])
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false}"#.utf8)
    }
}
