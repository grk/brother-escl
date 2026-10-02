import Foundation

/// Minimal blocking TCP client; scans run on a background queue so blocking is fine.
final class TCPConnection {
    enum Failure: Error, CustomStringConvertible {
        case resolve(String), connect(String, Int32), io(String, Int32), closed, tooLong
        var description: String {
            switch self {
            case .resolve(let h): return "cannot resolve \(h)"
            case .connect(let h, let e): return "connect to \(h) failed: \(String(cString: strerror(e)))"
            case .io(let op, let e): return "\(op) failed: \(String(cString: strerror(e)))"
            case .closed: return "connection closed by peer"
            case .tooLong: return "peer sent more data than expected"
            }
        }
    }

    private let fd: Int32
    private var buffer = Data()

    /// `connectTimeout` bounds the TCP handshake (a dead address would otherwise block for
    /// ~75 s); `timeout` bounds every later send/receive.
    init(host: String, port: UInt16, timeout: TimeInterval, connectTimeout: TimeInterval = 5) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw Failure.resolve(host) }
        defer { freeaddrinfo(res) }
        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw Failure.io("socket", errno) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var err: Int32 = 0
        if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            err = errno
            if err == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(connectTimeout * 1000)) == 1 {
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                } else {
                    err = ETIMEDOUT
                }
            }
        }
        guard err == 0 else {
            Darwin.close(fd)
            throw Failure.connect(host, err)
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                guard n > 0 else { throw Failure.io("send", errno) }
                off += n
            }
        }
    }

    func read(exactly count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// Reads up to and including "\n"; returns the line without line terminators.
    func readLine(maxLength: Int = 256) throws -> Data {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return Data(line.filter { $0 != 0x0D })
            }
            guard buffer.count < maxLength else { throw Failure.tooLong }
            try fill()
        }
    }

    /// Reads until the peer closes the connection, `maxLength` bytes or `deadline`, whichever
    /// comes first.
    func readToEnd(maxLength: Int, deadline: Date) -> Data {
        while buffer.count < maxLength && Date() < deadline {
            do { try fill() } catch { break }
        }
        return Data(buffer.prefix(maxLength))
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n < 0 { throw Failure.io("recv", errno) }
        if n == 0 { throw Failure.closed }
        buffer.append(contentsOf: chunk[0..<n])
    }

    func close() { Darwin.close(fd) }
}
