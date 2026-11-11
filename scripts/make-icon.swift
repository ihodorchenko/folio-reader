// Draws the 1024×1024 Folio icon PNG: a rounded tile, a page with text
// and a magnifying glass (reader + force-click dictionary).
//
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("failed to create the context")
}
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// ── 1. Background: rounded tile with a gradient and a soft shadow ─────────────
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = roundedPath(tile, radius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 46,
              color: rgb(0.08, 0.10, 0.25, 0.45))
ctx.setFillColor(rgb(0.30, 0.34, 0.92))
ctx.addPath(tilePath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgb(0.40, 0.53, 0.98), rgb(0.45, 0.25, 0.86), rgb(0.24, 0.16, 0.55)] as CFArray,
    locations: [0.0, 0.58, 1.0]
)!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 140, y: 900),
                       end: CGPoint(x: 900, y: 120),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Subtle highlight at the top
let gloss = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gloss,
                       start: CGPoint(x: 300, y: 924),
                       end: CGPoint(x: 300, y: 520),
                       options: [])
ctx.restoreGState()

// Tile outline
ctx.addPath(tilePath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
ctx.setLineWidth(3)
ctx.strokePath()

// ── 2. Document page ─────────────────────────────────────────────────────────
let page = CGRect(x: 268, y: 214, width: 448, height: 596)
let pagePath = roundedPath(page, radius: 34)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.35))
ctx.setFillColor(rgb(1, 1, 1))
ctx.addPath(pagePath)
ctx.fillPath()
ctx.restoreGState()

// Text lines: the first one is the "heading" in the accent color, the rest are gray.
func drawLine(y: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    let rect = CGRect(x: page.minX + 44, y: page.minY + y, width: width, height: height)
    ctx.setFillColor(color)
    ctx.addPath(roundedPath(rect, radius: height / 2))
    ctx.fillPath()
}

let ink = rgb(0.16, 0.18, 0.28)
let lightInk = rgb(0.78, 0.80, 0.88)
let accent = rgb(1.0, 0.55, 0.22)
drawLine(y: 486, width: 232, height: 34, color: accent)   // heading
drawLine(y: 424, width: 340, height: 20, color: ink)
drawLine(y: 388, width: 300, height: 20, color: lightInk)
drawLine(y: 352, width: 336, height: 20, color: lightInk)
drawLine(y: 316, width: 268, height: 20, color: lightInk)
drawLine(y: 280, width: 312, height: 20, color: lightInk)
drawLine(y: 244, width: 236, height: 20, color: lightInk)

// ── 3. Magnifying glass ──────────────────────────────────────────────────────
let lensCenter = CGPoint(x: 706, y: 372)
let lensRadius: CGFloat = 124
let glass = rgb(0.10, 0.13, 0.28)
let glassTint = rgb(0.55, 0.70, 1.0, 0.35)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0, 0, 0, 0.35))
// lens: light fill + thick outline
ctx.setFillColor(rgb(1, 1, 1, 0.92))
ctx.fillEllipse(in: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                           width: lensRadius * 2, height: lensRadius * 2))
ctx.restoreGState()

// highlight inside the lens
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                          width: lensRadius * 2, height: lensRadius * 2))
ctx.clip()
ctx.setFillColor(glassTint)
ctx.fill(CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                width: lensRadius * 2, height: lensRadius * 2))
ctx.restoreGState()

// handle
ctx.saveGState()
ctx.setStrokeColor(glass)
ctx.setLineWidth(52)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: lensCenter.x + 88, y: lensCenter.y - 88))
ctx.addLine(to: CGPoint(x: 884, y: 194))
ctx.strokePath()
ctx.restoreGState()

// lens outline
ctx.setStrokeColor(glass)
ctx.setLineWidth(34)
ctx.strokeEllipse(in: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                             width: lensRadius * 2, height: lensRadius * 2))

// the "word" inside the lens — three short strokes
ctx.setFillColor(rgb(0.35, 0.40, 0.62))
for (offset, width) in [(CGFloat(26), CGFloat(96)), (CGFloat(-6), CGFloat(126)), (CGFloat(-38), CGFloat(78))] {
    let rect = CGRect(x: lensCenter.x - 62, y: lensCenter.y + offset, width: width, height: 16)
    ctx.addPath(roundedPath(rect, radius: 8))
    ctx.fillPath()
}

// ── 4. Saving ────────────────────────────────────────────────────────────────
guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode the PNG")
}
try data.write(to: URL(fileURLWithPath: outPath))
print("OK: \(outPath) (\(Int(image.width))×\(Int(image.height)))")
