import Accelerate
import XCTest
@testable import oximux_device_capture

final class DeviceCaptureTests: XCTestCase {
    func testArgumentsParseLikeTheSimHelper() throws {
        let parsed = try CaptureOptions.parse(["--device", "00008130-001234CC2183001C", "--scale", "0.001", "--fps", "500", "--format", "avcc"]).get()
        XCTAssertEqual(parsed.udid, "00008130-001234CC2183001C")
        XCTAssertEqual(parsed.scale, 0.05, "a tiny scale is clamped, never full resolution")
        XCTAssertEqual(parsed.fps, 30, "out of range falls back")
        XCTAssertEqual(parsed.format, .avcc)
        for bad in [[], ["--device"], ["--device", ""], ["--device", "abc;rm -rf /"], ["--device", "../x"]] {
            if case .success = CaptureOptions.parse(bad) { XCTFail("\(bad) accepted") }
        }
    }

    func testRecordingsStayInTheNamedFolder() {
        let dir = FileManager.default.temporaryDirectory.path
        XCTAssertNotNil(RecordPath.validate("\(dir)/rec.mov"))
        for bad in ["rec.mov", "\(dir)/rec.mp4", "\(dir)/../rec.mov", "\(dir)/./rec.mov", "/nonexistent-dir/rec.mov"] {
            XCTAssertNil(RecordPath.validate(bad), bad)
        }
    }

    /// View-only: every input and accessibility command says so; capture
    /// control works without a phone (no stream: pause/resume do nothing).
    func testInputIsUnsupported() {
        let commands: [[String: Any]] = [
            ["cmd": "touch", "phase": "begin", "x": 0.5, "y": 0.5],
            ["cmd": "multitouch", "phase": "begin", "x1": 0, "y1": 0, "x2": 1, "y2": 1],
            ["cmd": "scroll", "dx": 1, "dy": 1],
            ["cmd": "key", "phase": "down", "usage": 4],
            ["cmd": "button", "name": "home"],
            ["cmd": "ax_describe"], ["cmd": "ax_frontmost"], ["cmd": "memory_warning"],
            ["cmd": "configure", "orientation": 3],
        ]
        for raw in commands {
            guard case .success(let parsed) = ParsedCommand.parse(raw) else { return XCTFail("\(raw) did not parse") }
            guard case .fail(let why) = DeviceCommands.answer(parsed, stream: nil) else { return XCTFail("\(raw) was not refused") }
            XCTAssertEqual(why, DeviceCommands.unsupported)
        }
        guard case .ok = DeviceCommands.answer(.ping, stream: nil) else { return XCTFail("ping") }
        guard case .ok = DeviceCommands.answer(.configure(scale: 0.5, fps: 30, orientation: nil, format: .avcc), stream: nil) else { return XCTFail("configure") }
        guard case .none = DeviceCommands.answer(.pause, stream: nil) else { return XCTFail("pause") }
    }

    /// The shared H.264 output encodes a synthetic BGRA picture: a key frame
    /// with its avcC description (the encoder this target links works).
    func testASyntheticFrameEncodes() throws {
        let (w, h) = (64, 128)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
        defer { bytes.deallocate() }
        memset(bytes, 0x80, w * h * 4)
        let pixels = vImage_Buffer(data: bytes, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        let packet = try H264Output().encode(pixels, keyframe: true, fps: 30)
        let unwrapped = try XCTUnwrap(packet)
        XCTAssertTrue(unwrapped.keyframe)
        XCTAssertNotNil(unwrapped.description)
        XCTAssertFalse(unwrapped.avcc.isEmpty)
    }
}
