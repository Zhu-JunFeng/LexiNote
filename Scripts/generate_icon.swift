import AppKit
import Foundation

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("LexiNote/Resources/Assets.xcassets")
private let appIcon = root.appendingPathComponent("AppIcon.appiconset")
private let menuIcon = root.appendingPathComponent("MenuBarGlyph.imageset")

try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuIcon, withIntermediateDirectories: true)

private func render(size: Int, draw: (CGContext) -> Void) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "LexiNoteIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(context)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LexiNoteIcon", code: 2)
    }
    return data
}

private func drawAppIcon(_ context: CGContext) {
    let green = NSColor(srgbRed: 0.13, green: 0.31, blue: 0.25, alpha: 1)
    let cream = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.93, alpha: 1)
    let muted = NSColor(srgbRed: 0.72, green: 0.80, blue: 0.70, alpha: 1)

    context.setFillColor(green.cgColor)
    context.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944),
                           cornerWidth: 210, cornerHeight: 210, transform: nil))
    context.fillPath()

    // One quiet line gives the mark depth without adding detail at menu sizes.
    context.setStrokeColor(muted.withAlphaComponent(0.45).cgColor)
    context.setLineWidth(10)
    context.move(to: CGPoint(x: 330, y: 746))
    context.addLine(to: CGPoint(x: 694, y: 746))
    context.strokePath()

    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 300, y: 808))
    ribbon.addQuadCurve(to: CGPoint(x: 328, y: 836), control: CGPoint(x: 300, y: 836))
    ribbon.addLine(to: CGPoint(x: 696, y: 836))
    ribbon.addQuadCurve(to: CGPoint(x: 724, y: 808), control: CGPoint(x: 724, y: 836))
    ribbon.addLine(to: CGPoint(x: 724, y: 236))
    ribbon.addLine(to: CGPoint(x: 512, y: 354))
    ribbon.addLine(to: CGPoint(x: 300, y: 236))
    ribbon.closeSubpath()
    context.setFillColor(cream.cgColor)
    context.addPath(ribbon)
    context.fillPath()

    context.setFillColor(green.cgColor)
    let letter = NSAttributedString(string: "L", attributes: [
        .font: NSFont(name: "Georgia-Bold", size: 360) ?? NSFont.boldSystemFont(ofSize: 360),
        .foregroundColor: green
    ])
    let letterSize = letter.size()
    letter.draw(at: NSPoint(x: 512 - letterSize.width / 2 - 8, y: 424))
}

private func drawMenuIcon(_ context: CGContext) {
    context.scaleBy(x: 16, y: 16) // 1024-point canvas -> 64-point mark
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 11, y: 59))
    ribbon.addLine(to: CGPoint(x: 53, y: 59))
    ribbon.addLine(to: CGPoint(x: 53, y: 7))
    ribbon.addLine(to: CGPoint(x: 32, y: 19))
    ribbon.addLine(to: CGPoint(x: 11, y: 7))
    ribbon.closeSubpath()
    context.setFillColor(NSColor.black.cgColor)
    context.addPath(ribbon)
    context.fillPath()

    context.setBlendMode(.clear)
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(5.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 26, y: 47))
    context.addLine(to: CGPoint(x: 26, y: 29))
    context.addLine(to: CGPoint(x: 40, y: 29))
    context.strokePath()
    context.setBlendMode(.normal)
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let data = try render(size: size, draw: drawAppIcon)
    try data.write(to: appIcon.appendingPathComponent("icon-\(size).png"), options: .atomic)
}
for size in [18, 36] {
    let data = try render(size: size, draw: drawMenuIcon)
    try data.write(to: menuIcon.appendingPathComponent("glyph-\(size).png"), options: .atomic)
}
