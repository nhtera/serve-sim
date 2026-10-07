import AVFoundation
import Foundation

/// A recording of the phone's screen into a `.mov` (H.264, re-encoded from the
/// capture's BGRA frames; measured at about +7 points of CPU while it runs).
/// Fed from the capture queue; started and stopped from the command queue.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?
    private var started = false
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer != nil
    }

    /// Arm a recording into `url`; the writer is sized from the first frame.
    func start(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil else { return "already recording" }
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            return "could not create the movie: \(error.localizedDescription)"
        }
        self.url = url
        started = false
        firstTime = .invalid
        lastTime = .invalid
        return nil
    }

    // Capture queue.
    func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if input == nil {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
            ]
            let made = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            made.expectsMediaDataInRealTime = true
            guard writer.canAdd(made) else { return }
            writer.add(made)
            input = made
        }
        guard let input else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            started = true
            firstTime = time
        }
        // A rotated phone changes the frame size; one movie keeps one size,
        // so frames of another size are skipped rather than corrupting it.
        if input.isReadyForMoreMediaData, writer.status == .writing {
            input.append(sample)
            lastTime = time
        }
    }

    /// How a recording ended.
    enum Finished {
        case done(path: String, millis: Int)
        case failed(String)
    }

    /// Finish the movie: its path and length, or why not.
    @discardableResult
    func finish() -> Finished {
        lock.lock()
        let (writer, input, url, started, first, last) = (self.writer, self.input, self.url, self.started, firstTime, lastTime)
        self.writer = nil
        self.input = nil
        self.url = nil
        lock.unlock()
        guard let writer, let url else { return .failed("not recording") }
        guard started, let input else {
            writer.cancelWriting()
            return .failed("no frame was recorded (is the phone's screen on?)")
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            return .failed("the movie was not finalized: \(writer.error?.localizedDescription ?? "timed out")")
        }
        let millis = first.isValid && last.isValid ? Int((CMTimeGetSeconds(last) - CMTimeGetSeconds(first)) * 1000) : 0
        return .done(path: url.path, millis: max(0, millis))
    }
}
