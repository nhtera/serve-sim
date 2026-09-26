import Foundation

/// Protocol version announced in the first `hello` event. OxiMux refuses a
/// helper whose version it does not speak, so bump this on any wire change
/// that an older OxiMux would misread. See oximux/PROTOCOL.md.
let protocolVersion = 2

/// One inbound command after validation. Parsing is pure and separate from
/// execution so `--conformance` can echo exactly what the helper understood,
/// and OxiMux's tests can check their encoder against the shipped binary.
///
/// Every number from stdin is untrusted: coordinates are clamped to 0...1,
/// deltas must be finite, and integer codes are clamped into `UInt32` — a
/// bare `UInt32(_:)` traps on out-of-range input and would kill the helper.
enum ParsedCommand: Equatable {
    case ping
    /// Portrait-normalized coordinates, whatever the orientation: HID ignores
    /// rotation, so OxiMux maps display → portrait before sending.
    case touch(phase: String, x: Double, y: Double, edge: UInt32)
    case multitouch(phase: String, x1: Double, y1: Double, x2: Double, y2: Double)
    case scroll(dx: Double, dy: Double, x: Double?, y: Double?)
    case key(phase: String, usage: UInt32)
    case button(name: String)
    case configure(scale: Double?, fps: Double?, orientation: UInt32?, format: StreamFormat?)
    case pause
    case resume
    case screenshot
    case axDescribe
    case axFrontmost
    case memoryWarning

    static let touchPhases: Set<String> = ["begin", "move", "end"]
    static let keyPhases: Set<String> = ["down", "up"]
    static let buttons: Set<String> = ["home", "lock", "siri", "side_button", "app_switcher", "swipe_home"]

    /// Commands that drive the simulator's HID client and so must wait for
    /// its setup. Everything else (capture control, screenshots, AX) runs
    /// without it.
    var needsHID: Bool {
        switch self {
        // memory_warning needs the SimDevice that HID setup resolves.
        case .touch, .multitouch, .scroll, .key, .button, .memoryWarning: return true
        case .configure(_, _, let orientation, _): return orientation != nil
        default: return false
        }
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownCommand(String)
        case invalid(String)

        var description: String {
            switch self {
            case .unknownCommand(let name): return "unknown command \(name)"
            case .invalid(let why): return why
            }
        }
    }

    static func parse(_ c: [String: Any]) -> Result<ParsedCommand, ParseError> {
        let cmd = c["cmd"] as? String ?? ""
        switch cmd {
        case "ping": return .success(.ping)
        case "touch":
            let phase = str(c["phase"])
            guard touchPhases.contains(phase) else { return .failure(.invalid("touch phase must be begin|move|end")) }
            return .success(.touch(phase: phase, x: unit(c["x"]), y: unit(c["y"]), edge: u32(c["edge"])))
        case "multitouch":
            let phase = str(c["phase"])
            guard touchPhases.contains(phase) else { return .failure(.invalid("multitouch phase must be begin|move|end")) }
            return .success(.multitouch(phase: phase, x1: unit(c["x1"]), y1: unit(c["y1"]),
                                        x2: unit(c["x2"]), y2: unit(c["y2"])))
        case "scroll":
            return .success(.scroll(dx: dbl(c["dx"]), dy: dbl(c["dy"]),
                                    x: c["x"] == nil ? nil : unit(c["x"]), y: c["y"] == nil ? nil : unit(c["y"])))
        case "key":
            let phase = str(c["phase"])
            guard keyPhases.contains(phase) else { return .failure(.invalid("key phase must be down|up")) }
            return .success(.key(phase: phase, usage: u32(c["usage"])))
        case "button":
            let name = str(c["name"])
            guard buttons.contains(name) else { return .failure(.invalid("unknown button \(name)")) }
            return .success(.button(name: name))
        case "configure":
            let scale = num(c["scale"]).flatMap { $0 > 0 && $0 <= 1 ? $0 : nil }
            let fps = num(c["fps"]).flatMap { $0 >= 1 && $0 <= 60 ? $0 : nil }
            var orientation: UInt32?
            if c["orientation"] != nil {
                let o = u32(c["orientation"])
                guard (1...4).contains(o) else { return .failure(.invalid("orientation must be 1...4")) }
                orientation = o
            }
            var format: StreamFormat?
            if c["format"] != nil {
                guard let f = StreamFormat(wire: str(c["format"])) else {
                    return .failure(.invalid("format must be jpeg|avcc"))
                }
                format = f
            }
            return .success(.configure(scale: scale, fps: fps, orientation: orientation, format: format))
        case "pause": return .success(.pause)
        case "resume": return .success(.resume)
        case "screenshot": return .success(.screenshot)
        case "ax_describe": return .success(.axDescribe)
        case "ax_frontmost": return .success(.axFrontmost)
        case "memory_warning": return .success(.memoryWarning)
        default: return .failure(.unknownCommand(cmd))
        }
    }

    /// The command as the helper understood it: clamped values, defaults
    /// filled in, absent optionals omitted. `--conformance` echoes this.
    var canonical: [String: Any] {
        switch self {
        case .ping: return ["cmd": "ping"]
        case let .touch(phase, x, y, edge):
            return ["cmd": "touch", "phase": phase, "x": x, "y": y, "edge": edge]
        case let .multitouch(phase, x1, y1, x2, y2):
            return ["cmd": "multitouch", "phase": phase, "x1": x1, "y1": y1, "x2": x2, "y2": y2]
        case let .scroll(dx, dy, x, y):
            var out: [String: Any] = ["cmd": "scroll", "dx": dx, "dy": dy]
            if let x { out["x"] = x }
            if let y { out["y"] = y }
            return out
        case let .key(phase, usage): return ["cmd": "key", "phase": phase, "usage": usage]
        case let .button(name): return ["cmd": "button", "name": name]
        case let .configure(scale, fps, orientation, format):
            var out: [String: Any] = ["cmd": "configure"]
            if let format { out["format"] = format.wire }
            if let scale { out["scale"] = scale }
            if let fps { out["fps"] = fps }
            if let orientation { out["orientation"] = orientation }
            return out
        case .pause: return ["cmd": "pause"]
        case .resume: return ["cmd": "resume"]
        case .screenshot: return ["cmd": "screenshot"]
        case .axDescribe: return ["cmd": "ax_describe"]
        case .axFrontmost: return ["cmd": "ax_frontmost"]
        case .memoryWarning: return ["cmd": "memory_warning"]
        }
    }

    private static func str(_ v: Any?) -> String { v as? String ?? "" }
    /// A number (JSON bools are not numbers here), if finite.
    private static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    /// A finite number, else 0.
    private static func dbl(_ v: Any?) -> Double { num(v) ?? 0 }
    /// A normalized coordinate, clamped to 0...1.
    private static func unit(_ v: Any?) -> Double { min(1, max(0, dbl(v))) }
    /// An integer code clamped into UInt32 (never traps).
    private static func u32(_ v: Any?) -> UInt32 { UInt32(min(Double(UInt32.max), max(0, dbl(v).rounded()))) }
}

/// The stream encodings, by their names on the wire (`--format`,
/// `configure.format`). Upstream's `mjpeg` is our per-message JPEG `frame`;
/// `avcc` is the H.264 `video` message.
extension StreamFormat {
    init?(wire: String) {
        switch wire {
        case "jpeg": self = .mjpeg
        case "avcc": self = .avcc
        default: return nil
        }
    }

    var wire: String {
        switch self {
        case .mjpeg: return "jpeg"
        case .avcc: return "avcc"
        }
    }
}
