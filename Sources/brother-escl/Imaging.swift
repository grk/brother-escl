import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Colour handling: the scanner always delivers colour JPEG; grey and black & white
/// are produced here so we only depend on the one well-understood data format.
enum Imaging {
    enum Mode: String { case color = "RGB24", gray = "Grayscale8", bw = "BlackAndWhite1" }

    /// Converts to the requested colour mode, drops rows past `lines` (ADF pages declare a
    /// placeholder height in the JPEG header) and, when `size` is given, returns exactly that
    /// many pixels: padded with white on the right/bottom (16 px width alignment, glass shorter
    /// than the advertised A4/Letter area) or cut off when the sheet is longer.
    static func convert(_ jpeg: Data, lines: Int, to mode: Mode, dpi: Int, size: (Int, Int)? = nil) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              var img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return jpeg }
        // The line counter can trail the real height by a row, so only trust it for placeholders.
        var cropped = false
        if lines > 0 && img.height > lines + 16,
           let c = img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: lines)) {
            (img, cropped) = (c, true)
        }
        let (w, h) = size ?? (img.width, img.height)
        if mode == .color && !cropped && w == img.width && h == img.height { return jpeg }

        let gray = mode != .color
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue
                                                   : CGImageAlphaInfo.noneSkipLast.rawValue) else { return jpeg }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))   // top-left
        if mode == .bw, let p = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            let stride = ctx.bytesPerRow
            for y in 0..<h { for x in 0..<w { p[y * stride + x] = p[y * stride + x] < 160 ? 0 : 255 } }
        }
        guard let out = ctx.makeImage() else { return jpeg }
        return encodeJPEG(out, dpi: dpi) ?? jpeg
    }

    static func encodeJPEG(_ img: CGImage, dpi: Int) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
