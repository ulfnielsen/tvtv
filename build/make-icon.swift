import AppKit
import Foundation

// TVTV icon — "Serif T on paper, over a faint table"
// Matches the tvmv icon style (serif capital in dark ink on a warm
// cream-to-parchment tile) but with a "T" and a very vague table grid
// behind the letter, evoking TVTV's parquet/csv table-viewing purpose.

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let tileSize = canvas - inset * 2          // 824
let cornerRadius = tileSize * 0.2237       // ~184

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("Failed to create bitmap rep\n".data(using: .utf8)!)
    exit(1)
}

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("Failed to create graphics context\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

cg.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let tileRect = NSRect(x: inset, y: inset, width: tileSize, height: tileSize)
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

// MARK: - Drop shadow (under the tile)
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
tilePath.fill()
cg.restoreGState()

// MARK: - Warm cream-to-parchment gradient fill
cg.saveGState()
tilePath.addClip()

let cream = NSColor(calibratedRed: 0.992, green: 0.972, blue: 0.929, alpha: 1.0)
let parchment = NSColor(calibratedRed: 0.945, green: 0.901, blue: 0.819, alpha: 1.0)
let gradient = NSGradient(colors: [cream, parchment])!
gradient.draw(in: tileRect, angle: -90)

// MARK: - Soft inner vignette (paper character)
let center = NSPoint(x: tileRect.midX, y: tileRect.midY)
let radial = NSGradient(colors: [
    NSColor.clear,
    NSColor(calibratedRed: 0.62, green: 0.54, blue: 0.40, alpha: 0.0),
    NSColor(calibratedRed: 0.50, green: 0.41, blue: 0.27, alpha: 0.16)
])!
radial.draw(fromCenter: center, radius: tileSize * 0.18,
            toCenter: center, radius: tileSize * 0.74,
            options: [])

// MARK: - Very vague table in the background
// A faint grid of columns/rows with a slightly stronger header band, kept
// low-contrast so it reads as texture behind the "T", not a foreground chart.
let tableInsetX = tileSize * 0.150
let tableInsetTop = tileSize * 0.175
let tableInsetBottom = tileSize * 0.150
let tableRect = NSRect(
    x: tileRect.minX + tableInsetX,
    y: tileRect.minY + tableInsetBottom,
    width: tileSize - tableInsetX * 2,
    height: tileSize - tableInsetTop - tableInsetBottom
)

let cols = 4
let rows = 6
let rowH = tableRect.height / CGFloat(rows)
let colW = tableRect.width / CGFloat(cols)

// Faint header band (top row) — a touch of tint so the grid reads as a table.
let headerFill = NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.20, alpha: 0.30)
headerFill.setFill()
NSBezierPath(rect: NSRect(x: tableRect.minX,
                          y: tableRect.maxY - rowH,
                          width: tableRect.width,
                          height: rowH)).fill()

// Grid lines — low alpha "vague" ink (a touch more visible than v1).
let gridColor = NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.20, alpha: 0.60)
gridColor.setStroke()
let grid = NSBezierPath()
grid.lineWidth = 3.75
// horizontal row lines (including top & bottom edges)
for r in 0...rows {
    let y = tableRect.minY + CGFloat(r) * rowH
    grid.move(to: NSPoint(x: tableRect.minX, y: y))
    grid.line(to: NSPoint(x: tableRect.maxX, y: y))
}
// vertical column lines (including left & right edges)
for c in 0...cols {
    let x = tableRect.minX + CGFloat(c) * colW
    grid.move(to: NSPoint(x: x, y: tableRect.minY))
    grid.line(to: NSPoint(x: x, y: tableRect.maxY))
}
grid.stroke()

cg.restoreGState()

// MARK: - Serif capital "T" glyph
func resolveFont(size: CGFloat) -> NSFont {
    let candidates = ["Source Serif 4 Semibold", "SourceSerif4-Semibold",
                      "Source Serif 4", "Georgia-Bold", "Georgia"]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    if #available(macOS 10.15, *) {
        return NSFont(descriptor:
            NSFont.systemFont(ofSize: size, weight: .semibold)
                .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,
            size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    return NSFont.boldSystemFont(ofSize: size)
}

let glyphFontSize = tileSize * 0.74
let inkColor = NSColor(calibratedRed: 0.149, green: 0.118, blue: 0.090, alpha: 1.0)
let font = resolveFont(size: glyphFontSize)

let glyph = "T"
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: inkColor,
    .kern: 0.0
]
let attr = NSAttributedString(string: glyph, attributes: attrs)

let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
let imgBounds = CTLineGetImageBounds(line, cg)

let opticalLift: CGFloat = tileSize * 0.015
let drawX = tileRect.midX - imgBounds.midX
let drawY = tileRect.midY - imgBounds.midY + opticalLift

cg.saveGState()
cg.textMatrix = .identity
cg.translateBy(x: drawX, y: drawY)
CTLineDraw(line, cg)
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Write PNG
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/ulfnielsen/dev/tvtv/build/icon-1024.png"
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(pngData.count) bytes)")
} catch {
    FileHandle.standardError.write("Failed to write PNG: \(error)\n".data(using: .utf8)!)
    exit(1)
}
