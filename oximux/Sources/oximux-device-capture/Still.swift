import Accelerate

/// Whether two frames show the same screen. A phone's frames are decoded from
/// its own lossy USB stream, so a still screen never repeats byte for byte
/// (measured on an iPhone 15 Pro Max home screen: about 3% of bytes differ,
/// by up to 51). Averaging 8×8 cells cancels that noise (cells then differ by
/// at most 22, mostly under 8), while a caret, a digit or a tap highlight —
/// several pixels wide at 3× — moves a cell far more.
///
/// The few columns and rows short of a whole cell at the right and bottom
/// edges (2 and 4 on a 1290×2796 screen) are not compared.
enum Still {
    static let cell = 8
    /// Largest cell difference still counted as the same screen.
    static let tolerance = 32

    /// One brightness value per 8×8 cell of a BGRA picture (rows and columns
    /// short of a whole cell are left out).
    static func thumbnail(_ pixels: vImage_Buffer) -> [UInt8] {
        let (w, h) = (Int(pixels.width) / cell, Int(pixels.height) / cell)
        guard w > 0, h > 0, let base = pixels.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var thumb = [UInt8](repeating: 0, count: w * h)
        for ty in 0..<h {
            for tx in 0..<w {
                var sum = 0
                for y in ty * cell..<(ty + 1) * cell {
                    var p = base + y * pixels.rowBytes + tx * cell * 4
                    for _ in 0..<cell {
                        sum += Int(p[0]) + 2 * Int(p[1]) + Int(p[2]) // B, 2G, R
                        p += 4
                    }
                }
                thumb[ty * w + tx] = UInt8(sum / (4 * cell * cell))
            }
        }
        return thumb
    }

    static func looksSame(_ a: [UInt8], _ b: [UInt8], within limit: Int = tolerance) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > limit { return false }
        return true
    }
}

/// Which frames of a phone's stream to send. A frame that looks like the last
/// one sent is skipped — but a change smaller than [`Still.tolerance`] must
/// not stay unsent for ever (the tail of a fade, a toggle's colour), so:
/// - after a change, once the screen has held still for [`settleAfter`], one
///   **settle** frame shows where it came to rest;
/// - while still, a frame still visibly off the last one sent goes out every
///   [`idleRefresh`] at most.
struct StillGate {
    /// How long the screen must hold still before its settle frame.
    static let settleAfter = 0.4
    static let idleRefresh = 2.0
    /// Frame-to-frame difference read as "holding still", and the drift from
    /// the last sent frame worth an idle refresh: above the stream's noise
    /// (cells mostly under 8, rarely to 22), below any real change.
    static let steady = 12

    enum Decision: Equatable {
        /// A change: send it.
        case send
        /// The still screen once more (`avcc`: a sharp key frame).
        case settle
        case skip
    }

    private var lastSent: [UInt8]?
    private var lastSentAt = 0.0
    private var previous: [UInt8]?
    private var stillSince = 0.0
    private var settlePending = false

    /// What to do with the frame whose thumbnail is `thumb`, seen at `now`
    /// (seconds); `force`: it must go out (a new setting, a resume).
    mutating func decide(_ thumb: [UInt8], now: Double, force: Bool) -> Decision {
        let moved = previous.map { !Still.looksSame($0, thumb, within: Self.steady) } ?? true
        if moved { stillSince = now }
        previous = thumb
        guard !force, let lastSent, Still.looksSame(lastSent, thumb) else { return .send }
        if settlePending && now - stillSince >= Self.settleAfter { return .settle }
        if now - lastSentAt >= Self.idleRefresh && !Still.looksSame(lastSent, thumb, within: Self.steady) { return .settle }
        return .skip
    }

    /// The frame decided `decision` went out.
    mutating func sent(_ thumb: [UInt8], now: Double, as decision: Decision) {
        lastSent = thumb
        lastSentAt = now
        settlePending = decision == .send
    }
}
