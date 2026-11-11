import SwiftUI
import AppKit

/// The camera is the workspace; live markings belong to the tracked board.
struct BoardWorkspace: View {
    @ObservedObject var model: BoardModel
    @State private var showMarks = false
    @State private var error: String?

    @AppStorage("board.controlsPinned") private var pinned = false
    @State private var dismissal = 0
    @State private var calibrating = false
    @State private var dockExclusions: [CGRect] = []

    private var showingAnnotationTools: Bool { model.isAnnotatingLive || !model.isLive }

    var body: some View {
        ZStack {
            if model.isLive {
                BoardLiveView(camera: model.camera, annotations: model.liveAnnotations.annotations,
                              overlays: model.overlays.overlays, foregroundMasks: model.preservePhysicalWriting ? model.foregroundMasks : [:],
                              isEditing: model.isAnnotatingLive, label: model.annotationLabel,
                              onMark: model.markLive)
            } else if let image = model.image {
                AnnotationCanvas(image: image, annotations: model.draft?.annotations ?? [], onMark: model.mark)
            } else {
                BoardTheme.surface
            }
            if !calibrating {
                BoardProximityDock(edge: .trailing, expandedWidth: 258, railHeight: 52,
                                   expandedHeight: showingAnnotationTools ? 308 : 230,
                                   pinned: pinned, keepOpen: showMarks, dismissal: dismissal) { _ in
                    VStack(spacing: 0) {
                        dockHeader
                        BoardDockHatchRule(height: 5)
                        BoardCameraControls(model: model, camera: model.camera).padding(10)
                        if showingAnnotationTools {
                            BoardDockHatchRule(height: 5)
                            annotationControls.padding(10)
                        }
                        Spacer(minLength: 0)
                    }
                } rail: {
                    Button { pinned = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .regular))
                            .frame(width: 40, height: 52)
                    }.buttonStyle(.plain).help("Board controls").accessibilityLabel("Open Board controls")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: BoardDockCoordinateSpace.name)
        .environment(\.boardDockExclusionRects, dockExclusions)
        .onPreferenceChange(BoardDockExclusionKey.self) { dockExclusions = $0 }
        .foregroundStyle(BoardTheme.ink).background(BoardTheme.surface)
        .ignoresSafeArea()
        .onReceive(model.camera.$isCalibrating.removeDuplicates()) { calibrating = $0 }
        .onReceive(model.library.$errorMessage.compactMap { $0 }) { error = $0 }
        .onReceive(model.$errorMessage.compactMap { $0 }) { error = $0 }
        .onReceive(model.liveAnnotations.$errorMessage.compactMap { $0 }) { error = $0 }
        .onReceive(model.overlays.$errorMessage.compactMap { $0 }) { error = $0 }
        .onReceive(model.camera.$status.removeDuplicates()) { value in
            if value != "Camera off" && !value.hasPrefix("Camera on") && !value.hasPrefix("Starting") && !value.hasPrefix("Allow camera") { error = value }
        }
        .onReceive(model.camera.$calibrationError.removeDuplicates().compactMap { $0 }) { error = $0 }
        .alert("Board", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var dockHeader: some View {
        HStack(spacing: 8) {
            Text("Board").font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
            icon(pinned ? "pin.fill" : "pin", help: pinned ? "Unpin controls" : "Keep controls open") { pinned.toggle() }
                .foregroundStyle(pinned ? BoardTheme.orange : BoardTheme.ink)
            icon("xmark", help: "Collapse controls") { pinned = false; dismissal &+= 1 }
        }.padding(.leading, 14).padding(.trailing, 8).frame(height: 40)
    }

    private var annotationControls: some View {
        VStack(spacing: 4) {
            TextField("Rectangle label", text: $model.annotationLabel)
                .textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 10).frame(height: 32)
                .background(BoardTheme.field, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Label for the next rectangle")
            HStack {
                Button(action: model.undoAnnotation) { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(model.displayedAnnotations.isEmpty)
                Spacer()
                Button { showMarks.toggle() } label: { Label("Rectangles", systemImage: "square.stack") }
                    .popover(isPresented: $showMarks, arrowEdge: .leading) { markings }
            }.buttonStyle(.plain).font(.system(size: 13)).frame(height: 28)
        }
    }

    private var markings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rectangles").font(.system(size: 15, weight: .medium))
            if model.displayedAnnotations.isEmpty {
                Text("No rectangles yet").font(.system(size: 13)).foregroundStyle(BoardTheme.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.displayedAnnotations) { annotation in
                        HStack(spacing: 8) {
                            TextField("Label", text: Binding(get: {
                                model.displayedAnnotations.first { $0.id == annotation.id }?.label ?? ""
                            }, set: { value in
                                model.renameAnnotation(annotation.id, label: value)
                            }))
                            .textFieldStyle(.plain).font(.system(size: 14))
                            icon("xmark", help: "Remove rectangle") {
                                model.removeAnnotation(annotation.id)
                            }
                        }
                        .padding(.leading, 10).padding(.vertical, 3)
                        .background(BoardTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(maxHeight: 280)
        }.padding(18).frame(width: 300).background(BoardTheme.paper)
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
