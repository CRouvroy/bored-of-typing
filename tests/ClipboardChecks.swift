import AppKit
import Foundation

@main struct ClipboardChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("research.board.clipboard-checks.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Board clipboard é \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 12, bitsPerPixel: 32)!
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                             255, 255, 0, 255, 0, 0, 0, 255, 102, 153, 51, 128]
        for (index, byte) in rgba.enumerated() { original.bitmapData![index] = byte }
        let source = original.representation(using: .png, properties: [:])!
        let imageURL = root.appendingPathComponent("annotated board.png")
        try source.write(to: imageURL)
        try BoardClipboard.copyImage(at: imageURL, to: pasteboard)
        expect(pasteboard.pasteboardItems?.count == 1, "Image should be one pasteboard item")
        expect(pasteboard.string(forType: .string) == nil, "Image copy must not advertise path text")
        expect(pasteboard.data(forType: .fileURL) == nil, "Image copy must not advertise file URLs")
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), let actual = NSBitmapImageRep(data: data) else {
                fatalError("Missing or undecodable \(type.rawValue)")
            }
            expect(actual.pixelsWide == 3 && actual.pixelsHigh == 2, "Image dimensions changed")
            for y in 0..<2 { for x in 0..<3 {
                // Compare decoded image-space components, not this display's device profile.
                let a = actual.colorAt(x: x, y: y)!
                let i = (y * 3 + x) * 4
                expect(abs(a.redComponent - CGFloat(rgba[i]) / 255) < 0.01 &&
                       abs(a.greenComponent - CGFloat(rgba[i + 1]) / 255) < 0.01 &&
                       abs(a.blueComponent - CGFloat(rgba[i + 2]) / 255) < 0.01 &&
                       abs(a.alphaComponent - CGFloat(rgba[i + 3]) / 255) < 0.01,
                       "Decoded \(type.rawValue) pixel differs at \(x),\(y): \(a.redComponent),\(a.greenComponent),\(a.blueComponent),\(a.alphaComponent)")
            } }
        }

        try BoardClipboard.copyFolder(root, to: pasteboard)
        expect(pasteboard.string(forType: .string) == root.standardizedFileURL.path, "Folder should copy its absolute path exactly")
        expect(pasteboard.string(forType: .string)?.hasPrefix("/") == true, "Folder path must be absolute")
        expect(pasteboard.data(forType: .png) == nil && pasteboard.data(forType: .tiff) == nil,
               "Folder copy should replace image types")

        let sentinel = "Preserve this test clipboard on validation failure"
        func expectFailurePreservesClipboard(_ operation: () throws -> Void) {
            pasteboard.clearContents()
            pasteboard.setString(sentinel, forType: .string)
            do { try operation(); fatalError("Expected clipboard validation failure") }
            catch { expect(!error.localizedDescription.isEmpty, "Clipboard errors should be localized") }
            expect(pasteboard.string(forType: .string) == sentinel, "Validation error cleared the clipboard")
        }
        expectFailurePreservesClipboard { try BoardClipboard.copyImage(at: root.appendingPathComponent("missing.png"), to: pasteboard) }
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        expectFailurePreservesClipboard { try BoardClipboard.copyImage(at: invalid, to: pasteboard) }
        expectFailurePreservesClipboard { try BoardClipboard.copyFolder(imageURL, to: pasteboard) }
        expectFailurePreservesClipboard { try BoardClipboard.copyImage(at: URL(string: "https://example.invalid/image.png")!, to: pasteboard) }
        print("PASS: \(checks) clipboard format, pixel, path and failure-preservation checks. General clipboard untouched.")
    }
}
