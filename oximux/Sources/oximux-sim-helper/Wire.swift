import Foundation

/// The helper's only I/O channel to OxiMux: framed messages on the ORIGINAL
/// stdout, length-prefixed JSON commands on stdin. No sockets, ever.
///
/// Outbound framing: `[u8 kind][u32 LE len][payload]`.
/// - `Kind.frame`: `[u32 LE width][u32 LE height][JPEG bytes]`
/// - `Kind.event`: UTF-8 JSON object (`ready`, `size`, `response`, `error`, `log`)
///
/// Inbound framing: `[u32 LE len][UTF-8 JSON object]`.
enum Wire {
    enum Kind: UInt8 {
        case frame = 1
        case event = 2
    }

    /// Private duplicate of the original stdout. Set up by `claimStdout()`.
    private static var frameFd: Int32 = -1
    private static let lock = NSLock()

    /// The upstream capture/HID code logs with `print`, which writes to fd 1.
    /// Keep those bytes out of the binary frame stream: move the real stdout
    /// to a private fd, then point fd 1 at stderr so stray prints land in
    /// OxiMux's log instead of corrupting the framing. Must run before any
    /// upstream code executes.
    static func claimStdout() {
        frameFd = dup(STDOUT_FILENO)
        precondition(frameFd >= 0, "dup(stdout) failed")
        _ = fcntl(frameFd, F_SETFD, FD_CLOEXEC)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    static func sendFrame(width: Int, height: Int, jpeg: Data) {
        send(.frame, framePayload(width: width, height: height, jpeg: jpeg))
    }

    static func sendEvent(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(.event, data)
    }

    /// An event whose `result` is already-serialized JSON (AX dumps), spliced
    /// in without a decode/re-encode round trip.
    static func sendResponse(id: Int, rawResult: Data) {
        var data = Data("{\"event\":\"response\",\"id\":\(id),\"ok\":true,\"result\":".utf8)
        data.append(rawResult)
        data.append(Data("}".utf8))
        send(.event, data)
    }

    /// `[u8 kind][u32 LE len]` — the outbound message header. Pure, so the
    /// framing is unit-tested without touching file descriptors.
    static func header(_ kind: Kind, payloadCount: Int) -> Data {
        var header = Data(capacity: 5)
        header.append(kind.rawValue)
        appendU32(&header, UInt32(payloadCount))
        return header
    }

    /// `[u32 LE width][u32 LE height][JPEG bytes]` — a frame payload.
    static func framePayload(width: Int, height: Int, jpeg: Data) -> Data {
        var payload = Data(capacity: 8 + jpeg.count)
        appendU32(&payload, UInt32(width))
        appendU32(&payload, UInt32(height))
        payload.append(jpeg)
        return payload
    }

    private static func send(_ kind: Kind, _ payload: Data) {
        let header = header(kind, payloadCount: payload.count)
        lock.lock()
        defer { lock.unlock() }
        // A failed write means OxiMux is gone; stdin EOF will end us shortly,
        // but don't wait for it.
        if !writeAll(header) || !writeAll(payload) { _exit(0) }
    }

    private static func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var ptr = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(frameFd, ptr, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                ptr += n
                left -= n
            }
            return true
        }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    enum Inbound {
        case command([String: Any])
        /// A well-framed body that is not a JSON object: reply and keep going.
        case malformed
        /// EOF or broken framing (zero/oversized length): the caller exits.
        case closed
    }

    /// Blocking read of one inbound command.
    static func readCommand() -> Inbound {
        guard let lenBytes = readExactly(4) else { return .closed }
        let len = lenBytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard len > 0, len <= maxCommandBytes, let body = readExactly(Int(len)) else { return .closed }
        return decodeBody(body)
    }

    /// Largest inbound command body; a bigger length prefix is broken framing.
    static let maxCommandBytes: UInt32 = 1 << 20

    /// One inbound body → a command, or `.malformed` when it is not a JSON object.
    static func decodeBody(_ body: Data) -> Inbound {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .malformed
        }
        return .command(object)
    }

    private static func readExactly(_ count: Int) -> Data? {
        var out = Data(count: count)
        var got = 0
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                let n = read(STDIN_FILENO, base + got, count - got)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? out : nil
    }
}
