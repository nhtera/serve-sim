import AVFoundation
import CoreMediaIO
import Foundation

// oximux-device-capture --device <UDID> [--scale 0.05-1] [--fps 1-60] [--quality 0.1-1] [--format jpeg|avcc]
// oximux-device-capture --version
// oximux-device-capture --conformance [--fatal <reason>]   (no phone; for tests)
//
// Streams one USB iPhone's screen (macOS shows it as a screen-capture device)
// as JPEG frames or H.264 on stdout, in the sim helper's protocol v2, and
// records it to a .mov on request. View-only: input commands are answered
// "unsupported". Exits when stdin closes. See oximux/PROTOCOL.md, "Device
// capture helper".
//
// Ships inside its own app bundle, "OxiMux Device Capture.app", which alone
// carries the camera entitlement: OxiMux spawns it with responsibility
// disclaimed, so the camera grant belongs to this bundle and never reaches
// OxiMux's terminals or agents.

if CommandLine.arguments.contains("--version") {
    print("oximux-device-capture \(helperVersion)")
    exit(0)
}

Wire.claimStdout()
signal(SIGPIPE, SIG_IGN)

// Before the camera, the phone and the arguments: no device, no prompt.
if CommandLine.arguments.contains("--conformance") {
    CaptureConformance.run(Array(CommandLine.arguments.dropFirst()))
}

/// Report a startup failure the host can act on (`reason` is machine
/// readable), then exit.
func fatal(_ reason: String, _ message: String) -> Never {
    Wire.sendEvent(["event": "fatal", "reason": reason, "message": message])
    _exit(3)
}

let options: CaptureOptions
switch CaptureOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): options = parsed
case .failure(let error):
    Wire.sendEvent(["event": "hello", "proto": protocolVersion, "version": helperVersion, "xcode": ""])
    fatal("bad_args", "\(error.message); usage: oximux-device-capture --device <UDID> [--scale S] [--fps N] [--quality Q] [--format jpeg|avcc]")
}

// `hello` first, as the sim helper does, so OxiMux checks the protocol before
// trusting anything else on the pipe.
Wire.sendEvent(["event": "hello", "proto": protocolVersion, "version": helperVersion, "xcode": ""])

// Screen-capture devices are hidden until a process opts in.
var allow: UInt32 = 1
var property = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
let optIn = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
if optIn != 0 {
    // Tells "the phone never appeared" from "macOS refused the opt-in".
    FileHandle.standardError.write(Data("oximux-device-capture: screen-capture opt-in failed (OSStatus \(optIn))\n".utf8))
}

let access = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .video) { ok in
    granted = ok
    access.signal()
}
access.wait()
guard granted else {
    fatal("camera_denied", "macOS denied camera access to OxiMux Device Capture (System Settings › Privacy & Security › Camera)")
}

/// The phone, by its UDID: AVFoundation's `uniqueID` is devicectl's
/// `hardwareProperties.udid` (measured). It appears within a second of the
/// opt-in; give it a few.
func findDevice(_ udid: String, within seconds: Double) -> AVCaptureDevice? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        if let device = session.devices.first(where: { $0.uniqueID == udid }) { return device }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return nil
}

guard let device = findDevice(options.udid, within: 8) else {
    fatal("device_not_connected", "the iPhone is not connected over USB (or not trusted, or locked at its first unlock)")
}

let stream = DeviceStream(options: options)
do {
    try stream.start(device: device)
} catch DeviceStream.StartError.busy(let why) {
    fatal("device_busy", why)
} catch {
    fatal("capture_failed", "\(error)")
}
// Ordering contract: `ready` precedes every `size` and frame. A phone's
// orientation is whatever its screen shows; frames arrive already rotated.
Wire.sendEvent(["event": "ready", "udid": options.udid, "pid": Int(getpid()), "orientation": 1])
stream.startEncoding()
DeviceCommands(stream: stream).run()

// The unplug can come as a notification or not at all (it is delivered
// through this run loop, and only while one runs): check the phone itself
// every second too.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if !device.isConnected {
        Shutdown.now(stream.recorder, code: 3, fatal: DeviceStream.unplugged)
    }
}
// A run loop, not `dispatchMain()`: CoreMediaIO and AVFoundation deliver
// device changes through the main run loop (it serves the main queue too).
RunLoop.main.run()
