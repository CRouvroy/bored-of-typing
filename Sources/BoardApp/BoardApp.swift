import SwiftUI
import AppKit
import Combine

@main
struct BoardApp: App {
    @NSApplicationDelegateAdaptor(BoardAppDelegate.self) private var delegate
    @StateObject private var model = BoardModel()
    var body: some Scene {
        Window("Board", id: "board") {
            BoardWorkspace(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .tint(BoardTheme.orange)
                .onAppear { delegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.camera.stop() }
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import photograph…", action: model.importImage).keyboardShortcut("o")
                Button("Annotate board", action: model.beginAnnotation).keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Copy board image", action: model.copyBoard).keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy folder path", action: model.copyFolderPath)
                Button("Save markings", action: model.save).keyboardShortcut("s")
                Divider()
                Button("Connect Claude…", action: model.connectClaude)
                    .disabled(model.isConnectingClaude)
            }
            CommandGroup(replacing: .help) { Button("How to use Board", action: model.showHelp) }
        }
        MenuBarExtra("Board", systemImage: "rectangle.on.rectangle") {
            BoardMenu(model: model)
        }
    }
}

@MainActor
final class BoardAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BoardModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.saveIfNeeded() != false else {
            let alert = NSAlert(); alert.messageText = "Your markings could not be saved"
            alert.informativeText = model?.library.errorMessage ?? "Keep Board open and export your image before quitting."
            alert.addButton(withTitle: "Keep Board open"); alert.runModal()
            return .terminateCancel
        }
        model?.camera.stop()
        return .terminateNow
    }
}

struct BoardMenu: View {
    @ObservedObject var model: BoardModel
    @ObservedObject private var camera: CameraController
    init(model: BoardModel) { self.model = model; self.camera = model.camera }
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Board") { openWindow(id: "board"); NSApp.activate(ignoringOtherApps: true) }
        Button("Copy board image", action: model.copyBoard)
            .disabled(model.isCapturing || (model.isLive ? !camera.captureAllowed : model.image == nil))
        Divider()
        Button("How to use Board", action: model.showHelp)
        Button("Quit Board") { model.camera.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class BoardModel: ObservableObject {
    let camera = CameraController()
    let library: BoardLibrary
    let liveAnnotations: LiveBoardAnnotationStore
    let overlays: BoardOverlayStore
    private var collaboration: BoardCollaborationService?
    // Legacy internal name; live masks now encode uniform temporary opacity only.
    @Published var preservePhysicalWriting = true
    @Published var foregroundMasks: [UUID: CGImage] = [:]
    @Published var draft: BoardSnapshot?
    @Published var image: NSImage?
    @Published var isLive = true
    @Published var isAnnotatingLive = false
    @Published var errorMessage: String?
    @Published var copyPulse = 0
    @Published var annotationLabel = ""
    @Published var isCapturing = false
    @Published var isConnectingClaude = false
    private var subscriptions = Set<AnyCancellable>()
    var dirty: Bool {
        guard let draft, let saved = library.snapshots.first(where: { $0.id == draft.id }) else { return false }
        return draft != saved
    }
    init() {
        let root = ProcessInfo.processInfo.environment["BOARD_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        library = BoardLibrary(rootURL: root)
        liveAnnotations = LiveBoardAnnotationStore(rootURL: library.rootURL)
        overlays = BoardOverlayStore(rootURL: library.rootURL)
        library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        liveAnnotations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        overlays.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        // UI validation uses an isolated library and an explicitly supplied fixture.
        let args = CommandLine.arguments
        if root != nil, let index = args.firstIndex(of: "--ui-test-image"), args.count > index + 1,
           let fixture = NSImage(contentsOfFile: args[index + 1]), let item = library.add(image: fixture, title: "UI TEST — sample board") { select(item) }
        do { collaboration = try BoardCollaborationService(model: self) }
        catch { errorMessage = error.localizedDescription }
    }
    func select(_ item: BoardSnapshot) {
        guard saveIfNeeded() else { return }
        if camera.isCalibrating { camera.cancelCalibration() }
        let saved = library.snapshots.first(where: { $0.id == item.id }) ?? item
        draft = saved; image = library.displayImage(for: saved); isLive = false
    }
    @discardableResult func saveIfNeeded() -> Bool {
        guard dirty, let draft else { return true }
        guard library.update(snapshot: draft) else {
            errorMessage = library.errorMessage ?? "Your markings could not be saved."
            return false
        }
        return true
    }
    func save() {
        _ = saveIfNeeded()
    }
    func showLive() { guard saveIfNeeded() else { return }; isLive = true; isAnnotatingLive = false }
    func beginBoardCalibration() {
        guard !isCapturing, saveIfNeeded() else { return }
        isLive = true
        camera.beginCalibration()
    }
    func beginAnnotation() {
        guard isLive else { return }
        if isAnnotatingLive { isAnnotatingLive = false; return }
        guard camera.isRunning, !camera.isCalibrating, camera.trackingState == .tracking, camera.trackedQuad != nil else { return }
        guard liveAnnotations.canWrite else { errorMessage = liveAnnotations.errorMessage ?? "Live markings could not be opened. Reopen Board before editing."; return }
        isAnnotatingLive = true
    }
    private func captureSnapshot(annotations: [BoardAnnotation] = [], region: BoardRegionCopy.Selection? = nil,
                                 overlayValues: [BoardOverlay] = [], masks: [String: Data]? = nil,
                                 completion: @escaping (BoardSnapshot) -> Void) {
        guard !isCapturing, camera.captureAllowed, saveIfNeeded() else { return }
        guard library.canWrite else { errorMessage = library.errorMessage ?? "The board library is read-only. Reopen Board before copying a new capture."; return }
        isCapturing = true
        camera.capture { [weak self] result in
            guard let self else { return }
            self.isCapturing = false
            switch result {
            case .success(let image):
                do {
                    if let region {
                        let prepared = try BoardRegionCopy.prepare(image: image, selection: region)
                        let mapped = overlayValues.filter { $0.regionID == region.annotation.id }.map { value -> BoardOverlay in
                            var copy = value; copy.regionID = prepared.annotation.id; return copy
                        }
                        let selectedMasks = masks?.filter { key, _ in mapped.contains { $0.id.uuidString == key } }
                        if let item = self.storeSnapshot(image: prepared.image, title: prepared.title, annotations: [prepared.annotation],
                                                         overlayValues: mapped, masks: selectedMasks) { completion(item) }
                    } else {
                        let title = "Capture \(self.library.snapshots.count + 1)"
                        if let item = self.storeSnapshot(image: image, title: title, annotations: annotations,
                                                         overlayValues: overlayValues, masks: masks) { completion(item) }
                    }
                } catch { self.errorMessage = error.localizedDescription }
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }
    private func storeSnapshot(image: NSImage, title: String, annotations: [BoardAnnotation],
                               overlayValues: [BoardOverlay] = [], masks: [String: Data]? = nil) -> BoardSnapshot? {
        guard let item = library.add(image: image, title: title, annotations: annotations,
                                     overlays: overlayValues.isEmpty ? nil : overlayValues,
                                     overlayMasks: masks?.isEmpty == false ? masks : nil) else {
            errorMessage = library.errorMessage ?? "The capture could not be saved. Nothing was copied."
            return nil
        }
        return item
    }
    /// Camera capture rectifies its exact verified frame. The persistent markings
    /// already use that board's normalized coordinates, independently of its pose.
    func copyBoard() {
        if isLive {
            let marks = camera.trackingState == .tracking ? liveAnnotations.annotations : []
            let values = overlays.overlays.filter { overlay in marks.contains { $0.id == overlay.regionID } }
            captureSnapshot(annotations: marks, overlayValues: values, masks: encodedMasks(for: values)) { [weak self] item in self?.copySnapshot(item) }
        } else {
            guard saveIfNeeded(), let draft else { return }
            copySnapshot(draft)
        }
    }
    var canCopyRegion: Bool {
        !isCapturing && (isLive ? camera.isRunning && camera.captureAllowed && camera.trackingState == .tracking && camera.trackedQuad != nil : image != nil && draft != nil)
    }
    func copyRegion(_ id: UUID) {
        let values = displayedAnnotations
        guard let index = values.firstIndex(where: { $0.id == id }) else {
            errorMessage = "That rectangle is no longer available. Choose another rectangle."
            return
        }
        // Freeze ID, geometry and label together; later edits cannot redirect an
        // in-flight copy to another rectangle or to the full camera image.
        let selection = BoardRegionCopy.Selection(annotation: values[index], index: index)
        guard canCopyRegion else {
            errorMessage = isCapturing ? "Wait for the current copy to finish." :
                isLive ? "Turn on the camera and track the full board before copying a rectangle." : "Open an image before copying a rectangle."
            return
        }
        if isLive {
            let values = overlays.overlays.filter { $0.regionID == id }
            captureSnapshot(region: selection, overlayValues: values, masks: encodedMasks(for: values)) { [weak self] item in self?.copySnapshot(item) }
        } else {
            guard saveIfNeeded(), let draft, let original = library.image(for: draft) else { return }
            do {
                let prepared = try BoardRegionCopy.prepare(image: original, selection: selection)
                let values = (draft.overlays ?? []).filter { $0.regionID == id }.map { value -> BoardOverlay in
                    var copy = value; copy.regionID = prepared.annotation.id; return copy
                }
                let masks = draft.overlayMasks?.filter { key, _ in values.contains { $0.id.uuidString == key } }
                if let item = storeSnapshot(image: prepared.image, title: prepared.title, annotations: [prepared.annotation],
                                             overlayValues: values, masks: masks) { copySnapshot(item) }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func encodedMasks(for values: [BoardOverlay]) -> [String: Data]? {
        guard preservePhysicalWriting else { return nil }
        var result: [String: Data] = [:]
        for overlay in values {
            if let mask = foregroundMasks[overlay.id],
               let png = NSBitmapImageRep(cgImage: mask).representation(using: .png, properties: [:]) {
                result[overlay.id.uuidString] = png
            }
        }
        return result.isEmpty ? nil : result
    }
    private func copySnapshot(_ snapshot: BoardSnapshot) {
        guard let url = library.publishCurrent(snapshot: snapshot) else { return }
        do {
            try BoardClipboard.copyImage(at: url)
            copyPulse += 1
        } catch { errorMessage = error.localizedDescription }
    }
    func copyFolderPath() {
        guard saveIfNeeded() else { return }
        if !isLive, let draft, library.publishCurrent(snapshot: draft) == nil { return }
        do {
            try BoardClipboard.copyFolder(library.rootURL)
            copyPulse += 1
        } catch { errorMessage = error.localizedDescription }
    }
    func setOverlayHidden(_ overlay: BoardOverlay, hidden: Bool) {
        do { _ = try overlays.setHidden(id: overlay.id, hidden: hidden, expectedRevision: overlay.revision) }
        catch { errorMessage = error.localizedDescription }
    }
    func setOverlayOpacity(_ overlay: BoardOverlay, opacity: Double) {
        do { _ = try overlays.setOpacity(id: overlay.id, opacity: opacity, expectedRevision: overlay.revision) }
        catch { errorMessage = error.localizedDescription }
    }
    func deleteOverlays(_ selection: [BoardOverlay]) {
        do {
            try overlays.remove(expectedRevisions: Dictionary(uniqueKeysWithValues: selection.map { ($0.id, $0.revision) }))
            for overlay in selection { foregroundMasks.removeValue(forKey: overlay.id) }
        } catch { errorMessage = error.localizedDescription }
    }
    func importImage() {
        guard saveIfNeeded() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = "Import a photograph of your board. The original file stays unchanged."
        guard panel.runModal() == .OK, let url = panel.url, let imported = NSImage(contentsOf: url) else { return }
        if let item = library.add(image: imported, title: url.deletingPathExtension().lastPathComponent) { select(item) }
    }
    func mark(_ rect: CGRect) {
        guard !isLive, var draft else { return }
        draft.annotations.append(BoardAnnotation(rect: rect, label: annotationLabel.trimmingCharacters(in: .whitespacesAndNewlines)))
        self.draft = draft
    }
    var displayedAnnotations: [BoardAnnotation] { isLive ? liveAnnotations.annotations : draft?.annotations ?? [] }
    func markLive(_ rect: CGRect) {
        guard isLive, isAnnotatingLive, camera.isRunning, !camera.isCalibrating,
              camera.trackingState == .tracking, camera.trackedQuad != nil else { return }
        let clipped = BoardGeometry.clamped(rect)
        guard clipped.width > 0.001, clipped.height > 0.001 else { return }
        var values = liveAnnotations.annotations
        values.append(BoardAnnotation(rect: clipped, label: annotationLabel.trimmingCharacters(in: .whitespacesAndNewlines)))
        commitLiveAnnotations(values)
    }
    func undoAnnotation() {
        var values = displayedAnnotations
        guard !values.isEmpty else { return }
        values.removeLast(); replaceAnnotations(values)
    }
    func removeAnnotation(_ id: UUID) { replaceAnnotations(displayedAnnotations.filter { $0.id != id }) }
    func renameAnnotation(_ id: UUID, label: String) {
        var values = displayedAnnotations
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].label = label; replaceAnnotations(values)
    }
    private func replaceAnnotations(_ values: [BoardAnnotation]) {
        if isLive { commitLiveAnnotations(values) }
        else { draft?.annotations = values }
    }
    private func commitLiveAnnotations(_ values: [BoardAnnotation]) {
        // A store made read-only after an external change does not emit another
        // error itself. Repeated user edits must still report their failed save.
        if !liveAnnotations.replace(values) {
            errorMessage = liveAnnotations.errorMessage ?? "Your live markings could not be saved."
        }
    }
    func connectClaude() {
        guard !isConnectingClaude else { return }
        isConnectingClaude = true
        Task {
            defer { isConnectingClaude = false }
            do {
                let result = try await BoardMCPSetup.connect()
                let alert = NSAlert()
                alert.messageText = "Claude setup"
                alert.informativeText = result
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Using Board"
        alert.informativeText = "Move to the right edge to open the controls. Pin keeps the panel open; × collapses it.\n\nCamera selects Mac or iPhone. Track selects four board corners; confirm with ✓. Annotate draws named rectangles that stay attached to the board.\n\nCopy captures the whole board; its arrow selects one rectangle. Paste with ⌘V. Camera → Recent opens saved versions.\n\nFile → Connect Claude sets up the local MCP for Claude Desktop and Claude Code."
        alert.addButton(withTitle: "Got it"); alert.runModal()
    }
}

struct AnnotationCanvas: View {
    @Environment(\.boardDockExclusionRects) private var dockExclusions
    let image: NSImage
    let annotations: [BoardAnnotation]
    let onMark: (CGRect) -> Void
    @State private var drag: CGRect?
    @State private var rendered: NSImage?
    @State private var dragStarted = false
    @State private var dragBlocked = false
    var body: some View {
        GeometryReader { geo in
            let imageSize = image.size
            let scale = min(geo.size.width / max(1, imageSize.width), geo.size.height / max(1, imageSize.height))
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            ZStack {
                BoardTheme.paperShade
                ZStack(alignment: .topLeading) {
                    Image(nsImage: rendered ?? image).resizable().frame(width: size.width, height: size.height)
                    if let drag { Rectangle().stroke(BoardTheme.orange, style: StrokeStyle(lineWidth: 2, dash: [5,3])).frame(width: drag.width, height: drag.height).offset(x: drag.minX, y: drag.minY) }
                }.frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        if !dragStarted {
                            dragStarted = true
                            let start = CGPoint(x: value.startLocation.x + (geo.size.width - size.width) / 2,
                                                y: value.startLocation.y + (geo.size.height - size.height) / 2)
                            dragBlocked = dockExclusions.contains { $0.contains(start) }
                        }
                        guard !dragBlocked else { drag = nil; return }
                        drag = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y), width: abs(value.location.x-value.startLocation.x), height: abs(value.location.y-value.startLocation.y)).intersection(CGRect(origin: .zero, size: size))
                    }.onEnded { _ in
                        if !dragBlocked, let r = drag, !r.isNull, r.width >= 8, r.height >= 8 { onMark(BoardGeometry.normalized(r, in: size)) }
                        drag = nil
                        dragStarted = false; dragBlocked = false
                    })
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 5))
        }.frame(minHeight: 200)
            .onAppear { rendered = BoardLibrary.render(image, annotations: annotations) }
            .onChange(of: annotations) { _, value in rendered = BoardLibrary.render(image, annotations: value) }
            .onChange(of: ObjectIdentifier(image)) { _, _ in rendered = BoardLibrary.render(image, annotations: annotations) }
    }
}
