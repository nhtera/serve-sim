import Foundation

/// Maps inbound JSON commands onto the upstream HID / capture / AX code.
///
/// Every command may carry an integer `id`; commands that return data
/// (`ax_describe`, `ax_frontmost`, `screenshot`, `ping`) answer with a
/// `response` event carrying the same id. Touch coordinates are normalized
/// 0...1 in the device's PORTRAIT framebuffer space, whatever the current
/// orientation: HID ignores rotation, so the caller maps display → portrait.
///
/// Every number from stdin is untrusted: coordinates are clamped to 0...1,
/// deltas must be finite, and integer codes are clamped into `UInt32` —
/// a bare `UInt32(_:)` traps on out-of-range input and would kill the helper.
final class Commands: @unchecked Sendable {
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

    /// Runs until stdin closes, then exits the process. Commands are handled
    /// in arrival order so a touch `begin`/`move`/`end` sequence stays ordered.
    func run() {
        let queue = AsyncStream<[String: Any]>.makeStream()
        Thread {
            while true {
                // A bare Thread has no autorelease pool; JSONSerialization
                // autoreleases on every parse.
                let next = autoreleasepool { Wire.readCommand() }
                switch next {
                case .command(let command): queue.continuation.yield(command)
                case .malformed: Wire.sendEvent(["event": "error", "message": "malformed command"])
                // Parent gone (or the framing broke): never outlive OxiMux.
                case .closed: _exit(0)
                }
            }
        }.start()
        Task {
            for await command in queue.stream { await self.handle(command) }
        }
    }

    private func handle(_ c: [String: Any]) async {
        let id = c["id"] as? Int
        let cmd = c["cmd"] as? String ?? ""
        if cmd != "ping", cmd != "pause", cmd != "resume", cmd != "configure" {
            do { try await hidReady.value } catch {
                fail(id, "hid setup failed: \(error.localizedDescription)")
                return
            }
        }
        let (w, h) = (Int(u32(c["w"])), Int(u32(c["h"])))
        switch cmd {
        case "ping":
            reply(id, ["pong": true])
        case "touch":
            await hid.sendTouch(type: str(c["phase"]), x: unit(c["x"]), y: unit(c["y"]),
                                screenWidth: w, screenHeight: h, edge: u32(c["edge"]))
        case "multitouch":
            await hid.sendMultiTouch(type: str(c["phase"]), x1: unit(c["x1"]), y1: unit(c["y1"]),
                                     x2: unit(c["x2"]), y2: unit(c["y2"]), screenWidth: w, screenHeight: h)
        case "scroll":
            await hid.sendScroll(dx: dbl(c["dx"]), dy: dbl(c["dy"]),
                                 anchorX: c["x"] == nil ? nil : unit(c["x"]), anchorY: c["y"] == nil ? nil : unit(c["y"]),
                                 screenWidth: w, screenHeight: h)
        case "key":
            await hid.sendKey(type: str(c["phase"]), usage: u32(c["usage"]))
        case "button":
            await hid.sendButton(button: str(c["name"]), deviceUDID: udid)
        case "orientation":
            let ok = await hid.sendOrientation(orientation: u32(c["value"]))
            if ok { reply(id, ["ok": true]) } else { fail(id, "orientation failed") }
        case "pause":
            stream.setPaused(true)
        case "resume":
            stream.setPaused(false)
        case "configure":
            stream.configure(scale: (c["scale"] as? NSNumber)?.doubleValue, fps: (c["fps"] as? NSNumber)?.doubleValue)
        case "screenshot":
            guard let png = stream.snapshotPNG() else { return fail(id, "no frame yet") }
            reply(id, ["png_base64": png.base64EncodedString()])
        case "ax_describe", "ax_frontmost":
            await axQuery(id: id, frontmost: cmd == "ax_frontmost")
        default:
            fail(id, "unknown command \(cmd)")
        }
    }

    /// AX queries block on the simulator; keep them off the command queue.
    private func axQuery(id: Int?, frontmost: Bool) async {
        let udid = self.udid
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

    private func reply(_ id: Int?, _ result: [String: Any]) {
        guard let id else { return }
        Wire.sendEvent(["event": "response", "id": id, "ok": true, "result": result])
    }

    private func fail(_ id: Int?, _ message: String) {
        var event: [String: Any] = ["event": "response", "ok": false, "error": message]
        if let id { event["id"] = id }
        Wire.sendEvent(event)
    }

    private func str(_ v: Any?) -> String { v as? String ?? "" }
    /// A finite number, else 0.
    private func dbl(_ v: Any?) -> Double {
        let d = (v as? NSNumber)?.doubleValue ?? 0
        return d.isFinite ? d : 0
    }
    /// A normalized coordinate, clamped to 0...1.
    private func unit(_ v: Any?) -> Double { min(1, max(0, dbl(v))) }
    /// An integer code clamped into UInt32 (never traps).
    private func u32(_ v: Any?) -> UInt32 { UInt32(min(Double(UInt32.max), max(0, dbl(v).rounded()))) }
}
