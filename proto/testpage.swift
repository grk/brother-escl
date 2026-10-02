// Generates an A4 scanner test page (testpage.pdf): edge rulers, color patches,
// gray ramp, text sizes and line-pair patterns.
import Foundation
import CoreGraphics
import CoreText

let mm: CGFloat = 72 / 25.4
let W = 210 * mm, H = 297 * mm
var box = CGRect(x: 0, y: 0, width: W, height: H)
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "testpage.pdf")
let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
// Top-left origin in millimetres.
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: mm, y: -mm)

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ pt: CGFloat, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, pt / mm, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
    ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ w: CGFloat = 0.15) {
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(w)
    ctx.move(to: CGPoint(x: x1, y: y1)); ctx.addLine(to: CGPoint(x: x2, y: y2)); ctx.strokePath()
}

// Rulers on all four edges, starting at the paper edge (printer margins will clip some).
for i in 0...210 {
    let l: CGFloat = i % 10 == 0 ? 6 : (i % 5 == 0 ? 4 : 2.5)
    line(CGFloat(i), 0, CGFloat(i), l); line(CGFloat(i), 297, CGFloat(i), 297 - l)
    if i % 10 == 0 && i > 0 && i < 210 { text("\(i)", CGFloat(i) + 0.5, 9, 6); text("\(i)", CGFloat(i) + 0.5, 290, 6) }
}
for i in 0...297 {
    let l: CGFloat = i % 10 == 0 ? 6 : (i % 5 == 0 ? 4 : 2.5)
    line(0, CGFloat(i), l, CGFloat(i)); line(210, CGFloat(i), 210 - l, CGFloat(i))
    if i % 10 == 0 && i > 10 && i < 290 { text("\(i)", 7, CGFloat(i) + 1, 6); text("\(i)", 196, CGFloat(i) + 1, 6) }
}
// Frame 15 mm in from each edge.
ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(0.3)
ctx.stroke(CGRect(x: 15, y: 15, width: 180, height: 267))

text("brother-escl · scanner test page", 20, 26, 16, bold: true)
text("A4 210 × 297 mm · print at 100 % · ↑ this edge to the top, printed side down on the glass", 20, 32, 8)

// Color patches.
let colors: [(String, CGColor)] = [
    ("R", CGColor(red: 1, green: 0, blue: 0, alpha: 1)), ("G", CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
    ("B", CGColor(red: 0, green: 0, blue: 1, alpha: 1)), ("C", CGColor(red: 0, green: 1, blue: 1, alpha: 1)),
    ("M", CGColor(red: 1, green: 0, blue: 1, alpha: 1)), ("Y", CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
    ("K", CGColor(gray: 0, alpha: 1)), ("skin", CGColor(red: 0.91, green: 0.72, blue: 0.6, alpha: 1)),
    ("sky", CGColor(red: 0.4, green: 0.6, blue: 0.85, alpha: 1))]
text("Colors", 20, 42, 9, bold: true)
for (i, (n, c)) in colors.enumerated() {
    let x = 20 + CGFloat(i) * 19.5
    rect(x, 45, 17, 17, c); text(n, x, 66, 7)
}

// Gray ramp 0–100 % in 11 steps.
text("Gray scale (0–100 %)", 20, 77, 9, bold: true)
for i in 0...10 {
    let x = 20 + CGFloat(i) * 15.9
    rect(x, 80, 15.9, 14, CGColor(gray: 1 - CGFloat(i) / 10, alpha: 1)); text("\(i * 10)", x + 4, 98, 6)
}
ctx.setLineWidth(0.15); ctx.stroke(CGRect(x: 20, y: 80, width: 15.9 * 11, height: 14))

// Text sizes.
text("Text", 20, 110, 9, bold: true)
var y: CGFloat = 116
for pt in [4, 5, 6, 8, 10, 12, 16, 24] as [CGFloat] {
    y += pt * 0.42 + 2
    text("\(Int(pt)) pt  The quick brown fox" + (pt < 16 ? " 0123456789 · Zażółć gęślą jaźń" : " 0123"), 20, y, pt)
}

// Line-pair patterns: lines per mm.
text("Line pairs (lines / mm)", 20, 182, 9, bold: true)
for (i, lpmm) in ([1, 2, 3, 4, 5, 6, 8] as [CGFloat]).enumerated() {
    let x0 = 20 + CGFloat(i) * 25, pitch = 1 / lpmm
    var x = x0
    while x < x0 + 20 { rect(x, 186, pitch / 2, 20, CGColor(gray: 0, alpha: 1)); x += pitch }
    text("\(Int(lpmm))", x0 + 8, 211, 7)
}

// Diagonal + circle for geometry / skew check.
ctx.setLineWidth(0.3)
ctx.strokeEllipse(in: CGRect(x: 20, y: 220, width: 50, height: 50))
line(20, 220, 70, 270, 0.3); line(70, 220, 20, 270, 0.3)
text("50 mm circle — should come out round", 75, 245, 8)
text("Frame 15 mm from the edges · rulers start at 0 mm at the paper edge", 75, 252, 8)

// Corner labels.
text("TL", 17, 20, 7, bold: true); text("TR", 186, 20, 7, bold: true)
text("BL", 17, 280, 7, bold: true); text("BR", 186, 280, 7, bold: true)

ctx.endPDFPage()
ctx.closePDF()
print("wrote \(url.path)")
