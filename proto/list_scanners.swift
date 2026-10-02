// Lists scanners that macOS Image Capture can see (same list Preview uses),
// opens a session on ours and prints its functional unit.
import Foundation
import ImageCaptureCore

final class D: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    var held: [ICDevice] = []
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("FOUND:", device.name ?? "?", "| transport:", device.transportType ?? "?")
        guard let s = device as? ICScannerDevice, (device.name ?? "").contains("eSCL") else { return }
        held.append(s)
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        print("SESSION:", error.map { "\($0)" } ?? "ok")
    }
    func deviceDidBecomeReady(_ device: ICDevice) { print("READY") }
    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        print("UNIT:", functionalUnit.type.rawValue, "res:", functionalUnit.supportedResolutions.map { $0 },
              "size:", functionalUnit.physicalSize, "err:", error.map { "\($0)" } ?? "none")
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
}

let d = D()
let b = ICDeviceBrowser()
b.delegate = d
b.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
    ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue |
    ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue)!
b.start()
RunLoop.main.run(until: Date().addingTimeInterval(12))
print("done")
