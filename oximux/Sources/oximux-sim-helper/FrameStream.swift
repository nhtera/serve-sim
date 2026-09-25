import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Accelerate

/// Capture → (dedupe) → scale → rotate → JPEG → stdout, at most `fps` frames
/// a second.
///
/// The simulator framebuffer never rotates: in landscape the UI is drawn
/// sideways inside the portrait buffer. Frames are rotated here, by the
/// device orientation OxiMux commanded, so OxiMux paints them as-is (GPUI
/// cannot rotate an image). Measured on Xcode 26.3: orientation 3 puts the
/// UI's top at the buffer's right edge (rotate 90° counter-clockwise), 4 at
/// its left edge (90° clockwise), 2 upside down (180°).
///
/// `FrameCapture` (upstream) calls back on its own queue for every
/// simulator frame plus a 5 fps idle re-emit. We keep only the newest buffer
/// in a slot and let one encoder thread drain it, so a slow encode drops
/// frames instead of queueing them. Idle re-emits of unchanged pixels are
/// skipped (byte compare against the last sent buffer) so a still screen
/// costs OxiMux zero decodes.
final class FrameStream: @unchecked Sendable {
    private let capture = FrameCapture()
    private let udid: String
    private let cond = NSCondition()
    /// Serializes "orientation changed" against frame emission, so every frame
    /// written after the `orientation` event carries the new rotation and none
    /// written before it does. Held while writing; never inside `cond`.
    private let emitLock = NSLock()
    // Guarded by `cond`.
    private var latest: CVPixelBuffer?
    private var paused = false
    private var forceNext = true
    private var scale: Double
    private var fps: Double
    private var lastSent: CVPixelBuffer?
    private var lastSize: (Int, Int) = (0, 0)
    private var orientation: UInt32 = 1
    private let quality: Double
    private let rateTicks = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(udid: String, scale: Double, fps: Double, quality: Double, orientation: UInt32) {
        self.udid = udid
        self.scale = scale
        self.fps = fps
        self.quality = quality
        self.orientation = (1...4).contains(orientation) ? orientation : 1
    }

    /// Start capturing. Frames are buffered but not encoded until
    /// `startEncoding()`, so nothing reaches stdout before `ready`.
    func start() async throws {
        try await capture.start(deviceUDID: udid) { [weak self] buffer, _ in
            self?.offer(buffer)
        }
        // One consumer applies rate changes in order, always reading the
        // latest desired state — so a quick pause→resume can never land as
        // "resumed encoder, paused capture" (a frozen stream).
        Task { [weak self, capture, rateTicks] in
            for await _ in rateTicks.stream {
                guard let rate = self?.currentRate() else { return }
                // 25% headroom: two equal-rate throttles in series beat
                // against each other and lose ~2 fps; a slightly faster
                // capture always has a fresh frame at the encoder's deadline.
                await capture.setCaptureRate(maxFPS: min(60, rate.fps * 1.25), paused: rate.paused)
            }
        }
        rateTicks.continuation.yield()
    }

    /// Begin emitting `size` and frames. Called once, right after `ready`.
    func startEncoding() {
        let thread = Thread { [weak self] in self?.encodeLoop() }
        thread.name = "oximux-sim-encode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func offer(_ buffer: CVPixelBuffer) {
        cond.lock()
        latest = buffer
        cond.signal()
        cond.unlock()
    }

    func setPaused(_ value: Bool) {
        cond.lock()
        paused = value
        if !value { forceNext = true }
        cond.signal()
        cond.unlock()
        syncCaptureRate()
    }

    /// Apply new stream settings. A new orientation also emits the
    /// `orientation` event, ordered against frames (see `emitLock`).
    func configure(scale: Double?, fps: Double?, orientation: UInt32?) {
        emitLock.lock()
        cond.lock()
        if let scale, scale > 0, scale <= 1 { self.scale = scale }
        if let fps, fps >= 1, fps <= 60 { self.fps = fps }
        let rotated = orientation.map { (1...4).contains($0) } ?? false
        if let orientation, rotated { self.orientation = orientation }
        forceNext = true
        cond.unlock()
        if let orientation, rotated { Wire.sendEvent(["event": "orientation", "value": orientation]) }
        emitLock.unlock()
        syncCaptureRate()
    }

    private func currentRate() -> (fps: Double, paused: Bool) {
        cond.lock()
        defer { cond.unlock() }
        return (fps, paused)
    }

    /// Mirror the encoder's rate and pause into capture, so a paused or
    /// slow stream also stops paying for full-frame copies it would drop.
    private func syncCaptureRate() {
        rateTicks.continuation.yield()
    }

    /// The current screen as a full-resolution PNG, rotated for display like
    /// the stream, for screenshots.
    func snapshotPNG() -> Data? {
        cond.lock()
        let buffer = latest ?? lastSent
        let orientation = self.orientation
        cond.unlock()
        guard let buffer else { return nil }
        return Self.encodeImage(buffer, scale: 1, orientation: orientation, type: "public.png", quality: nil)?.0
    }

    private func encodeLoop() {
        // Monotonic seconds: a wall-clock step (manual change, NTP after
        // wake) must never stall the stream.
        var due = 0.0
        // A bare Thread has no autorelease pool: without one per iteration,
        // every ImageIO/CoreGraphics temporary leaks for the helper's lifetime.
        while true { autoreleasepool { encodeOnce(due: &due) } }
    }

    private func encodeOnce(due: inout Double) {
        cond.lock()
        while latest == nil || paused { cond.wait() }
        let interval = 1.0 / fps
        let now = ProcessInfo.processInfo.systemUptime
        let wait = min(due - now, interval)
        if wait > 0 {
            // Sleep off the rate cap, still holding out for the newest frame.
            cond.unlock()
            Thread.sleep(forTimeInterval: wait)
            return
        }
        let buffer = latest!
        latest = nil
        let force = forceNext
        forceNext = false
        let scale = self.scale
        let orientation = self.orientation
        let previous = lastSent
        cond.unlock()

        if !force, let previous, Self.samePixels(previous, buffer) { return }
        // Deadline pacing: sleeping overshoot doesn't accumulate into a lower rate.
        due = max(due + interval, ProcessInfo.processInfo.systemUptime - interval)
        guard let (jpeg, outW, outH) = Self.encodeImage(
            buffer, scale: scale, orientation: orientation, type: "public.jpeg", quality: quality)
        else { return }

        emitLock.lock()
        defer { emitLock.unlock() }
        cond.lock()
        let stale = self.orientation != orientation
        if stale { forceNext = true } // re-encode this screen with the new rotation
        cond.unlock()
        if stale { return }
        let size = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        if size != lastSize {
            lastSize = size
            Wire.sendEvent(["event": "size", "width": size.0, "height": size.1])
        }
        Wire.sendFrame(width: outW, height: outH, jpeg: jpeg)
        cond.lock()
        lastSent = buffer
        cond.unlock()
    }

    /// Whole-buffer compare. ~12 MB for a Pro Max at native size; runs only on
    /// the ≤ 5 fps idle path in practice, since a changing screen differs early.
    private static func samePixels(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetBytesPerRow(a) == CVPixelBufferGetBytesPerRow(b)
        else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else {
            return false
        }
        return memcmp(pa, pb, CVPixelBufferGetBytesPerRow(a) * CVPixelBufferGetHeight(a)) == 0
    }

    /// Encode `buffer` (BGRA) at `scale`, rotated for `orientation`, without
    /// copying the full-size frame: the CGImage wraps the locked pixel memory
    /// (or a small scratch buffer) directly; downscaling and rotation are one
    /// vImage (NEON) pass each.
    private static func encodeImage(
        _ buffer: CVPixelBuffer, scale: Double, orientation: UInt32, type: String, quality: Double?
    ) -> (Data, Int, Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var scratch: UnsafeMutableRawPointer?
        var rotated: UnsafeMutableRawPointer?
        defer { free(scratch); free(rotated) }
        var pixels = src
        if scale < 0.999 {
            let w = max(1, Int((Double(src.width) * scale).rounded()))
            let h = max(1, Int((Double(src.height) * scale).rounded()))
            scratch = malloc(w * 4 * h)
            guard scratch != nil else { return nil }
            pixels = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            guard vImageScale_ARGB8888(&src, &pixels, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
        }
        if let turn = rotation(for: orientation) {
            let quarter = turn != UInt8(kRotate180DegreesClockwise)
            let w = Int(quarter ? pixels.height : pixels.width)
            let h = Int(quarter ? pixels.width : pixels.height)
            rotated = malloc(w * 4 * h)
            guard rotated != nil else { return nil }
            var dest = vImage_Buffer(data: rotated, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var black: [UInt8] = [0, 0, 0, 0xFF]
            guard vImageRotate90_ARGB8888(&pixels, &dest, turn, &black, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
            pixels = dest
        }
        let size = pixels.rowBytes * Int(pixels.height)
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels.data, size: size, releaseData: { _, _, _ in }),
              let image = CGImage(
                width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixels.rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        // The image borrows `pixels`; encode before the lock/scratch go away.
        guard let data = encode(image, type: type, quality: quality) else { return nil }
        return (data, image.width, image.height)
    }

    /// The vImage rotation that turns the portrait framebuffer into the
    /// display image for `orientation`, or nil for portrait.
    static func rotation(for orientation: UInt32) -> UInt8? {
        switch orientation {
        case 2: return UInt8(kRotate180DegreesClockwise)
        case 3: return UInt8(kRotate90DegreesCounterClockwise)
        case 4: return UInt8(kRotate90DegreesClockwise)
        default: return nil
        }
    }

    private static func encode(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
