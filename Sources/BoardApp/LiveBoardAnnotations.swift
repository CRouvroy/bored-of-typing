import AppKit
import Combine
import Darwin
import Foundation

/// Maps the board's unit square to camera coordinates, both with a top-left origin.
/// A projective map is necessary: a bounding box or bilinear interpolation drifts
/// when the board is viewed at an angle.
struct BoardProjectiveMap {
    private let forward: [Double]
    private let inverse: [Double]

    init?(corners: [CGPoint]) {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        var equations: [[Double]] = []
        for (p, q) in zip(square, corners) {
            let x = Double(p.x), y = Double(p.y), u = Double(q.x), v = Double(q.y)
            equations.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            equations.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for column in 0..<8 {
            guard let pivot = (column..<8).max(by: { abs(equations[$0][column]) < abs(equations[$1][column]) }),
                  abs(equations[pivot][column]) > 1e-12 else { return nil }
            equations.swapAt(column, pivot)
            let divisor = equations[column][column]
            for j in column...8 { equations[column][j] /= divisor }
            for row in 0..<8 where row != column {
                let factor = equations[row][column]
                for j in column...8 { equations[row][j] -= factor * equations[column][j] }
            }
        }
        let m = equations.map { $0[8] } + [1]
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard m.allSatisfy(\.isFinite), abs(determinant) > 1e-12 else { return nil }
        let inverse = [e*i-f*h, c*h-b*i, b*f-c*e, f*g-d*i, a*i-c*g, c*d-a*f, d*h-e*g, b*g-a*h, a*e-b*d].map { $0 / determinant }
        let denominators = square.map { g * $0.x + h * $0.y + i }
        guard inverse.allSatisfy(\.isFinite), denominators.allSatisfy({ $0 > 1e-9 }) else { return nil }
        forward = m; self.inverse = inverse
    }

    func imagePoint(_ point: CGPoint) -> CGPoint? { Self.apply(forward, point) }
    func boardPoint(_ point: CGPoint) -> CGPoint? {
        guard let p = Self.apply(inverse, point), p.x >= -1e-7, p.y >= -1e-7, p.x <= 1.0000001, p.y <= 1.0000001 else { return nil }
        return CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
    }
    func imageCorners(for rect: CGRect) -> [CGPoint]? {
        let r = BoardGeometry.clamped(rect)
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        let mapped = points.compactMap(imagePoint)
        return mapped.count == 4 ? mapped : nil
    }
    private static func apply(_ m: [Double], _ point: CGPoint) -> CGPoint? {
        let x = Double(point.x), y = Double(point.y), denominator = m[6] * x + m[7] * y + m[8]
        guard x.isFinite, y.isFinite, denominator.isFinite, abs(denominator) > 1e-10 else { return nil }
        let u = (m[0] * x + m[1] * y + m[2]) / denominator
        let v = (m[3] * x + m[4] * y + m[5]) / denominator
        return u.isFinite && v.isFinite ? CGPoint(x: u, y: v) : nil
    }
}

/// One physical board, independent of captures and calibration. Existing snapshots
/// own their annotations and are never rewritten when these live markings change.
@MainActor
final class LiveBoardAnnotationStore: ObservableObject {
    @Published private(set) var annotations: [BoardAnnotation] = []
    @Published private(set) var errorMessage: String?
    private(set) var canWrite = true
    let fileURL: URL
    private var loadedData: Data?
    private let rootURL: URL
    private struct Envelope: Codable { let schemaVersion: Int; let annotations: [BoardAnnotation] }

    init(rootURL: URL) {
        self.rootURL = rootURL
        fileURL = rootURL.appendingPathComponent("live-annotations.json")
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try rejectSymbolicLink()
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1, Self.valid(envelope.annotations) else { throw StoreError.invalidData }
            annotations = envelope.annotations; loadedData = data
        } catch {
            canWrite = false
            errorMessage = "Your live markings were preserved but could not be opened. \(error.localizedDescription)"
        }
    }

    @discardableResult func replace(_ values: [BoardAnnotation]) -> Bool {
        guard canWrite else { return false }
        do {
            guard Self.valid(values) else { throw StoreError.invalidData }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let descriptor = open(rootURL.appendingPathComponent(".live-annotations.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw StoreError.busy }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.busy }
            defer { flock(descriptor, LOCK_UN) }
            try rejectSymbolicLink()
            let existing = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
            guard existing == loadedData else { canWrite = false; throw StoreError.changedOnDisk }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, annotations: values))
            try data.write(to: fileURL, options: .atomic)
            loadedData = data; annotations = values; errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func rejectSymbolicLink() throws {
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw StoreError.invalidData }
    }
    private static func valid(_ values: [BoardAnnotation]) -> Bool {
        Set(values.map(\.id)).count == values.count && values.allSatisfy { a in
            [a.x, a.y, a.width, a.height].allSatisfy(\.isFinite) && a.x >= 0 && a.y >= 0 &&
            a.width > 0 && a.height > 0 && a.x + a.width <= 1.0000001 && a.y + a.height <= 1.0000001
        }
    }
    private enum StoreError: LocalizedError {
        case invalidData, changedOnDisk, busy
        var errorDescription: String? {
            switch self {
            case .invalidData: return "The live markings file is invalid or belongs to a newer version of Board."
            case .changedOnDisk: return "Live markings changed in another process. Reopen Board; the other version was preserved."
            case .busy: return "Another Board process is saving live markings. Try the change again."
            }
        }
    }
}
