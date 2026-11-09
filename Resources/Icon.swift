import AppKit

// Draws the 一瞥 app icon: a graphite tile, two window cards fanned behind a light front card
// outlined in amber, and a small amber spark. Coordinates follow the 200-unit design grid (y down).
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let variants = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
                (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
                (512, "icon_512x512"), (1024, "icon_512x512@2x")]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

for (pixels, name) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let c = graphics.cgContext
    c.interpolationQuality = .high
    c.setShouldAntialias(true)
    let unit = CGFloat(pixels) / 1024
    // The macOS icon body is 824 of 1024 points; the design tile spans 8…192 of its 200-unit grid.
    let scale = 824.0 / 184.0 * unit
    c.translateBy(x: 100 * unit, y: CGFloat(pixels) - 100 * unit)
    c.scaleBy(x: scale, y: -scale)
    c.translateBy(x: -8, y: -8)

    // Tile
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit, color: color(0x000000, 0.28))
    c.addPath(rounded(CGRect(x: 8, y: 8, width: 184, height: 184), 41.5))
    c.setFillColor(color(0x1C1E22)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(rounded(CGRect(x: 8, y: 8, width: 184, height: 184), 41.5)); c.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x34373E), color(0x1C1E22), color(0x15161A)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 100, y: 8), end: CGPoint(x: 100, y: 192), options: [])
    c.restoreGState()

    // Back cards, fanned
    func card(_ rect: CGRect, angle: CGFloat, around center: CGPoint, fill: UInt32) {
        c.saveGState()
        c.translateBy(x: center.x, y: center.y); c.rotate(by: angle * .pi / 180); c.translateBy(x: -center.x, y: -center.y)
        c.addPath(rounded(rect, 12)); c.setFillColor(color(fill)); c.fillPath()
        c.restoreGState()
    }
    card(CGRect(x: 40, y: 58, width: 104, height: 76), angle: -11, around: CGPoint(x: 92, y: 96), fill: 0x3B3E45)
    card(CGRect(x: 47, y: 68, width: 104, height: 76), angle: -4, around: CGPoint(x: 99, y: 106), fill: 0x5B5F67)

    // Front card
    let front = CGRect(x: 54, y: 82, width: 106, height: 78)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 22 * unit, color: color(0x000000, 0.35))
    c.addPath(rounded(front, 12)); c.setFillColor(color(0xF6F6F3)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(rounded(front, 12)); c.clip()
    c.setFillColor(color(0xE4E3DD)); c.fill(CGRect(x: 54, y: 82, width: 106, height: 18))
    c.restoreGState()
    c.setFillColor(color(0xB4B5AF))
    for x in [67.0, 77.0, 87.0] { c.fillEllipse(in: CGRect(x: x - 3, y: 88, width: 6, height: 6)) }
    for (rect, fill) in [(CGRect(x: 68, y: 112, width: 54, height: 8), 0xC3C4BE), (CGRect(x: 68, y: 128, width: 78, height: 8), 0xDCDCD6),
                         (CGRect(x: 68, y: 144, width: 40, height: 6), 0xDCDCD6)] as [(CGRect, UInt32)] {
        c.addPath(rounded(rect, rect.height / 2)); c.setFillColor(color(fill)); c.fillPath()
    }
    // Amber outline: the window you are about to land on
    c.addPath(rounded(front.insetBy(dx: -0.5, dy: -0.5), 12.5))
    c.setStrokeColor(color(0xF0A030)); c.setLineWidth(5); c.strokePath()

    // Spark
    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: 154, y: 34))
    spark.addQuadCurve(to: CGPoint(x: 174, y: 54), control: CGPoint(x: 154, y: 54))
    spark.addQuadCurve(to: CGPoint(x: 154, y: 74), control: CGPoint(x: 154, y: 54))
    spark.addQuadCurve(to: CGPoint(x: 134, y: 54), control: CGPoint(x: 154, y: 54))
    spark.addQuadCurve(to: CGPoint(x: 154, y: 34), control: CGPoint(x: 154, y: 54))
    spark.closeSubpath()
    c.addPath(spark); c.setFillColor(color(0xF0A030)); c.fillPath()

    graphics.flushGraphics()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name).png"))
}
