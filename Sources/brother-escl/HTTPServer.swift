import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lower-cased keys
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func xml(_ s: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/xml")], body: Data(s.utf8))
    }
    static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// Tiny HTTP/1.1 server on Network.framework, advertised via Bonjour.
/// Handlers may block (a scan takes tens of seconds), so each request runs on a concurrent queue.
/// It listens on the LAN, so request size, connection count and idle time are all bounded.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    static let maxHeaderBytes = 16 << 10
    static let maxBodyBytes = 1 << 20      // ScanSettings are ~1 KB
    static let maxConnections = 32
    static let idleTimeout: TimeInterval = 30

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "http", attributes: .concurrent)
    private let lock = NSLock()
    private var connections = 0

    init(port: UInt16, service: NWListener.Service, handler: @escaping Handler) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = service
        self.handler = handler
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("listening on port \(self.listener.port?.rawValue ?? 0)")
            case .failed(let e): log("listener failed: \(e)"); exit(1)
            default: break
            }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add(let ep) = change { log("advertised \(ep)") }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        lock.lock()
        let allowed = connections < Self.maxConnections
        if allowed { connections += 1 }
        lock.unlock()
        guard allowed else {
            log("too many connections; rejecting \(c.endpoint)")
            c.cancel()
            return
        }
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: c.cancel()   // leads to .cancelled, counted there exactly once
            case .cancelled:
                self?.lock.lock()
                self?.connections -= 1
                self?.lock.unlock()
            default: break
            }
        }
        c.start(queue: queue)
        serve(c, buffer: Data())
    }

    private func serve(_ c: NWConnection, buffer: Data) {
        switch Self.parse(buffer) {
        case .request(let req, let rest):
            let resp = handler(req)
            send(resp, on: c, keepAlive: req.headers["connection"]?.lowercased() != "close") {
                self.serve(c, buffer: rest)
            }
        case .error(let status):
            send(.empty(status), on: c, keepAlive: false) {}
        case .incomplete:
            // Drop connections that sit idle (or trickle a request) for too long.
            let timeout = DispatchWorkItem { c.cancel() }
            queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timeout)
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, done, err in
                timeout.cancel()
                if let data, !data.isEmpty {
                    self.serve(c, buffer: buffer + data)
                } else if done || err != nil {
                    c.cancel()
                }
            }
        }
    }

    private func send(_ r: HTTPResponse, on c: NWConnection, keepAlive: Bool, next: @escaping () -> Void) {
        var head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        c.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { err in
            if err != nil || !keepAlive { c.cancel() } else { next() }
        })
    }

    enum ParseResult {
        case request(HTTPRequest, rest: Data)
        case incomplete
        case error(Int)
    }

    static func parse(_ buf: Data) -> ParseResult {
        guard let end = buf.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeaderBytes ? .error(431) : .incomplete
        }
        guard end.lowerBound - buf.startIndex <= maxHeaderBytes else { return .error(431) }
        let lines = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .error(400) }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { return .error(400) }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .error(501) }   // chunked bodies unsupported
        var len = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .error(400) }
            guard n <= maxBodyBytes else { return .error(413) }
            len = n
        }
        let bodyStart = end.upperBound
        guard buf.endIndex - bodyStart >= len else { return .incomplete }
        let body = buf[bodyStart..<(bodyStart + len)]
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return .request(HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: Data(body)),
                        rest: Data(buf[(bodyStart + len)...]))
    }
}

private let logTimestamp = ISO8601DateFormatter()

func log(_ s: String) {
    FileHandle.standardError.write(Data("\(logTimestamp.string(from: Date())) \(s)\n".utf8))
}
