import SwiftUI
import AppKit

enum BoardCameraLayout {
    static func aspectFit(_ image: CGSize, in available: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2, width: size.width, height: size.height)
    }
}

struct BoardCalibrationEditor: View {
    let image: NSImage
    var onConfirm: ([CGPoint]) -> Void
    var onCancel: () -> Void
    @State private var points: [CGPoint] = []
    @State private var dragOrigin: CGPoint?
    @State private var draggingIndex: Int?

    private var quad: BoardQuad? { try? BoardQuad(points: points) }

    var body: some View {
        GeometryReader { geometry in
            let rect = BoardCameraLayout.aspectFit(image.size, in: geometry.size)
            let controlFrame = CGRect(x: geometry.size.width - 48, y: max(8, geometry.size.height * 0.44 - 58), width: 40, height: 116)
            ZStack(alignment: .topLeading) {
                BoardTheme.surface
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            let workspacePoint = CGPoint(x: value.location.x + rect.minX, y: value.location.y + rect.minY)
                            guard points.count < 4, rect.width > 0, rect.height > 0, !controlFrame.contains(workspacePoint) else { return }
                            let point = CGPoint(x: value.location.x / rect.width, y: value.location.y / rect.height)
                            guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
                            points.append(point)
                        })
                    Path { path in
                        let ordered = quad?.points ?? points
                        guard let first = ordered.first else { return }
                        path.move(to: CGPoint(x: first.x * rect.width, y: first.y * rect.height))
                        for point in ordered.dropFirst() { path.addLine(to: CGPoint(x: point.x * rect.width, y: point.y * rect.height)) }
                        if ordered.count == 4 { path.closeSubpath() }
                    }.stroke(points.count == 4 && quad == nil ? Color.red : BoardTheme.orange, lineWidth: 2).allowsHitTesting(false)
                    ForEach(points.indices, id: \.self) { index in
                        Circle().fill(BoardTheme.orange).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .frame(width: 34, height: 34).contentShape(Circle())
                            .position(x: points[index].x * rect.width, y: points[index].y * rect.height)
                            .accessibilityLabel("Corner \(index + 1)")
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("board-calibration")).onChanged { value in
                                if draggingIndex != index { dragOrigin = points[index]; draggingIndex = index }
                                guard let origin = dragOrigin else { return }
                                points[index] = CGPoint(x: min(1, max(0, origin.x + value.translation.width / rect.width)),
                                                        y: min(1, max(0, origin.y + value.translation.height / rect.height)))
                            }.onEnded { _ in dragOrigin = nil; draggingIndex = nil })
                    }
                }
                .frame(width: rect.width, height: rect.height).coordinateSpace(name: "board-calibration")
                .position(x: rect.midX, y: rect.midY)
                VStack(spacing: 2) {
                    Button { if !points.isEmpty { points.removeLast() } } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 32)
                    }.disabled(points.isEmpty).help("Undo corner").accessibilityLabel("Undo corner")
                    Button { onConfirm(points) } label: {
                        Image(systemName: "checkmark").foregroundStyle(BoardTheme.orange).frame(width: 32, height: 32)
                    }.disabled(quad == nil).help(points.count < 4 ? "Choose four corners to track" : "Track board").accessibilityLabel("Track board")
                    Button(action: onCancel) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .help("Cancel calibration").accessibilityLabel("Cancel calibration")
                }
                .buttonStyle(BoardDockButtonStyle()).font(.system(size: 14))
                .frame(width: controlFrame.width, height: controlFrame.height)
                .background(BoardTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(BoardTheme.line, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.045), radius: 9, x: -1, y: 4)
                .position(x: controlFrame.midX, y: controlFrame.midY)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
    }
}

struct BoardTrackedOutline: View {
    let quad: BoardQuad
    let imageSize: CGSize
    var isLost = false
    var body: some View {
        GeometryReader { geometry in
            let rect = BoardCameraLayout.aspectFit(imageSize, in: geometry.size)
            let points = quad.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let outline = Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            let color = isLost ? Color.red : BoardTheme.orange
            ZStack {
                outline.stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineJoin: .round, dash: isLost ? [9, 6] : []))
                outline.stroke(color, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: isLost ? [9, 6] : []))
                ForEach(points.indices, id: \.self) { index in
                    Circle().fill(color).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .position(points[index])
                }
            }
        }.allowsHitTesting(false).accessibilityElement(children: .ignore)
            .accessibilityLabel(isLost ? "Last board position — tracking lost" : "Tracked board")
    }
}
