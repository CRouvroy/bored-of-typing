import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/make-icon.swift OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("Board.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let paper = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.91, alpha: 1)
let chalk = NSColor(calibratedRed: 0.99, green: 0.985, blue: 0.97, alpha: 1)
let graphite = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.24, alpha: 1)
let orange = NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.15, alpha: 1)

func line(_ points: [CGPoint], width: CGFloat, color: NSColor) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.move(to: first)
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Could not allocate icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        context.setAllowsAntialiasing(true)

        paper.setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 104, yRadius: 104).fill()

        // A physical board, with an annotation that remains recognizable at menu/Dock sizes.
        line([CGPoint(x: 210, y: 184), CGPoint(x: 175, y: 104)], width: 16, color: graphite)
        line([CGPoint(x: 302, y: 184), CGPoint(x: 337, y: 104)], width: 16, color: graphite)
        line([CGPoint(x: 196, y: 149), CGPoint(x: 316, y: 149)], width: 12, color: graphite)

        graphite.setFill()
        NSBezierPath(roundedRect: NSRect(x: 86, y: 181, width: 340, height: 231), xRadius: 19, yRadius: 19).fill()
        chalk.setFill()
        NSBezierPath(roundedRect: NSRect(x: 101, y: 198, width: 310, height: 198), xRadius: 7, yRadius: 7).fill()
        line([CGPoint(x: 78, y: 184), CGPoint(x: 434, y: 184)], width: 13, color: graphite)

        orange.withAlphaComponent(0.10).setFill()
        let annotation = NSBezierPath(roundedRect: NSRect(x: 127, y: 256, width: 139, height: 108), xRadius: 7, yRadius: 7)
        annotation.fill()
        orange.setStroke()
        annotation.lineWidth = 11
        annotation.stroke()
        line([CGPoint(x: 293, y: 344), CGPoint(x: 374, y: 344)], width: 10, color: graphite.withAlphaComponent(0.56))
        line([CGPoint(x: 293, y: 310), CGPoint(x: 350, y: 310)], width: 10, color: graphite.withAlphaComponent(0.36))
        line([CGPoint(x: 133, y: 228), CGPoint(x: 219, y: 228)], width: 8, color: graphite.withAlphaComponent(0.36))
        orange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 360, y: 218, width: 18, height: 18)).fill()

        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon")
        }
        try png.write(to: iconset.appendingPathComponent(filename), options: .atomic)
    }
}
print(iconset.path)
