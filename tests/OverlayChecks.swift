import AppKit
import Darwin
import Foundation

@main struct OverlayChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? value()) == true else { fatalError(message) }; checks += 1
        }
        func rejects(_ message: String, _ action: () throws -> Void) {
            do { try action(); fatalError(message) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-overlays-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let region = BoardAnnotation(rect: CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.64), label: "Query planning")
        let store = BoardOverlayStore(rootURL: root)
        expect(store.canWrite && store.overlays.isEmpty, "Empty store")
        var text = BoardOverlay(regionID: region.id, title: "Question", kind: .text, text: "Which plan minimizes the number of scanned rows?")
        text = try store.upsert(text, expectedRevision: nil)
        expect(text.revision == 1 && store.overlays == [text], "Create assigns first revision")
        let other = BoardOverlayStore(rootURL: root)
        expect(other.overlays == [text], "JSON round trip")
        var diagram = BoardOverlay(regionID: region.id, title: "Research flow", kind: .diagram,
            nodes: [BoardOverlayNode(id: "query", x: 0.05, y: 0.33, width: 0.24, height: 0.30, label: "Query"),
                    BoardOverlayNode(id: "plan", x: 0.38, y: 0.33, width: 0.24, height: 0.30, label: "Plan"),
                    BoardOverlayNode(id: "result", x: 0.71, y: 0.33, width: 0.24, height: 0.30, label: "Result")],
            edges: [BoardOverlayEdge(from: "query", to: "plan"), BoardOverlayEdge(from: "plan", to: "result")])
        diagram = try other.upsert(diagram, expectedRevision: nil)
        let changed = try store.update(id: text.id, expectedRevision: 1, hidden: true, opacity: 0.6)
        expect(changed.revision == 2 && changed.hidden && changed.opacity == 0.6, "Combined update is one revision")
        expect(store.overlays.count == 2 && store.overlays.contains(diagram), "Independent external writes preserved")
        let saved = try Data(contentsOf: store.fileURL)
        rejects("Stale CAS must fail") { _ = try other.setHidden(id: text.id, hidden: false, expectedRevision: 1) }
        expect(try Data(contentsOf: store.fileURL) == saved, "CAS conflict preserves exact bytes")
        text = try store.update(id: text.id, expectedRevision: 2, hidden: false, opacity: 0.94)
        expect(text.revision == 3 && !text.hidden && text.text.contains("scanned"), "Soft delete restores exact content")
        var rebound = text; rebound.regionID = UUID()
        rejects("Anchor cannot silently move") { _ = try store.upsert(rebound, expectedRevision: 3) }
        var excessive = text; excessive.text = String(repeating: "x", count: 4_001)
        rejects("Bound text length") { try excessive.validate() }
        excessive = diagram; excessive.nodes[0].width = 2
        rejects("Bound node geometry") { try excessive.validate() }
        excessive = diagram; excessive.nodes[1].id = excessive.nodes[0].id
        rejects("Unique node identifiers") { try excessive.validate() }
        excessive = diagram; excessive.edges[0].to = "missing"
        rejects("Valid edge endpoints") { try excessive.validate() }
        rejects("Finite opacity") { _ = try store.setOpacity(id: text.id, opacity: .nan, expectedRevision: 3) }
        let descriptor = open(root.appendingPathComponent(".overlays.lock").path, O_RDWR)
        expect(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Acquire competing writer lock")
        rejects("Busy lock must preserve file") { _ = try store.setHidden(id: text.id, hidden: true, expectedRevision: 3) }
        flock(descriptor, LOCK_UN); close(descriptor)
        let valid = try Data(contentsOf: store.fileURL)
        try Data("{broken".utf8).write(to: store.fileURL)
        rejects("Corrupt external document rejected") { try store.reloadIfChanged() }
        expect(!store.canWrite && store.overlays.count == 2, "Corruption retains last valid overlays")
        rejects("Corrupt file cannot be overwritten") { _ = try store.upsert(text, expectedRevision: 3) }
        expect(try Data(contentsOf: store.fileURL) == Data("{broken".utf8), "Corrupt bytes preserved")
        try valid.write(to: store.fileURL)
        expect(try store.reloadIfChanged() && store.canWrite, "Restoring same last-valid bytes resumes writing")
        let future = Data("{\"schemaVersion\":2,\"overlays\":[]}".utf8)
        try future.write(to: store.fileURL)
        let futureStore = BoardOverlayStore(rootURL: root)
        expect(!futureStore.canWrite, "Newer schema read-only")
        expect(try Data(contentsOf: store.fileURL) == future, "Newer schema preserved")
        try valid.write(to: store.fileURL); _ = try store.reloadIfChanged()
        let symbolicRoot = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: symbolicRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symbolicRoot.appendingPathComponent("overlays.json"), withDestinationURL: store.fileURL)
        expect(!BoardOverlayStore(rootURL: symbolicRoot).canWrite, "Symbolic-link metadata refused")
        let bounded = BoardOverlayStore(rootURL: root.appendingPathComponent("bounded"))
        for index in 0..<60 { _ = try bounded.upsert(BoardOverlay(regionID: region.id, title: "\(index)"), expectedRevision: nil) }
        rejects("Bound overlay count") { _ = try bounded.upsert(BoardOverlay(regionID: region.id), expectedRevision: nil) }
        expect(bounded.overlays.count == 60, "Count limit preserves all existing entries")

        let deletions = BoardOverlayStore(rootURL: root.appendingPathComponent("deletions"))
        let first = try deletions.upsert(BoardOverlay(regionID: region.id, title: "First"), expectedRevision: nil)
        let hiddenToDelete = try deletions.upsert(BoardOverlay(regionID: region.id, title: "Second", hidden: true), expectedRevision: nil)
        let writer = BoardOverlayStore(rootURL: deletions.fileURL.deletingLastPathComponent())
        let independent = try writer.upsert(BoardOverlay(regionID: region.id, title: "Independent"), expectedRevision: nil)
        try deletions.remove(expectedRevisions: [first.id: first.revision])
        expect(deletions.overlays == [hiddenToDelete, independent], "Delete removes one entry and preserves independent additions")
        expect(BoardOverlayStore(rootURL: deletions.fileURL.deletingLastPathComponent()).overlays == [hiddenToDelete, independent],
            "Deletion persists across reopening")
        let beforeConflict = try Data(contentsOf: deletions.fileURL)
        rejects("Deleting a missing item must fail") { try deletions.remove(expectedRevisions: [first.id: first.revision]) }
        rejects("Batch delete must reject stale revisions atomically") {
            try deletions.remove(expectedRevisions: [hiddenToDelete.id: hiddenToDelete.revision, independent.id: independent.revision + 1])
        }
        expect(try Data(contentsOf: deletions.fileURL) == beforeConflict && deletions.overlays == [hiddenToDelete, independent],
            "Failed deletion preserves exact bytes and all other selections")
        let selected = Dictionary(uniqueKeysWithValues: deletions.overlays.map { ($0.id, $0.revision) })
        let later = try writer.upsert(BoardOverlay(regionID: region.id, title: "Added while confirming"), expectedRevision: nil)
        try deletions.remove(expectedRevisions: selected)
        expect(deletions.overlays == [later], "Clear includes hidden entries but preserves additions made after selection")
        try deletions.remove(expectedRevisions: [later.id: later.revision])
        expect(deletions.overlays.isEmpty && BoardOverlayStore(rootURL: deletions.fileURL.deletingLastPathComponent()).overlays.isEmpty,
            "Clear persists an empty live overlay list")
        try Data("{broken".utf8).write(to: deletions.fileURL)
        rejects("Delete cannot overwrite corrupt external data") { try deletions.remove(expectedRevisions: [later.id: later.revision]) }
        expect(try Data(contentsOf: deletions.fileURL) == Data("{broken".utf8), "Corrupt overlay bytes survive deletion attempts")
        let freed = bounded.overlays[0]
        try bounded.remove(expectedRevisions: [freed.id: freed.revision])
        _ = try bounded.upsert(BoardOverlay(regionID: region.id, title: "Replacement"), expectedRevision: nil)
        expect(bounded.overlays.count == 60 && !bounded.overlays.contains { $0.id == freed.id }, "Deletion frees an overlay slot")

        let renderer = BoardOverlayRenderer(), size = CGSize(width: 800, height: 500)
        let sourceContext = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sourceContext.setFillColor(NSColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 1).cgColor)
        sourceContext.fill(CGRect(origin: .zero, size: size))
        let source = NSImage(cgImage: sourceContext.makeImage()!, size: size)
        func sample(_ image: NSImage, _ x: Double, _ y: Double) -> NSColor {
            let cg = BoardLibrary.cgImage(image)!, bitmap = NSBitmapImageRep(cgImage: cg)
            return bitmap.colorAt(x: min(cg.width - 1, Int(Double(cg.width) * x)), y: min(cg.height - 1, Int(Double(cg.height) * y)))!.usingColorSpace(.deviceRGB)!
        }
        let raster = renderer.raster(overlays: [text], region: region, size: CGSize(width: 2_048, height: 1_024))!
        expect(max(BoardLibrary.cgImage(raster)!.width, BoardLibrary.cgImage(raster)!.height) == 1_024, "Live raster capped at1024")
        expect(renderer.raster(overlays: [text], region: region, size: CGSize(width: 2_048, height: 1_024)) === raster, "Unchanged raster cached")
        let faded = renderer.raster(overlays: [text], region: region, size: CGSize(width: 2_048, height: 1_024), fadedIDs: [text.id])!
        expect(sample(faded, 0.05, 0.1).alphaComponent < sample(raster, 0.05, 0.1).alphaComponent * 0.3, "Ephemeral fade does not mutate persistent opacity")
        expect(text.opacity == 0.94, "Stored opacity remains unchanged by fade")
        var hidden = text; hidden.hidden = true
        expect(renderer.raster(overlays: [hidden], region: region, size: size) == nil, "Hidden raster omitted")
        let composed = renderer.compose(image: source, overlays: [text], annotations: [region])!
        expect(BoardLibrary.cgImage(composed)!.width == 800 && BoardLibrary.cgImage(composed)!.height == 500, "Copy keeps full resolution")
        expect(sample(composed, 0.03, 0.03).blueComponent > 0.5 && sample(composed, 0.21, 0.20).redComponent > 0.8, "Text panel stays within anchored region")
        let absent = renderer.compose(image: source, overlays: [text], annotations: [])!
        expect(sample(absent, 0.21, 0.20).redComponent < 0.3, "Removed region hides orphaned overlay without deleting it")
        let diagramRaster = renderer.raster(overlays: [diagram], region: region, size: size)!
        let diagramBackground = sample(diagramRaster, 0.5, 0.1)
        expect(diagramBackground.alphaComponent > 0.9 && diagramBackground.redComponent > 0.95 && diagramBackground.blueComponent > 0.9,
               "Diagram background covers old connectors with a pale panel")
        expect(sample(diagramRaster, 0.17, 0.38).redComponent > 0.8, "Native node panel renders")
        let arrow = sample(diagramRaster, 0.33, 0.48)
        expect(arrow.redComponent > 0.6 && arrow.greenComponent < 0.4 && arrow.blueComponent < 0.3,
               "Native connecting arrow remains distinct from the pale background")
        let quad = try BoardQuad(points: [CGPoint(x: 0.15, y: 0.1), CGPoint(x: 0.9, y: 0.2), CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.05, y: 0.8)])
        let projected = renderer.projected(overlays: [text], annotations: [region], quad: quad, imageSize: size, outputSize: size)!
        let mapping = BoardProjectiveMap(corners: quad.points)!
        let point = mapping.imagePoint(CGPoint(x: region.x + region.width * 0.05, y: region.y + region.height * 0.1))!
        expect(sample(projected, point.x, point.y).alphaComponent > 0.7, "Projection uses the board homography and top-left origin")
        expect(sample(projected, 0.02, 0.02).alphaComponent == 0, "Warped overlay remains transparent outside its region")
        func quadrantMask(_ quadrant: Int) -> CGImage {
            let width = 128, height = 96
            var bytes = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width {
                if (x >= width / 2 ? 1 : 0) + (y >= height / 2 ? 2 : 0) == quadrant { bytes[y * width + x] = 255 }
            } }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: Data(bytes) as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        var panel = text; panel.text = ""
        for maskedOverlay in [panel, diagram] { for quadrant in 0..<4 {
            let mask = quadrantMask(quadrant), masks = [maskedOverlay.id: mask]
            let x = quadrant % 2 == 0 ? 0.25 : 0.75, y = quadrant / 2 == 0 ? 0.25 : 0.75
            let punched = renderer.raster(overlays: [maskedOverlay], region: region, size: size, foregroundMasks: masks)!
            expect(sample(punched, x, y).alphaComponent < 0.02, "White physical-ink quadrant must punch a correctly oriented live hole")
            expect(sample(punched, 1-x, 1-y).alphaComponent > 0.8, "Black mask must preserve the other live quadrant")
            let copy = renderer.compose(image: source, overlays: [maskedOverlay], annotations: [region], foregroundMasks: masks)!
            let onBoard = CGPoint(x: region.x + region.width * x, y: region.y + region.height * y)
            expect(sample(copy, onBoard.x, onBoard.y).redComponent < 0.3, "Physical board pixels show through copy composition")
            let live = renderer.projected(overlays: [maskedOverlay], annotations: [region], quad: quad, imageSize: size, outputSize: size, foregroundMasks: masks)!
            let onCamera = mapping.imagePoint(onBoard)!
            expect(sample(live, onCamera.x, onCamera.y).alphaComponent < 0.02, "Physical-ink mask follows the same board homography")
        } }
        expect(sample(renderer.raster(overlays: [panel], region: region, size: size)!, 0.25, 0.25).alphaComponent > 0.8,
               "Removing a mask restores the cached AI layer without stale holes")

        // Small notes share a parent region without painting over all of it.
        var note = BoardOverlay(regionID: region.id, title: "LIKE note", kind: .text,
            text: "LIKE example\n'abc' LIKE 'a%' → true.",
            frame: BoardOverlayFrame(x: 0.05, y: 0.10, width: 0.42, height: 0.22))
        let legacyData = try JSONEncoder().encode(panel)
        expect(try JSONDecoder().decode(BoardOverlay.self, from: legacyData).frame == nil,
               "Missing frame keeps old overlay documents compatible")
        note = try store.upsert(note, expectedRevision: nil)
        expect(BoardOverlayStore(rootURL: root).overlays.first(where: { $0.id == note.id })?.frame == note.frame,
               "Small placement persists without losing normalized coordinates")
        var invalid = note; invalid.frame!.x = 0.9
        rejects("Placement cannot leave its parent region") { try invalid.validate() }
        invalid = note; invalid.frame!.height = 0
        rejects("Placement needs positive area") { try invalid.validate() }
        invalid = note; invalid.frame!.width = .nan
        rejects("Placement must be finite") { try invalid.validate() }

        let noteRaster = renderer.raster(overlays: [note], region: region, size: size)!
        expect(sample(noteRaster, 0.09, 0.29).alphaComponent > 0.9, "Small note paints its selected top-left frame")
        expect(sample(noteRaster, 0.75, 0.20).alphaComponent == 0, "Small note leaves the right side untouched")
        expect(sample(noteRaster, 0.25, 0.80).alphaComponent == 0, "Top-left placement is not vertically inverted")
        var second = note; second.id = UUID(); second.title = "Second note"; second.text = "Check NULL semantics."
        second.frame = BoardOverlayFrame(x: 0.56, y: 0.65, width: 0.38, height: 0.22)
        let both = renderer.raster(overlays: [note, second], region: region, size: size)!
        expect(sample(both, 0.60, 0.83).alphaComponent > 0.9, "Second note uses its own independent frame")
        expect(sample(both, 0.50, 0.50).alphaComponent == 0, "Two notes leave the space between them transparent")
        expect(sample(both, 0.09, 0.29) == sample(noteRaster, 0.09, 0.29), "A second note does not overpaint the first")
        let noteCopy = renderer.compose(image: source, overlays: [note, second], annotations: [region])!
        let insideNote = CGPoint(x: region.x + region.width * 0.09, y: region.y + region.height * 0.29)
        let outsideNote = CGPoint(x: region.x + region.width * 0.50, y: region.y + region.height * 0.50)
        expect(sample(noteCopy, insideNote.x, insideNote.y).redComponent > 0.8, "Full-resolution copy places the small note once")
        expect(sample(noteCopy, outsideNote.x, outsideNote.y).blueComponent > 0.5 && sample(noteCopy, outsideNote.x, outsideNote.y).redComponent < 0.3,
               "Full-resolution copy preserves physical pixels outside note frames")

        var smallDiagram = diagram; smallDiagram.id = UUID()
        smallDiagram.frame = BoardOverlayFrame(x: 0.50, y: 0.08, width: 0.45, height: 0.40)
        let localDiagram = renderer.raster(overlays: [smallDiagram], region: region, size: size)!
        expect(sample(localDiagram, 0.50 + 0.45 * 0.17, 0.08 + 0.40 * 0.38).redComponent > 0.8,
               "Diagram nodes use coordinates local to the diagram frame")
        let localArrow = sample(localDiagram, 0.50 + 0.45 * 0.33, 0.08 + 0.40 * 0.48)
        expect(localArrow.redComponent > 0.6 && localArrow.greenComponent < 0.5,
               "Diagram arrows follow the same local placement as their nodes")
        expect(sample(localDiagram, 0.25, 0.25).alphaComponent == 0 && sample(localDiagram, 0.75, 0.75).alphaComponent == 0,
               "Small diagram background does not cover the rest of its region")

        let uniform = CGImage(width:128,height:96,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:128,
            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[],
            provider:CGDataProvider(data:Data(repeating:170,count:128*96) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let dimmedNote = renderer.raster(overlays: [note, second], region: region, size: size, foregroundMasks: [note.id: uniform])!
        let dimmedAlpha = sample(dimmedNote, 0.09, 0.29).alphaComponent
        expect(abs(dimmedAlpha - note.opacity / 3) < 0.03,
               "Uniform activity opacity affects the selected note without repositioning it (alpha=\(dimmedAlpha))")
        expect(sample(dimmedNote, 0.60, 0.83).alphaComponent > 0.9 && sample(dimmedNote, 0.50, 0.50).alphaComponent == 0,
               "Fading one note leaves its neighbor opaque and the gap clear")
        let oldMaskedNote = renderer.raster(overlays: [note, second], region: region, size: size, foregroundMasks: [note.id: quadrantMask(0)])!
        expect(sample(oldMaskedNote, 0.09, 0.29).alphaComponent < 0.02 && sample(oldMaskedNote, 0.60, 0.83).alphaComponent > 0.9,
               "Legacy spatial masks retain parent-region coordinates with small frames")
        let noteProjection = renderer.projected(overlays: [note, second], annotations: [region], quad: quad,
            imageSize: size, outputSize: size)!
        let projectedInside = mapping.imagePoint(insideNote)!, projectedOutside = mapping.imagePoint(outsideNote)!
        expect(sample(noteProjection, projectedInside.x, projectedInside.y).alphaComponent > 0.8,
               "Live homography projects the small note's local placement")
        expect(sample(noteProjection, projectedOutside.x, projectedOutside.y).alphaComponent == 0,
               "Live homography leaves the board visible between notes")

        let demo = renderer.compose(image: source, overlays: [diagram], annotations: [region])!
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            try BoardLibrary.pngData(demo)!.write(to: url)
            let demoRegion = BoardAnnotation(rect: CGRect(x: 0.05, y: 0.08, width: 0.90, height: 0.84), label: "Example board")
            let answer = BoardOverlay(regionID: demoRegion.id, title: "LIKE example", opacity: 1, kind: .text,
                text: "LIKE example\n'abc' LIKE 'a%' → true.\n'abc' LIKE 'a_' → false.",
                frame: BoardOverlayFrame(x: 0.06, y: 0.06, width: 0.64, height: 0.30))
            var flow = diagram; flow.regionID = demoRegion.id; flow.opacity = 1
            flow.nodes[0].label = "Value"; flow.nodes[1].label = "Pattern"; flow.nodes[2].label = "Match"
            flow.frame = BoardOverlayFrame(x: 0.14, y: 0.47, width: 0.78, height: 0.43)
            let placementDemo = renderer.compose(image: source, overlays: [answer, flow], annotations: [demoRegion])!
            try BoardLibrary.pngData(placementDemo)!.write(to: url.deletingLastPathComponent().appendingPathComponent("overlay-placement-check.png"))
        }
        print("PASS: \(checks) overlay CAS, persistence, bounds, masking, native drawing and projective composition checks")
    }
}
