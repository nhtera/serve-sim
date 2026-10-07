import Foundation

/// The capture helper's command line, parsed purely (tested without a phone).
/// Same rules as the sim helper: `--scale` is clamped (a tiny scale never
/// silently becomes full resolution); other out-of-range values fall back to
/// their default.
struct CaptureOptions: Equatable {
    var udid: String
    var scale: Double = 1
    var fps: Double = 30
    var quality: Double = 0.7
    var format: StreamFormat = .mjpeg

    struct ParseError: Error, Equatable {
        let message: String
    }

    static func parse(_ args: [String]) -> Result<CaptureOptions, ParseError> {
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func number(_ name: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let v = value(name).flatMap(Double.init), v.isFinite, range.contains(v) else { return fallback }
            return v
        }
        // A UDID is hex and dashes (`00008130-001234CC2183001C`): nothing a
        // log line or a path could be bent with.
        guard let udid = value("--device"), !udid.isEmpty,
              udid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            return .failure(ParseError(message: "--device <UDID> is required (hex digits and dashes)"))
        }
        var options = CaptureOptions(udid: udid)
        options.scale = min(1, max(0.05, value("--scale").flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 1))
        options.fps = number("--fps", 1...60, 30)
        options.quality = number("--quality", 0.1...1, 0.7)
        options.format = value("--format").flatMap(StreamFormat.init(wire:)) ?? .mjpeg
        return .success(options)
    }
}

/// Where a recording may be written: a `.mov` inside the directory OxiMux
/// names, never anywhere `..` could lead.
enum RecordPath {
    static func validate(_ path: String) -> URL? {
        guard path.hasPrefix("/"), path.hasSuffix(".mov"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return url
    }
}
