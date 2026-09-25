import Foundation

// oximux-sim-helper --udid <UDID> [--scale 0.5] [--fps 30] [--quality 0.7]
//
// Streams one booted simulator as JPEG frames on stdout and applies input
// commands from stdin (see Wire.swift). Exits when stdin closes.

if CommandLine.arguments.contains("--version") {
    print("oximux-sim-helper \(helperVersion)")
    exit(0)
}

Wire.claimStdout()
signal(SIGPIPE, SIG_IGN)

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let udid = argValue("--udid"), !udid.isEmpty else {
    fputs("usage: oximux-sim-helper --udid <UDID> [--scale S] [--fps N] [--quality Q]\n", stderr)
    exit(64)
}
/// A numeric flag inside `range`, else `fallback` (rejects NaN/inf/0 fps).
func argNumber(_ name: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
    guard let v = argValue(name).flatMap(Double.init), range.contains(v) else { return fallback }
    return v
}
let scale = argNumber("--scale", 0.05...1, 1.0)
let fps = argNumber("--fps", 1...60, 30)
let quality = argNumber("--quality", 0.1...1, 0.7)

let stream = FrameStream(udid: udid, scale: scale, fps: fps, quality: quality)
let commands = Commands(udid: udid, stream: stream)
commands.run()

Task {
    do {
        try await stream.start()
        Wire.sendEvent(["event": "ready", "udid": udid, "pid": Int(getpid())])
    } catch {
        Wire.sendEvent(["event": "error", "message": error.localizedDescription])
        exit(3)
    }
}

dispatchMain()
