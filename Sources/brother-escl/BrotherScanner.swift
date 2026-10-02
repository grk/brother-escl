import Foundation

/// Client for Brother's native network scan protocol (TCP 54921), as spoken by
/// the MFC-9340CDW and similar models.
///
/// Session:
///   <- "+OK 200\r\n"
///   -> ESC "I\nR=<x>,<y>\nM=<mode>\n" 0x80          query
///   <- 0x00 <len u16 LE> "xres,yres,source,width_mm,width_px,height_mm,height_px," 0x00
///        source 2 = flatbed; 1 = ADF (paper loaded), then height is 0 = "until end of sheet"
///   -> ESC "X\nR=..\nM=..\nC=JPEG\n...A=x1,y1,x2,y2\n..." 0x80   start scan (y2 = 0 for ADF)
///   <- records until 0x80:
///        0x80                         end of job
///        0x82 + 9 bytes               end of page
///        type, 07 00, page u16 LE, 84, lines u32 LE, len u16 LE, data
///                                     image data (JPEG for C=JPEG); `lines` counts rows
///                                     delivered so far. ADF JPEGs declare a placeholder
///                                     height (11000), so `lines` is the real page height.
struct BrotherScanner {
    let host: String

    static let port: UInt16 = 54921
    static let timeout: TimeInterval = 90
    static let resolutions = [100, 150, 200, 300, 600]
    /// Upper bounds on what we accept from the device (a 600 dpi colour A4 page is ~20 MB),
    /// so a misbehaving or impersonating host can't exhaust memory.
    static let maxPageBytes = 128 << 20
    static let maxJobBytes = 1 << 30
    /// Only the first floor(width / 16) * 16 columns of each JPEG line are real image data;
    /// the remainder is garbage. Requesting widths that are multiples of 16 avoids it.
    static let widthAlign = 16

    struct Geometry {
        let xRes: Int, yRes: Int
        let source: Int
        let widthPx: Int, heightPx: Int
        var isFeeder: Bool { source == 1 }
    }

    struct Page {
        let jpeg: Data
        /// Real number of image rows; the JPEG header may claim more.
        let lines: Int
    }

    enum ScanError: Error, CustomStringConvertible {
        case unexpectedGreeting(String)
        case badQueryReply
        case deviceError(UInt8)
        case tooLarge
        var description: String {
            switch self {
            case .unexpectedGreeting(let g): return "unexpected greeting: \(g)"
            case .badQueryReply: return "bad reply to query"
            case .deviceError(let c): return String(format: "scanner returned status 0x%02X", c)
            case .tooLarge: return "scan data exceeds size limit"
            }
        }
    }

    /// Pixel region at the scan resolution.
    struct Region { var x: Int, y: Int, width: Int, height: Int }

    static func nearestResolution(_ r: Int) -> Int {
        resolutions.min(by: { abs($0 - r) < abs($1 - r) })!
    }

    /// Scans in colour and returns one JPEG per page (several when the ADF is loaded).
    /// The scanner picks the ADF by itself whenever paper is loaded in it.
    func scan(resolution: Int, region: Region?) throws -> [Page] {
        let conn = try TCPConnection(host: host, port: Self.port, timeout: Self.timeout)
        defer { conn.close() }
        try handshake(conn)
        let g = try query(conn, resolution: resolution)

        let maxW = g.widthPx
        var r = region ?? Region(x: 0, y: 0, width: maxW, height: g.heightPx)
        r.x = min(max(r.x, 0), maxW - Self.widthAlign)
        r.width = min(max(r.width, Self.widthAlign), maxW - r.x)
        r.width -= r.width % Self.widthAlign
        let y1: Int, y2: Int
        if g.isFeeder {
            (y1, y2) = (0, 0)   // sheet length is unknown up front
        } else {
            r.y = min(max(r.y, 0), g.heightPx - 1)
            r.height = min(max(r.height, 1), g.heightPx - r.y)
            (y1, y2) = (r.y, r.y + r.height)
        }
        log("scanning from \(g.isFeeder ? "ADF" : "flatbed") at \(g.xRes) dpi")

        try conn.write(command("X", [
            "R=\(g.xRes),\(g.yRes)", "M=CGRAY", "C=JPEG", "J=MID", "B=50", "N=50",
            "A=\(r.x),\(y1),\(r.x + r.width),\(y2)",
            "S=NORMAL_SCAN", "P=0", "G=0", "L=128",
        ]))
        return try readPages(conn)
    }

    private func handshake(_ conn: TCPConnection) throws {
        let greet = String(decoding: try conn.readLine(), as: UTF8.self)
        guard greet.hasPrefix("+OK") else { throw ScanError.unexpectedGreeting(greet) }
    }

    private func query(_ conn: TCPConnection, resolution: Int) throws -> Geometry {
        try conn.write(command("I", ["R=\(resolution),\(resolution)", "M=CGRAY"]))
        let head = try conn.read(exactly: 3)
        guard head[0] == 0 else { throw ScanError.deviceError(head[0]) }
        let len = Int(head[1]) | Int(head[2]) << 8
        let body = try conn.read(exactly: len)
        let f = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            .split(separator: ",").compactMap { Int($0) }
        // xres, yres, source, width mm, width px, height mm, height px
        guard f.count >= 7, f[0] > 0, f[1] > 0, f[4] >= Self.widthAlign, f[6] >= 0 else {
            throw ScanError.badQueryReply
        }
        guard f[2] == 1 || f[6] > 0 else { throw ScanError.badQueryReply }
        return Geometry(xRes: f[0], yRes: f[1], source: f[2], widthPx: f[4], heightPx: f[6])
    }

    private func command(_ op: String, _ fields: [String]) -> Data {
        var d = Data([0x1B])
        d.append(contentsOf: Array((op + "\n" + fields.map { $0 + "\n" }.joined()).utf8))
        d.append(0x80)
        return d
    }

    private func readPages(_ conn: TCPConnection) throws -> [Page] {
        var pages: [Page] = []
        var page = Data()
        var lines = 0
        var total = 0
        while true {
            let type = try conn.read(exactly: 1)[0]
            switch type {
            case 0x80:
                if !page.isEmpty { pages.append(Page(jpeg: page, lines: lines)) }
                return pages
            case 0x82:
                _ = try conn.read(exactly: 9)
                if !page.isEmpty { pages.append(Page(jpeg: page, lines: lines)) }
                (page, lines) = (Data(), 0)
            case 0x81...0xFF:
                throw ScanError.deviceError(type)
            default:
                let hdr = try conn.read(exactly: 11)   // bytes 1...11 of the record header
                lines = Int(hdr[5]) | Int(hdr[6]) << 8 | Int(hdr[7]) << 16 | Int(hdr[8]) << 24
                let len = Int(hdr[9]) | Int(hdr[10]) << 8
                total += len
                guard page.count + len <= Self.maxPageBytes, total <= Self.maxJobBytes else {
                    throw ScanError.tooLarge
                }
                page.append(try conn.read(exactly: len))
            }
        }
    }
}
