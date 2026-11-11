import AppKit
import Foundation

@main
struct RegionCopyChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? condition()) == true else { fatalError(message) }; checks += 1
        }
        let cg = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(NSColor.white.cgColor); cg.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        cg.setFillColor(NSColor.blue.cgColor); cg.fill(CGRect(x: 230, y: 380, width: 30, height: 30))
        cg.setFillColor(NSColor.red.cgColor); cg.fill(CGRect(x: 0, y: 580, width: 20, height: 20))
        let image = NSImage(cgImage: cg.makeImage()!, size: CGSize(width: 800, height: 600))
        var mark = BoardAnnotation(rect: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4), label: " Current\nArchitecture ")
        let selection = BoardRegionCopy.Selection(annotation: mark, index: 0)
        mark.x = 0.7; mark.label = "Changed after click"
        let prepared = try BoardRegionCopy.prepare(image: image, selection: selection)
        let pixels = BoardLibrary.cgImage(prepared.image)!
        expect(pixels.width == 400 && pixels.height == 240, "Normal region must retain source pixel resolution")
        expect(prepared.title == "Current Architecture", "Selection title must freeze and normalize whitespace")
        expect(prepared.annotation.label == prepared.title && prepared.annotation.rect == CGRect(x: 0, y: 0, width: 1, height: 1), "Only selected label must be re-anchored inside crop")
        let crop = NSBitmapImageRep(cgImage: pixels)
        let blue = crop.colorAt(x: 40, y: 80)!.usingColorSpace(.deviceRGB)!
        expect(blue.blueComponent > 0.8 && blue.redComponent < 0.2, "Crop must use top-left board coordinates, not flipped pixels")
        let topLeft = crop.colorAt(x: 5, y: 5)!.usingColorSpace(.deviceRGB)!
        expect(topLeft.redComponent > 0.95 && topLeft.greenComponent > 0.95, "Outside-board content must not enter crop")
        let rendered = BoardLibrary.render(prepared.image, annotations: [prepared.annotation])!
        let bitmap = NSBitmapImageRep(cgImage: BoardLibrary.cgImage(rendered)!)
        var captionPixels = 0
        for y in 0..<35 { for x in 0..<200 {
            let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if c.redComponent > 0.6 && c.greenComponent < 0.5 && c.blueComponent < 0.3 { captionPixels += 1 }
        } }
        expect(captionPixels > 400, "Selected label must remain inside the crop rather than being clipped above it")
        let retainedBlue = bitmap.colorAt(x: 40, y: 80)!.usingColorSpace(.deviceRGB)!
        expect(retainedBlue.blueComponent > 0.8 && retainedBlue.redComponent < 0.2, "Region content below the label must remain intact")
        let blank = BoardAnnotation(rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), label: " \n ")
        expect(BoardRegionCopy.title(for: blank, index: 2) == "Rectangle 3", "Unlabelled rectangles need stable menu fallback")
        let tiny = BoardAnnotation(rect: CGRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01), label: "Tiny")
        let tinyResult = try BoardRegionCopy.prepare(image: image, selection: .init(annotation: tiny, index: 0))
        let tinyPixels = BoardLibrary.cgImage(tinyResult.image)!
        expect(tinyPixels.width == 120 && tinyPixels.height == 36, "Tiny regions need caption margin without resampling their pixels")
        expect(abs(tinyResult.annotation.y - 30.0 / 36.0) < 1e-9, "Tiny region label must occupy its caption margin")
        for invalid in [BoardAnnotation(x: .nan, y: 0, width: 0.2, height: 0.2, label: "bad"),
                        BoardAnnotation(x: -0.1, y: 0, width: 0.2, height: 0.2, label: "bad"),
                        BoardAnnotation(x: 0.9, y: 0, width: 0.2, height: 0.2, label: "bad"),
                        BoardAnnotation(x: 0, y: 0, width: 0, height: 0.2, label: "bad")] {
            expect((try? BoardRegionCopy.prepare(image: image, selection: .init(annotation: invalid, index: 0))) == nil, "Invalid region must fail, never become full-board copy")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoardRegionChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BoardLibrary(rootURL: root)
        let original = library.add(image: image, title: "Original board")!
        let originalURL = root.appendingPathComponent("originals").appendingPathComponent(original.imageName)
        let before = try Data(contentsOf: originalURL)
        let previousExport = library.publishCurrent(snapshot: original)!
        let previousBytes = try Data(contentsOf: previousExport)
        var region = library.add(image: prepared.image, title: prepared.title)!
        region.annotations = [prepared.annotation]
        expect(library.update(snapshot: region), "Region must persist as its own version")
        let regionExport = library.publishCurrent(snapshot: region)!
        expect(library.currentManifest()?.snapshotID == region.id, "Published manifest must identify the region, not the full board")
        expect(library.currentManifest()?.pixelWidth == 400 && library.currentManifest()?.pixelHeight == 240, "Published dimensions must match cropped output")
        expect(try Data(contentsOf: originalURL) == before && Data(contentsOf: previousExport) == previousBytes, "Prior originals and exports must remain byte-identical")
        expect(regionExport != previousExport && library.snapshots.count == 2, "Region copy must create exactly one separate version")
        if let output = CommandLine.arguments.dropFirst().first {
            try BoardLibrary.pngData(rendered)!.write(to: URL(fileURLWithPath: output))
        }
        print("PASS: \(checks) region geometry, caption, persistence and immutability checks")
    }
}
