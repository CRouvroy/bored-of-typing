import AppKit
import Combine
import CoreFoundation
import Darwin
import Foundation

/// Local, bounded mailbox used by the stdio MCP adapter. No sockets, credentials,
/// model calls, unsolicited screenshots, or chat databases are involved.
@MainActor
final class BoardCollaborationService {
    private weak var model: BoardModel?
    private let root: URL
    private let requests: URL
    private let responses: URL
    private let images: URL
    private var lock: Int32 = -1
    private var timer: Timer?
    private var lastStatusWrite = Date.distantPast
    private var lastCleanup = Date.distantPast
    private var statusFingerprint = Data()
    private var revision = 0
    private let instanceID = UUID()
    private var completed: [UUID: (Date, [String: Any])] = [:]
    private var pending = Set<UUID>()
    private var captureInFlight = false
    private var samplingEnabled = false
    private var sampleEpoch: UUID?
    private var lastSampleTime: TimeInterval?
    private var inkDetector = BoardInkChangeDetector()
    private var inkContents: [UUID: BoardOverlay] = [:]
    private var inkGenerations: [UUID: Int] = [:]
    private var nextInkGeneration = 0

    init(model: BoardModel) throws {
        self.model = model
        root = model.library.rootURL.appendingPathComponent("collaboration", isDirectory: true)
        requests = root.appendingPathComponent("requests", isDirectory: true)
        responses = root.appendingPathComponent("responses", isDirectory: true)
        images = root.appendingPathComponent("images", isDirectory: true)
        for directory in [root, requests, responses, images] {
            try Self.rejectLink(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        lock = open(root.appendingPathComponent(".service.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock); lock = -1 }
            throw CollaborationError.message("Another Board window owns the collaboration connection. Use that window or close it first.")
        }
        model.camera.onBoardSample = { [weak self] image, epoch in self?.acceptSample(image, epoch: epoch) }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }
    deinit { timer?.invalidate(); if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

    private func tick() {
        guard let model else { return }
        let regions = Set(model.liveAnnotations.annotations.map(\.id))
        let active = maySample(model) && model.overlays.overlays.contains {
            !$0.hidden && $0.opacity > 0 && regions.contains($0.regionID)
        }
        if active != samplingEnabled {
            samplingEnabled = active; model.camera.setBoardSamplingEnabled(active)
            resetActivity(model)
        }
        // No sample may leave the display permanently dim after interruption,
        // partial framing, camera loss or a stalled analysis queue.
        if let lastSampleTime, ProcessInfo.processInfo.systemUptime - lastSampleTime > 1.5 {
            resetActivity(model)
        }
        if Date().timeIntervalSince(lastStatusWrite) >= 2 {
            do { try writeJSON(status(), to: root.appendingPathComponent("status.json")); lastStatusWrite = Date() }
            catch { report(error) }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return }
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(64) {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !pending.contains(id) else { continue }
            if let saved = completed[id] { try? writeJSON(saved.1, to: responseURL(id)); try? FileManager.default.removeItem(at: url); continue }
            do {
                try Self.rejectLink(url)
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, let count = info.fileSize, count <= 65_536 else { throw CollaborationError.message("Request is too large or unavailable.") }
                guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      Self.integer(value["schemaVersion"]) == 1,
                      let identifier = value["id"] as? String, UUID(uuidString: identifier) == id,
                      let created = Self.number(value["createdAt"]),
                      Date().timeIntervalSince1970 - created < 10, created - Date().timeIntervalSince1970 <= 5,
                      let method = value["method"] as? String,
                      let arguments = value["arguments"] as? [String: Any] else { throw CollaborationError.message("Request is invalid or expired. Inspect current state before trying a change again.") }
                pending.insert(id)
                try handle(method, arguments: arguments, id: id)
            } catch { complete(id, error: error.localizedDescription) }
        }
        if Date().timeIntervalSince(lastCleanup) >= 30 { cleanup(); lastCleanup = Date() }
    }

    private func status() -> [String: Any] {
        guard let model else { return [:] }
        let annotations = model.liveAnnotations.annotations
        let regions = annotations.prefix(100).enumerated().map { index, a -> [String: Any] in
            ["id": a.id.uuidString, "label": a.label.isEmpty ? "Rectangle \(index + 1)" : Self.compact(a.label, bytes: 160),
             "x": a.x, "y": a.y, "width": a.width, "height": a.height]
        }
        let value: [String: Any] = ["cameraOn": model.camera.isRunning,
            "tracking": model.camera.trackingState.rawValue, "liveView": model.isLive,
            "regions": regions, "regionsTruncated": annotations.count > 100,
            "overlays": model.overlays.overlays.map(Self.summary), "preservePhysicalWriting": model.preservePhysicalWriting,
            "automaticTransparency": model.preservePhysicalWriting,
            "overlayVisibilityPolicy": "temporary-uniform-opacity",
            "capabilities": ["overlayKinds": ["text", "diagram"],
                             "overlayFrame": "normalized-top-left-in-region"]]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data != statusFingerprint {
            revision += 1; statusFingerprint = data
        }
        return value.merging(["schemaVersion": 1, "revision": revision, "instanceID": instanceID.uuidString,
                              "updatedAt": Date().timeIntervalSince1970]) { _, new in new }
    }

    private func handle(_ method: String, arguments: [String: Any], id: UUID) throws {
        guard let model else { throw CollaborationError.message("Board is closing.") }
        switch method {
        case "board_status":
            let current = status()
            if Self.integer(arguments["since_revision"]) == revision,
               (arguments["instance_id"] as? String) == instanceID.uuidString {
                complete(id, result: ["unchanged": true, "revision": revision, "instanceID": instanceID.uuidString])
            } else { complete(id, result: current) }
        case "board_list_overlays":
            if let raw = arguments["overlay_id"] as? String {
                guard let overlayID = UUID(uuidString: raw), let overlay = model.overlays.overlays.first(where: { $0.id == overlayID }) else {
                    throw CollaborationError.message("Unknown overlay. Read board_status for current IDs.")
                }
                complete(id, result: ["overlay": try Self.object(overlay)])
            } else { complete(id, result: ["overlays": model.overlays.overlays.map(Self.summary)]) }
        case "board_read_region":
            try readRegion(arguments, id: id)
        case "board_put_overlay":
            guard var object = arguments["overlay"] as? [String: Any],
                  let region = object["regionID"] as? String, let regionID = UUID(uuidString: region),
                  model.liveAnnotations.annotations.contains(where: { $0.id == regionID }) else {
                throw CollaborationError.message("Choose an existing live rectangle using its regionID from board_status.")
            }
            if object["id"] == nil { object["id"] = UUID().uuidString }
            object["revision"] = 0
            for (key, value) in ["title": "", "text": "", "opacity": 1.0, "hidden": false, "nodes": [], "edges": []] as [String: Any] {
                if object[key] == nil { object[key] = value }
            }
            let overlay = try JSONDecoder().decode(BoardOverlay.self, from: JSONSerialization.data(withJSONObject: object))
            let expected = try expectedRevision(arguments, required: false)
            let saved = try model.overlays.upsert(overlay, expectedRevision: expected)
            // A replacement starts a fresh motion baseline; manual opacity stays independent.
            inkContents.removeValue(forKey: saved.id)
            model.foregroundMasks.removeValue(forKey: saved.id)
            complete(id, result: ["overlay": Self.summary(saved)])
        case "board_set_overlay":
            guard let raw = arguments["overlay_id"] as? String, let overlayID = UUID(uuidString: raw),
                  let expected = try expectedRevision(arguments, required: true) else { throw CollaborationError.message("An overlay ID and current expected_revision are required.") }
            let hidden = try Self.optionalBoolean(arguments, "hidden")
            let opacity = arguments["opacity"].flatMap(Self.number)
            if arguments["opacity"] != nil && opacity == nil { throw CollaborationError.message("Opacity must be a finite number.") }
            guard hidden != nil || opacity != nil else { throw CollaborationError.message("Specify hidden or opacity.") }
            let saved = try model.overlays.update(id: overlayID, expectedRevision: expected, hidden: hidden, opacity: opacity)
            complete(id, result: ["overlay": Self.summary(saved)])
        default: throw CollaborationError.message("Unknown Board operation.")
        }
    }

    private func readRegion(_ arguments: [String: Any], id: UUID) throws {
        guard let model, model.isLive, model.camera.isRunning, model.camera.trackingState == .tracking,
              model.camera.trackedQuad?.isFullyVisible == true, model.camera.captureAllowed else {
            throw CollaborationError.message("Open Board's live camera and track the entire board before requesting an image.")
        }
        guard !captureInFlight, !model.isCapturing else { throw CollaborationError.message("A board capture is already in progress. Try again after it finishes.") }
        guard let raw = arguments["region_id"] as? String, let regionID = UUID(uuidString: raw),
              let region = model.liveAnnotations.annotations.first(where: { $0.id == regionID }) else {
            throw CollaborationError.message("Unknown region. Read board_status for rectangle IDs.")
        }
        let maximum = arguments["max_edge"] == nil ? 1024 : (Self.integer(arguments["max_edge"]) ?? 0)
        guard (256...1600).contains(maximum) else { throw CollaborationError.message("max_edge must be an integer from 256 to 1600.") }
        let include = try Self.optionalBoolean(arguments, "include_overlays") ?? false
        let overlays = include ? model.overlays.overlays : []
        let annotations = model.liveAnnotations.annotations
        captureInFlight = true
        let masks = model.preservePhysicalWriting ? model.foregroundMasks : [:]
        model.camera.capture { [weak self] result in
            guard let self else { return }
            self.captureInFlight = false
            do {
                let image = try result.get()
                let rendered: NSImage
                if include {
                    guard let composed = BoardOverlayRenderer.shared.compose(image: image, overlays: overlays, annotations: annotations,
                                                                             foregroundMasks: masks) else { throw CollaborationError.message("The overlays could not be rendered.") }
                    rendered = composed
                } else { rendered = image }
                guard let crop = BoardLibrary.cropped(rendered, normalizedRect: region.rect),
                      let reduced = Self.resized(crop, maximum: maximum), let cg = BoardLibrary.cgImage(reduced),
                      let png = BoardLibrary.pngData(reduced), png.count <= 12_000_000 else { throw CollaborationError.message("The requested region could not be encoded.") }
                let name = id.uuidString + ".png"
                let url = self.images.appendingPathComponent(name)
                try Self.rejectLink(url)
                try png.write(to: url, options: .atomic)
                self.complete(id, result: ["imageName": name, "width": cg.width, "height": cg.height,
                    "regionID": regionID.uuidString, "label": Self.compact(region.label, bytes: 160), "includeOverlays": include])
            } catch { self.complete(id, error: error.localizedDescription) }
        }
    }
    private func acceptSample(_ image: CGImage, epoch: UUID) {
        guard samplingEnabled, let model, maySample(model) else { return }
        if sampleEpoch != epoch {
            resetActivity(model)
            sampleEpoch = epoch
        }
        lastSampleTime = ProcessInfo.processInfo.systemUptime
        let regions = Dictionary(uniqueKeysWithValues: model.liveAnnotations.annotations.map { ($0.id, $0.rect) })
        let ids = Set(model.overlays.overlays.map(\.id))
        inkContents = inkContents.filter { ids.contains($0.key) }
        inkGenerations = inkGenerations.filter { ids.contains($0.key) }
        let targets = model.overlays.overlays.compactMap { overlay -> BoardInkChangeDetector.Target? in
            guard !overlay.hidden, overlay.opacity > 0, let region = regions[overlay.regionID] else { return nil }
            let placement = overlay.frame?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let rect = CGRect(x: region.minX + placement.minX * region.width,
                              y: region.minY + placement.minY * region.height,
                              width: placement.width * region.width,
                              height: placement.height * region.height)
            var content = overlay
            content.revision = 0; content.hidden = false; content.opacity = 1
            if inkContents[overlay.id] != content {
                nextInkGeneration += 1
                inkContents[overlay.id] = content
                inkGenerations[overlay.id] = nextInkGeneration
            }
            return BoardInkChangeDetector.Target(id: overlay.id, revision: inkGenerations[overlay.id]!, rect: rect)
        }
        model.foregroundMasks = inkDetector.consume(image, targets: targets)
    }
    private func maySample(_ model: BoardModel) -> Bool {
        model.isLive && model.preservePhysicalWriting && model.camera.isRunning &&
        model.camera.captureAllowed && model.camera.trackingState == .tracking &&
        model.camera.trackedQuad?.isFullyVisible == true
    }
    private func resetActivity(_ model: BoardModel) {
        inkDetector.reset()
        sampleEpoch = nil
        lastSampleTime = nil
        if !model.foregroundMasks.isEmpty { model.foregroundMasks = [:] }
    }

    private func expectedRevision(_ arguments: [String: Any], required: Bool) throws -> Int? {
        guard let value = arguments["expected_revision"] else {
            if required { throw CollaborationError.message("Read the current overlay revision before editing it.") }
            return nil
        }
        guard let number = Self.integer(value), number >= 1 else { throw CollaborationError.message("expected_revision must be a positive integer.") }
        return number
    }
    private func complete(_ id: UUID, result: [String: Any]? = nil, error: String? = nil) {
        var value: [String: Any] = ["schemaVersion": 1, "id": id.uuidString]
        if let error { value["error"] = String(error.prefix(1500)) } else { value["result"] = result ?? [:] }
        if let data = try? JSONSerialization.data(withJSONObject: value), data.count > 262_144 {
            value = ["schemaVersion": 1, "id": id.uuidString, "error": "This response exceeds Board's metadata limit. Request one overlay or a smaller region."]
        }
        completed[id] = (Date(), value); pending.remove(id)
        do {
            try writeJSON(value, to: responseURL(id))
            let request = requests.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: request.path) { try FileManager.default.removeItem(at: request) }
        } catch { report(error) }
        lastStatusWrite = .distantPast
    }
    private func responseURL(_ id: UUID) -> URL { responses.appendingPathComponent(id.uuidString + ".json") }
    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try Self.rejectLink(url)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 262_144 else { throw CollaborationError.message("Board's collaboration metadata exceeds its size limit.") }
        try data.write(to: url, options: .atomic)
    }
    private func cleanup() {
        completed = completed.filter { Date().timeIntervalSince($0.value.0) < 120 }
        if completed.count > 128 {
            let oldest = completed.sorted { $0.value.0 < $1.value.0 }.prefix(completed.count - 128)
            for entry in oldest { completed.removeValue(forKey: entry.key) }
        }
        for directory in [requests, responses, images] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for file in files.prefix(512) {
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      ["json", "png"].contains(file.pathExtension),
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let date = values.contentModificationDate, Date().timeIntervalSince(date) > 120 else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    private func report(_ error: Error) {
        guard model?.errorMessage != error.localizedDescription else { return }
        model?.errorMessage = error.localizedDescription
    }
    private static func summary(_ overlay: BoardOverlay) -> [String: Any] {
        var value: [String: Any] = ["id": overlay.id.uuidString, "regionID": overlay.regionID.uuidString, "revision": overlay.revision,
         "kind": overlay.kind.rawValue, "title": compact(overlay.title, bytes: 120), "opacity": overlay.opacity, "hidden": overlay.hidden]
        if let frame = overlay.frame {
            value["frame"] = ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height]
        }
        return value
    }
    private static func compact(_ value: String, bytes: Int) -> String {
        String(decoding: value.utf8.prefix(bytes), as: UTF8.self)
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw CollaborationError.message("The overlay could not be encoded.")
        }
        return object
    }
    private static func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CollaborationError.message("Board's collaboration files must be local regular files.")
        }
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number, abs(number) < Double(Int.max) else { return nil }
        return Int(number)
    }
    private static func optionalBoolean(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CollaborationError.message("\(key) must be true or false.")
        }
        return number.boolValue
    }
    static func resized(_ image: NSImage, maximum: Int) -> NSImage? {
        guard let source = BoardLibrary.cgImage(image), maximum > 0 else { return nil }
        let scale = min(1, Double(maximum) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded())), height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: CGSize(width: width, height: height))
    }
    private enum CollaborationError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}
