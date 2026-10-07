import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// A USB iPhone's screen → (dedupe) → scale → JPEG or H.264 → stdout, at most
/// `fps` frames a second, plus an optional recording.
///
/// Unlike a simulator, a phone's frames already show its screen the way it
/// is held: a landscape app arrives as a landscape buffer. So nothing is
/// rotated here; `size` carries the **displayed** size, and an `orientation`
/// event (1 portrait, 3 landscape) follows whenever the aspect flips. The
/// phone sends about 60 frames a second whatever the screen does, so a still
/// screen is caught by comparing pixels (`Still`), like the sim helper's idle
/// re-emits.
///
/// Capture calls back on its own queue; only the newest buffer is kept in a
/// slot, and one encode thread drains it, so a slow encode drops frames
/// instead of queueing them.
final class DeviceStream: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum StartError: Error {
        /// Another app holds the device (QuickTime's movie recording, say).
        case busy(String)
        case failed(String)
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "oximux.device-capture.capture")
    private let cond = NSCondition()
    // Guarded by `cond`.
    private var latest: CVPixelBuffer?
    private var paused = false
    private var forceNext = true
    private var scale: Double
    private var fps: Double
    private var format: StreamFormat
    /// The newest frame captured, for screenshots (never an old one: each
    /// buffer held is one fewer in the capture pool).
    private var lastCaptured: CVPixelBuffer?
    private let quality: Double
    // Encode thread only.
    private var stillGate = StillGate()
    private var lastSize = (0, 0)
    private var landscape = false
    private lazy var h264 = H264Output()
    private var encodeFailures = 0
    private static let maxEncodeFailures = 3
    /// The recording in progress, fed from the capture queue.
    let recorder = Recorder()
    private var deviceID = ""

    init(options: CaptureOptions) {
        scale = options.scale
        fps = options.fps
        format = options.format
        quality = options.quality
    }

    func start(device: AVCaptureDevice) throws {
        deviceID = device.uniqueID
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch let error as NSError where error.code == AVError.deviceAlreadyUsedByAnotherSession.rawValue
            || error.code == AVError.deviceInUseByAnotherApplication.rawValue {
            throw StartError.busy("another app is using the iPhone's screen (close QuickTime's recording, say)")
        }
        guard session.canAddInput(input) else { throw StartError.busy("the iPhone's screen cannot be captured right now") }
        session.addInput(input)
        // BGRA: what the shared encoders take (H264Output copies BGRA rows).
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw StartError.failed("the capture output was refused") }
        session.addOutput(output)
        // Delivered through the main run loop (main.swift runs it).
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, (note.object as? AVCaptureDevice)?.uniqueID == self.deviceID else { return }
            Shutdown.now(self.recorder, code: 3, fatal: Self.unplugged)
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Shutdown.now(self.recorder, code: 3, fatal: ("capture_failed", error?.localizedDescription ?? "capture stopped"))
        }
        session.startRunning()
        guard session.isRunning else { throw StartError.failed("the capture session did not start") }
    }

    static let unplugged = (reason: "device_not_connected", message: "the iPhone was unplugged")

    func startEncoding() {
        let thread = Thread { [weak self] in self?.encodeLoop() }
        thread.name = "oximux-device-encode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // Capture queue.
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            recorder.append(sample)
            cond.lock()
            latest = buffer
            lastCaptured = buffer
            cond.signal()
            cond.unlock()
        }
    }

    // Capture queue: a frame AVFoundation dropped (late, or out of buffers).
    func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        // Late frames are expected (`alwaysDiscardsLateVideoFrames`); running
        // out of buffers is worth knowing.
        if let reason = reason as? String, reason != (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) {
            FileHandle.standardError.write(Data("oximux-device-capture: frame dropped: \(reason)\n".utf8))
        }
    }

    func setPaused(_ value: Bool) {
        cond.lock()
        paused = value
        if !value { forceNext = true }
        cond.signal()
        cond.unlock()
        // Stop paying for frames nobody shows (a recording still needs them).
        output.connection(with: .video)?.isEnabled = !value || recorder.isRecording
    }

    /// Apply new stream settings; any change forces the next frame, which in
    /// `avcc` is a key frame.
    func configure(scale: Double?, fps: Double?, format: StreamFormat?) {
        cond.lock()
        if let scale, scale > 0, scale <= 1 { self.scale = scale }
        if let fps, fps >= 1, fps <= 60 { self.fps = fps }
        if let format { self.format = format }
        forceNext = true
        cond.unlock()
    }

    /// The current screen as a full-resolution PNG, for screenshots.
    func snapshotPNG() -> Data? {
        cond.lock()
        let buffer = lastCaptured
        cond.unlock()
        guard let buffer else { return nil }
        return Self.withPixels(buffer, scale: 1) { Self.encodeImage($0, type: "public.png", quality: nil) }?.0
    }

    /// Keep frames flowing while recording, even when paused.
    func recordingChanged() {
        cond.lock()
        let paused = self.paused
        cond.unlock()
        output.connection(with: .video)?.isEnabled = !paused || recorder.isRecording
    }

    private func encodeLoop() {
        var due = 0.0
        // A bare Thread has no autorelease pool: one per frame, or every
        // ImageIO/CoreGraphics temporary leaks for the helper's lifetime.
        while true { autoreleasepool { encodeOnce(due: &due) } }
    }

    private func encodeOnce(due: inout Double) {
        cond.lock()
        while latest == nil || paused { cond.wait() }
        let interval = 1.0 / fps
        let wait = min(due - ProcessInfo.processInfo.systemUptime, interval)
        if wait > 0 {
            cond.unlock()
            Thread.sleep(forTimeInterval: wait)
            return
        }
        let buffer = latest!
        latest = nil
        let force = forceNext
        forceNext = false
        let (scale, format, frameRate) = (self.scale, self.format, self.fps)
        cond.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        // Paced whether or not it is sent: a still screen is looked at `fps`
        // times a second, not at the phone's 60.
        due = max(due + interval, now - interval)
        let thumb = Self.withPixels(buffer, scale: 1) { Still.thumbnail($0) } ?? []
        let decision = stillGate.decide(thumb, now: now, force: force)
        if decision == .skip { return }
        var keyframe = force
        // A settle frame stays on screen: in `avcc`, a sharp key frame.
        let sharp = decision == .settle && format == .avcc
        keyframe = keyframe || sharp

        let size = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        if size != lastSize {
            lastSize = size
            Wire.sendEvent(["event": "size", "width": size.0, "height": size.1])
            let nowLandscape = size.0 > size.1
            if nowLandscape != landscape {
                landscape = nowLandscape
                Wire.sendEvent(["event": "orientation", "value": nowLandscape ? 3 : 1])
            }
            keyframe = true // a new size needs a new decoder
        }
        switch format {
        case .avcc:
            do {
                guard let packet = try Self.withPixels(buffer, scale: scale, {
                    try h264.encode($0, keyframe: keyframe, fps: frameRate, sharp: sharp)
                }) else {
                    if keyframe && !sharp { cond.lock(); forceNext = true; cond.unlock() }
                    return
                }
                encodeFailures = 0
                if let description = packet.description {
                    Wire.sendVideo(width: packet.width, height: packet.height, tag: .description, data: description)
                }
                Wire.sendVideo(width: packet.width, height: packet.height, tag: packet.keyframe ? .keyframe : .delta, data: packet.avcc)
            } catch {
                encodeFailures += 1
                cond.lock()
                forceNext = true
                let fallBack = encodeFailures >= Self.maxEncodeFailures && self.format == .avcc
                if fallBack { self.format = .mjpeg }
                cond.unlock()
                if fallBack {
                    encodeFailures = 0
                    Wire.sendEvent(["event": "format", "value": StreamFormat.mjpeg.wire,
                                    "message": "H.264 encoding failed (\(error)); streaming JPEG"])
                }
                return
            }
        case .mjpeg:
            guard let (jpeg, w, h) = Self.withPixels(buffer, scale: scale, {
                Self.encodeImage($0, type: "public.jpeg", quality: quality)
            }) else { return }
            Wire.sendFrame(width: w, height: h, jpeg: jpeg)
        }
        stillGate.sent(thumb, now: now, as: decision)
    }

    /// Hand `body` the BGRA pixels of `buffer` at `scale`: the locked pixel
    /// memory itself, or one vImage (NEON) downscale. Valid only inside `body`.
    static func withPixels<T>(_ buffer: CVPixelBuffer, scale: Double, _ body: (vImage_Buffer) throws -> T?) rethrows -> T? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        guard scale < 0.999 else { return try body(src) }
        let w = max(2, Int((Double(src.width) * scale).rounded()))
        let h = max(2, Int((Double(src.height) * scale).rounded()))
        guard let scratch = malloc(w * 4 * h) else { return nil }
        defer { free(scratch) }
        var dest = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        guard vImageScale_ARGB8888(&src, &dest, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return try body(dest)
    }

    static func encodeImage(_ pixels: vImage_Buffer, type: String, quality: Double?) -> (Data, Int, Int)? {
        let size = pixels.rowBytes * Int(pixels.height)
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels.data, size: size, releaseData: { _, _, _ in }),
              let image = CGImage(
                width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixels.rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data, image.width, image.height) : nil
    }
}
