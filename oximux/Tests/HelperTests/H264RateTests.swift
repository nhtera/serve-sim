import XCTest
@testable import oximux_sim_helper

/// The H.264 budget follows the picture, within bounds.
final class H264RateTests: XCTestCase {
    func testBitrateScalesWithPixelsAndFps() {
        let half = H264Output.bitrate(width: 603, height: 1311, fps: 30)
        let full = H264Output.bitrate(width: 1206, height: 2622, fps: 30)
        XCTAssertEqual(half, Int(603.0 * 1311 * 30 * H264Output.bitsPerPixel))
        XCTAssertEqual(full, Int(1206.0 * 2622 * 30 * H264Output.bitsPerPixel))
        XCTAssertEqual(H264Output.bitrate(width: 1206, height: 2622, fps: 15), full / 2, accuracy: 1)
    }

    func testBitrateStaysInBounds() {
        XCTAssertEqual(H264Output.bitrate(width: 100, height: 100, fps: 1), H264Output.bitrateRange.lowerBound)
        XCTAssertEqual(H264Output.bitrate(width: 2064, height: 2752, fps: 60), H264Output.bitrateRange.upperBound)
    }
}
