import XCTest

/// The runner: one UI test that parks for up to a day, serving commands on
/// the phone's loopback until OxiMux sends `shutdown` (or stops the test).
///
/// OxiMux starts it with `xcodebuild test-without-building`, passing a fresh
/// token per launch as `TEST_RUNNER_OXIMUX_TOKEN` (XCTest hands it in as
/// `OXIMUX_TOKEN`), and reads the port from the `OXIMUX_RUNNER_LISTENING`
/// line. The token is never logged.
final class RunnerSession: XCTestCase {
    /// The longest a runner stays up.
    static let park: TimeInterval = 24 * 3600

    override func setUp() {
        super.setUp()
        // A failed XCTest call is a command's error, never the end of the run.
        continueAfterFailure = true
    }

    func testRun() throws {
        let token = ProcessInfo.processInfo.environment["OXIMUX_TOKEN"] ?? ""
        guard token.utf8.count >= 32 else {
            return XCTFail("OXIMUX_TOKEN must be set (TEST_RUNNER_OXIMUX_TOKEN), at least 32 characters")
        }
        // Off the runner's own blank screen, to the phone's home screen.
        XCUIDevice.shared.press(.home)
        let shutdown = expectation(description: "shutdown")
        let commands = Commands(onShutdown: { shutdown.fulfill() })
        let server = HTTPServer(token: token) { commands.handle($0) }
        try server.start(
            ready: { port in
                print("OXIMUX_RUNNER_LISTENING port=\(port)")
                fflush(stdout)
                NSLog("OXIMUX_RUNNER_LISTENING port=%ld", Int(port))
            },
            failed: { error in
                print("OXIMUX_RUNNER_FAILED \(error)")
                shutdown.fulfill()
            })
        // Waiting runs the main run loop, which is where commands execute.
        _ = XCTWaiter().wait(for: [shutdown], timeout: Self.park)
        server.stop()
    }

    /// Two snapshot misses XCTest reports while an app redraws are expected
    /// here; a failure while a command runs is that command's error
    /// (`IssueSink`); anything else is recorded as usual.
    override func record(_ issue: XCTIssue) {
        let benign = ["Failed to get matching snapshot", "Failed to get matching snapshots"]
        if benign.contains(where: { issue.compactDescription.contains($0) }) {
            return
        }
        if IssueSink.take(issue.compactDescription) {
            return
        }
        super.record(issue)
    }
}
