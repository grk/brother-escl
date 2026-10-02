// End-to-end test through ImageCaptureCore (the framework Preview uses):
// finds our eSCL scanner, opens a session and scans the flatbed into a folder.
// Usage: ic_scan <outdir> [dpi]
import Foundation
import ImageCaptureCore

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let dpi = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 150

final class T: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    var scanner: ICScannerDevice?
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard scanner == nil, let s = device as? ICScannerDevice, (s.name ?? "").contains("MFC-9340CDW") else { return }
        print("found", s.name ?? "")
        scanner = s
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) { print("session", error ?? "ok") }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    func scannerDevice(_ s: ICScannerDevice, didSelect fu: ICScannerFunctionalUnit, error: (any Error)?) {
        print("unit", fu.type.rawValue, "error", error ?? "none")
        guard error == nil else { exit(1) }
        fu.resolution = fu.supportedResolutions.integerGreaterThanOrEqualTo(dpi) ?? 300
        fu.pixelDataType = .RGB
        fu.bitDepth = .depth8Bits
        fu.scanArea = NSRect(origin: .zero, size: fu.physicalSize)
        s.transferMode = .fileBased
        s.downloadsDirectory = outDir
        s.documentName = "ic_scan"
        s.documentUTI = "public.jpeg"
        print("scanning at", fu.resolution, "dpi, area", fu.scanArea)
        s.requestScan()
    }
    func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL) { print("saved", url.path) }
    func scannerDevice(_ s: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        print("complete", error ?? "ok")
        exit(error == nil ? 0 : 1)
    }
}

let t = T()
let b = ICDeviceBrowser()
b.delegate = t
b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
    ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
b.start()
RunLoop.main.run(until: Date().addingTimeInterval(120))
print("timeout")
exit(2)
