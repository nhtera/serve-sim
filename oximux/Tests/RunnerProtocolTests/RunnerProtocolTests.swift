import Foundation
import Network
import XCTest
@testable import OximuxRunnerCore

/// The control runner's protocol pieces, without a phone: command decoding,
/// envelopes, HTTP heads, the token check, the journal, and the server's
/// request handling (live, on this Mac's loopback).
final class RunnerProtocolTests: XCTestCase {
    private let token = String(repeating: "t", count: 48)

    func testCommandsDecodeStrictly() throws {
        let tap = try RunnerCommand.decode(Data(#"{"command":"tap","commandId":"c1","x":1.5,"y":2,"app":"com.example"}"#.utf8)).get()
        XCTAssertEqual(tap.name, "tap")
        XCTAssertEqual(tap.id, "c1")
        XCTAssertTrue(tap.isMutating)
        XCTAssertEqual(tap.number("x"), 1.5)
        XCTAssertEqual(tap.string("app"), "com.example")
        XCTAssertFalse(try RunnerCommand.decode(Data(#"{"command":"snapshot"}"#.utf8)).get().isMutating)
        for bad in ["[]", "nope", #"{"x":1}"#, #"{"command":""}"#, #"{"command":"tap","commandId":""}"#] {
            guard case .failure(let error) = RunnerCommand.decode(Data(bad.utf8)) else { return XCTFail(bad) }
            XCTAssertEqual(error.code, "BAD_REQUEST", bad)
        }
    }

    func testNumbersAndPointsAreChecked() throws {
        let command = try RunnerCommand.decode(Data(#"{"command":"drag","flag":true,"s":"1","from":{"x":1,"y":2},"to":{"x":1}}"#.utf8)).get()
        XCTAssertNil(command.number("flag"), "a bool is not a number")
        XCTAssertNil(command.number("s"))
        XCTAssertEqual(command.point("from")?.x, 1)
        XCTAssertNil(command.point("to"))
        XCTAssertThrowsError(try command.require(command.point("to"), "to"))
    }

    func testEnvelopesHaveOneShape() throws {
        let ok = try JSONSerialization.jsonObject(with: Envelope.ok(["n": 1], reactivated: true)) as? [String: Any]
        XCTAssertEqual(ok?["ok"] as? Bool, true)
        XCTAssertEqual(ok?["reactivated"] as? Bool, true)
        XCTAssertEqual((ok?["data"] as? [String: Any])?["n"] as? Int, 1)
        let failed = try JSONSerialization.jsonObject(with: Envelope.failure(.busy)) as? [String: Any]
        let error = failed?["error"] as? [String: Any]
        XCTAssertEqual(failed?["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "RUNNER_BUSY")
        XCTAssertNotNil(error?["hint"])
    }

    /// XCTest's complaint keeps its first line, not its element dump.
    func testXCTestErrorsAreShort() {
        let error = RunnerError.xctest("Failed to synthesize event: Neither element nor any descendant has keyboard focus.\nElement subtree:\n →Application")
        XCTAssertFalse(error.message.contains("subtree"))
        XCTAssertEqual(error.hint, "tap the text field first")
        XCTAssertLessThanOrEqual(RunnerError.xctest(String(repeating: "x", count: 1000)).message.count, 301)
    }

    func testHeadsParse() {
        let request = Data("POST / HTTP/1.1\r\nAuthorization: Bearer abc\r\nCONTENT-LENGTH: 2\r\n\r\n{}".utf8)
        guard case let .head(head, start) = HTTP.parseHead(request) else { return XCTFail("no head") }
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.contentLength, 2)
        XCTAssertEqual(head.headers["authorization"], "Bearer abc")
        XCTAssertEqual(start, request.count - 2)
        XCTAssertEqual(HTTP.parseHead(Data("POST / HTTP/1.1\r\n".utf8)), .incomplete)
        guard case .invalid = HTTP.parseHead(Data("nonsense\r\n\r\n".utf8)) else { return XCTFail("accepted nonsense") }
        guard case .invalid = HTTP.parseHead(Data(repeating: 0x41, count: HTTP.maxHead + 1)) else { return XCTFail("endless head") }
    }

    func testTheTokenIsComparedWhole() {
        let t = Array("secret-token".utf8)
        XCTAssertTrue(HTTP.constantTimeEqual(t, t))
        XCTAssertFalse(HTTP.constantTimeEqual(Array("secret".utf8), t), "a prefix")
        XCTAssertFalse(HTTP.constantTimeEqual(t + [0x41], t), "longer")
        XCTAssertFalse(HTTP.constantTimeEqual([], []), "no token never matches")
        let head = { (auth: String?) in HTTP.Head(method: "POST", target: "/", headers: auth.map { ["authorization": $0] } ?? [:]) }
        let digest = HTTP.digest(of: "secret-token")
        XCTAssertTrue(HTTP.authorized(head("Bearer secret-token"), digest: digest))
        XCTAssertFalse(HTTP.authorized(head("Bearer secret-toke"), digest: digest))
        XCTAssertFalse(HTTP.authorized(head("Basic secret-token"), digest: digest))
        XCTAssertFalse(HTTP.authorized(head(nil), digest: digest))
        // The digest itself is no password.
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(HTTP.authorized(head("Bearer \(hex)"), digest: digest))
    }

    /// The environment carries the digest as hex; anything else is refused.
    func testTheDigestIsReadAsHex() {
        let hex = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b" // SHA-256("secret")
        XCTAssertEqual(HTTP.digest(hex: hex), HTTP.digest(of: "secret"))
        XCTAssertEqual(HTTP.digest(hex: hex.uppercased()), HTTP.digest(of: "secret"))
        XCTAssertNil(HTTP.digest(hex: String(hex.dropLast())))
        XCTAssertNil(HTTP.digest(hex: String(hex.dropLast()) + "g"))
        XCTAssertNil(HTTP.digest(hex: ""))
        XCTAssertNil(HTTP.digest(hex: "+" + String(hex.dropFirst())))
    }

    /// Authorization comes before anything else is looked at: a stranger
    /// learns nothing, not even whether the body was too big.
    func testRequestsAreAnsweredInOrderOfConcern() {
        let server = HTTPServer(digest: HTTP.digest(of: token)) { _ in Data() }
        func request(_ method: String = "POST", target: String = "/", auth: Bool = true, length: Int, body: String = "") -> Data {
            var head = "\(method) \(target) HTTP/1.1\r\nContent-Length: \(length)\r\n"
            if auth { head += "Authorization: Bearer \(token)\r\n" }
            return Data((head + "\r\n" + body).utf8)
        }
        func status(_ step: HTTPServer.Step) -> Int? {
            guard case .reply(let data) = step, let line = String(data: data.prefix(12), encoding: .utf8) else { return nil }
            return Int(line.dropFirst(9).prefix(3))
        }
        XCTAssertEqual(status(server.next(request(auth: false, length: 99_000_000))), 401)
        XCTAssertEqual(status(server.next(request("GET", length: 0))), 405)
        XCTAssertEqual(status(server.next(request(target: "/x", length: 0))), 404)
        XCTAssertEqual(status(server.next(request(length: RunnerProtocol.maxBody + 1))), 413)
        XCTAssertEqual(server.next(request(length: 4, body: "{}")), .needMore)
        XCTAssertEqual(server.next(request(length: 2, body: "{}")), .handle(Data("{}".utf8)))
    }

    /// An id is taken before its command runs: a copy meanwhile is told it
    /// is running, a command that never ran gives its id back, and a
    /// finished one answers every copy after.
    func testTheJournalRunsEachIdOnce() {
        let journal = Journal()
        XCTAssertEqual(journal.begin("a"), .fresh)
        XCTAssertEqual(journal.begin("a"), .pending)
        XCTAssertEqual(journal.entry("a"), .pending)
        journal.finish("a", Data("done".utf8))
        XCTAssertEqual(journal.begin("a"), .done(Data("done".utf8)))
        XCTAssertEqual(journal.begin("b"), .fresh)
        journal.release("b") // turned away busy: never ran
        XCTAssertEqual(journal.begin("b"), .fresh)
        XCTAssertNil(journal.entry("c"))
    }

    func testTheJournalKeepsTheNewestAndEveryRunningOne() {
        let journal = Journal(capacity: 2)
        XCTAssertEqual(journal.begin("running"), .fresh)
        journal.finish("1", Data("a".utf8))
        journal.finish("2", Data("b".utf8))
        journal.finish("3", Data("c".utf8))
        XCTAssertEqual(journal.entry("running"), .pending, "a command still running is never dropped")
        XCTAssertNil(journal.entry("1"))
        XCTAssertNil(journal.entry("2"))
        XCTAssertEqual(journal.entry("3"), .done(Data("c".utf8)))
    }

    /// A whole number in range, or a bad request — never a trap.
    func testBundleIDsAreChecked() throws {
        let decode = { (json: String) in try RunnerCommand.decode(Data(json.utf8)).get() }
        XCTAssertEqual(try decode(#"{"command":"type"}"#).bundleIDs("candidates", max: 2), [])
        XCTAssertEqual(try decode(#"{"command":"type","candidates":["com.example.a","dev.x-y.b"]}"#).bundleIDs("candidates", max: 2), ["com.example.a", "dev.x-y.b"])
        for bad in [#""com.example""#, #"[1]"#, #"[""]"#, #"["a b"]"#, #"["a","b","c"]"#] {
            XCTAssertThrowsError(try decode(#"{"command":"type","candidates":"# + bad + "}").bundleIDs("candidates", max: 2), bad) { error in
                XCTAssertEqual((error as? RunnerError)?.code, "BAD_REQUEST", bad)
            }
        }
    }

    func testIntegersAreCheckedNotConverted() throws {
        let command = try RunnerCommand.decode(Data(#"{"command":"tap","taps":1e300,"half":1.5,"ok":2}"#.utf8)).get()
        XCTAssertEqual(try command.integer("ok", in: 1...2, fallback: 1), 2)
        XCTAssertEqual(try command.integer("absent", in: 1...2, fallback: 1), 1)
        XCTAssertThrowsError(try command.integer("taps", in: 1...2, fallback: 1))
        XCTAssertThrowsError(try command.integer("half", in: 1...2, fallback: 1))
    }

    /// One reading of every request: no chunked body, no second length or
    /// token; and the head is "seen" once it is whole.
    func testAmbiguousHeadsAreRefused() {
        for head in ["POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
                     "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
                     "POST / HTTP/1.1\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n"] {
            guard case .invalid = HTTP.parseHead(Data(head.utf8)) else { return XCTFail(head) }
        }
        XCTAssertFalse(HTTP.headComplete(Data("POST / HTTP/1.1\r\n".utf8)))
        XCTAssertTrue(HTTP.headComplete(Data("POST / HTTP/1.1\r\n\r\n".utf8)))
    }

    /// The server on this Mac's loopback: a request with the token is
    /// handled, one without is refused, and a fifth connection at once is
    /// turned away.
    func testTheServerServesOnLoopback() throws {
        let server = HTTPServer(digest: HTTP.digest(of: token)) { body in Envelope.ok(["echo": String(data: body, encoding: .utf8) ?? ""]) }
        let ready = expectation(description: "listening")
        let port = Port()
        try server.start(ready: { p in port.value = p; ready.fulfill() }, failed: { XCTFail("\($0)") })
        wait(for: [ready], timeout: 5)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port.value)/")!
        func post(_ token: String?) throws -> (Int, Data) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"command":"status"}"#.utf8)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let done = expectation(description: "reply")
            var result = (0, Data())
            URLSession.shared.dataTask(with: request) { data, response, _ in
                result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5)
            return result
        }
        let (ok, body) = try post(token)
        XCTAssertEqual(ok, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("status"))
        XCTAssertEqual(try post(nil).0, 401)
        XCTAssertEqual(try post("wrong").0, 401)

        // Four held open, the fifth is answered 503 at once.
        let held = (0..<RunnerProtocol.maxConnections).map { _ in try? socket(port.value) }
        Thread.sleep(forTimeInterval: 0.3)
        let fifth = try socket(port.value)
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = recv(fifth, &buffer, buffer.count, 0)
        XCTAssertTrue(String(decoding: buffer.prefix(max(0, n)), as: UTF8.self).hasPrefix("HTTP/1.1 503"))
        close(fifth)
        held.compactMap { $0 }.forEach { close($0) }
    }

    private final class Port: @unchecked Sendable {
        var value: UInt16 = 0
    }

    /// A blocking TCP connection to 127.0.0.1:`port`.
    private func socket(_ port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        return fd
    }
}
