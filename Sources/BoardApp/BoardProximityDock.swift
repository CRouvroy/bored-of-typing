// Floating surface and motion adapted from Desk; see LICENSE.
import SwiftUI
import AppKit

/// Both edges use the same fixed-layout flyout. Only the mask and the small
/// compact rail follow motion; the expanded controls never resize while opening.
struct BoardProximityDock<Content: View, Rail: View>: View {
    let edge: HorizontalEdge
    let expandedWidth: CGFloat
    let railHeight: CGFloat
    let expandedHeight: CGFloat
    let pinned: Bool
    var keepOpen = false
    let dismissal: Int
    @ViewBuilder var content: (Bool) -> Content
    @ViewBuilder var rail: () -> Rail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var editing = false
    @State private var interacting = false
    @State private var pointerInsideSurface = false
    @State private var dismissedUntilExit = false
    // Reference storage is intentionally unobserved here. Only MotionSurface
    // observes the mask's samples; pointer attraction cannot rebuild the content.
    @State private var motion = Motion()
    @State private var transient = Transient()
    private final class Transient {
        var pointer: CGPoint?
        var closeTask: Task<Void, Never>?
        var lastSampleTime = 0.0
    }
    private var held: Bool { pinned || keepOpen || editing || interacting }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = min(expandedWidth, max(40, size.width - 32))
            let height = min(max(railHeight, expandedHeight), max(railHeight, size.height - 16))
            let fullFrame = CGRect(x: edge == .leading ? 8 : size.width - width - 8,
                                   y: min(size.height - height - 8, max(8, restY(size) - height / 2)), width: width, height: height)
            let viewport = geometry.frame(in: .named(BoardDockCoordinateSpace.name))
            let resting = restingFrame(size)
            let proximity = BoardDockProximityRegion(rail: resting)
            // A visual preview never reserves the whole window edge or intercepts
            // controls behind it. Only a fully opened panel owns its full frame.
            let blocked = expanded || held ? fullFrame : resting
            let exclusion = blocked.offsetBy(dx: viewport.minX, dy: viewport.minY)
            ZStack(alignment: .topLeading) {
                BoardWorkspacePointerMonitor(onPointer: { updatePointer($0, size: size, fullFrame: fullFrame) },
                                        onEditing: { active in
                                            if editing != active { editing = active }
                                            if active { expand() } else { reevaluate(size: size, fullFrame: fullFrame) }
                                        }, focusRegion: expanded || held ? fullFrame : .zero,
                                        pointerRegion: expanded || held ? fullFrame : proximity.trackingBounds,
                                        onInteraction: { active in
                                            if interacting != active { interacting = active }
                                            if active { expand() } else { reevaluate(size: size, fullFrame: fullFrame) }
                                        })
                    // NSViewRepresentable has no intrinsic viewport size. Pin
                    // its bounds to the same coordinates as both edge formulas;
                    // the fixed-width surface must not shrink this observer.
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
                MotionSurface(motion: motion, edge: edge, railHeight: railHeight,
                                  fullFrame: fullFrame, restY: restY(size), expanded: expanded,
                                  reduceMotion: reduceMotion,
                                  content: content(expanded), rail: rail())
                    .allowsHitTesting(held || pointerInsideSurface)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .preference(key: BoardDockExclusionKey.self, value: [exclusion])
            .onChange(of: pinned) { _, open in
                if open { dismissedUntilExit = false; expand() }
                else { reevaluate(size: size, fullFrame: fullFrame) }
            }
            .onChange(of: keepOpen) { _, open in
                if open { expand() } else { reevaluate(size: size, fullFrame: fullFrame) }
            }
            .onChange(of: dismissal) { _, _ in dismiss(size: size) }
            .onAppear { if held { expand() } }
            .onDisappear { cancelTimers() }
        }
    }

    private func restY(_ size: CGSize) -> CGFloat {
        min(size.height - railHeight / 2 - 8, max(railHeight / 2 + 8, size.height * 0.44))
    }
    private func restingFrame(_ size: CGSize) -> CGRect {
        CGRect(x: edge == .leading ? 8 : size.width - 48,
               y: restY(size) - railHeight / 2, width: 40, height: railHeight)
    }
    private func reevaluate(size: CGSize, fullFrame: CGRect) { updatePointer(transient.pointer, size: size, fullFrame: fullFrame) }
    private func updatePointer(_ point: CGPoint?, size: CGSize, fullFrame: CGRect) {
        transient.pointer = point
        if held { expand(); return }
        let proximity = BoardDockProximityRegion(rail: restingFrame(size))
        guard let point else {
            dismissedUntilExit = false
            setPointerInside(false)
            if expanded { scheduleClose() } else { preview(0, magnetY: nil, force: true) }
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if dismissedUntilExit {
            if !proximity.trackingBounds.contains(point) { dismissedUntilExit = false }
            else { return }
        }
        if expanded {
            setPointerInside(fullFrame.contains(point))
            if pointerInsideSurface { cancelTimers() } else { scheduleClose() }
            return
        }
        let reveal = proximity.reveal(at: point)
        setPointerInside(proximity.contains(point))
        if reveal >= 1 { expand(); return }
        // Distance drives the preview in both axes. There is no timer that opens
        // a panel merely because the cursor happens to share its x coordinate.
        let pull = min(6, max(-6, (point.y - proximity.rail.midY) * 0.12))
        preview(reduceMotion ? 0 : reveal, magnetY: reveal > 0 ? proximity.rail.midY + pull * reveal : nil,
                force: reveal == 0)
    }
    private func setPointerInside(_ value: Bool) {
        if pointerInsideSurface != value { pointerInsideSurface = value }
    }
    private func preview(_ reveal: CGFloat, magnetY: CGFloat?, force: Bool = false) {
        let previous = motion.sample
        guard abs(previous.reveal - reveal) >= 0.008 || abs((previous.magnetY ?? 0) - (magnetY ?? 0)) >= 1 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - transient.lastSampleTime >= 1.0 / 60 else { return }
        transient.lastSampleTime = now
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.92)) {
            motion.sample = .init(reveal: reveal, magnetY: magnetY)
        }
    }
    private func expand() {
        cancelTimers()
        guard !expanded || motion.sample.reveal != 1 else { return }
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.9)) {
            expanded = true
            motion.sample = .init(reveal: 1, magnetY: motion.sample.magnetY)
        }
    }
    private func collapse() {
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.94)) {
            expanded = false
            motion.sample = .init(reveal: 0, magnetY: nil)
        }
    }
    private func dismiss(size: CGSize) {
        if editing { NSApp.keyWindow?.makeFirstResponder(nil) }
        editing = false; interacting = false; setPointerInside(false)
        // Dismissal outside the capsule's neighbourhood needs no edge-wide latch.
        dismissedUntilExit = transient.pointer.map { BoardDockProximityRegion(rail: restingFrame(size)).trackingBounds.contains($0) } ?? false
        cancelTimers(); collapse()
    }
    private func cancelTimers() {
        transient.closeTask?.cancel(); transient.closeTask = nil
    }
    private func scheduleClose() {
        guard transient.closeTask == nil, expanded else { return }
        transient.closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            transient.closeTask = nil
            guard !held else { return }
            collapse()
        }
    }
}

private final class Motion: ObservableObject {
    struct Sample: Equatable { var reveal: CGFloat = 0; var magnetY: CGFloat? }
    @Published var sample = Sample()
}

/// Expanded content is a stable value supplied by the parent. Animation changes
/// a vector mask and rail position inside a fixed frame, never sidebar layout.
private struct MotionSurface<Content: View, Rail: View>: View {
    @ObservedObject var motion: Motion
    let edge: HorizontalEdge
    let railHeight: CGFloat
    let fullFrame: CGRect
    let restY: CGFloat
    let expanded: Bool
    let reduceMotion: Bool
    let content: Content
    let rail: Rail

    var body: some View {
        let reveal = motion.sample.reveal
        let width = 40 + (fullFrame.width - 40) * reveal
        let height = railHeight + (fullFrame.height - railHeight) * reveal
        let centerY = (motion.sample.magnetY ?? restY) * (1 - reveal) + fullFrame.midY * reveal
        let clip = CGRect(x: edge == .leading ? 0 : fullFrame.width - width,
                          y: centerY - height / 2 - fullFrame.minY, width: width, height: height)
        let shape = RevealShape(rect: clip, radius: 18 - reveal * 10)
        ZStack(alignment: .topLeading) {
            BoardTheme.paper
            content
                .frame(width: fullFrame.width, height: fullFrame.height)
                .opacity(expanded ? 1 : 0)
                .offset(x: reduceMotion ? 0 : (edge == .leading ? -1 : 1) * (1 - reveal) * 12)
                .allowsHitTesting(expanded).accessibilityHidden(!expanded)
            rail.frame(width: 40, height: railHeight)
                .position(x: edge == .leading ? 20 : fullFrame.width - 20,
                          y: restY - fullFrame.minY)
                // Keep a legible rail throughout the proximity preview. The
                // expanded controls crossfade only once the rail is entered.
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded).accessibilityHidden(expanded)
        }
        .frame(width: fullFrame.width, height: fullFrame.height)
        // Clip the entire composition, including compact selection highlights.
        .mask(shape)
        .overlay(shape.stroke(BoardTheme.line, lineWidth: 0.75).allowsHitTesting(false))
        .compositingGroup()
        .shadow(color: .black.opacity(0.045), radius: 9, x: edge == .leading ? 1 : -1, y: 4)
        .contentShape(shape)
        .position(x: fullFrame.midX, y: fullFrame.midY)
    }
}

private struct RevealShape: Shape {
    var rect: CGRect
    var radius: CGFloat
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { .init(.init(rect.origin.x, rect.origin.y), .init(.init(rect.width, rect.height), radius)) }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first.first, height: newValue.second.first.second)
            radius = newValue.second.second
        }
    }
    func path(in _: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: radius) }
}

/// A quiet etched divider shared by the floating panels. It never takes pointer events.
struct BoardDockHatchRule: View {
    var height: CGFloat = 6
    var body: some View {
        Canvas { context, size in
            var marks = Path()
            for x in stride(from: -size.height, through: size.width, by: 6) {
                marks.move(to: CGPoint(x: x, y: size.height))
                marks.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(marks, with: .color(BoardTheme.line.opacity(0.65)), lineWidth: 0.5)
        }
        .frame(height: height).clipped()
        .overlay(alignment: .top) { Rectangle().fill(BoardTheme.line.opacity(0.55)).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(BoardTheme.line.opacity(0.55)).frame(height: 0.5) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The canvas stays the coordinate origin as the dock reveals above it.
enum BoardDockCoordinateSpace { static let name = "board-workspace" }
struct BoardDockExclusionKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
private struct BoardDockExclusionEnvironmentKey: EnvironmentKey { static let defaultValue: [CGRect] = [] }
extension EnvironmentValues {
    var boardDockExclusionRects: [CGRect] {
        get { self[BoardDockExclusionEnvironmentKey.self] }
        set { self[BoardDockExclusionEnvironmentKey.self] = newValue }
    }
}
