import Foundation

// oximux-sim-helper --udid <UDID> [--scale 0.5] [--fps 30] [--quality 0.7] [--orientation 1]
// oximux-sim-helper --conformance
// oximux-sim-helper --version
//
// Streams one booted simulator as JPEG frames on stdout and applies input
// commands from stdin (see oximux/PROTOCOL.md). Exits when stdin closes.

if CommandLine.arguments.contains("--version") {
    print("oximux-sim-helper \(helperVersion)")
    exit(0)
}

Wire.claimStdout()
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--conformance") {
    Conformance.run()
}

/// Announce ourselves, then report a startup failure the host can act on
/// (`reason` is machine-readable) and exit.
func fatal(_ reason: String, _ message: String) -> Never {
    Wire.sendEvent(["event": "fatal", "reason": reason, "message": message])
    exit(3)
}

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// A numeric flag inside `range`, else `fallback` (rejects NaN/inf/0 fps).
func argNumber(_ name: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
    guard let v = argValue(name).flatMap(Double.init), range.contains(v) else { return fallback }
    return v
}

// `hello` is always the first message, so OxiMux can check the protocol
// version before trusting anything else on the pipe.
let developerDir = Xcode.developerDir()
Wire.sendEvent(["event": "hello", "proto": protocolVersion, "version": helperVersion, "xcode": developerDir])

guard let udid = argValue("--udid"), !udid.isEmpty else {
    fatal("bad_args", "usage: oximux-sim-helper --udid <UDID> [--scale S] [--fps N] [--quality Q] [--orientation 1-4]")
}
let scale = argNumber("--scale", 0.05...1, 1.0)
let fps = argNumber("--fps", 1...60, 30)
let quality = argNumber("--quality", 0.1...1, 0.7)
let orientation = UInt32(argNumber("--orientation", 1...4, 1))

// The private frameworks are dlopen'd from the active Xcode. When that fails
// (no Xcode, a moved framework in a new Xcode) upstream code fails later with
// a vague "device not found"; name the real cause instead.
SimFrameworks.load()
if NSClassFromString("SimServiceContext") == nil {
    fatal("framework_load_failed", "CoreSimulator did not load from \(developerDir)")
}
if dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") == nil {
    fatal("framework_load_failed", "SimulatorKit did not load from \(developerDir)")
}

let stream = FrameStream(udid: udid, scale: scale, fps: fps, quality: quality, orientation: orientation)
let commands = Commands(udid: udid, stream: stream)
commands.run()

Task {
    do {
        try await stream.start()
    } catch let error as NSError {
        // FrameCapture's codes: 1 = no such device, 2 = not booted.
        let reason = error.domain == "FrameCapture" && error.code == 1 ? "device_not_found"
            : error.domain == "FrameCapture" && error.code == 2 ? "device_not_booted"
            : "capture_failed"
        fatal(reason, error.localizedDescription)
    }
    // Ordering contract: `ready` precedes every `size` and frame.
    Wire.sendEvent(["event": "ready", "udid": udid, "pid": Int(getpid()), "orientation": orientation])
    stream.startEncoding()
}

dispatchMain()
