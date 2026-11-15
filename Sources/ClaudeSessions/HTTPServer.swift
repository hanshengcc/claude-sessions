import Foundation
import Network
import SessionCore

/// One accepted client connection. Either answers once and closes, or becomes
/// a Server-Sent Events stream that stays open until either side closes it.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []
    private var pending = Data()
    private var flushScheduled = false

    private static let flushDelay: DispatchTimeInterval = .milliseconds(12)
    private static let receiveChunk = 64 * 1024

    let remoteHost: String

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        if case .hostPort(let host, _) = connection.endpoint {
            remoteHost = "\(host)"
        } else {
            remoteHost = ""
        }
    }

    /// The connection keeps itself alive through this handler until it closes;
    /// nothing else owns a one-shot request.
    func start(onRequest: @escaping @Sendable (HTTPRequest, HTTPConnection) -> Void) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: markClosed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(onRequest: onRequest)
    }

    private func receive(onRequest: @escaping @Sendable (HTTPRequest, HTTPConnection) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                onRequest(request, self)
            case .invalid:
                respond(status: 400, body: Data("bad request".utf8))
            case .incomplete:
                if isComplete || error != nil { close() } else { receive(onRequest: onRequest) }
            }
        }
    }

    // MARK: One-shot responses

    func respond(status: Int, contentType: String = "text/plain; charset=utf-8", headers: [String: String] = [:],
                 body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [self] _ in close() })
    }

    func respondJSON(_ object: Any, status: Int = 200) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respond(status: status, contentType: "application/json", headers: ["Cache-Control": "no-store"], body: body)
    }

    // MARK: Server-Sent Events

    func startEventStream() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n: open\n\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    /// Queue one SSE event; writes are coalesced for a few ms to batch small pty reads.
    func sendEvent(name: String, data: String, id: String? = nil) {
        var event = ""
        if let id { event += "id: \(id)\n" }
        event += "event: \(name)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) { event += "data: \(line)\n" }
        event += "\n"
        enqueue(Data(event.utf8))
    }

    func sendComment(_ text: String) { enqueue(Data(": \(text)\n\n".utf8)) }

    private func enqueue(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            pending.append(data)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in
                flushScheduled = false
                guard !closed, !pending.isEmpty else { return }
                let chunk = pending
                pending = Data()
                connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
            }
        }
    }

    // MARK: Lifecycle

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if closed { handler() } else { closeHandlers.append(handler) }
        }
    }

    func close() {
        connection.cancel()
        markClosed()
    }

    private func markClosed() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            connection.stateUpdateHandler = nil // break the self-retain from start()
            let handlers = closeHandlers
            closeHandlers = []
            handlers.forEach { $0() }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Error"
        }
    }
}

/// Plain HTTP/1.1 listener; rejects anything not on a private network.
final class HTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claude-sessions.http")
    private var listener: NWListener?
    private let handler: @Sendable (HTTPRequest, HTTPConnection) -> Void
    var onStateChange: (@Sendable (String?) -> Void)?

    init(handler: @escaping @Sendable (HTTPRequest, HTTPConnection) -> Void) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?(nil)
            case .failed(let error): self?.onStateChange?(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let client = HTTPConnection(connection: connection, queue: queue)
            guard AddressPolicy.isAllowed(client.remoteHost) else {
                NSLog("ClaudeSessions: rejected remote connection from %@", client.remoteHost)
                connection.cancel()
                return
            }
            client.start(onRequest: handler)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
