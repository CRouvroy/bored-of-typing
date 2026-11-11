import AppKit
import Foundation

@main struct LibraryOverlayChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? value()) == true else { fatalError(message) }; checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoardLibraryOverlayChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func colorImage(_ width: Int, _ height: Int) -> NSImage {
            let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(NSColor(srgbRed: 0.15, green: 0.3, blue: 0.65, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return NSImage(cgImage: c.makeImage()!, size: CGSize(width: width, height: height))
        }
        func maskData(width: Int = 128, height: Int = 96) -> Data {
            var bytes = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height / 2 { for x in 0..<width / 2 { bytes[y * width + x] = 255 } }
            let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(bytes) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        }
        func pixel(_ image: NSImage, _ x: Int, _ y: Int) -> NSColor {
            NSBitmapImageRep(cgImage: BoardLibrary.cgImage(image)!).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }
        let original = colorImage(400, 300)
        let region = BoardAnnotation(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), label: "")
        let overlay = BoardOverlay(id: UUID(uuidString: "ABCDEFAB-1234-4000-8000-ABCDEFABCDEF")!, regionID: region.id,
                                   revision: 4, title: "Architecture", opacity: 1, text: "")
        let mask = maskData(), masks = [overlay.id.uuidString: mask]
        let store = BoardLibrary(rootURL: root.appendingPathComponent("library"))
        guard let snapshot = store.add(image: original, title: "Board with AI", annotations: [region],
            overlays: [overlay], overlayMasks: masks) else { fatalError(store.errorMessage ?? "add failed") }
        let originalURL = store.rootURL.appendingPathComponent("originals/\(snapshot.imageName)")
        let rawBytes = try Data(contentsOf: originalURL)
        expect(snapshot.overlays == [overlay] && snapshot.overlayMasks == masks, "Capture preserves overlay revision and mask provenance")
        expect(store.overlayMasks(for: snapshot)[overlay.id]?.width == 128, "Stored mask decodes for saved display")
        let raw = store.image(for: snapshot)!, display = store.displayImage(for: snapshot)!
        expect(pixel(raw, 280, 210).redComponent < 0.3, "image(for:) remains the physical photograph")
        expect(pixel(display, 120, 90).redComponent < 0.3, "White top-left mask preserves physical display pixels")
        expect(pixel(display, 280, 210).redComponent > 0.9, "Unmasked AI panel appears in saved display")
        expect(pixel(display, 40, 100).redComponent < 0.3, "Saved display excludes user annotation strokes")
        guard let export = store.exportAnnotated(snapshot: snapshot), let exported = NSImage(contentsOf: export) else { fatalError("export failed") }
        expect(BoardLibrary.cgImage(exported)!.width == 400, "Derived export retains raw resolution")
        expect(pixel(exported, 120, 90).redComponent < 0.3, "Copy/export preserves physical content under mask")
        expect(pixel(exported, 280, 210).redComponent > 0.9, "Copy/export includes AI panel")
        let border = pixel(exported, 40, 100)
        expect(border.redComponent > 0.6 && border.greenComponent < 0.5, "User annotation strokes render after AI")
        expect(try Data(contentsOf: originalURL) == rawBytes, "Display and export preserve original bytes")
        let firstExport = try Data(contentsOf: export)
        guard let published = store.publishCurrent(snapshot: snapshot), let manifest = store.currentManifest() else { fatalError("publish failed") }
        expect(manifest.overlays == [overlay] && manifest.overlayMasks == masks, "Current manifest retains AI/mask provenance")
        expect(manifest.imagePath == published.path && manifest.pixelWidth == 400 && manifest.pixelHeight == 300, "Manifest identifies derived full-resolution export")
        let reopened = BoardLibrary(rootURL: store.rootURL)
        expect(reopened.canWrite && reopened.snapshots.first?.overlays == snapshot.overlays && reopened.snapshots.first?.overlayMasks == masks,
               "Overlay metadata and PNG masks round-trip through schema1")
        var edited = snapshot; edited.overlays![0].hidden = true
        expect(store.update(snapshot: edited), "Saved overlay visibility may be edited independently")
        expect(pixel(store.displayImage(for: edited)!, 280, 210).redComponent < 0.3, "Hidden overlay disappears from saved display")
        expect(try Data(contentsOf: export) == firstExport && Data(contentsOf: originalURL) == rawBytes, "Later metadata edit preserves previous export and original")
        expect(reopened.snapshots.first?.overlays?.first?.hidden == false, "Another snapshot value is not mutated by saved edits")

        // A small note occupies only its own normalized frame inside the parent
        // annotation. Its photograph and placement metadata remain independent.
        let frame = BoardOverlayFrame(x: 0.15, y: 0.2, width: 0.4, height: 0.25)
        let small = BoardOverlay(regionID: region.id, revision: 1, title: "Small note", opacity: 1, text: "", frame: frame)
        let second = BoardOverlay(regionID: region.id, revision: 1, title: "Second note", opacity: 1, text: "",
                                  frame: BoardOverlayFrame(x: 0.65, y: 0.65, width: 0.25, height: 0.2))
        let placedStore = BoardLibrary(rootURL: root.appendingPathComponent("placed-notes"))
        let placed = placedStore.add(image: original, title: "Two small notes", annotations: [region], overlays: [small, second])!
        let placedDisplay = placedStore.displayImage(for: placed)!
        expect(pixel(placedDisplay, 150, 110).redComponent > 0.9, "Small note draws at its parent-relative top-left frame")
        expect(pixel(placedDisplay, 280, 210).redComponent > 0.9, "A second independently placed note remains visible")
        expect(pixel(placedDisplay, 280, 110).redComponent < 0.3, "Small notes leave the rest of their region untouched")
        expect(pixel(placedStore.image(for: placed)!, 150, 110).redComponent < 0.3, "Placed overlays never bake into the physical original")
        let placedReopened = BoardLibrary(rootURL: placedStore.rootURL)
        expect(placedReopened.canWrite && placedReopened.snapshots[0].overlays == [small, second], "Placed overlay frames round-trip through the library")
        let placedExport = placedStore.exportAnnotated(snapshot: placed)!
        expect(pixel(NSImage(contentsOf: placedExport)!, 150, 110).redComponent > 0.9, "Export uses the same bounded note placement")
        _ = placedStore.publishCurrent(snapshot: placed)
        expect(placedStore.currentManifest()?.overlays?.first?.frame == frame, "Published metadata keeps exact normalized placement")
        var badPlacement = placed
        badPlacement.overlays![0].frame = BoardOverlayFrame(x: 0.9, y: 0, width: 0.2, height: 0.2)
        expect(!placedStore.update(snapshot: badPlacement), "Saved overlays cannot escape their parent region")
        expect(placedStore.displayImage(for: badPlacement) == nil, "Invalid placement cannot silently render as a full-region overlay")
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overlay)) as! [String: Any]
        legacyObject.removeValue(forKey: "frame")
        let legacyOverlay = try JSONDecoder().decode(BoardOverlay.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        expect(legacyOverlay.frame == nil && legacyOverlay == overlay, "An older overlay with no frame keeps its full-region meaning")

        for invalid in [["../bad": mask], [UUID().uuidString: mask], [overlay.id.uuidString: Data("not a PNG".utf8)],
                        [overlay.id.uuidString: Data(repeating: 0, count: 65_537)], [overlay.id.uuidString: maskData(width: 64)],
                        [overlay.id.uuidString: BoardLibrary.pngData(colorImage(128, 96))!],
                        [overlay.id.uuidString: mask, overlay.id.uuidString.lowercased(): mask]] {
            var malformed = edited; malformed.overlayMasks = invalid
            expect(!store.update(snapshot: malformed), "Invalid, foreign or aliased masks must not save")
            expect(store.displayImage(for: malformed) == nil && store.exportAnnotated(snapshot: malformed) == nil,
                   "Invalid mask cannot silently render unmasked AI")
        }
        var tooMany = edited; tooMany.overlays = (0..<61).map { _ in BoardOverlay(regionID: region.id, revision: 1) }
        expect(!store.update(snapshot: tooMany), "At most60 overlays may belong to one snapshot")
        var duplicate = edited; duplicate.overlays = [overlay, overlay]
        expect(!store.update(snapshot: duplicate), "Overlay IDs must be unique")
        var noRevision = edited; noRevision.overlays![0].revision = 0
        expect(!store.update(snapshot: noRevision), "Captured overlay needs an assigned revision")
        let tooManyMasks = Dictionary(uniqueKeysWithValues: (0..<61).map { _ in (UUID().uuidString, mask) })
        expect((try? BoardLibrary.decodeOverlayMasks(tooManyMasks)) == nil, "At most60 masks may decode")
        let countBefore = try FileManager.default.contentsOfDirectory(atPath: store.rootURL.appendingPathComponent("originals").path).count
        expect(store.add(image: original, title: "Invalid", overlays: [overlay], overlayMasks: [overlay.id.uuidString: Data()]) == nil,
               "Invalid capture metadata is rejected before writing original")
        expect(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.appendingPathComponent("originals").path).count == countBefore,
               "Rejected metadata creates no stray original")

        let oldStore = BoardLibrary(rootURL: root.appendingPathComponent("old-schema1"))
        let old = oldStore.add(image: original, title: "Before AI")!
        var oldJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: oldStore.rootURL.appendingPathComponent("library.json"))) as! [String: Any]
        var oldRows = oldJSON["snapshots"] as! [[String: Any]]
        oldRows[0].removeValue(forKey: "overlays"); oldRows[0].removeValue(forKey: "overlayMasks"); oldJSON["snapshots"] = oldRows
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: oldStore.rootURL.appendingPathComponent("library.json"))
        let compatible = BoardLibrary(rootURL: oldStore.rootURL)
        expect(compatible.canWrite && compatible.snapshots.first?.overlays == nil && compatible.snapshots.first?.overlayMasks == nil,
               "Older schema1 without optional overlay fields opens")
        expect(compatible.exportAnnotated(snapshot: old) != nil, "Older schema1 exports normally")
        _ = compatible.publishCurrent(snapshot: old)
        expect(compatible.currentManifest()?.overlays == nil && compatible.currentManifest()?.overlayMasks == nil, "Old manifest optional fields decode nil")

        let corruptRoot = root.appendingPathComponent("corrupt-mask")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        var corruptJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: store.rootURL.appendingPathComponent("library.json"))) as! [String: Any]
        var rows = corruptJSON["snapshots"] as! [[String: Any]]
        rows[0]["overlayMasks"] = [overlay.id.uuidString: Data("invalid".utf8).base64EncodedString()]; corruptJSON["snapshots"] = rows
        let corruptBytes = try JSONSerialization.data(withJSONObject: corruptJSON)
        let corruptURL = corruptRoot.appendingPathComponent("library.json"); try corruptBytes.write(to: corruptURL)
        let blocked = BoardLibrary(rootURL: corruptRoot)
        expect(!blocked.canWrite && blocked.snapshots.isEmpty && blocked.add(image: original, title: "Cannot replace") == nil,
               "Corrupt saved mask makes library read-only")
        expect(try Data(contentsOf: corruptURL) == corruptBytes, "Corrupt mask bytes are preserved exactly")
        print("PASS: \(checks) saved AI overlay, mask, export, provenance and schema1 compatibility checks")
    }
}
