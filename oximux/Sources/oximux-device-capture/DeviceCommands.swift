import Foundation

/// Inbound commands for the capture helper. The same framing and parser as
/// the sim helper (`ParsedCommand`), plus `record_start` / `record_stop`;
/// every input or accessibility command is answered `unsupported` (a phone is
/// driven by its own runner, not by this view-only helper).
final class DeviceCommands: @unchecked Sendable {
    private let stream: DeviceStream
    private let queue = DispatchQueue(label: "oximux.device-capture.commands")

    init(stream: DeviceStream) {
        self.stream = stream
    }

    /// Runs until stdin closes: then the recording is finalized and the
    /// helper exits.
    func run() {
        Thread { [stream, queue] in
            while true {
                let next = autoreleasepool { Wire.readCommand() }
                switch next {
                case .command(let raw):
                    queue.async { Self.handle(raw, stream: stream) }
                case .malformed:
                    Self.fail(nil, "malformed command")
                case .closed:
                    queue.sync { _ = stream.recorder.finish() }
                    _exit(0)
                }
            }
        }.start()
    }

    /// One command, in arrival order.
    static func handle(_ raw: [String: Any], stream: DeviceStream) {
        let id = raw["id"] as? Int
        switch raw["cmd"] as? String {
        case "record_start":
            guard let path = raw["path"] as? String, let url = RecordPath.validate(path) else {
                return fail(id, "record_start needs an absolute .mov path in an existing folder, without ..")
            }
            if let why = stream.recorder.start(url) { return fail(id, why) }
            stream.recordingChanged()
            return reply(id, ["ok": true])
        case "record_stop":
            let finished = stream.recorder.finish()
            stream.recordingChanged()
            switch finished {
            case let .done(path, millis): return reply(id, ["ok": true, "path": path, "duration_ms": millis])
            case let .failed(why): return fail(id, why)
            }
        default:
            break
        }
        switch ParsedCommand.parse(raw) {
        case .failure(let error):
            fail(id, error.description)
        case .success(let command):
            switch answer(command, stream: stream) {
            case .ok(let result): reply(id, result)
            case .fail(let why): fail(id, why)
            case .none: break
            }
        }
    }

    /// What a parsed command answers here.
    enum Answer {
        case ok([String: Any])
        case fail(String)
        /// No reply (pause, resume).
        case none
    }

    /// What a parsed command does here.
    static func answer(_ command: ParsedCommand, stream: DeviceStream?) -> Answer {
        switch command {
        case .ping:
            return .ok(["pong": true])
        case let .configure(scale, fps, orientation, format):
            // The phone turns by itself; there is nothing to command.
            guard orientation == nil else { return .fail(unsupported) }
            stream?.configure(scale: scale, fps: fps, format: format)
            return .ok(["ok": true])
        case .pause:
            stream?.setPaused(true)
            return .none
        case .resume:
            stream?.setPaused(false)
            return .none
        case .screenshot:
            guard let png = stream?.snapshotPNG() else { return .fail("no frame yet") }
            return .ok(["png_base64": png.base64EncodedString()])
        case .touch, .multitouch, .scroll, .key, .button, .axDescribe, .axFrontmost, .memoryWarning:
            return .fail(unsupported)
        }
    }

    static let unsupported = "unsupported"

    static func reply(_ id: Int?, _ result: [String: Any]) {
        guard let id else { return }
        Wire.sendEvent(["event": "response", "id": id, "ok": true, "result": result])
    }

    /// A failed command: a `response` when it had an id, else an `error` event.
    static func fail(_ id: Int?, _ message: String) {
        guard let id else { return Wire.sendEvent(["event": "error", "message": message]) }
        Wire.sendEvent(["event": "response", "id": id, "ok": false, "error": message])
    }
}
