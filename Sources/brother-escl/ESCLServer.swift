import Foundation
import Network

/// eSCL (AirScan) front end: the protocol macOS Image Capture / Preview speak to network scanners.
final class ESCLServer {
    let locator: PrinterLocator
    let name: String
    let uuid: String
    let port: UInt16
    private var http: HTTPServer?

    private enum JobState: String { case processing = "Processing", completed = "Completed",
                                         canceled = "Canceled", aborted = "Aborted" }

    private final class Job {
        let id: String
        var state = JobState.processing
        var pages: [Data] = []          // emptied as they are delivered
        var completed = 0               // pages scanned
        var delivered = 0
        var finishedAt: Date?
        init(id: String) { self.id = id }
    }
    private var jobs: [String: Job] = [:]
    private let cond = NSCondition()
    private var busy = false

    /// Finished jobs are kept this long so clients can still read their final status.
    private static let jobRetention: TimeInterval = 300

    // Advertised area in 1/300 inch (eSCL units). The glass really covers 2480×3437
    // (210×291 mm), but macOS hides paper sizes that don't fit the advertised area, so we
    // claim Letter width and A4 height and pad the uncovered strip with white.
    private static let maxWidth = 2550    // 8.5"
    private static let maxHeight = 3508   // 297 mm

    init(locator: PrinterLocator, name: String, uuid: String, port: UInt16) {
        self.locator = locator
        self.name = name
        self.uuid = uuid
        self.port = port
    }

    func start() throws {
        let txt: [String: String] = [
            "txtvers": "1", "vers": "2.63", "rs": "eSCL", "ty": name, "uuid": uuid,
            "pdl": "image/jpeg", "cs": "color,grayscale,binary", "is": "platen,adf",
            "duplex": "F", "note": "", "representation": "",
        ]
        let service = NWListener.Service(name: name, type: "_uscan._tcp",
                                         txtRecord: NWTXTRecord(txt))
        let server = try HTTPServer(port: port, service: service) { [unowned self] in self.handle($0) }
        server.start()
        http = server
    }

    // MARK: - Routing

    private func handle(_ r: HTTPRequest) -> HTTPResponse {
        log("\(r.method) \(r.path)")
        let p = r.path.split(separator: "/").map(String.init)   // ["eSCL", ...]
        guard p.first == "eSCL" else { return .empty(404) }
        let rest = Array(p.dropFirst())
        switch (r.method, rest.count) {
        case ("GET", 1) where rest[0] == "ScannerCapabilities": return .xml(capabilities())
        case ("GET", 1) where rest[0] == "ScannerStatus": return .xml(status())
        case ("POST", 1) where rest[0] == "ScanJobs": return createJob(r.body)
        case ("GET", 3) where rest[0] == "ScanJobs" && rest[2] == "NextDocument": return nextDocument(rest[1])
        case ("DELETE", 2) where rest[0] == "ScanJobs": return cancel(rest[1])
        default: return .empty(404)
        }
    }

    // MARK: - Jobs

    private func createJob(_ body: Data) -> HTTPResponse {
        let xml = String(decoding: body, as: UTF8.self)
        let res = BrotherScanner.nearestResolution(Self.int("XResolution", in: xml) ?? 300)
        let mode = Imaging.Mode(rawValue: Self.tag("ColorMode", in: xml) ?? "") ?? .color
        var region: BrotherScanner.Region?
        if let w = Self.int("Width", in: xml), let h = Self.int("Height", in: xml), w > 0, h > 0 {
            // Clamp in eSCL units first: values come straight from the network.
            let x = min(max(Self.int("XOffset", in: xml) ?? 0, 0), Self.maxWidth - 1)
            let y = min(max(Self.int("YOffset", in: xml) ?? 0, 0), Self.maxHeight - 1)
            let cw = min(w, Self.maxWidth - x), ch = min(h, Self.maxHeight - y)
            let px = { (v: Int) in v * res / 300 }
            region = .init(x: px(x), y: px(y), width: max(px(cw), 1), height: max(px(ch), 1))
        }

        cond.lock()
        if busy { cond.unlock(); return .empty(503) }
        busy = true
        pruneJobs()
        let job = Job(id: UUID().uuidString.lowercased())
        jobs[job.id] = job
        cond.unlock()
        log("job \(job.id): \(res) dpi \(mode.rawValue) region \(region.map { "\($0)" } ?? "full")")

        DispatchQueue.global().async {
            var pages: [Data] = []
            var error: String?
            do {
                pages = try self.scan(resolution: res, region: region).map {
                    Imaging.convert($0.jpeg, lines: $0.lines, to: mode, dpi: res,
                                    size: region.map { ($0.width, $0.height) })
                }
            } catch let e {
                error = "\(e)"
            }
            self.cond.lock()
            if job.state == .processing {
                job.state = error == nil ? .completed : .aborted
                job.pages = pages
                job.completed = pages.count
            }
            job.finishedAt = Date()
            self.busy = false
            self.cond.broadcast()
            self.cond.unlock()
            log("job \(job.id): \(error ?? "\(pages.count) page(s)")")
        }
        var resp = HTTPResponse.empty(201)
        resp.headers = [("Location", "/eSCL/ScanJobs/\(job.id)")]
        return resp
    }

    /// Drops jobs that finished more than `jobRetention` ago. Call with `cond` held.
    private func pruneJobs() {
        let cutoff = Date().addingTimeInterval(-Self.jobRetention)
        jobs = jobs.filter { $0.value.finishedAt.map { $0 > cutoff } ?? true }
    }

    /// Scans on the printer's current address (re-located automatically if it changed).
    private func scan(resolution: Int, region: BrotherScanner.Region?) throws -> [BrotherScanner.Page] {
        let host = try locator.host()
        // The scan port is sometimes refused for a few seconds (e.g. right after another client).
        for attempt in 1... {
            do {
                return try BrotherScanner(host: host).scan(resolution: resolution, region: region)
            } catch let e as TCPConnection.Failure {
                guard case .connect = e, attempt < 4 else { throw e }
                log("\(e); retrying")
                Thread.sleep(forTimeInterval: 2)
            }
        }
        fatalError("unreachable")
    }

    private func nextDocument(_ id: String) -> HTTPResponse {
        cond.lock()
        defer { cond.unlock() }
        guard let job = jobs[id] else { return .empty(404) }
        while job.state == .processing { cond.wait() }
        // 404 ends the job for the client: no more pages, or the job was canceled/aborted.
        guard job.state == .completed, job.delivered < job.pages.count else { return .empty(404) }
        let page = job.pages[job.delivered]
        job.pages[job.delivered] = Data()   // release it; the client won't ask again
        job.delivered += 1
        return HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg")], body: page)
    }

    /// Marks the job canceled and wakes any waiting NextDocument. The scan already running on
    /// the device is left to finish (aborting mid-transfer can wedge the scanner's session);
    /// its pages are discarded.
    private func cancel(_ id: String) -> HTTPResponse {
        cond.lock()
        defer { cond.unlock() }
        guard let job = jobs[id] else { return .empty(404) }
        if job.state == .processing { job.state = .canceled }
        cond.broadcast()
        return .empty(200)
    }

    // MARK: - XML

    private func status() -> String {
        cond.lock()
        pruneJobs()
        let state = busy ? "Processing" : "Idle"
        let jobXML = jobs.values.map { j in """
            <scan:JobInfo>
              <pwg:JobUri>/eSCL/ScanJobs/\(j.id)</pwg:JobUri>
              <pwg:JobUuid>\(j.id)</pwg:JobUuid>
              <pwg:JobState>\(j.state.rawValue)</pwg:JobState>
              <pwg:ImagesCompleted>\(j.completed)</pwg:ImagesCompleted>
              <pwg:ImagesToTransfer>\(j.state == .completed ? j.completed - j.delivered : 0)</pwg:ImagesToTransfer>
            </scan:JobInfo>
            """ }.joined(separator: "\n")
        cond.unlock()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.63</pwg:Version>
          <pwg:State>\(state)</pwg:State>
          <scan:Jobs>\(jobXML)</scan:Jobs>
        </scan:ScannerStatus>
        """
    }

    private func inputCaps(_ tag: String) -> String {
        let res = BrotherScanner.resolutions.map {
            "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution><scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
        }.joined()
        return """
        <scan:\(tag)>
          <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>\(Self.maxWidth)</scan:MaxWidth>
          <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>\(Self.maxHeight)</scan:MaxHeight>
          <scan:MaxScanRegions>1</scan:MaxScanRegions>
          <scan:SettingProfiles><scan:SettingProfile>
            <scan:ColorModes>
              <scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode><scan:ColorMode>BlackAndWhite1</scan:ColorMode>
            </scan:ColorModes>
            <scan:DocumentFormats>
              <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
            </scan:DocumentFormats>
            <scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>
          </scan:SettingProfile></scan:SettingProfiles>
          <scan:SupportedIntents>
            <scan:Intent>Document</scan:Intent><scan:Intent>TextAndGraphic</scan:Intent><scan:Intent>Photo</scan:Intent><scan:Intent>Preview</scan:Intent>
          </scan:SupportedIntents>
          <scan:MaxOpticalXResolution>600</scan:MaxOpticalXResolution>
          <scan:MaxOpticalYResolution>600</scan:MaxOpticalYResolution>
        </scan:\(tag)>
        """
    }

    private func capabilities() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.63</pwg:Version>
          <pwg:MakeAndModel>\(Self.escape(name))</pwg:MakeAndModel>
          <pwg:SerialNumber>\(uuid.prefix(8))</pwg:SerialNumber>
          <scan:UUID>\(uuid)</scan:UUID>
          <scan:Platen>\(inputCaps("PlatenInputCaps"))</scan:Platen>
          <scan:Adf>
            \(inputCaps("AdfSimplexInputCaps"))
            <scan:FeederCapacity>35</scan:FeederCapacity>
            <scan:AdfOptions><scan:AdfOption>DetectPaperLoaded</scan:AdfOption></scan:AdfOptions>
          </scan:Adf>
        </scan:ScannerCapabilities>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - ScanSettings parsing

    private static var patterns: [String: NSRegularExpression] = [:]
    private static let patternsLock = NSLock()

    /// Text of the first `<prefix:name>…</` element. The pattern has no nested or overlapping
    /// quantifiers, so matching stays linear even on hostile input (an earlier
    /// `\s*([^<]*?)\s*` version backtracked catastrophically on long runs of spaces).
    static func tag(_ name: String, in xml: String) -> String? {
        patternsLock.lock()
        let re = patterns[name] ?? (try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?\(name)>([^<]*)</"))
        patterns[name] = re
        patternsLock.unlock()
        guard let re else { return nil }
        let ns = xml as NSString
        guard let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Integer element value, or nil if missing, malformed or absurdly large.
    static func int(_ name: String, in xml: String) -> Int? {
        guard let v = tag(name, in: xml).flatMap({ Int($0) }), abs(v) <= 1_000_000 else { return nil }
        return v
    }
}
