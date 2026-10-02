import Foundation
import IOKit

// brother-escl: exposes a Brother MFC-9340CDW (native scan protocol) as an eSCL/AirScan
// scanner so it shows up in Preview and Image Capture.
//
// Usage: brother-escl [--host IP] [--match MFC-9340CDW] [--port 8090] [--name "Brother MFC-9340CDW"]
//        brother-escl --discover
// The printer is located automatically (see PrinterLocator) and again whenever its address
// changes; --host only gives a starting hint.

var host: String?
var match = "MFC-9340CDW"
var port: UInt16 = 8090
var name = "Brother MFC-9340CDW"
var discoverOnly = false

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--host": host = value(of: a)
    case "--match": match = value(of: a)
    case "--port":
        guard let p = args.next().flatMap({ UInt16($0) }), p > 0 else { usage("--port needs a number 1-65535") }
        port = p
    case "--name": name = value(of: a)
    case "--discover": discoverOnly = true
    default: usage("unknown argument \(a)")
    }
}

/// The next argument, which must be present and non-empty (an empty --match would accept any
/// web server on the network as the printer).
func value(of flag: String) -> String {
    guard let v = args.next(), !v.isEmpty else { usage("\(flag) needs a value") }
    return v
}

func usage(_ problem: String) -> Never {
    FileHandle.standardError.write(Data("""
        \(problem)
        usage: brother-escl [--host IP] [--match TEXT] [--port 8090] [--name NAME] | --discover\n
        """.utf8))
    exit(2)
}

if discoverOnly {
    do {
        print(try PrinterLocator(match: match, hint: host).host())
        exit(0)
    } catch {
        print(error)
        exit(1)
    }
}

// Stable UUID per Mac and printer model: macOS keeps recognising it as the same device
// whatever the printer's IP address, and two Macs running brother-escl don't collide.
let platformUUID: String = {
    let dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(dev) }
    return IORegistryEntryCreateCFProperty(dev, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String ?? ProcessInfo.processInfo.hostName
}()

let uuid: String = {
    var bytes = Array("brother-escl:\(platformUUID):\(match)".utf8)
    var h: UInt64 = 0xcbf29ce484222325
    var out = [UInt8]()
    for round in 0..<2 {
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        withUnsafeBytes(of: h.bigEndian) { out += $0 }
        bytes.append(UInt8(round))
    }
    out[6] = (out[6] & 0x0F) | 0x50
    out[8] = (out[8] & 0x3F) | 0x80
    return UUID(uuid: (out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
                       out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15])).uuidString.lowercased()
}()

do {
    let locator = PrinterLocator(match: match, hint: host)
    let server = ESCLServer(locator: locator, name: name, uuid: uuid, port: port)
    try server.start()
    dispatchMain()
} catch {
    log("fatal: \(error)")
    exit(1)
}
