import AppKit
import Combine
import Darwin
import Foundation

enum BoardOverlayKind: String, Codable { case text, diagram }
/// Normalized top-left placement inside a user-marked parent region.
/// Missing placement on older overlays means the whole parent region.
struct BoardOverlayFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x <= 1, y <= 1, width <= 1, height <= 1,
              x + width <= 1.0000001, y + height <= 1.0000001 else {
            throw BoardOverlayError.invalidData
        }
    }
}
struct BoardOverlayNode: Codable, Equatable, Identifiable {
    var id: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var label: String
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
struct BoardOverlayEdge: Codable, Equatable {
    var from: String
    var to: String
    var label: String = ""
}
struct BoardOverlay: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var regionID: UUID
    var revision: Int = 0
    var title: String = ""
    var opacity: Double = 0.94
    var hidden: Bool = false
    var kind: BoardOverlayKind = .text
    var text: String = ""
    var nodes: [BoardOverlayNode] = []
    var edges: [BoardOverlayEdge] = []
    var frame: BoardOverlayFrame? = nil
    func validate() throws {
        try frame?.validate()
        guard revision >= 0, revision < Int.max, title.count <= 120, text.count <= 4_000,
              opacity.isFinite, (0...1).contains(opacity), nodes.count <= 24, edges.count <= 40,
              Set(nodes.map(\.id)).count == nodes.count else { throw BoardOverlayError.invalidData }
        for node in nodes {
            guard !node.id.isEmpty, node.id.count <= 64, node.label.count <= 400,
                  [node.x, node.y, node.width, node.height].allSatisfy(\.isFinite),
                  node.x >= 0, node.y >= 0, node.width > 0, node.height > 0,
                  node.x + node.width <= 1.0000001, node.y + node.height <= 1.0000001 else { throw BoardOverlayError.invalidData }
        }
        let identifiers = Set(nodes.map(\.id))
        guard edges.allSatisfy({ identifiers.contains($0.from) && identifiers.contains($0.to) && $0.from != $0.to && $0.label.count <= 200 }) else {
            throw BoardOverlayError.invalidData
        }
    }
}
enum BoardOverlayError: LocalizedError {
    case invalidData, newerSchema, unavailable, busy, changedOnDisk, unknownOverlay, revisionConflict, limitReached
    var errorDescription: String? {
        switch self {
        case .invalidData: return "The overlay is invalid or exceeds Board’s size limits."
        case .newerSchema: return "These overlays belong to a newer version of Board. The file was preserved."
        case .unavailable: return "The overlays file could not be opened safely. The existing file was preserved."
        case .busy: return "Another process is updating overlays. Try again."
        case .changedOnDisk: return "Overlays changed during this update. Refresh and try again."
        case .unknownOverlay: return "This overlay no longer exists. Refresh the board."
        case .revisionConflict: return "This overlay changed since it was read. Refresh it before editing."
        case .limitReached: return "This board already has 60 overlays. Edit or restore an existing overlay."
        }
    }
}

/// MCP uses this schema, lock and compare-and-swap contract. Hidden items are retained.
@MainActor final class BoardOverlayStore: ObservableObject {
    @Published private(set) var overlays: [BoardOverlay] = []
    @Published private(set) var errorMessage: String?
    private(set) var canWrite = true
    let fileURL: URL
    private let rootURL: URL
    private var loadedData: Data?
    private struct Envelope: Codable { var schemaVersion: Int; var overlays: [BoardOverlay] }
    init(rootURL: URL) {
        self.rootURL = rootURL; fileURL = rootURL.appendingPathComponent("overlays.json")
        do { try reloadIfChanged() }
        catch { canWrite = false; errorMessage = error.localizedDescription }
    }
    /// nil means create only. Existing items require their exact current revision.
    @discardableResult func upsert(_ overlay: BoardOverlay, expectedRevision: Int?) throws -> BoardOverlay {
        try overlay.validate()
        return try transaction { values in
            var updated = overlay
            if let index = values.firstIndex(where: { $0.id == overlay.id }) {
                guard expectedRevision == values[index].revision else { throw BoardOverlayError.revisionConflict }
                guard overlay.regionID == values[index].regionID else { throw BoardOverlayError.invalidData }
                updated.revision = values[index].revision + 1; values[index] = updated
            } else {
                guard expectedRevision == nil else { throw BoardOverlayError.revisionConflict }
                guard values.count < 60 else { throw BoardOverlayError.limitReached }
                updated.revision = 1; values.append(updated)
            }
            return updated
        }
    }
    @discardableResult func setHidden(id: UUID, hidden: Bool, expectedRevision: Int) throws -> BoardOverlay {
        try update(id: id, expectedRevision: expectedRevision, hidden: hidden)
    }
    @discardableResult func setOpacity(id: UUID, opacity: Double, expectedRevision: Int) throws -> BoardOverlay {
        try update(id: id, expectedRevision: expectedRevision, opacity: opacity)
    }
    /// Remove only the exact versions selected by the user, preserving other writers' additions.
    func remove(expectedRevisions: [UUID: Int]) throws {
        guard !expectedRevisions.isEmpty else { return }
        try transaction { values in
            for (id, revision) in expectedRevisions {
                guard let overlay = values.first(where: { $0.id == id }) else { throw BoardOverlayError.unknownOverlay }
                guard overlay.revision == revision else { throw BoardOverlayError.revisionConflict }
            }
            values.removeAll { expectedRevisions[$0.id] != nil }
        }
    }
    @discardableResult func update(id: UUID, expectedRevision: Int, hidden: Bool? = nil, opacity: Double? = nil) throws -> BoardOverlay {
        if let opacity, !opacity.isFinite || !(0...1).contains(opacity) { throw BoardOverlayError.invalidData }
        return try transaction { values in
            guard let index = values.firstIndex(where: { $0.id == id }) else { throw BoardOverlayError.unknownOverlay }
            guard values[index].revision == expectedRevision else { throw BoardOverlayError.revisionConflict }
            if let hidden { values[index].hidden = hidden }
            if let opacity { values[index].opacity = opacity }
            values[index].revision += 1; try values[index].validate()
            return values[index]
        }
    }
    /// Invalid/newer external data never replaces the last valid in-memory content.
    @discardableResult func reloadIfChanged() throws -> Bool {
        do {
            let data = try readData()
            guard data != loadedData || !canWrite else { return false }
            let values = try decode(data)
            overlays = values; loadedData = data; canWrite = true; errorMessage = nil
            return true
        } catch { canWrite = false; errorMessage = error.localizedDescription; throw error }
    }
    private func transaction<Result>(_ change: (inout [BoardOverlay]) throws -> Result) throws -> Result {
        do {
            guard canWrite else { throw BoardOverlayError.unavailable }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let descriptor = open(rootURL.appendingPathComponent(".overlays.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw BoardOverlayError.busy }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw BoardOverlayError.busy }
            defer { flock(descriptor, LOCK_UN) }
            let before = try readData()
            var values: [BoardOverlay]
            do { values = try decode(before) } catch { canWrite = false; throw error }
            // Preserve independent external edits, then CAS the requested item.
            let result = try change(&values)
            for overlay in values { try overlay.validate() }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(Envelope(schemaVersion: 1, overlays: values))
            guard try readData() == before else { throw BoardOverlayError.changedOnDisk }
            try encoded.write(to: fileURL, options: .atomic)
            loadedData = encoded; overlays = values; errorMessage = nil
            return result
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    private func readData() throws -> Data? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT { return nil }; throw BoardOverlayError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4 * 1_024 * 1_024 else { throw BoardOverlayError.unavailable }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BoardOverlayError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }
    private func decode(_ data: Data?) throws -> [BoardOverlay] {
        guard let data else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw BoardOverlayError.newerSchema }
        guard envelope.overlays.count <= 60, Set(envelope.overlays.map(\.id)).count == envelope.overlays.count else { throw BoardOverlayError.invalidData }
        for overlay in envelope.overlays { try overlay.validate(); guard overlay.revision >= 1 else { throw BoardOverlayError.invalidData } }
        return envelope.overlays
    }
}
