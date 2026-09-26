import Accelerate
import Foundation
import XCTest
@testable import oximux_sim_helper

/// The command parser is the helper's input contract with OxiMux. These pin
/// its validation and clamping; OxiMux checks its own encoder against the
/// shipped binary through `--conformance`, which echoes `canonical`.
final class ProtocolTests: XCTestCase {
    private func parse(_ json: String) -> Result<ParsedCommand, ParsedCommand.ParseError> {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ParsedCommand.parse(object)
    }

    func testTouchClampsCoordinatesAndDefaultsEdge() {
        XCTAssertEqual(try parse(#"{"cmd":"touch","phase":"begin","x":1.5,"y":-2}"#).get(),
                       .touch(phase: "begin", x: 1, y: 0, edge: 0))
    }

    func testTouchRejectsUnknownPhase() {
        guard case .failure(.invalid) = parse(#"{"cmd":"touch","phase":"down","x":0,"y":0}"#) else {
            return XCTFail("expected invalid phase")
        }
    }

    func testIntegerCodesNeverTrap() {
        XCTAssertEqual(try parse(#"{"cmd":"key","phase":"down","usage":1e300}"#).get(),
                       .key(phase: "down", usage: UInt32.max))
        XCTAssertEqual(try parse(#"{"cmd":"key","phase":"up","usage":-5}"#).get(),
                       .key(phase: "up", usage: 0))
    }

    func testConfigureDropsOutOfRangeValuesButRejectsBadOrientation() {
        XCTAssertEqual(try parse(#"{"cmd":"configure","scale":2,"fps":30}"#).get(),
                       .configure(scale: nil, fps: 30, orientation: nil, format: nil))
        guard case .failure = parse(#"{"cmd":"configure","orientation":7}"#) else {
            return XCTFail("orientation 7 must be rejected")
        }
        XCTAssertEqual(try parse(#"{"cmd":"configure","orientation":3}"#).get(),
                       .configure(scale: nil, fps: nil, orientation: 3, format: nil))
    }

    func testConfigureFormatIsJpegOrAvcc() {
        XCTAssertEqual(try parse(#"{"cmd":"configure","format":"avcc"}"#).get(),
                       .configure(scale: nil, fps: nil, orientation: nil, format: .avcc))
        XCTAssertEqual(ParsedCommand.configure(scale: nil, fps: nil, orientation: nil, format: .mjpeg).canonical["format"] as? String,
                       "jpeg")
        guard case .failure = parse(#"{"cmd":"configure","format":"hevc"}"#) else {
            return XCTFail("an unknown format must be rejected")
        }
        XCTAssertFalse(ParsedCommand.configure(scale: nil, fps: nil, orientation: nil, format: .avcc).needsHID)
    }

    func testBooleansAreNotNumbers() {
        XCTAssertEqual(try parse(#"{"cmd":"configure","scale":true}"#).get(),
                       .configure(scale: nil, fps: nil, orientation: nil, format: nil))
    }

    func testButtonsAreAllowListed() {
        XCTAssertEqual(try parse(#"{"cmd":"button","name":"home"}"#).get(), .button(name: "home"))
        guard case .failure = parse(#"{"cmd":"button","name":"volume_up"}"#) else {
            return XCTFail("unknown button must be rejected")
        }
    }

    func testUnknownCommand() {
        XCTAssertEqual(parse(#"{"cmd":"launch_missiles"}"#), .failure(.unknownCommand("launch_missiles")))
    }

    func testOnlyInputCommandsWaitForHID() {
        XCTAssertTrue(ParsedCommand.touch(phase: "begin", x: 0, y: 0, edge: 0).needsHID)
        XCTAssertTrue(ParsedCommand.configure(scale: nil, fps: nil, orientation: 3, format: nil).needsHID)
        XCTAssertFalse(ParsedCommand.configure(scale: 0.5, fps: nil, orientation: nil, format: nil).needsHID)
        XCTAssertFalse(ParsedCommand.screenshot.needsHID)
        XCTAssertFalse(ParsedCommand.axDescribe.needsHID)
        XCTAssertTrue(ParsedCommand.memoryWarning.needsHID)
    }

    func testCanonicalOmitsAbsentOptionals() {
        let c = ParsedCommand.scroll(dx: 1, dy: -2, x: nil, y: 0.5).canonical
        XCTAssertEqual(c["cmd"] as? String, "scroll")
        XCTAssertNil(c["x"])
        XCTAssertEqual(c["y"] as? Double, 0.5)
    }

    /// Measured on Xcode 26.3 (see FrameStream): 3 → CCW, 4 → CW, 2 → 180°.
    func testRotationPerOrientation() {
        XCTAssertNil(FrameStream.rotation(for: 1))
        XCTAssertEqual(FrameStream.rotation(for: 2), UInt8(kRotate180DegreesClockwise))
        XCTAssertEqual(FrameStream.rotation(for: 3), UInt8(kRotate90DegreesCounterClockwise))
        XCTAssertEqual(FrameStream.rotation(for: 4), UInt8(kRotate90DegreesClockwise))
    }
}
