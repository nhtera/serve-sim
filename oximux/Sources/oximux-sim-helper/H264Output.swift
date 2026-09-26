import Accelerate
import CoreVideo
import Foundation

/// The `avcc` output: display-ready pixels (already scaled and rotated by
/// `FrameStream`) → a private pooled IOSurface buffer → upstream's
/// `H264Encoder` → one encoded picture.
///
/// Used only from the encode thread, one frame at a time: the thread waits
/// for each encode, so a slow encode drops frames at `FrameStream`'s slot,
/// exactly like the JPEG path. The copy into our own buffer matters: the
/// capture buffer wraps SimulatorKit's recycled framebuffer, and the pixels
/// handed in may be scratch memory freed as soon as we return.
final class H264Output {
    struct Packet {
        let width: Int
        let height: Int
        /// The avcC record (SPS/PPS). Sent before every key frame, so OxiMux
        /// can (re)build its decoder at any key frame: after a resume, a
        /// format switch, or a reset of its own.
        let description: Data?
        let keyframe: Bool
        /// Length-prefixed AVCC NAL units.
        let avcc: Data
    }

    enum Failure: Error, CustomStringConvertible {
        case noBuffer
        case timedOut
        case encoder(Error)

        var description: String {
            switch self {
            case .noBuffer: return "could not allocate a pixel buffer"
            case .timedOut: return "the encoder did not answer"
            case .encoder(let error): return "\(error)"
            }
        }
    }

    private let encoder = H264Encoder()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var lastDescription: Data?

    /// Encode `pixels` (BGRA). `nil` when VideoToolbox dropped the frame
    /// under pressure, which is not an error.
    func encode(_ pixels: vImage_Buffer, keyframe: Bool) throws -> Packet? {
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        guard let buffer = copy(pixels, width: width, height: height) else { throw Failure.noBuffer }
        guard let encoded = try encodeWaiting(buffer, keyframe: keyframe) else { return nil }
        let isKey = encoded.kind == .keyframe
        // Upstream hands out the record once per encoder session; keep it.
        if let fresh = encoded.description { lastDescription = fresh }
        return Packet(width: width, height: height, description: isKey ? lastDescription : nil,
                      keyframe: isKey, avcc: encoded.avcc)
    }

    /// Bridge the encoder actor to this thread. Bounded, so a wedged
    /// VideoToolbox can never stall the stream for good: the caller falls
    /// back to JPEG.
    private func encodeWaiting(_ buffer: CVPixelBuffer, keyframe: Bool) throws -> H264Encoder.Encoded? {
        final class Box: @unchecked Sendable {
            var result: Result<H264Encoder.Encoded?, Error> = .success(nil)
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let pixelBuffer = buffer
        Task { [encoder] in
            do {
                box.result = .success(try await encoder.encode(pixelBuffer, forceKeyframe: keyframe))
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else { throw Failure.timedOut }
        do {
            return try box.result.get()
        } catch {
            throw Failure.encoder(error)
        }
    }

    /// `pixels` into a fresh IOSurface-backed BGRA buffer from our pool.
    private func copy(_ pixels: vImage_Buffer, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }
        // OxiMux paints the decoded picture with a BT.601 YCbCr → RGB
        // matrix; ask the encoder to convert with the same one, or saturated
        // colors shift (VideoToolbox otherwise picks BT.709 for HD sizes).
        CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let base = CVPixelBufferGetBaseAddress(dst), let src = pixels.data else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        let rowBytes = min(width * 4, pixels.rowBytes, dstStride)
        for row in 0..<height {
            memcpy(base + row * dstStride, src + row * pixels.rowBytes, rowBytes)
        }
        return dst
    }
}
