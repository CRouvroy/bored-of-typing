// Capsule proximity geometry adapted from Desk; see LICENSE.
import CoreGraphics

/// Proximity follows the visible capsule in both dimensions, never an entire
/// window edge. Kept independent of AppKit so the activation boundary is testable.
struct BoardDockProximityRegion {
    let rail: CGRect
    let radius: CGFloat
    let halo: CGFloat
    let fullInset: CGFloat

    init(rail: CGRect, radius: CGFloat = 18, halo: CGFloat = 18, fullInset: CGFloat = 4) {
        self.rail = rail
        self.radius = min(max(0, radius), min(rail.width, rail.height) / 2)
        self.halo = max(1, halo)
        self.fullInset = min(max(0, fullInset), min(rail.width, rail.height) / 2)
    }

    var trackingBounds: CGRect { rail.insetBy(dx: -halo, dy: -halo) }

    /// Negative inside the rounded rectangle; zero at its visible boundary.
    func signedDistance(to point: CGPoint) -> CGFloat {
        guard point.x.isFinite, point.y.isFinite else { return .infinity }
        let x = abs(point.x - rail.midX) - (rail.width / 2 - radius)
        let y = abs(point.y - rail.midY) - (rail.height / 2 - radius)
        return hypot(max(x, 0), max(y, 0)) + min(max(x, y), 0) - radius
    }

    func contains(_ point: CGPoint) -> Bool { signedDistance(to: point) <= 0 }

    /// Smooth from no reveal just outside the halo to full reveal four points
    /// inside the capsule. Reversing direction reverses the preview immediately.
    func reveal(at point: CGPoint) -> CGFloat {
        let distance = signedDistance(to: point)
        guard distance.isFinite else { return 0 }
        let t = min(1, max(0, (halo - distance) / (halo + fullInset)))
        return t * t * (3 - 2 * t)
    }
}
