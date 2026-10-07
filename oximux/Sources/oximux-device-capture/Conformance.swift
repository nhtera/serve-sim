import Foundation

/// `oximux-device-capture --conformance`: a phone-free, camera-free stand-in
/// for a capture session, so OxiMux can drive the binary that ships — spawn,
/// handshake, every command, a recording — in CI.
///
/// It says `hello`, sends one synthetic frame, `ready` and `size`, then
/// answers commands as a view-only session with no frames would
/// (`DeviceCommands.answer`): `record_start` checks its path for real and
/// writes a stand-in movie there, `record_stop` reports it. Closing stdin
/// mid-recording reports the movie (`recorded`), as an unplug does.
/// `--fatal <reason>` instead ends right after `hello` with that `fatal`, so
/// OxiMux can check how it maps each one.
enum CaptureConformance {
    static let movie = Data("oximux conformance movie".utf8)

    static func run(_ args: [String]) -> Never {
        Wire.sendEvent(["event": "hello", "proto": protocolVersion, "version": helperVersion, "xcode": ""])
        if let i = args.firstIndex(of: "--fatal"), i + 1 < args.count {
            Wire.sendEvent(["event": "fatal", "reason": args[i + 1], "message": "conformance \(args[i + 1])"])
            _exit(3)
        }
        Wire.sendEvent(["event": "ready", "udid": "conformance", "pid": Int(getpid()), "orientation": 1])
        Wire.sendEvent(["event": "size", "width": 1290, "height": 2796])
        Wire.sendFrame(width: 3, height: 2, jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        var recording: String?
        while true {
            switch autoreleasepool(invoking: { Wire.readCommand() }) {
            case .command(let raw):
                let id = raw["id"] as? Int
                switch raw["cmd"] as? String {
                case "record_start":
                    guard recording == nil else { DeviceCommands.fail(id, "already recording"); continue }
                    guard let path = raw["path"] as? String, let url = RecordPath.validate(path),
                          FileManager.default.createFile(atPath: url.path, contents: movie) else {
                        DeviceCommands.fail(id, "record_start needs a new .mov, by an absolute path without . or .., in a folder that exists and can be written")
                        continue
                    }
                    recording = url.path
                    DeviceCommands.reply(id, ["ok": true])
                case "record_stop":
                    guard let path = recording else { DeviceCommands.fail(id, "not recording"); continue }
                    recording = nil
                    DeviceCommands.reply(id, ["ok": true, "path": path, "duration_ms": 0])
                default:
                    switch ParsedCommand.parse(raw) {
                    case .success(let command): DeviceCommands.respond(id, DeviceCommands.answer(command, stream: nil))
                    case .failure(let error): DeviceCommands.fail(id, error.description)
                    }
                }
            case .malformed:
                DeviceCommands.fail(nil, "malformed command")
            case .closed:
                if let path = recording {
                    Wire.sendEvent(["event": "recorded", "path": path, "duration_ms": 0])
                }
                _exit(0)
            }
        }
    }
}
