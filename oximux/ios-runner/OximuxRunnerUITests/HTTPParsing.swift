import Foundation

/// The little HTTP/1.1 the runner speaks: a request head (method, target,
/// headers), a `Content-Length` body, a bearer token compared in constant
/// time, and a `Connection: close` reply. Pure Foundation.
enum HTTP {
    /// The longest request head accepted.
    static let maxHead = 16 << 10

    struct Head: Equatable {
        var method: String
        var target: String
        /// Lower-cased names.
        var headers: [String: String]

        var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }
    }

    enum HeadResult: Equatable {
        /// Not all of it yet.
        case incomplete
        case head(Head, bodyStart: Int)
        case invalid(String)
    }

    /// Parse the head at the start of `buffer`, if all of it is there.
    static func parseHead(_ buffer: Data) -> HeadResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .invalid("the request head is too long") : .incomplete
        }
        guard end.lowerBound <= maxHead, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            return .invalid("the request head is not valid")
        }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid("not an HTTP/1.x request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("a header line has no colon") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .head(Head(method: String(start[0]), target: String(start[1]), headers: headers), bodyStart: end.upperBound - buffer.startIndex)
    }

    /// Whether `head` carries `Authorization: Bearer <token>`, compared in
    /// time that does not depend on where the two first differ.
    static func authorized(_ head: Head, token: String) -> Bool {
        guard let value = head.headers["authorization"], value.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(Array(value.dropFirst("Bearer ".count).utf8), Array(token.utf8))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        // Every byte of the longer is looked at, whatever matches.
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<max(a.count, b.count) {
            diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return diff == 0 && !b.isEmpty
    }

    /// A whole reply; `body` empty for none.
    static func response(_ status: Int, _ body: Data = Data()) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
                      413: "Content Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        return data
    }
}
