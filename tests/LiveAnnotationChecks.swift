import AppKit
import Darwin
import Foundation

@main
struct LiveAnnotationChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? condition()) == true else { fatalError(message) }
            checks += 1
        }
        func near(_ a: CGPoint?, _ b: CGPoint, tolerance: CGFloat = 1e-8) -> Bool {
            guard let a else { return false }; return hypot(a.x - b.x, a.y - b.y) < tolerance
        }
        // Deliberately non-affine: the denominator varies across the board.
        func camera(_ p: CGPoint) -> CGPoint {
            let denominator = 1 + 0.4 * p.x + 0.2 * p.y
            return CGPoint(x: (0.65 * p.x + 0.08 * p.y + 0.1) / denominator,
                           y: (0.04 * p.x + 0.7 * p.y + 0.08) / denominator)
        }
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        guard let identity = BoardProjectiveMap(corners: square), let map = BoardProjectiveMap(corners: square.map(camera)) else {
            fatalError("Valid homographies should be constructible")
        }
        for y in [0.0, 0.1, 0.5, 0.9, 1.0] {
            for x in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let p = CGPoint(x: x, y: y)
                expect(near(identity.imagePoint(p), p), "Identity projection")
                expect(near(map.imagePoint(p), camera(p)), "Projection must match analytic perspective transform")
                expect(near(map.boardPoint(camera(p)), p), "Inverse must recover board position")
            }
        }
        let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        guard let projected = map.imageCorners(for: rect) else { fatalError("Rectangle projection") }
        expect(near(projected[0], camera(CGPoint(x: 0.2, y: 0.3))) && near(projected[2], camera(CGPoint(x: 0.6, y: 0.55))), "Mark must project its actual board-plane corners")
        expect(map.boardPoint(camera(CGPoint(x: -0.1, y: 0.5))) == nil, "Clicks outside board must not create markings")
        expect(map.boardPoint(CGPoint(x: CGFloat.nan, y: 0)) == nil, "Nonfinite input must fail")
        expect(BoardProjectiveMap(corners: Array(repeating: .zero, count: 4)) == nil, "Singular quad must fail")
        expect(BoardProjectiveMap(corners: [CGPoint(x: CGFloat.infinity, y: 0)] + Array(square.dropFirst())) == nil, "Nonfinite quad must fail")
        let moved = square.map { p in CGPoint(x: camera(p).x * 0.85 + 0.05, y: camera(p).y * 0.8 + 0.1) }
        let movedMap = BoardProjectiveMap(corners: moved)!
        let boardPoint = CGPoint(x: 0.37, y: 0.65)
        expect(near(movedMap.boardPoint(movedMap.imagePoint(boardPoint)!), boardPoint), "Camera motion must preserve board coordinates")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoardLiveChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveBoardAnnotationStore(rootURL: root)
        let mark = BoardAnnotation(rect: rect, label: "Current Architecture")
        expect(store.replace([mark]), "Live mark should persist")
        let saved = try Data(contentsOf: store.fileURL)
        let reopened = LiveBoardAnnotationStore(rootURL: root)
        expect(reopened.annotations == [mark], "Mark and identity must survive restart/recalibration")
        expect(!store.replace([mark, mark]), "Duplicate IDs must be rejected")
        expect(try Data(contentsOf: store.fileURL) == saved, "Invalid edit must preserve committed bytes")
        var bad = mark; bad.width = 2
        expect(!store.replace([bad]), "Out-of-board mark must not persist")

        let lock = open(root.appendingPathComponent(".live-annotations.lock").path, O_RDWR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { fatalError("Fixture lock") }
        expect(!store.replace([]), "Concurrent lock must block writing")
        expect(store.annotations == [mark], "Blocked write must preserve visible committed marks")
        flock(lock, LOCK_UN); close(lock)
        expect(store.replace([mark]), "Store should recover after lock release")

        for (name, bytes) in [("corrupt", Data("broken json".utf8)),
                              ("newer", Data("{\"schemaVersion\":99,\"annotations\":[]}".utf8))] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("live-annotations.json")
            try bytes.write(to: file)
            let blocked = LiveBoardAnnotationStore(rootURL: directory)
            expect(!blocked.canWrite && !blocked.replace([mark]), "Corrupt/newer markings must remain read-only")
            expect(try Data(contentsOf: file) == bytes, "Corrupt/newer bytes must be preserved")
        }
        var renamed = mark; renamed.label = "Changed elsewhere"
        expect(reopened.replace([renamed]), "Independent writer may commit unchanged base")
        let external = try Data(contentsOf: store.fileURL)
        expect(!store.replace([]) && !store.canWrite, "Stale writer must stop after external change")
        expect(try Data(contentsOf: store.fileURL) == external, "External markings must survive")

        // Copy stores a rectified original and its own immutable annotation snapshot.
        let library = BoardLibrary(rootURL: root.appendingPathComponent("copies"))
        let cg = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(NSColor.white.cgColor); cg.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = NSImage(cgImage: cg.makeImage()!, size: CGSize(width: 400, height: 300))
        var snapshot = library.add(image: image, title: "Rectified copy fixture")!
        let original = library.rootURL.appendingPathComponent("originals").appendingPathComponent(snapshot.imageName)
        let originalBytes = try Data(contentsOf: original)
        snapshot.annotations = [mark]
        expect(library.update(snapshot: snapshot), "Copy metadata must retain live markings")
        let export = library.publishCurrent(snapshot: snapshot)!
        let exportBytes = try Data(contentsOf: export)
        expect(reopened.replace([]), "Live marking removal should persist independently")
        expect(library.snapshots.first?.annotations == [mark], "Removing live markings must not modify copied version")
        expect(try Data(contentsOf: original) == originalBytes && Data(contentsOf: export) == exportBytes, "Prior originals and exports must remain byte-identical")
        let bitmap = NSBitmapImageRep(data: exportBytes)!
        let border = bitmap.colorAt(x: 80, y: 120)!.usingColorSpace(.deviceRGB)!
        expect(border.redComponent > 0.6 && border.greenComponent < 0.5, "Rectified copy must include the board-normalized annotation")
        print("PASS: \(checks) live annotation perspective, persistence and copy checks")
    }
}
