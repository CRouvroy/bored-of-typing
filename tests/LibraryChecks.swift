import AppKit
import Darwin
import Foundation

@main
struct LibraryChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? condition()) == true else { fatalError(message) }
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoardChecks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipped = BoardGeometry.clamped(CGRect(x: 0.8, y: 0.9, width: -1.1, height: -0.5))
        expect(abs(clipped.minX) < 0.0001 && abs(clipped.width - 0.8) < 0.0001, "Reverse drag must clamp to image")
        let pixels = BoardGeometry.pixelRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), imageSize: CGSize(width: 1000, height: 500))
        expect(abs(pixels.minY - 200) < 0.0001 && abs(pixels.width - 300) < 0.0001, "Top-left geometry must convert to bottom-left pixels")
        expect(BoardGeometry.clamped(CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.3)) == .zero, "Nonfinite geometry must be rejected")

        let width = 400, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: height - 20, width: 20, height: 20))
        let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: width, height: height))
        let store = BoardLibrary(rootURL: directory.appendingPathComponent("valid"))
        guard var snapshot = store.add(image: image, title: "Test capture") else { fatalError(store.errorMessage ?? "add failed") }
        expect(store.snapshots.count == 1, "Snapshot should be persisted")
        let originalURL = store.rootURL.appendingPathComponent("originals").appendingPathComponent(snapshot.imageName)
        let originalBytes = try Data(contentsOf: originalURL)
        snapshot.annotations = [BoardAnnotation(x: 0.25, y: 0.2, width: 0.5, height: 0.3, label: "Equation A")]
        snapshot.isPinned = true
        expect(store.update(snapshot: snapshot), "Annotation should save")
        expect(try Data(contentsOf: originalURL) == originalBytes, "Annotation save must preserve original bytes")
        let reloaded = BoardLibrary(rootURL: store.rootURL)
        expect(reloaded.snapshots.first?.annotations == snapshot.annotations && reloaded.snapshots.first?.isPinned == true, "Metadata must survive reopen")
        expect(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.appendingPathComponent("revisions").path).count == 1, "A metadata revision must precede update")
        guard let export = store.exportAnnotated(snapshot: snapshot), let exported = NSImage(contentsOf: export),
              let exportedCG = BoardLibrary.cgImage(exported) else { fatalError("export failed") }
        expect(exportedCG.width == width && exportedCG.height == height, "Export must retain source resolution")
        let bitmap = NSBitmapImageRep(cgImage: exportedCG)
        let border = bitmap.colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
        expect(border.redComponent > 0.6 && border.greenComponent < 0.5 && border.blueComponent < 0.3, "Border must appear in top-left-based expected region")
        let blue = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        expect(blue.blueComponent > 0.8 && blue.redComponent < 0.2, "Rendering must preserve source orientation")
        let emptyBottom = bitmap.colorAt(x: 100, y: 220)!.usingColorSpace(.deviceRGB)!
        expect(emptyBottom.redComponent > 0.95 && emptyBottom.greenComponent > 0.95, "Annotation must not be flipped to lower image")
        guard let crop = BoardLibrary.cropped(image, normalizedRect: CGRect(x: 0, y: 0, width: 0.05, height: 20.0 / 300.0)),
              let cropCG = BoardLibrary.cgImage(crop) else { fatalError("crop failed") }
        expect(cropCG.width == 20 && cropCG.height == 20, "Crop must retain selected source pixel dimensions")
        let croppedBlue = NSBitmapImageRep(cgImage: cropCG).colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        expect(croppedBlue.blueComponent > 0.8 && croppedBlue.redComponent < 0.2, "Top-left crop must match visible top-left source")

        expect(store.currentManifest() == nil, "No board should be published until requested")
        guard let published = store.publishCurrent(snapshot: snapshot), let manifest = store.currentManifest() else { fatalError("publish failed") }
        expect(manifest.snapshotID == snapshot.id && manifest.imagePath == published.path, "Manifest must identify the published immutable export")
        expect(manifest.annotations == snapshot.annotations && manifest.pixelWidth == width && manifest.pixelHeight == height,
               "Manifest must retain complete annotation text and original pixel dimensions")
        let manifestBeforeRead = try Data(contentsOf: store.currentManifestURL)
        _ = store.currentManifest()
        expect(try Data(contentsOf: store.currentManifestURL) == manifestBeforeRead, "Reading the manifest must not mutate disk")

        let lock = open(store.rootURL.appendingPathComponent(".library.lock").path, O_RDWR)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { fatalError("test lock unavailable") }
        var lockedUpdate = snapshot; lockedUpdate.title = "Must not save while locked"
        expect(!store.update(snapshot: lockedUpdate), "Competing writer lock must prevent metadata save")
        expect(store.snapshots.first?.title == snapshot.title, "Failed save must preserve the in-memory committed snapshot")
        flock(lock, LOCK_UN); close(lock)
        expect(store.update(snapshot: lockedUpdate), "Save must recover after the other writer releases its lock")
        snapshot = lockedUpdate

        var tampered = snapshot; tampered.imageName = "../secret.png"
        expect(!store.update(snapshot: tampered), "Original file reference may not be changed")
        var nonfinite = snapshot; nonfinite.annotations[0].x = .nan
        expect(!store.update(snapshot: nonfinite), "NaN annotation may not persist")
        for (name, bytes) in [("corrupt", Data("not json".utf8)),
                              ("newer", Data("{\"schemaVersion\":99,\"snapshots\":[]}".utf8))] {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let metadata = root.appendingPathComponent("library.json")
            try bytes.write(to: metadata)
            let blocked = BoardLibrary(rootURL: root)
            expect(!blocked.canWrite && blocked.add(image: image, title: "Must fail") == nil, "Invalid/newer library must block writes")
            expect(try Data(contentsOf: metadata) == bytes, "Invalid/newer library bytes must be preserved")
        }
        let concurrentData = Data("{\"schemaVersion\":99,\"snapshots\":[]}".utf8)
        try concurrentData.write(to: store.rootURL.appendingPathComponent("library.json"))
        snapshot.title = "Changed"
        expect(!store.update(snapshot: snapshot), "External metadata edit must block this writer")
        expect(try Data(contentsOf: store.rootURL.appendingPathComponent("library.json")) == concurrentData, "Concurrent writer bytes must survive")
        print("PASS: \(checks) persistence, geometry and raster rendering checks")
    }
}
