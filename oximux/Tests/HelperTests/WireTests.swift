import Foundation
import XCTest
@testable import oximux_sim_helper

/// Golden bytes for the stdio framing OxiMux decodes (`crates/simulator`).
/// A change here is a protocol change: bump the helper version and update
/// OxiMux's decoder in the same release.
final class WireTests: XCTestCase {
    func testHeaderIsKindThenLittleEndianLength() {
        XCTAssertEqual([UInt8](Wire.header(.frame, payloadCount: 0x0102_0304)), [1, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual([UInt8](Wire.header(.event, payloadCount: 5)), [2, 5, 0, 0, 0])
    }

    func testFramePayloadIsWidthHeightThenJpeg() {
        let payload = Wire.framePayload(width: 603, height: 1311, jpeg: Data([0xFF, 0xD8]))
        XCTAssertEqual([UInt8](payload), [0x5B, 0x02, 0, 0, 0x1F, 0x05, 0, 0, 0xFF, 0xD8])
    }

    func testDecodeBodyAcceptsJsonObject() {
        guard case .command(let cmd) = Wire.decodeBody(Data(#"{"cmd":"pause"}"#.utf8)) else {
            return XCTFail("expected a command")
        }
        XCTAssertEqual(cmd["cmd"] as? String, "pause")
    }

    func testDecodeBodyRejectsNonObjects() {
        for body in ["[1,2]", "\"x\"", "not json", ""] {
            guard case .malformed = Wire.decodeBody(Data(body.utf8)) else {
                return XCTFail("\(body) should be malformed")
            }
        }
    }

    func testCommandCapIsOneMebibyte() {
        XCTAssertEqual(Wire.maxCommandBytes, 1 << 20)
    }
}
