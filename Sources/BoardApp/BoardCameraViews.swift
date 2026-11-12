import SwiftUI
import AppKit

/// Camera changes redraw only these controls and the live preview, not the workspace.
struct BoardCameraControls: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var camera: CameraController
    @State private var copied = false
    @State private var pendingClear: [BoardOverlay] = []
    @State private var showClearConfirmation = false

    private var sourceName: String { camera.devices.first { $0.id == camera.selectedDeviceID }?.name ?? "Camera" }
    private var trackingActive: Bool { camera.trackingState == .tracking }
    private var copyDisabled: Bool { model.isCapturing || (model.isLive ? !camera.captureAllowed : model.image == nil) }
    private var canBeginAnnotation: Bool { camera.isRunning && !camera.isCalibrating && trackingActive && camera.trackedQuad != nil }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    if camera.isRunning || camera.isStarting { camera.stop() }
                    else { model.showLive(); camera.start() }
                } label: {
                    actionLabel(camera.isStarting ? "Starting" : camera.isRunning ? "Camera ON" : "Camera OFF",
                                symbol: camera.isRunning ? "video.fill" : "video")
                }
                .buttonStyle(BoardDockButtonStyle())
                .help(camera.isRunning ? "Turn off \(sourceName)" : "Turn on \(sourceName)")
                cameraMenu
            }
            Button {
                if trackingActive { camera.clearCalibration() }
                else { model.beginBoardCalibration() }
            } label: {
                actionLabel(camera.trackingState == .lost ? "Recalibrate" : "Track", symbol: "viewfinder", selected: trackingActive)
                    .foregroundStyle(camera.trackingState == .lost ? Color.red : trackingActive ? BoardTheme.orange : BoardTheme.ink)
            }
            .buttonStyle(BoardDockButtonStyle())
            .disabled(!camera.isRunning || camera.isCalibrating || model.isCapturing)
            .help(trackingActive ? "Stop board tracking" : "Choose four board corners")
            .accessibilityValue(trackingActive ? "On" : camera.trackingState == .lost ? "Lost" : "Off")
            .contextMenu {
                Button("Recalibrate", action: model.beginBoardCalibration).disabled(!camera.isRunning)
                Button("Clear tracking", action: camera.clearCalibration).disabled(camera.trackingState == .off && !camera.isCalibrating)
            }
            Button {
                if model.isLive { model.beginAnnotation() }
                else { model.showLive() }
            } label: {
                actionLabel(model.isLive ? "Annotate" : "Live", symbol: model.isLive ? "pencil.tip.crop.circle" : "video",
                            selected: model.isLive && model.isAnnotatingLive)
                    .foregroundStyle(model.isLive && model.isAnnotatingLive ? BoardTheme.orange : BoardTheme.ink)
            }
            .buttonStyle(BoardDockButtonStyle())
            .disabled(model.isCapturing || (model.isLive && !model.isAnnotatingLive && !canBeginAnnotation))
            .help(model.isLive ? (model.isAnnotatingLive ? "Finish drawing; markings remain on the board" : "Draw labelled rectangles on the tracked board") : "Save annotations and return to the camera")
            .accessibilityValue(model.isLive && model.isAnnotatingLive ? "On" : "Off")
            HStack(spacing: 0) {
                Button(action: model.copyBoard) {
                    actionLabel(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(BoardDockButtonStyle())
                .disabled(copyDisabled)
                .help(model.isLive && camera.trackedQuad?.isFullyVisible == false ? "Bring all four board corners into view to copy" : "Copy the whole board image")
                .contextMenu {
                    Button("Copy folder path", action: model.copyFolderPath)
                    Button("Show folder") { NSWorkspace.shared.open(model.library.rootURL) }
                }
                copyMenu
            }
            .foregroundStyle(BoardTheme.orange)
            .task(id: model.copyPulse) {
                guard model.copyPulse > 0 else { return }
                copied = true
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
                copied = false
            }
        }.font(.system(size: 14))
        .confirmationDialog("Delete all AI annotations?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                model.deleteOverlays(pendingClear)
                pendingClear = []
            }
            Button("Cancel", role: .cancel) { pendingClear = [] }
        }
    }

    private func actionLabel(_ title: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 20)
            Text(title)
            Spacer(minLength: 4)
            if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .medium)) }
        }.padding(.horizontal, 9).frame(height: 36).contentShape(Rectangle())
    }

    private var copyMenu: some View {
        Menu {
            Button("Whole board", action: model.copyBoard).disabled(copyDisabled)
            if !model.displayedAnnotations.isEmpty {
                Divider()
                ForEach(Array(model.displayedAnnotations.enumerated()), id: \.element.id) { index, annotation in
                    Button(BoardRegionCopy.title(for: annotation, index: index)) { model.copyRegion(annotation.id) }
                        .disabled(!model.canCopyRegion)
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(copyDisabled)
        .help("Copy the whole board or one rectangle")
        .accessibilityLabel("Copy options")
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(camera.devices) { device in
                Button { camera.selectedDeviceID = device.id } label: {
                    if camera.selectedDeviceID == device.id { Label(device.name, systemImage: "checkmark") }
                    else { Text(device.name) }
                }
            }
            Divider()
            Toggle("Center Stage", isOn: Binding(get: { camera.centerStageEnabled }, set: { camera.setCenterStage($0) }))
                .disabled(!camera.isRunning || !camera.centerStageSupported || camera.centerStageLocked)
            Button("Refresh cameras", action: camera.refreshDevices)
            Button("Camera settings", action: camera.openCameraSettings)
            if !model.overlays.overlays.isEmpty {
                Menu("AI annotations") {
                    Toggle("Automatic transparency", isOn: $model.preservePhysicalWriting)
                    Divider()
                    ForEach(model.overlays.overlays) { overlay in
                        Menu(overlay.title.isEmpty ? "Overlay" : overlay.title) {
                            Button(overlay.hidden ? "Show" : "Hide") {
                                model.setOverlayHidden(overlay, hidden: !overlay.hidden)
                            }
                            Button("Opaque") { model.setOverlayOpacity(overlay, opacity: 1) }
                            Button("Transparent") { model.setOverlayOpacity(overlay, opacity: 0.25) }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteOverlays([overlay]) }
                        }
                    }
                    Divider()
                    Button("Clear all…", role: .destructive) {
                        pendingClear = model.overlays.overlays
                        showClearConfirmation = true
                    }
                }
            }
            Divider()
            Button("Import photograph…", action: model.importImage)
            if !model.library.snapshots.isEmpty {
                Menu("Recent images") {
                    ForEach(Array(model.library.snapshots.prefix(20))) { item in
                        Button(item.title) { model.select(item) }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 36).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Camera, Center Stage and recent images")
        .accessibilityLabel("Camera options")
    }
}

struct BoardLiveView: View {
    @ObservedObject var camera: CameraController
    var annotations: [BoardAnnotation] = []
    var overlays: [BoardOverlay] = []
    var foregroundMasks: [UUID: CGImage] = [:]
    var isEditing = false
    var label = ""
    var onMark: (CGRect) -> Void = { _ in }

    var body: some View {
        if camera.isCalibrating, let image = camera.calibrationImage {
            BoardCalibrationEditor(image: image, onConfirm: camera.commitCalibration, onCancel: camera.cancelCalibration)
                .id(ObjectIdentifier(image))
        } else {
            ZStack {
                if camera.isRunning {
                    CameraPreview(session: camera.session)
                    if let quad = camera.displayQuad {
                        if camera.trackingState == .tracking {
                            BoardLiveOverlayLayer(overlays: overlays, annotations: annotations, quad: quad,
                                imageSize: camera.frameSize, isLost: false, foregroundMasks: foregroundMasks)
                                .allowsHitTesting(false)
                        }
                        BoardTrackedOutline(quad: quad, imageSize: camera.frameSize, isLost: camera.trackingState == .lost)
                        LiveBoardAnnotationOverlay(annotations: annotations, quad: quad, imageSize: camera.frameSize,
                            isEditing: isEditing && camera.trackedQuad != nil, isLost: camera.trackingState != .tracking,
                            label: label, onMark: onMark)
                    }
                    if camera.isCalibrating { ProgressView() }

                } else {
                    Image(systemName: "video.slash").font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(BoardTheme.secondary).accessibilityLabel("Camera is off")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BoardTheme.surface).clipped()
        }
    }
}

/// Persistent coordinates are in the board plane, independent of camera pose.
private struct LiveBoardAnnotationOverlay: View {
    let annotations: [BoardAnnotation]
    let quad: BoardQuad
    let imageSize: CGSize
    let isEditing: Bool
    let isLost: Bool
    let label: String
    let onMark: (CGRect) -> Void
    @Environment(\.boardDockExclusionRects) private var dockExclusions
    @State private var dragStart: CGPoint?
    @State private var blockedDrag = false
    @State private var draftRect: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let imageRect = BoardCameraLayout.aspectFit(imageSize, in: geometry.size)
            let projection = BoardProjectiveMap(corners: quad.points)
            Canvas { context, _ in
                guard let projection else { return }
                // Labels render after every outline, so another marking's edge
                // cannot strike through their text.
                for labelsOnly in [false, true] {
                    for annotation in annotations {
                        draw(annotation.rect, label: annotation.label, projection: projection,
                             imageRect: imageRect, draft: false, labelsOnly: labelsOnly, context: &context)
                    }
                    if let draftRect, !isLost {
                        draw(draftRect, label: label, projection: projection,
                             imageRect: imageRect, draft: true, labelsOnly: labelsOnly, context: &context)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                if dockExclusions.contains(where: { $0.contains(value.startLocation) }) { blockedDrag = true }
                guard isEditing, !isLost, !blockedDrag, let projection else { dragStart = nil; draftRect = nil; return }
                if dragStart == nil { dragStart = point(value.startLocation, imageRect: imageRect, projection: projection) }
                guard let start = dragStart, let end = point(value.location, imageRect: imageRect, projection: projection) else {
                    draftRect = nil; return
                }
                draftRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y))
            }.onEnded { value in
                defer { clearDrag() }
                guard isEditing, !isLost, !blockedDrag, !dockExclusions.contains(where: { $0.contains(value.startLocation) }), let projection, let start = dragStart,
                      let end = point(value.location, imageRect: imageRect, projection: projection),
                      hypot(value.translation.width, value.translation.height) >= 8 else { return }
                let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                if rect.width > 0.003, rect.height > 0.003 { onMark(rect) }
            })
            .allowsHitTesting(isEditing && !isLost)
        }
        .onChange(of: isLost) { _, _ in clearDrag() }
        .onChange(of: isEditing) { _, _ in clearDrag() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLost ? "Saved board markings at their last known position" : "Live board markings")
    }

    private func point(_ screen: CGPoint, imageRect: CGRect, projection: BoardProjectiveMap) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(screen) else { return nil }
        return projection.boardPoint(CGPoint(x: (screen.x - imageRect.minX) / imageRect.width,
                                             y: (screen.y - imageRect.minY) / imageRect.height))
    }
    private func clearDrag() { dragStart = nil; draftRect = nil; blockedDrag = false }
    private func draw(_ rect: CGRect, label: String, projection: BoardProjectiveMap, imageRect: CGRect,
                      draft: Bool, labelsOnly: Bool, context: inout GraphicsContext) {
        guard let projected = projection.imageCorners(for: rect) else { return }
        let points = projected.map { CGPoint(x: imageRect.minX + $0.x * imageRect.width,
                                            y: imageRect.minY + $0.y * imageRect.height) }
        var path = Path(); path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
        let color = isLost ? Color.red : BoardTheme.orange
        let dash: [CGFloat] = isLost || draft ? [7, 5] : []
        if !labelsOnly {
            context.stroke(path, with: .color(.white.opacity(isLost ? 0.45 : 0.85)), style: StrokeStyle(lineWidth: 4, lineJoin: .round, dash: dash))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: dash))
            return
        }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !title.isEmpty else { return }
        let text = context.resolve(Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: max(1, min(260, imageRect.width - 12)), height: 40))
        let width = min(imageRect.width, size.width + 12), height = min(imageRect.height, size.height + 8)
        let frame = CGRect(x: max(imageRect.minX, min(points[0].x, imageRect.maxX - width)),
                           y: max(imageRect.minY, min(points[0].y - height - 1, imageRect.maxY - height)),
                           width: width, height: height)
        context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(color.opacity(isLost ? 0.75 : 1)))
        context.draw(text, in: frame.insetBy(dx: 6, dy: 4))
    }
}
