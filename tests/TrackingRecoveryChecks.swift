import Foundation

@main struct TrackingRecoveryChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let initial = try BoardQuad(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.1),
            CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.1, y: 0.8)])
        let fresh = try BoardQuad(points: initial.points.map { CGPoint(x: $0.x + 0.03, y: $0.y + 0.02) })
        var gate = BoardTrackingRecoveryGate()
        var presentation = BoardTrackingPresentation()
        presentation.apply(BoardTrackingUpdate(quad: initial, state: .tracking, confidence: 0.9, time: 1))
        expect(gate.mayProcess && !gate.isLost && presentation.permitsCapture, "Initial accepted board can process and capture")

        var lossTransitions = 0
        if gate.lose(allowRecovery: true, canRecover: true) { lossTransitions += 1 }
        presentation.apply(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: 2))
        expect(gate.isLost && gate.mayProcess && !gate.hardInvalid, "A transient loss must keep background processing enabled")
        expect(!presentation.permitsCapture && presentation.trackedQuad == nil,
               "Retained recovery anchors must not authorize capture")
        expect(presentation.displayQuad == initial, "A transient loss retains the last outline for display only")
        for _ in 0..<12 {
            if gate.lose(allowRecovery: true, canRecover: true) { lossTransitions += 1 }
        }
        expect(lossTransitions == 1, "Repeated rejected frames produce one lost transition for logging")
        expect(gate.mayProcess && !presentation.permitsCapture, "Retries remain enabled while capture stays blocked")

        var recoveryTransitions = 0
        if gate.acceptTracking() { recoveryTransitions += 1 }
        expect(!presentation.permitsCapture, "A worker recovery signal alone must not expose stale display geometry")
        presentation.apply(BoardTrackingUpdate(quad: fresh, state: .tracking, confidence: 0.9, time: 3))
        expect(!gate.isLost && gate.mayProcess && presentation.permitsCapture && presentation.trackedQuad == fresh,
               "A fresh accepted result restores valid geometry and capture")
        for _ in 0..<12 { if gate.acceptTracking() { recoveryTransitions += 1 } }
        expect(recoveryTransitions == 1, "Normal tracking frames must not repeat recovered transition logs")

        _ = gate.lose(allowRecovery: false, canRecover: true)
        presentation.apply(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: 4))
        expect(gate.hardInvalid && !gate.mayProcess && !presentation.permitsCapture,
               "A source or framing invalidation closes processing and capture")
        expect(!gate.acceptTracking() && gate.isLost, "A stale result cannot recover a hard-invalidated calibration")
        _ = gate.lose(allowRecovery: true, canRecover: true)
        expect(gate.hardInvalid && !gate.mayProcess, "A later soft-loss retry must not reopen a source boundary")

        gate.reset()
        presentation.reset()
        expect(gate.mayProcess && !gate.isLost && !gate.hardInvalid,
               "An explicit reset allows a new calibration to start")
        expect(presentation.displayQuad == nil && presentation.trackedQuad == nil,
               "The new calibration must not inherit the old board boundary")
        presentation.apply(BoardTrackingUpdate(quad: initial, state: .tracking, confidence: 0.9, time: 5))
        expect(presentation.permitsCapture && presentation.trackedQuad == initial, "A new accepted seed restores capture")

        _ = gate.lose(allowRecovery: true, canRecover: false)
        expect(gate.hardInvalid && !gate.mayProcess, "Recovery without retained anchors must explicitly stop")
        print("PASS: \(checks) recovery-gate, capture-validity and transition-log checks. No camera initialized.")
    }
}
