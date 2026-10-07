import AVFoundation
import Foundation

/// A recording of the phone's screen into a `.mov` (H.264, re-encoded from the
/// capture's BGRA frames; measured at about +7 points of CPU while it runs).
/// Fed from the capture queue; started and stopped from the command queue
/// and, at exit, from whichever path ends the helper.
///
/// A writer that failed is never called again (AVAssetWriter raises on a call
/// in the wrong state, which would take the whole helper down): the failure
/// is kept and reported by [`finish`].
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    /// Held for a whole [`finish`], so a second caller (an unplug racing a
    /// `record_stop`, say) waits for the movie instead of exiting under it.
    private let finishing = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?
    private var size: (Int, Int)?
    private var started = false
    private var failure: String?
    private var firstTime = CMTime.invalid
    private var lastTime = CMTime.invalid

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer != nil
    }

    /// Arm a recording into `url` (validated by `RecordPath`); the writer is
    /// sized from the first frame.
    func start(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil else { return "already recording" }
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            return "could not create the movie: \(error.localizedDescription)"
        }
        self.url = url
        size = nil
        started = false
        failure = nil
        firstTime = .invalid
        lastTime = .invalid
        return nil
    }

    // Capture queue.
    func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, failure == nil, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let frame = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        if input == nil {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: frame.0,
                AVVideoHeightKey: frame.1,
            ]
            let made = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            made.expectsMediaDataInRealTime = true
            guard writer.canAdd(made) else { return fail("the movie refused its video track") }
            writer.add(made)
            input = made
            size = frame
        }
        guard let input else { return }
        if !started {
            guard writer.startWriting() else { return fail(writer.error?.localizedDescription ?? "the movie could not be written") }
            writer.startSession(atSourceTime: time)
            started = true
            firstTime = time
        }
        // One movie keeps one size: frames of another (a phone turned
        // mid-recording) are skipped rather than corrupting it.
        guard size.map({ $0 == frame }) ?? false else { return }
        guard writer.status == .writing else { return fail(writer.error?.localizedDescription ?? "the movie stopped being written") }
        if input.isReadyForMoreMediaData {
            input.append(sample)
            lastTime = time
        }
    }

    /// Called with `lock` held: keep why, and never touch the writer again.
    private func fail(_ why: String) {
        if failure == nil { failure = why }
    }

    /// How a recording ended.
    enum Finished: Equatable {
        case done(path: String, millis: Int)
        case failed(String)
    }

    /// Finish the movie: its path and length, or why not. A call while
    /// another is finishing waits for it (and then finds nothing recording).
    @discardableResult
    func finish() -> Finished {
        finishing.lock(); defer { finishing.unlock() }
        lock.lock()
        let (writer, input, url, started, failure, first, last) = (self.writer, self.input, self.url, self.started, self.failure, firstTime, lastTime)
        self.writer = nil
        self.input = nil
        self.url = nil
        lock.unlock()
        guard let writer, let url else { return .failed("not recording") }
        if let failure {
            if writer.status == .writing { writer.cancelWriting() }
            return .failed(failure)
        }
        guard started, let input, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
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
