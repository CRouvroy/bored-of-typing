import AppKit
import CoreImage
import SwiftUI

/// Cached native drawing only: no web content, executable markup or image URLs.
@MainActor final class BoardOverlayRenderer {
    static let shared = BoardOverlayRenderer()
    private let cache = NSCache<NSString, NSImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    init() { cache.totalCostLimit = 32 * 1_024 * 1_024; cache.countLimit = 24 }

    func raster(overlays: [BoardOverlay], region: BoardAnnotation, size: CGSize, fadedIDs: Set<UUID> = [], foregroundMasks: [UUID: CGImage] = [:]) -> NSImage? {
        let visible = selected(overlays, regionID: region.id, fadedIDs: fadedIDs)
        guard !visible.isEmpty, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, 1_024 / max(size.width, size.height))
        let pixels = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        if visible.contains(where: { foregroundMasks[$0.id] != nil }) {
            guard let context = bitmap(pixels) else { return nil }
            for overlay in visible {
                guard let flat = raster(overlays: [overlay], region: region, size: size),
                      let cg = BoardLibrary.cgImage(flat) else { continue }
                let output: CGImage
                if let mask = foregroundMasks[overlay.id] {
                    guard let punched = masked(cg, foreground: mask) else { continue }; output = punched
                } else { output = cg }
                context.draw(output, in: CGRect(origin: .zero, size: pixels))
            }
            guard let output = context.makeImage() else { return nil }
            return NSImage(cgImage: output, size: pixels)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(visible) else { return nil }
        var hash = Hasher(); hash.combine(encoded)
        let key = "\(region.id):\(Int(pixels.width))x\(Int(pixels.height)):\(hash.finalize())" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let context = bitmap(pixels) else { return nil }
        draw(visible, size: pixels, context: context)
        guard let cg = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: pixels)
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    /// Draws vectors at the original image resolution; callers add annotation outlines afterward.
    func compose(image: NSImage, overlays: [BoardOverlay], annotations: [BoardAnnotation], fadedIDs: Set<UUID> = [], foregroundMasks: [UUID: CGImage] = [:]) -> NSImage? {
        guard let source = BoardLibrary.cgImage(image) else { return nil }
        let size = CGSize(width: source.width, height: source.height)
        guard let context = bitmap(size) else { return nil }
        context.draw(source, in: CGRect(origin: .zero, size: size))
        for region in annotations {
            let visible = selected(overlays, regionID: region.id, fadedIDs: fadedIDs)
            guard !visible.isEmpty else { continue }
            let rect = BoardGeometry.pixelRect(region.rect, imageSize: size)
            guard rect.width > 0, rect.height > 0 else { continue }
            context.saveGState(); context.clip(to: rect); context.translateBy(x: rect.minX, y: rect.minY)
            for overlay in visible {
                if let mask = foregroundMasks[overlay.id] {
                    guard let layer = bitmap(CGSize(width: ceil(rect.width), height: ceil(rect.height))) else { continue }
                    draw([overlay], size: rect.size, context: layer)
                    if let cg = layer.makeImage(), let punched = masked(cg, foreground: mask) {
                        context.draw(punched, in: CGRect(origin: .zero, size: rect.size))
                    }
                } else { draw([overlay], size: rect.size, context: context) }
            }
            context.restoreGState()
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }

    /// Transparent viewport image. Each region is warped through the tracked board plane.
    func projected(overlays: [BoardOverlay], annotations: [BoardAnnotation], quad: BoardQuad,
                   imageSize: CGSize, outputSize: CGSize, fadedIDs: Set<UUID> = [], foregroundMasks: [UUID: CGImage] = [:]) -> NSImage? {
        guard !overlays.isEmpty, imageSize.width > 0, imageSize.height > 0,
              outputSize.width.isFinite, outputSize.height.isFinite, outputSize.width > 0, outputSize.height > 0,
              let map = BoardProjectiveMap(corners: quad.points) else { return nil }
        let scale = min(2, 2_048 / max(outputSize.width, outputSize.height))
        let pixels = CGSize(width: max(1, (outputSize.width * scale).rounded()), height: max(1, (outputSize.height * scale).rounded()))
        let fit = min(pixels.width / imageSize.width, pixels.height / imageSize.height)
        let imageRect = CGRect(x: (pixels.width - imageSize.width * fit) / 2, y: (pixels.height - imageSize.height * fit) / 2,
                               width: imageSize.width * fit, height: imageSize.height * fit)
        let extent = CGRect(origin: .zero, size: pixels)
        var result = CIImage(color: .clear).cropped(to: extent), count = 0
        for region in annotations {
            guard let corners = map.imageCorners(for: region.rect),
                  let flat = raster(overlays: overlays, region: region,
                    size: CGSize(width: region.width * imageSize.width, height: region.height * imageSize.height), fadedIDs: fadedIDs, foregroundMasks: foregroundMasks),
                  let source = BoardLibrary.cgImage(flat) else { continue }
            let p = corners.map { CIVector(x: imageRect.minX + $0.x * imageRect.width,
                                          y: pixels.height - imageRect.minY - $0.y * imageRect.height) }
            let warped = CIImage(cgImage: source).applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": p[0], "inputTopRight": p[1], "inputBottomRight": p[2], "inputBottomLeft": p[3]])
            result = warped.composited(over: result).cropped(to: extent); count += 1
        }
        guard count > 0, let cg = ciContext.createCGImage(result, from: extent) else { return nil }
        return NSImage(cgImage: cg, size: outputSize)
    }

    private func selected(_ overlays: [BoardOverlay], regionID: UUID, fadedIDs: Set<UUID>) -> [BoardOverlay] {
        overlays.filter { $0.regionID == regionID && !$0.hidden && $0.opacity > 0 && (try? $0.validate()) != nil }
            .map { value in var copy = value; if fadedIDs.contains(copy.id) { copy.opacity *= 0.22 }; return copy }
    }
    private func bitmap(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    /// Live masks are uniform temporary opacity; older saved spatial masks remain
    /// supported in parent-region coordinates. Apply after cache retrieval.
    private func masked(_ image: CGImage, foreground: CGImage) -> CGImage? {
        guard foreground.width > 0, foreground.height > 0 else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Live activity is a scalar alpha, not a color. Core Image color-manages
        // gray170 before blending (making it about0.4 rather than170/255).
        // Apply uniform masks directly so the requested one-third alpha is exact.
        if let value = uniformGray(foreground) {
            if value == 0 { return image }
            guard let context = bitmap(extent.size) else { return nil }
            context.setAlpha(1 - CGFloat(value) / 255)
            context.draw(image, in: extent)
            return context.makeImage()
        }
        let mask = CIImage(cgImage: foreground).transformed(by: CGAffineTransform(
            scaleX: CGFloat(image.width) / CGFloat(foreground.width), y: CGFloat(image.height) / CGFloat(foreground.height)))
        let clear = CIImage(color: .clear).cropped(to: extent)
        let output = clear.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: image), kCIInputMaskImageKey: mask])
        return ciContext.createCGImage(output, from: extent)
    }
    private func uniformGray(_ image: CGImage) -> UInt8? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 8,
              image.colorSpace?.numberOfComponents == 1,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let first = bytes[0]
        for y in 0..<image.height { for x in 0..<image.width {
            if bytes[y * image.bytesPerRow + x] != first { return nil }
        } }
        return first
    }
    private func draw(_ overlays: [BoardOverlay], size: CGSize, context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for overlay in overlays {
            // Frame coordinates are local to the user rectangle, never the camera.
            // Keep the containing canvas intact for homography and legacy masks.
            let placement = BoardGeometry.pixelRect(overlay.frame?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: size)
            guard placement.width > 0, placement.height > 0 else { continue }
            context.saveGState(); context.clip(to: placement)
            context.translateBy(x: placement.minX, y: placement.minY)
            context.setAlpha(overlay.opacity)
            let size = placement.size, unit = min(placement.width, placement.height)
            let bounds = CGRect(origin: .zero, size: size)
            // Cover old connectors only inside this note or diagram's own frame.
            panel(bounds.insetBy(dx: unit * 0.012, dy: unit * 0.012), radius: unit * 0.035, context: context)
            if overlay.kind == .text {
                let frame = bounds.insetBy(dx: unit * 0.08, dy: unit * 0.08)
                // Short, wide notes need readable type rather than a font that
                // shrinks in direct proportion to their small height.
                let font = overlay.frame == nil ? unit * 0.075 : min(max(unit * 0.075, size.width * 0.05), size.height * 0.22)
                text(overlay.text, frame: frame, fontSize: font, centered: false)
            } else {
                let nodes = Dictionary(uniqueKeysWithValues: overlay.nodes.map { ($0.id, $0) })
                for edge in overlay.edges {
                    guard let from = nodes[edge.from], let to = nodes[edge.to] else { continue }
                    let a = BoardGeometry.pixelRect(from.rect, imageSize: size), b = BoardGeometry.pixelRect(to.rect, imageSize: size)
                    let ac = CGPoint(x: a.midX, y: a.midY), bc = CGPoint(x: b.midX, y: b.midY)
                    let start = boundary(a, toward: bc), end = boundary(b, toward: ac)
                    arrow(from: start, to: end, unit: unit, context: context)
                    if !edge.label.isEmpty {
                        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                        let font = max(1, overlay.frame == nil ? unit * 0.043 : max(unit * 0.043, min(size.width * 0.024, unit * 0.09)))
                        let measured = (edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: font)])
                        let label = CGRect(x: middle.x - min(measured.width, size.width * 0.45) / 2 - font * 0.3,
                            y: middle.y - font * 0.85, width: min(measured.width, size.width * 0.45) + font * 0.6, height: font * 1.7)
                        panel(label, radius: font * 0.3, context: context)
                        text(edge.label, frame: label.insetBy(dx: font * 0.2, dy: 0), fontSize: font, centered: true)
                    }
                }
                for node in overlay.nodes {
                    let rect = BoardGeometry.pixelRect(node.rect, imageSize: size)
                    panel(rect.insetBy(dx: unit * 0.004, dy: unit * 0.004), radius: unit * 0.025, context: context)
                    context.setStrokeColor(NSColor(srgbRed: 0.74, green: 0.215, blue: 0.075, alpha: 0.8).cgColor)
                    context.setLineWidth(unit * 0.006)
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: unit * 0.004, dy: unit * 0.004), cornerWidth: unit * 0.025, cornerHeight: unit * 0.025, transform: nil)); context.strokePath()
                    let font = overlay.frame == nil ? min(unit * 0.065, rect.height * 0.24) :
                        min(max(unit * 0.065, size.width * 0.035), rect.height * 0.34, rect.width * 0.20)
                    text(node.label, frame: rect.insetBy(dx: unit * 0.025, dy: unit * 0.012),
                         fontSize: font, centered: true)
                }
            }
            context.restoreGState()
        }
    }
    private func panel(_ rect: CGRect, radius: CGFloat, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.setFillColor(NSColor(srgbRed: 0.994, green: 0.988, blue: 0.972, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
    }
    private func text(_ value: String, frame: CGRect, fontSize: CGFloat, centered: Bool) {
        guard !value.isEmpty, frame.width > 0, frame.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(1, fontSize), weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.20, alpha: 1), .paragraphStyle: paragraph]
        let value = NSAttributedString(string: value, attributes: attributes)
        let measured = value.boundingRect(with: frame.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = min(frame.height, measured.height)
        let target = CGRect(x: frame.minX, y: centered ? frame.midY - height / 2 : frame.maxY - height, width: frame.width, height: height)
        value.draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }
    private func boundary(_ rect: CGRect, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY), dx = point.x - center.x, dy = point.y - center.y
        let factor = min(abs(dx) > 1e-8 ? rect.width / 2 / abs(dx) : .infinity,
                         abs(dy) > 1e-8 ? rect.height / 2 / abs(dy) : .infinity)
        guard factor.isFinite else { return center }
        return CGPoint(x: center.x + dx * factor, y: center.y + dy * factor)
    }
    private func arrow(from a: CGPoint, to b: CGPoint, unit: CGFloat, context: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x), head = min(unit * 0.035, hypot(b.x - a.x, b.y - a.y) * 0.3)
        context.setStrokeColor(NSColor(srgbRed: 0.74, green: 0.215, blue: 0.075, alpha: 1).cgColor)
        context.setLineWidth(unit * 0.007); context.setLineCap(.round)
        context.move(to: a); context.addLine(to: b)
        context.move(to: CGPoint(x: b.x - head * cos(angle - 0.5), y: b.y - head * sin(angle - 0.5)))
        context.addLine(to: b); context.addLine(to: CGPoint(x: b.x - head * cos(angle + 0.5), y: b.y - head * sin(angle + 0.5))); context.strokePath()
    }
}

struct BoardLiveOverlayLayer: View {
    var overlays: [BoardOverlay]
    var annotations: [BoardAnnotation]
    var quad: BoardQuad
    var imageSize: CGSize
    var isLost: Bool = false
    var fadedIDs: Set<UUID> = []
    var foregroundMasks: [UUID: CGImage] = [:]
    var body: some View {
        GeometryReader { geometry in
            if let image = BoardOverlayRenderer.shared.projected(overlays: overlays, annotations: annotations,
                quad: quad, imageSize: imageSize, outputSize: geometry.size, fadedIDs: fadedIDs, foregroundMasks: foregroundMasks) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: geometry.size.width, height: geometry.size.height).opacity(isLost ? 0.35 : 1)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
