import Accelerate
import AVFoundation
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

    func testRecordingsStayInTheNamedFolder() throws {
        let dir = try scratchFolder()
        XCTAssertNotNil(RecordPath.validate("\(dir)/rec.mov"))
        for bad in ["rec.mov", "\(dir)/rec.mp4", "\(dir)/../rec.mov", "\(dir)/./rec.mov", "/nonexistent-dir/rec.mov"] {
            XCTAssertNil(RecordPath.validate(bad), bad)
        }
        // Nothing already there is replaced.
        FileManager.default.createFile(atPath: "\(dir)/taken.mov", contents: Data())
        XCTAssertNil(RecordPath.validate("\(dir)/taken.mov"))
        // A folder that cannot be written is refused up front.
        let locked = "\(dir)/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o555])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        XCTAssertNil(RecordPath.validate("\(locked)/rec.mov"))
    }

    /// A fresh empty folder for one test.
    private func scratchFolder() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oximux-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }

    /// A BGRA frame of one grey level, stamped `seconds` into the stream.
    private func frame(_ w: Int, _ h: Int, grey: UInt8, at seconds: Double) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(grey), CVPixelBufferGetBytesPerRow(buffer) * h)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// A recording from synthetic frames: a movie of their length, and a
    /// frame of another size (a phone turned) is skipped, not fatal.
    func testARecordingRoundTrips() throws {
        let path = "\(try scratchFolder())/rec.mov"
        let recorder = Recorder()
        XCTAssertNil(recorder.start(try XCTUnwrap(RecordPath.validate(path))))
        XCTAssertEqual(recorder.start(URL(fileURLWithPath: path)), "already recording")
        for i in 0..<10 {
            recorder.append(try frame(64, 128, grey: UInt8(i * 20), at: Double(i) / 30))
        }
        recorder.append(try frame(128, 64, grey: 0, at: 10.0 / 30)) // turned: skipped
        guard case let .done(done, millis) = recorder.finish() else { return XCTFail("not finished") }
        XCTAssertEqual(done, path)
        // Back-to-back frames outrun a real-time writer, which drops some:
        // the length is the last one it took.
        XCTAssert((1...300).contains(millis), "\(millis)")
        XCTAssertGreaterThan(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int), 0)
        XCTAssertEqual(recorder.finish(), .failed("not recording"))
    }

    /// Two paths ending the helper at once (an unplug and a `record_stop`):
    /// the second waits for the movie the first is finishing.
    func testASecondFinishWaitsForTheFirst() throws {
        let path = "\(try scratchFolder())/rec.mov"
        let recorder = Recorder()
        XCTAssertNil(recorder.start(URL(fileURLWithPath: path)))
        for i in 0..<5 { recorder.append(try frame(64, 128, grey: 90, at: Double(i) / 30)) }
        let results = [Recorder.Finished?](unsafeUninitializedCapacity: 2) { buffer, count in
            DispatchQueue.concurrentPerform(iterations: 2) { buffer[$0] = recorder.finish() }
            count = 2
        }
        XCTAssertEqual(results.compactMap { $0 }.filter { if case .done = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(results.contains(.failed("not recording")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "finished before either returned")
    }

    /// A recording that never saw a frame fails cleanly, without touching a
    /// writer that never started.
    func testARecordingWithoutFramesFailsCleanly() throws {
        let recorder = Recorder()
        XCTAssertNil(recorder.start(URL(fileURLWithPath: "\(try scratchFolder())/rec.mov")))
        guard case .failed = recorder.finish() else { return XCTFail("should fail") }
    }

    /// The stream's own downscale and still-image encode.
    func testAFrameIsScaledAndEncoded() throws {
        let sample = try frame(64, 128, grey: 200, at: 0)
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let half = try XCTUnwrap(DeviceStream.withPixels(buffer, scale: 0.5) { DeviceStream.encodeImage($0, type: "public.jpeg", quality: 0.7) })
        XCTAssertEqual(half.1, 32)
        XCTAssertEqual(half.2, 64)
        XCTAssertFalse(half.0.isEmpty)
    }

    /// Thumbnails `n` cells long, all at `level`.
    private func thumb(_ level: UInt8, _ n: Int = 16) -> [UInt8] { [UInt8](repeating: level, count: n) }

    /// A still screen sends nothing; a change goes out at once; once the
    /// screen comes to rest, one settle frame shows where — the tail of a
    /// fade too small to count as a change on its own.
    func testAStillScreenSettlesOnceAndThenStaysQuiet() {
        var gate = StillGate()
        var t = 0.0
        func step(_ level: UInt8, force: Bool = false) -> StillGate.Decision {
            let d = gate.decide(thumb(level), now: t, force: force)
            if d != .skip { gate.sent(thumb(level), now: t, as: d) }
            t += 1.0 / 30
            return d
        }
        XCTAssertEqual(step(100), .send) // the first frame
        XCTAssertEqual(step(100), .skip)
        XCTAssertEqual(step(160), .send) // a change
        // A fade's tail: each step under the change threshold.
        for level: UInt8 in [150, 140, 135, 132] { XCTAssertEqual(step(level), .skip) }
        var settled = 0
        for _ in 0..<30 { if step(132) == .settle { settled += 1 } }
        XCTAssertEqual(settled, 1, "one settle frame, at rest")
        for _ in 0..<120 { XCTAssertEqual(step(132), .skip, "quiet once settled") }
        XCTAssertEqual(step(132, force: true), .send)
    }

    /// A small change made while the screen sat still (a toggle's colour)
    /// is sent by the idle refresh, at most every two seconds.
    func testASmallChangeOnAStillScreenIsRefreshed() {
        var gate = StillGate()
        gate.sent(thumb(100), now: 0, as: .settle)
        XCTAssertEqual(gate.decide(thumb(100), now: 0.5, force: false), .skip)
        XCTAssertEqual(gate.decide(thumb(120), now: 1.0, force: false), .skip, "not before the idle refresh")
        XCTAssertEqual(gate.decide(thumb(120), now: 2.1, force: false), .settle)
        // Noise under the steady limit is never refreshed.
        gate.sent(thumb(120), now: 2.1, as: .settle)
        XCTAssertEqual(gate.decide(thumb(126), now: 9, force: false), .skip)
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

    /// Lossy-stream noise on a still screen reads as the same screen; a
    /// caret-sized mark does not.
    func testAStillScreenSurvivesNoiseButNotACaret() {
        let (w, h) = (64, 64)
        func picture(_ paint: (UnsafeMutablePointer<UInt8>) -> Void) -> [UInt8] {
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
            defer { bytes.deallocate() }
            memset(bytes, 0xC0, w * h * 4)
            paint(bytes)
            return Still.thumbnail(vImage_Buffer(data: bytes, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4))
        }
        let still = picture { _ in }
        XCTAssertEqual(still.count, 64)
        // Every byte nudged by up to ±51, as measured on a phone.
        var seed: UInt32 = 7
        let noisy = picture { p in
            for i in 0..<(w * h * 4) {
                seed = seed &* 1_103_515_245 &+ 12345
                p[i] = UInt8(clamping: 0xC0 + Int(seed >> 16) % 103 - 51)
            }
        }
        XCTAssertTrue(Still.looksSame(still, noisy))
        // A dark caret, 6 pixels wide and 20 tall.
        let caret = picture { p in
            for y in 20..<40 { for x in 10..<16 { for c in 0..<3 { p[(y * w + x) * 4 + c] = 0x10 } } }
        }
        XCTAssertFalse(Still.looksSame(still, caret))
        // A rotated phone (another size) is never the same screen.
        XCTAssertFalse(Still.looksSame(still, Array(still.prefix(32))))
    }
}
