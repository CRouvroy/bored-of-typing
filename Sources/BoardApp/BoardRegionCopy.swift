import AppKit

/// A selection is a value captured when the menu item is clicked, before an
/// asynchronous camera frame arrives. It never resolves an ID against later edits.
@MainActor
enum BoardRegionCopy {
    struct Selection {
        let annotation: BoardAnnotation
        let title: String
        init(annotation: BoardAnnotation, index: Int) {
            self.annotation = annotation
            title = BoardRegionCopy.title(for: annotation, index: index)
        }
    }
    struct Prepared {
        let image: NSImage
        let annotation: BoardAnnotation
        let title: String
    }

    nonisolated static func title(for annotation: BoardAnnotation, index: Int) -> String {
        let label = annotation.label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return label.isEmpty ? "Rectangle \(index + 1)" : label
    }

    /// Crop the unannotated, perspective-corrected image first. Re-anchor the
    /// selected label inside the resulting image instead of cropping it away.
    static func prepare(image: NSImage, selection: Selection) throws -> Prepared {
        let a = selection.annotation
        guard [a.x, a.y, a.width, a.height].allSatisfy(\.isFinite),
              a.x >= 0, a.y >= 0, a.width > 0, a.height > 0,
              a.x + a.width <= 1.0000001, a.y + a.height <= 1.0000001,
              let source = BoardLibrary.cgImage(image) else { throw RegionError.invalidRegion }
        // A tiny tolerance prevents 0.2 + 0.4 rounding from adding a whole
        // extra pixel through CGRect.integral; genuinely fractional pixels round out.
        let left = max(0, Int(floor(a.x * Double(source.width) + 1e-7)))
        let top = max(0, Int(floor(a.y * Double(source.height) + 1e-7)))
        let right = min(source.width, Int(ceil((a.x + a.width) * Double(source.width) - 1e-7)))
        let bottom = min(source.height, Int(ceil((a.y + a.height) * Double(source.height) - 1e-7)))
        guard right > left, bottom > top,
              let pixels = source.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { throw RegionError.invalidRegion }
        let crop = NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
        var output = crop
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        // Very small crops need a narrow caption margin to keep their contents
        // and label readable. Do not rescale or discard any captured pixels.
        if pixels.width < 120 || pixels.height < 40 {
            let width = max(120, pixels.width), height = pixels.height + 30
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RegionError.invalidRegion }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let left = (width - pixels.width) / 2
            context.draw(pixels, in: CGRect(x: left, y: 0, width: pixels.width, height: pixels.height))
            guard let padded = context.makeImage() else { throw RegionError.invalidRegion }
            output = NSImage(cgImage: padded, size: CGSize(width: width, height: height))
            rect = CGRect(x: Double(left) / Double(width), y: 30.0 / Double(height),
                          width: Double(pixels.width) / Double(width), height: Double(pixels.height) / Double(height))
        }
        return Prepared(image: output, annotation: BoardAnnotation(rect: rect, label: selection.title), title: selection.title)
    }

    enum RegionError: LocalizedError {
        case invalidRegion
        var errorDescription: String? { "That rectangle could not be copied. Draw a valid rectangle inside the board and try again." }
    }
}
