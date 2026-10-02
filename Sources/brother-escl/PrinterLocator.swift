import Foundation
import Network

/// Finds the printer's current IP address so nothing breaks when DHCP hands it a new one.
///
/// Lookup order: cached address → Bonjour (only works on the same subnet; mDNS doesn't cross
/// routers) → last known address (persisted), the `--host` hint and printers configured in
/// macOS → sweep of the /24 subnets of those addresses and of this Mac's own interfaces.
/// Every candidate is verified by its web page naming the model; only private (RFC 1918)
/// addresses are ever probed. Identification deliberately uses the web page, not the scan
/// port: the scanner briefly refuses port 54921 after many short connections.
final class PrinterLocator {
    /// Substring identifying the printer, e.g. "MFC-9340CDW".
    let match: String
    private let hint: String?
    private var cached: String?
    private var lastKnown: String?
    private let lock = NSLock()
    private let stateFile: URL

    static let serviceTypes = ["_pdl-datastream._tcp", "_ipp._tcp", "_printer._tcp"]

    init(match: String, hint: String? = nil) {
        self.match = match
        self.hint = hint
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/brother-escl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateFile = dir.appendingPathComponent("last-host")
        lastKnown = (try? String(contentsOf: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct NotFound: Error, CustomStringConvertible {
        let match: String
        var description: String { "printer matching \"\(match)\" not found (Bonjour, known addresses, subnet sweep)" }
    }

    /// The printer's address; a cached one is re-checked first, since DHCP may have moved it.
    func host() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            if Self.isPrinter(cached, match: match) { return cached }
            log("printer not at \(cached) any more; looking it up again")
            self.cached = nil
        }
        guard let found = locate() else { throw NotFound(match: match) }
        cached = found
        if found != lastKnown {
            lastKnown = found
            try? found.write(to: stateFile, atomically: true, encoding: .utf8)
        }
        return found
    }

    private func locate() -> String? {
        for b in Self.bonjour(match: match, timeout: 3) where Self.isPrinter(b.host, match: match) {
            log("found \"\(b.name)\" via Bonjour at \(b.host)")
            return b.host
        }
        var seeds: [String] = []
        for ip in [lastKnown, hint].compactMap({ $0 }) + Self.cupsPrinterIPs()
            where Self.isPrivate(ip) && !seeds.contains(ip) {
            seeds.append(ip)
        }
        for ip in seeds where Self.isPrinter(ip, match: match) {
            log("printer at \(ip)")
            return ip
        }
        var swept: Set<String> = []
        for ip in seeds + Self.localIPv4Addresses() {
            let net = ip.split(separator: ".").prefix(3).joined(separator: ".")
            guard swept.insert(net).inserted else { continue }
            if let found = Self.sweep(around: ip, match: match) {
                log("found printer at \(found) by sweeping \(net).0/24")
                return found
            }
        }
        return nil
    }

    /// IPv4 addresses from the device URIs of printers set up in macOS (`lpstat -v`).
    static func cupsPrinterIPs() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        p.arguments = ["-v"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let re = try? NSRegularExpression(pattern: "://(\\d+\\.\\d+\\.\\d+\\.\\d+)") else { return [] }
        let ns = out as NSString
        return re.matches(in: out, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Private IPv4 addresses of this Mac's active interfaces.
    static func localIPv4Addresses() -> [String] {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return [] }
        defer { freeifaddrs(ifs) }
        var out: [String] = []
        var p = ifs
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  i.pointee.ifa_flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if isPrivate(ip) { out.append(ip) }
        }
        return out
    }

    /// RFC 1918 address — the only kind we ever probe, so the sweep can't hit someone else's network.
    static func isPrivate(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    // MARK: - Verification

    /// The device's web page names the model. Brother's root page redirects to the status
    /// page, so one same-host redirect is followed. Reads are capped in size and time.
    static func isPrinter(_ ip: String, match: String) -> Bool {
        guard isPrivate(ip) else { return false }
        var path = "/"
        for _ in 0..<2 {
            guard let page = httpGet(ip, path: path) else { return false }
            if page.localizedCaseInsensitiveContains(match) { return true }
            guard let loc = page.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("location:") })?
                .dropFirst("location:".count).trimmingCharacters(in: .whitespaces),
                  loc.hasPrefix("/") else { return false }
            path = loc
        }
        return false
    }

    /// Raw HTTP/1.0 GET returning headers and body (at most 64 KB, within ~3 s).
    private static func httpGet(_ ip: String, path: String) -> String? {
        guard let conn = try? TCPConnection(host: ip, port: 80, timeout: 3, connectTimeout: 1) else { return nil }
        defer { conn.close() }
        guard (try? conn.write(Data("GET \(path) HTTP/1.0\r\nHost: \(ip)\r\n\r\n".utf8))) != nil else { return nil }
        let data = conn.readToEnd(maxLength: 64 << 10, deadline: Date().addingTimeInterval(3))
        return String(decoding: data, as: UTF8.self)
    }

    /// Connects to all `ips` at once and returns those that accepted within the timeout.
    static func openPorts(_ ips: [String], _ port: UInt16, timeoutMs: Int32) -> Set<String> {
        var pending: [(ip: String, fd: Int32)] = []
        var open: Set<String> = []
        for ip in ips {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 { open.insert(ip); close(fd) }
            else if errno == EINPROGRESS { pending.append((ip, fd)) }
            else { close(fd) }
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        var live = Set(fds.indices)
        while !live.isEmpty {
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0, poll(&fds, nfds_t(fds.count), left) > 0 else { break }
            for i in live where fds[i].revents != 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fds[i].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 { open.insert(pending[i].ip) }
                live.remove(i)
                fds[i].fd = -1   // poll ignores negative fds
            }
        }
        pending.forEach { close($0.fd) }
        return open
    }

    // MARK: - Subnet sweep

    /// Probes every host in `ip`'s /24 for a web server, then verifies candidates.
    /// Connects in two batches to stay well under the default 256 open-files limit.
    static func sweep(around ip: String, match: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, isPrivate(ip) else { return nil }
        let prefix = parts[0..<3].joined(separator: ".")
        let all = (1...254).map { "\(prefix).\($0)" }
        var open: Set<String> = []
        for batch in [Array(all[..<127]), Array(all[127...])] {
            open.formUnion(openPorts(batch, 80, timeoutMs: 1000))
        }
        return all.first { open.contains($0) && isPrinter($0, match: match) }
    }

    // MARK: - Bonjour

    /// Browses for printer services whose name contains `match` and resolves them to IPv4
    /// addresses (unverified — anyone can advertise any name). Waits `timeout` seconds, or
    /// returns as soon as one resolves.
    static func bonjour(match: String, timeout: TimeInterval) -> [(name: String, host: String)] {
        let queue = DispatchQueue(label: "discover")
        let done = DispatchSemaphore(value: 0)
        var results: [(name: String, host: String)] = []
        var browsers: [NWBrowser] = []
        var resolving: [NWConnection] = []

        func found(_ r: (String, String)) {   // on `queue`
            guard !results.contains(where: { $0.host == r.1 }) else { return }
            results.append(r)
            done.signal()
        }

        for type in serviceTypes {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case .service(let name, _, _, _) = r.endpoint,
                          name.localizedCaseInsensitiveContains(match) else { continue }
                    let params = NWParameters.tcp
                    (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let c = NWConnection(to: r.endpoint, using: params)
                    c.stateUpdateHandler = { state in
                        guard case .ready = state else { return }
                        if case .hostPort(let host, _)? = c.currentPath?.remoteEndpoint {
                            var h = "\(host)"
                            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }   // drop "%en0"
                            found((name, h))
                        }
                        c.cancel()
                    }
                    resolving.append(c)
                    c.start(queue: queue)
                }
            }
            browsers.append(b)
            b.start(queue: queue)
        }

        _ = done.wait(timeout: .now() + timeout)
        return queue.sync {
            browsers.forEach { $0.cancel() }
            resolving.forEach { $0.cancel() }
            return results
        }
    }
}
