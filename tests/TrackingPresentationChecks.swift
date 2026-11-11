import Foundation

@main struct TrackingPresentationChecks {
    static func main() throws {
        let initial = try BoardQuad(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.1, y: 0.8)])
        let moved = try BoardQuad(points: initial.points.map { CGPoint(x: $0.x + 0.05, y: $0.y) })
        var state = BoardTrackingPresentation()
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
        state.apply(BoardTrackingUpdate(quad: initial, state: .tracking, confidence: 1, time: 0))
        check(state.displayQuad == initial && state.permitsCapture, "Accepted calibration must be visible and usable")
        state.apply(BoardTrackingUpdate(quad: moved, state: .tracking, confidence: 0.9, time: 1))
        check(state.displayQuad == moved && state.trackedQuad == moved, "Visible corners must follow the accepted update")
        state.apply(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: 2))
        check(state.displayQuad == moved, "Tracking loss must retain the last visible boundary")
        check(state.state == .lost && state.trackedQuad == nil && !state.permitsCapture, "A retained outline must never authorize a stale capture")
        state.apply(BoardTrackingUpdate(quad: nil, state: .tracking, confidence: 1, time: 3))
        check(state.displayQuad == moved && !state.permitsCapture, "An incomplete update must not erase the outline or enable capture")
        state.apply(BoardTrackingUpdate(quad: initial, state: .tracking, confidence: 0.9, time: 4))
        check(state.displayQuad == initial && state.permitsCapture, "Fresh validated geometry must replace the stale boundary")
        let partial = try BoardQuad(points: initial.points.map { CGPoint(x: $0.x + 0.3, y: $0.y) }, allowOutside: true)
        state.apply(BoardTrackingUpdate(quad: partial, state: .tracking, confidence: 0.9, time: 5))
        check(state.state == .tracking && state.displayQuad == partial && !state.permitsCapture, "Partial boards must remain tracked without enabling incomplete captures")
        state.apply(BoardTrackingUpdate(quad: initial, state: .tracking, confidence: 0.9, time: 6))
        check(state.permitsCapture, "A board returning into frame must become copyable")
        state.reset()
        check(state.state == .off && state.displayQuad == nil && state.trackedQuad == nil, "Explicit clear must remove both geometries")
        print("PASS: \(count) persistent-outline and capture-validity checks")
    }
}
