import CoreGraphics

/// Geometry carrier for offscreen model/raster tests only. Tracking and camera
/// geometry have their own tests; these checks never load a native tracker.
struct BoardQuad {
    let points: [CGPoint]
    var isFullyVisible: Bool { points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) } }
}
