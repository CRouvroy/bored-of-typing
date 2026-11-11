import AppKit
import Combine
import Darwin
import Foundation
import ImageIO

/// Coordinates are fractions of the original image, with (0, 0) at its top left.
struct BoardAnnotation: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var label: String

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double, label: String) {
        self.id = id
        self.x = x; self.y = y; self.width = width; self.height = height
        self.label = label
    }

    init(id: UUID = UUID(), rect: CGRect, label: String) {
        let clipped = BoardGeometry.clamped(rect)
        self.init(id: id, x: clipped.minX, y: clipped.minY,
                  width: clipped.width, height: clipped.height, label: label)
    }
}

struct BoardSnapshot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String
    var imageName: String
    var annotations: [BoardAnnotation] = []
    var isPinned: Bool = false
    var overlays: [BoardOverlay]? = nil
    /// Per-overlay grayscale PNG: white preserves physical content, black displays AI.
    var overlayMasks: [String: Data]? = nil
}

/// Small on-demand entry point for assistants. Reading it does not load the image.
struct BoardCurrentManifest: Codable, Equatable {
    let schemaVersion: Int
    let publishedAt: Date
    let snapshotID: UUID
    let capturedAt: Date
    let title: String
    let imagePath: String
    let pixelWidth: Int
    let pixelHeight: Int
    let coordinates: String
    let annotations: [BoardAnnotation]
    var overlays: [BoardOverlay]? = nil
    var overlayMasks: [String: Data]? = nil
}

enum BoardGeometry {
    /// Standardizes reverse drags, clips them to the image, rejects nonfinite coordinates.
    static func clamped(_ rect: CGRect) -> CGRect {
        guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy({ $0.isFinite }) else { return .zero }
        let standard = rect.standardized
        let left = min(1, max(0, standard.minX)), top = min(1, max(0, standard.minY))
        let right = min(1, max(0, standard.maxX)), bottom = min(1, max(0, standard.maxY))
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        return clamped(CGRect(x: rect.origin.x / size.width, y: rect.origin.y / size.height,
                              width: rect.width / size.width, height: rect.height / size.height))
    }

    /// Pixel rectangle for AppKit/Core Graphics' unflipped, bottom-left drawing context.
    static func pixelRect(_ normalized: CGRect, imageSize: CGSize) -> CGRect {
        let r = clamped(normalized)
        return CGRect(x: r.minX * imageSize.width, y: (1 - r.maxY) * imageSize.height,
                      width: r.width * imageSize.width, height: r.height * imageSize.height)
    }
}

@MainActor
final class BoardLibrary: ObservableObject {
    @Published private(set) var snapshots: [BoardSnapshot] = []
    @Published var errorMessage: String?
    let rootURL: URL
    private(set) var canWrite = true
    private var loadedMetadata: Data?
    private let manager = FileManager.default
    private var metadataURL: URL { rootURL.appendingPathComponent("library.json") }
    private var imagesURL: URL { rootURL.appendingPathComponent("originals", isDirectory: true) }
    var currentManifestURL: URL { rootURL.appendingPathComponent("current.json") }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var snapshots: [BoardSnapshot]
    }

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Board", isDirectory: true)
        load()
    }

    @discardableResult
    func add(image: NSImage, title: String, annotations: [BoardAnnotation] = [],
             overlays: [BoardOverlay]? = nil, overlayMasks: [String: Data]? = nil) -> BoardSnapshot? {
        guard canWrite else { return nil }
        do {
            try checkMetadataUnchanged()
            guard let data = Self.pngData(image) else { throw LibraryError.imageEncoding }
            let id = UUID()
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = BoardSnapshot(id: id, title: trimmed.isEmpty ? "Board capture" : trimmed,
                                     imageName: "\(id.uuidString).png", annotations: annotations,
                                     overlays: overlays, overlayMasks: overlayMasks)
            guard Self.valid(item) else { throw LibraryError.invalidMetadata }
            try manager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
            // A new UUID names every original. No save or export ever overwrites one.
            try data.write(to: imagesURL.appendingPathComponent(item.imageName), options: .withoutOverwriting)
            try persist([item] + snapshots)
            errorMessage = nil
            return item
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func update(snapshot: BoardSnapshot) -> Bool {
        guard canWrite else { return false }
        do {
            guard let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { throw LibraryError.unknownSnapshot }
            let previous = snapshots[index]
            guard previous.imageName == snapshot.imageName, previous.createdAt == snapshot.createdAt else {
                throw LibraryError.originalChanged
            }
            guard Self.valid(snapshot) else { throw LibraryError.invalidMetadata }
            if snapshot == previous { return true }
            var updated = snapshots
            updated[index] = snapshot
            try persist(updated)
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func image(for snapshot: BoardSnapshot) -> NSImage? {
        guard Self.safeImageName(snapshot.imageName) else { return nil }
        let url = imagesURL.appendingPathComponent(snapshot.imageName)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Snapshot overlays are derived from the immutable camera image. AnnotationCanvas
    /// draws the user rectangles separately, so they are not included here.
    func displayImage(for snapshot: BoardSnapshot) -> NSImage? {
        do {
            guard Self.valid(snapshot), let source = image(for: snapshot) else { throw LibraryError.invalidMetadata }
            guard let overlays = snapshot.overlays, !overlays.isEmpty else { return source }
            let masks = try Self.decodeOverlayMasks(snapshot.overlayMasks)
            guard let composed = BoardOverlayRenderer.shared.compose(image: source, overlays: overlays,
                annotations: snapshot.annotations, foregroundMasks: masks) else { throw LibraryError.imageEncoding }
            return composed
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Loaded snapshots have already passed mask validation. An invalid ad-hoc snapshot
    /// reports an error; displayImage/exportAnnotated independently refuse it.
    func overlayMasks(for snapshot: BoardSnapshot) -> [UUID: CGImage] {
        do {
            try Self.validateOverlayContent(overlays: snapshot.overlays, masks: snapshot.overlayMasks)
            return try Self.decodeOverlayMasks(snapshot.overlayMasks)
        } catch { errorMessage = error.localizedDescription; return [:] }
    }

    /// Produces a full-resolution derived PNG. The original and prior exports remain intact.
    func exportAnnotated(snapshot: BoardSnapshot) -> URL? {
        do {
            guard Self.valid(snapshot), let source = displayImage(for: snapshot),
                  let rendered = Self.render(source, annotations: snapshot.annotations),
                  let data = Self.pngData(rendered) else { throw LibraryError.imageEncoding }
            let directory = rootURL.appendingPathComponent("exports", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("board-\(snapshot.id.uuidString)-\(UUID().uuidString).png")
            try data.write(to: url, options: .withoutOverwriting)
            errorMessage = nil
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Explicitly publishes one selected board to a stable manifest. No automatic polling
    /// or assistant message is performed. The manifest names an immutable image export.
    @discardableResult
    func publishCurrent(snapshot: BoardSnapshot) -> URL? {
        guard let url = exportAnnotated(snapshot: snapshot) else { return nil }
        do {
            guard let image = NSImage(contentsOf: url), let cg = Self.cgImage(image) else { throw LibraryError.imageEncoding }
            let manifest = BoardCurrentManifest(schemaVersion: 1, publishedAt: Date(), snapshotID: snapshot.id,
                capturedAt: snapshot.createdAt, title: snapshot.title, imagePath: url.path,
                pixelWidth: cg.width, pixelHeight: cg.height,
                coordinates: "Normalized fractions; origin at top left; x, y, width, height.", annotations: snapshot.annotations,
                overlays: snapshot.overlays, overlayMasks: snapshot.overlayMasks)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: currentManifestURL, options: .atomic)
            errorMessage = nil
            return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Returns the small published manifest without loading its image or modifying disk.
    func currentManifest() -> BoardCurrentManifest? {
        guard let data = try? Data(contentsOf: currentManifestURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BoardCurrentManifest.self, from: data), manifest.schemaVersion == 1,
              (try? Self.validateOverlayContent(overlays: manifest.overlays, masks: manifest.overlayMasks)) != nil else { return nil }
        return manifest
    }

    /// CGImage cropping uses top-left pixel coordinates, unlike CGContext drawing.
    static func cropped(_ image: NSImage, normalizedRect: CGRect) -> NSImage? {
        guard let original = cgImage(image) else { return nil }
        let r = BoardGeometry.clamped(normalizedRect)
        guard r.width > 0, r.height > 0 else { return nil }
        let pixels = CGRect(x: r.minX * Double(original.width), y: r.minY * Double(original.height),
                            width: r.width * Double(original.width), height: r.height * Double(original.height)).integral
        guard let crop = original.cropping(to: pixels) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }

    private func load() {
        guard manager.fileExists(atPath: metadataURL.path) else { return }
        do {
            let data = try Data(contentsOf: metadataURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = object?["schemaVersion"] as? Int else { throw LibraryError.invalidMetadata }
            guard version == 1 else { throw LibraryError.unsupportedVersion(version) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard Set(envelope.snapshots.map(\.id)).count == envelope.snapshots.count,
                  envelope.snapshots.allSatisfy(Self.valid) else { throw LibraryError.invalidMetadata }
            snapshots = envelope.snapshots
            loadedMetadata = data
        } catch {
            canWrite = false
            errorMessage = "Your saved library was preserved, but could not be opened. \(error.localizedDescription)"
        }
    }

    private func checkMetadataUnchanged() throws {
        guard canWrite else { throw LibraryError.readOnly }
        let current = manager.fileExists(atPath: metadataURL.path) ? try Data(contentsOf: metadataURL) : nil
        guard current == loadedMetadata else {
            canWrite = false
            throw LibraryError.changedOnDisk
        }
    }

    private func persist(_ values: [BoardSnapshot]) throws {
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let descriptor = open(rootURL.appendingPathComponent(".library.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LibraryError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        try checkMetadataUnchanged()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(schemaVersion: 1, snapshots: values))
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let previous = loadedMetadata {
            let revisions = rootURL.appendingPathComponent("revisions", isDirectory: true)
            try manager.createDirectory(at: revisions, withIntermediateDirectories: true)
            try previous.write(to: revisions.appendingPathComponent("\(UUID().uuidString).json"), options: .withoutOverwriting)
        }
        try data.write(to: metadataURL, options: .atomic)
        loadedMetadata = data
        snapshots = values
    }

    private static func safeImageName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && name.hasSuffix(".png")
    }

    private static func valid(_ item: BoardSnapshot) -> Bool {
        guard safeImageName(item.imageName), Set(item.annotations.map(\.id)).count == item.annotations.count,
              item.annotations.allSatisfy({ a in
                  [a.x, a.y, a.width, a.height].allSatisfy(\.isFinite) &&
                  a.x >= 0 && a.y >= 0 && a.width > 0 && a.height > 0 &&
                  a.x + a.width <= 1.0000001 && a.y + a.height <= 1.0000001
              }) else { return false }
        do { try validateOverlayContent(overlays: item.overlays, masks: item.overlayMasks); return true }
        catch { return false }
    }

    private static func validateOverlayContent(overlays: [BoardOverlay]?, masks: [String: Data]?) throws {
        let values = overlays ?? []
        guard values.count <= 60, Set(values.map(\.id)).count == values.count else { throw LibraryError.invalidMetadata }
        for overlay in values {
            try overlay.validate()
            guard overlay.revision >= 1 else { throw LibraryError.invalidMetadata }
        }
        let decoded = try decodeOverlayMasks(masks)
        guard Set(decoded.keys).isSubset(of: Set(values.map(\.id))) else { throw LibraryError.invalidMetadata }
    }

    /// Decode only small, single-frame grayscale PNG masks, before any composition.
    /// Data's Codable representation is base64; old schema-1 snapshots omit this field.
    static func decodeOverlayMasks(_ masks: [String: Data]?) throws -> [UUID: CGImage] {
        let values = masks ?? [:]
        guard values.count <= 60 else { throw LibraryError.invalidMetadata }
        var result: [UUID: CGImage] = [:]
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        for (key, data) in values {
            guard key.count == 36, let id = UUID(uuidString: key), id.uuidString.lowercased() == key.lowercased(),
                  result[id] == nil, !data.isEmpty, data.count <= 64 * 1_024,
                  data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
                  let source = CGImageSourceCreateWithData(data as CFData, options),
                  CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 128,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 96,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options),
                  image.width == 128, image.height == 96, image.colorSpace?.model == .monochrome,
                  image.bitsPerComponent == 8, image.alphaInfo == .none else { throw LibraryError.invalidMetadata }
            result[id] = image
        }
        return result
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        if let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           let cg = representation.cgImage { return cg }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = cgImage(image) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func render(_ image: NSImage, annotations: [BoardAnnotation]) -> NSImage? {
        guard let cg = cgImage(image), let context = CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let orange = NSColor(srgbRed: 0.74, green: 0.215, blue: 0.075, alpha: 1)
        let scale = min(size.width, size.height)
        let lineWidth = max(2, min(12, scale * 0.003))
        let font = NSFont.monospacedSystemFont(ofSize: max(13, min(72, scale * 0.022)), weight: .semibold)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        for annotation in annotations {
            let r = BoardGeometry.pixelRect(annotation.rect, imageSize: size)
            guard r.width > 0, r.height > 0 else { continue }
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(lineWidth + 2)
            context.stroke(r)
            context.setStrokeColor(orange.cgColor); context.setLineWidth(lineWidth); context.stroke(r)
            let label = annotation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                let text = NSString(string: label.replacingOccurrences(of: "\n", with: " "))
                let measured = text.size(withAttributes: attributes)
                let pad = max(5, font.pointSize * 0.3)
                let labelWidth = min(size.width, measured.width + pad * 2)
                let labelHeight = min(size.height, ceil(font.ascender - font.descender) + pad * 2)
                let frame = CGRect(x: min(r.minX, size.width - labelWidth),
                                   y: min(size.height - labelHeight, r.maxY + lineWidth),
                                   width: labelWidth, height: labelHeight)
                orange.setFill(); NSBezierPath(roundedRect: frame, xRadius: pad * 0.5, yRadius: pad * 0.5).fill()
                text.draw(in: frame.insetBy(dx: pad, dy: pad), withAttributes: attributes)
            }
        }
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: size)
    }

    private enum LibraryError: LocalizedError {
        case invalidMetadata, unsupportedVersion(Int), imageEncoding, unknownSnapshot, originalChanged, readOnly, changedOnDisk, lockUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidMetadata: return "The library contains invalid metadata."
            case .unsupportedVersion(let version): return "Library format \(version) is unsupported by this version of Board."
            case .imageEncoding: return "The image could not be read or rendered."
            case .unknownSnapshot: return "This capture is no longer in the library."
            case .originalChanged: return "An original capture cannot be changed."
            case .readOnly: return "The library is read-only because its saved data could not be opened."
            case .changedOnDisk: return "The library changed in another process. Reopen Board before saving; the other version has been preserved."
            case .lockUnavailable: return "Another Board process is saving the library. Try saving again after it finishes."
            }
        }
    }
}
