import Foundation

/// Executes inbound commands (see `ParsedCommand` and oximux/PROTOCOL.md)
/// against the upstream HID / capture / AX code.
///
/// Every command may carry an integer `id`. Commands that return data answer
/// with a `response` event carrying the same id; a command that fails answers
/// `ok: false` (or, without an id, emits an `error` event).
///
/// Ordering: input commands run in arrival order on one queue, so a touch
/// `begin`/`move`/`end` sequence stays ordered. Slow requests (AX dumps,
/// screenshots) run detached and reply by id, so they never delay a touch.
final class Commands: @unchecked Sendable {
    /// Inbound commands buffered while the executor is busy. A full queue
    /// means OxiMux is flooding or we are wedged; drop and say so rather
    /// than grow without bound.
    static let queueLimit = 512

    private let udid: String
    private let hid = HIDInjector()
    private let stream: FrameStream
    private let hidReady: Task<Void, Error>

    init(udid: String, stream: FrameStream) {
        self.udid = udid
        self.stream = stream
        let hid = self.hid
        hidReady = Task { try await hid.setup(deviceUDID: udid, duoHelper: "") }
    }

    /// Runs until stdin closes, then exits the process.
    func run() {
        let queue = AsyncStream<(Int?, ParsedCommand)>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queueLimit))
        Thread {
            while true {
                // A bare Thread has no autorelease pool; JSONSerialization
                // autoreleases on every parse.
                let next = autoreleasepool { Wire.readCommand() }
                switch next {
                case .command(let raw):
                    let id = raw["id"] as? Int
                    switch ParsedCommand.parse(raw) {
                    case .success(let command):
                        if case .dropped = queue.continuation.yield((id, command)) {
                            Self.fail(id, "command queue full; command dropped")
                        }
                    case .failure(let error):
                        Self.fail(id, error.description)
                    }
                case .malformed: Self.fail(nil, "malformed command")
                // Parent gone (or the framing broke): never outlive OxiMux.
                case .closed: _exit(0)
                }
            }
        }.start()
        Task {
            for await (id, command) in queue.stream { await self.handle(id: id, command) }
        }
    }

    private func handle(id: Int?, _ command: ParsedCommand) async {
        if command.needsHID {
            do { try await hidReady.value } catch {
                return Self.fail(id, "hid setup failed: \(error.localizedDescription)")
            }
        }
        switch command {
        case .ping:
            Self.reply(id, ["pong": true])
        case let .touch(phase, x, y, edge):
            // Width/height only matter for foldable (Duo) devices upstream.
            await hid.sendTouch(type: phase, x: x, y: y, screenWidth: 0, screenHeight: 0, edge: edge)
        case let .multitouch(phase, x1, y1, x2, y2):
            await hid.sendMultiTouch(type: phase, x1: x1, y1: y1, x2: x2, y2: y2, screenWidth: 0, screenHeight: 0)
        case let .scroll(dx, dy, x, y):
            await hid.sendScroll(dx: dx, dy: dy, anchorX: x, anchorY: y, screenWidth: 0, screenHeight: 0)
        case let .key(phase, usage):
            await hid.sendKey(type: phase, usage: usage)
        case let .button(name):
            await hid.sendButton(button: name, deviceUDID: udid)
        case let .configure(scale, fps, orientation):
            if let orientation {
                guard await hid.sendOrientation(orientation: orientation) else {
                    return Self.fail(id, "orientation failed")
                }
                // Frames are rotated for display from now on; tell OxiMux so
                // its pointer mapping and layout switch in the same beat.
                stream.configure(scale: scale, fps: fps, orientation: orientation)
                Wire.sendEvent(["event": "orientation", "value": orientation])
            } else {
                stream.configure(scale: scale, fps: fps, orientation: nil)
            }
            Self.reply(id, ["ok": true])
        case .pause:
            stream.setPaused(true)
        case .resume:
            stream.setPaused(false)
        case .screenshot:
            let stream = self.stream
            Task.detached {
                guard let png = stream.snapshotPNG() else { return Self.fail(id, "no frame yet") }
                Self.reply(id, ["png_base64": png.base64EncodedString()])
            }
        case .axDescribe, .axFrontmost:
            let udid = self.udid
            let frontmost = command == .axFrontmost
            Task.detached { await Self.axQuery(udid: udid, id: id, frontmost: frontmost) }
        case .memoryWarning:
            await hid.simulateMemoryWarning()
            Self.reply(id, ["ok": true])
        }
    }

    /// AX queries block on the simulator for up to a second or two; they run
    /// on a global queue and answer by id.
    private static func axQuery(udid: String, id: Int?, frontmost: Bool) async {
        let result: Result<Data, Error> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Result {
                    if frontmost {
                        let info = try AccessibilityBridge.shared.frontmostApp(udid: udid)
                        return try JSONSerialization.data(withJSONObject: info)
                    }
                    return try AccessibilityBridge.shared.describeUI(udid: udid)
                })
            }
        }
        switch result {
        case .success(let data): if let id { Wire.sendResponse(id: id, rawResult: data) }
        case .failure(let error): fail(id, error.localizedDescription)
        }
    }

    static func reply(_ id: Int?, _ result: [String: Any]) {
        guard let id else { return }
        Wire.sendEvent(["event": "response", "id": id, "ok": true, "result": result])
    }

    /// A failed command: a `response` when it had an id, else an `error` event.
    static func fail(_ id: Int?, _ message: String) {
        guard let id else {
            Wire.sendEvent(["event": "error", "message": message])
            return
        }
        Wire.sendEvent(["event": "response", "id": id, "ok": false, "error": message])
    }
}
