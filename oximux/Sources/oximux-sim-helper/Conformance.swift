import Foundation

/// `oximux-sim-helper --conformance`: a simulator-free mode that lets OxiMux
/// test its protocol code against the binary that actually ships.
///
/// It writes a fixed sequence (a `hello`, one synthetic frame and video
/// message, then one of
/// every event shape), then echoes each inbound command as the helper parsed
/// it — `{"event":"parsed","command":{…canonical…}}`, or
/// `{"event":"parsed","error":"…"}` when it was rejected — until stdin closes.
/// Nothing here touches CoreSimulator, so it runs on any Mac, including CI.
enum Conformance {
    /// The synthetic frame: 3×2, with a payload that is only the JPEG start
    /// and end markers. OxiMux checks the framing, not the image.
    static let frameWidth = 3
    static let frameHeight = 2
    static let frameBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    /// The synthetic `video` message: a description whose payload is only an
    /// avcC record's first four bytes (version 1, High profile, level 3.1).
    static let videoBytes = Data([0x01, 0x64, 0x00, 0x1F])

    static func run() -> Never {
        Wire.sendEvent(["event": "hello", "proto": protocolVersion, "version": helperVersion, "xcode": "conformance"])
        Wire.sendFrame(width: frameWidth, height: frameHeight, jpeg: frameBytes)
        Wire.sendVideo(width: frameWidth, height: frameHeight, tag: .description, data: videoBytes)
        Wire.sendEvent(["event": "ready", "udid": "conformance", "pid": 0, "orientation": 1])
        Wire.sendEvent(["event": "size", "width": 1206, "height": 2622])
        Wire.sendEvent(["event": "orientation", "value": 4])
        Wire.sendEvent(["event": "response", "id": 1, "ok": true, "result": ["pong": true]])
        Wire.sendResponse(id: 2, rawResult: Data(#"[{"AXLabel":"raw"}]"#.utf8))
        Wire.sendEvent(["event": "response", "id": 3, "ok": false, "error": "example failure"])
        Wire.sendEvent(["event": "error", "message": "example error"])
        Wire.sendEvent(["event": "format", "value": "jpeg", "message": "example fallback"])
        Wire.sendEvent(["event": "fatal", "reason": "framework_load_failed", "message": "example fatal"])
        Wire.sendEvent(["event": "conformance_ready"])
        while true {
            switch autoreleasepool(invoking: { Wire.readCommand() }) {
            case .command(let raw):
                switch ParsedCommand.parse(raw) {
                case .success(let command):
                    var echo: [String: Any] = ["event": "parsed", "command": command.canonical]
                    if let id = raw["id"] as? Int { echo["id"] = id }
                    Wire.sendEvent(echo)
                case .failure(let error):
                    Wire.sendEvent(["event": "parsed", "error": error.description])
                }
            case .malformed:
                Wire.sendEvent(["event": "error", "message": "malformed command"])
            case .closed:
                exit(0)
            }
        }
    }
}
