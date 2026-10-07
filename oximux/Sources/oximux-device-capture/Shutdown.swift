import Foundation

/// The one way the helper ends once it streams. An unplug, a capture error
/// and stdin closing can all arrive together; whichever comes first finishes
/// the recording and exits, and every later caller parks here until the
/// process is gone — none can exit under a movie still being written.
enum Shutdown {
    /// Never unlocked.
    private static let lock = NSLock()

    static func now(_ recorder: Recorder, code: Int32, fatal: (reason: String, message: String)? = nil) -> Never {
        lock.lock()
        // A movie cut short by an unplug is still a movie: say where it is.
        if case let .done(path, millis) = recorder.finish() {
            Wire.sendEvent(["event": "recorded", "path": path, "duration_ms": millis])
        }
        if let fatal {
            Wire.sendEvent(["event": "fatal", "reason": fatal.reason, "message": fatal.message])
        }
        // No atexit teardown while the capture and encode threads still run.
        _exit(code)
    }
}
