import Foundation
import Network

/// The runner's command server: HTTP/1.1 on the phone's **loopback only**
/// (usbmux reaches it from the Mac; nothing on the network can), on a port
/// the system picks. One request per connection; every request must carry
/// the bearer token whose SHA-256 it was given (401 with no body otherwise); a body over
/// `RunnerProtocol.maxBody` gets 413, a connection over
/// `RunnerProtocol.maxConnections` gets 503.
final class HTTPServer: @unchecked Sendable {
    /// Turns an authorized request body into the reply's JSON body. Called
    /// on a worker queue, never the listener's; it may block.
    typealias Handler = @Sendable (Data) -> Data

    private let digest: [UInt8]
    private let handler: Handler
    private let queue = DispatchQueue(label: "oximux.runner.http")
    private let workers = DispatchQueue(label: "oximux.runner.work", attributes: .concurrent)
    private var listener: NWListener?
    // `queue` only.
    private var open = 0

    /// How long one connection may take, request to reply (a long drag
    /// included); then it is dropped.
    static let connectionLimit: TimeInterval = 120
    /// How long a connection may take to send its request head: a peer that
    /// says nothing must not hold one of the few slots for long.
    static let headLimit: TimeInterval = 5

    /// One connection's progress (`queue` only).
    private final class Exchange {
        var buffer = Data()
        var headSeen = false
    }

    /// `digest`: the token's SHA-256 (see `HTTP.authorized`).
    init(digest: [UInt8], handler: @escaping Handler) {
        self.digest = digest
        self.handler = handler
    }

    /// Listen on 127.0.0.1; `ready` gets the port.
    func start(ready: @escaping @Sendable (UInt16) -> Void, failed: @escaping @Sendable (Error) -> Void) throws {
        let parameters = NWParameters.tcp
        // NWListener binds every interface unless told otherwise. Bound to
        // 127.0.0.1, nothing off the phone can connect. (Not `acceptLocalOnly`
        // on top: in a simulator its policy refuses even loopback peers.)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: if let port = listener.port?.rawValue { ready(port) }
            case .failed(let error): failed(error)
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        open += 1
        let over = open > RunnerProtocol.maxConnections
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            // A failed connection is cancelled too: counted out once, there.
            case .failed: connection.cancel()
            case .cancelled: self?.open -= 1
            default: break
            }
        }
        connection.start(queue: queue)
        if over {
            return reply(connection, HTTP.response(503))
        }
        let exchange = Exchange()
        queue.asyncAfter(deadline: .now() + Self.headLimit) { if !exchange.headSeen { connection.cancel() } }
        queue.asyncAfter(deadline: .now() + Self.connectionLimit) { connection.cancel() }
        read(connection, exchange)
    }

    private func read(_ connection: NWConnection, _ exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] chunk, _, done, error in
            guard let self else { return connection.cancel() }
            if let chunk { exchange.buffer.append(chunk) }
            let step = self.next(exchange.buffer)
            if step != .needMore || HTTP.headComplete(exchange.buffer) { exchange.headSeen = true }
            switch step {
            case .needMore where done || error != nil:
                connection.cancel()
            case .needMore:
                self.read(connection, exchange)
            case .reply(let response):
                self.reply(connection, response)
            case .handle(let body):
                self.workers.async {
                    let reply = HTTP.response(200, self.handler(body))
                    self.queue.async { self.reply(connection, reply) }
                }
            }
        }
    }

    enum Step: Equatable {
        case needMore
        case reply(Data)
        case handle(Data)
    }

    /// What to do with what has arrived so far. Pure: tested on macOS.
    func next(_ buffer: Data) -> Step {
        switch HTTP.parseHead(buffer) {
        case .incomplete: return .needMore
        case .invalid: return .reply(HTTP.response(400))
        case let .head(head, bodyStart):
            // Auth before anything else is looked at: a stranger learns
            // nothing, not even whether the body was too big.
            guard HTTP.authorized(head, digest: digest) else { return .reply(HTTP.response(401)) }
            guard head.method == "POST" else { return .reply(HTTP.response(405)) }
            guard head.target == "/" else { return .reply(HTTP.response(404)) }
            guard let length = head.contentLength, length >= 0 else { return .reply(HTTP.response(400)) }
            guard length <= RunnerProtocol.maxBody else { return .reply(HTTP.response(413)) }
            let have = buffer.count - bodyStart
            guard have >= length else { return .needMore }
            let start = buffer.startIndex + bodyStart
            return .handle(Data(buffer[start..<(start + length)]))
        }
    }

    private func reply(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
