import CoreImage
import CoreVideo
import Foundation
import Vision
import BoardNativeTracker

/// Normalized TOP LEFT coordinates. Points are clockwise: TL, TR, BR, BL.
struct BoardQuad: Codable, Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint
    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
    var boundingBox: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    var area: CGFloat {
        abs((0..<4).reduce(CGFloat.zero) { value, i in
            let a = points[i], b = points[(i + 1) % 4]
            return value + a.x * b.y - b.x * a.y
        }) / 2
    }
    var isFullyVisible: Bool { points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= 1 && $0.y <= 1 } }
    init(points: [CGPoint], allowOutside: Bool = false, preserveOrder: Bool = false) throws {
        let lower: CGFloat = allowOutside ? -0.5 : 0, upper: CGFloat = allowOutside ? 1.5 : 1
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            $0.x >= lower && $0.y >= lower && $0.x <= upper && $0.y <= upper }) else { throw BoardTrackingError.invalidCorners }
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        let angular = points.sorted { atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x) }
        let first = angular.indices.min { a, b in
            let av = angular[a].x + angular[a].y, bv = angular[b].x + angular[b].y
            return abs(av - bv) < 0.000001 ? angular[a].y < angular[b].y : av < bv
        }!
        let ordered = preserveOrder ? points : (0..<4).map { angular[($0 + first) % 4] }
        for i in 0..<4 {
            let a = ordered[i], b = ordered[(i + 1) % 4], c = ordered[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross > 0.00001, hypot(b.x - a.x, b.y - a.y) >= 0.015 else { throw BoardTrackingError.invalidCorners }
        }
        topLeft = ordered[0]; topRight = ordered[1]; bottomRight = ordered[2]; bottomLeft = ordered[3]
        guard area >= 0.0025 else { throw BoardTrackingError.invalidCorners }
    }
    /// UI previews only: tracker results outside the image are rejected, never clamped.
    static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
    private enum CodingKeys: String, CodingKey { case topLeft, topRight, bottomRight, bottomLeft }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(points: [values.decode(CGPoint.self, forKey: .topLeft), values.decode(CGPoint.self, forKey: .topRight),
                              values.decode(CGPoint.self, forKey: .bottomRight), values.decode(CGPoint.self, forKey: .bottomLeft)])
    }
}

enum BoardTrackingState: String, Codable { case off, tracking, lost }
struct BoardTrackingUpdate {
    let quad: BoardQuad?
    let state: BoardTrackingState
    let confidence: Float
    let time: Double
}
enum BoardTrackingError: LocalizedError {
    case invalidCorners, unavailableFrame, insufficientDetail, seedFailed
    var errorDescription: String? {
        switch self {
        case .invalidCorners: return "Choose four distinct corners around the board, inside the photograph."
        case .unavailableFrame: return "The camera frame could not be analyzed. Try calibrating again."
        case .insufficientDetail: return "The board has too little visible detail to follow. Include its frame or writing, then calibrate again."
        case .seedFailed: return "The board could not be followed from these corners. Hold the camera steady and calibrate again."
        }
    }
}

/// Serial background caller. Every estimate matches immutable calibration features.
final class BoardTracker {
    private let native = BNTCreate()
    private(set) var latest: BoardTrackingUpdate?
    private(set) var lastAnalysisSize: CGSize = .zero
    private(set) var analysisCount = 0
    private(set) var lastAnalysisDuration: Double = 0
    private(set) var lastRejection: String?
    private(set) var registrationRecoveries = 0
    private(set) var lastRecoveryDiagnostic: String?
    let maximumAnalysisEdge = 960
    private var seeded = false
    private var sourceSize: CGSize = .zero
    private var lastAttemptTime: Double = 0
    private var movingUntil: Double = 0
    var canRecover: Bool { seeded }
    deinit { BNTDestroy(native) }

    func reset() {
        BNTReset(native); seeded = false; latest = nil; sourceSize = .zero
        lastAnalysisSize = .zero; analysisCount = 0; lastAnalysisDuration = 0
        lastRejection = nil; registrationRecoveries = 0; lastRecoveryDiagnostic = nil
        lastAttemptTime = 0; movingUntil = 0
    }

    /// Use exactly the image on which the user placed the four calibration points.
    func start(buffer: CVPixelBuffer, quad: BoardQuad, time: Double) throws {
        reset()
        guard native != nil, time.isFinite, quad.isFullyVisible else { throw BoardTrackingError.unavailableFrame }
        let began = ProcessInfo.processInfo.systemUptime
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let exclusion = Self.personMask(buffer: buffer) else { throw BoardTrackingError.unavailableFrame }
        let corners = quad.points.flatMap { [Double($0.x), Double($0.y)] }
        guard let result = withBGRA(buffer, { bytes, stride in
            corners.withUnsafeBufferPointer { points in
                return exclusion.withUnsafeBufferPointer { mask in
                    BNTSeed(native, bytes, Int32(width), Int32(height), stride, points.baseAddress, mask.baseAddress, width)
                }
            }
        }) else { throw BoardTrackingError.unavailableFrame }
        analysisCount = 1; lastAnalysisDuration = ProcessInfo.processInfo.systemUptime - began
        setAnalysisSize(width: width, height: height)
        guard result.status == 1 else {
            lastRejection = "features seed rejection=\(result.rejectionCode)"
            BNTReset(native); throw BoardTrackingError.insufficientDetail
        }
        seeded = true; sourceSize = CGSize(width: width, height: height)
        lastAttemptTime = time; movingUntil = time + 0.75
        latest = BoardTrackingUpdate(quad: quad, state: .tracking, confidence: 1, time: time)
    }

    /// Forced capture verifies this exact buffer. The same timestamp is reused.
    func process(buffer: CVPixelBuffer, time: Double, force: Bool = false) -> BoardTrackingUpdate? {
        guard let previous = latest else { return nil }
        guard seeded else { return force ? previous : nil }
        guard time.isFinite, time >= previous.time,
              sourceSize == CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) else {
            seeded = false; BNTReset(native)
            return lose(time: time.isFinite ? time : previous.time, reason: "frame continuity")
        }
        if time == previous.time { return force ? previous : nil }
        let interval = previous.state == .lost ? 0.25 : (time < movingUntil ? 1.0 / 15 : 0.125)
        guard force || time - lastAttemptTime + 0.0005 >= interval else { return nil }
        lastAttemptTime = time
        let began = ProcessInfo.processInfo.systemUptime
        defer { lastAnalysisDuration = ProcessInfo.processInfo.systemUptime - began }
        analysisCount += 1
        guard var result = withBGRA(buffer, { bytes, stride in
            BNTProcess(native, bytes, Int32(CVPixelBufferGetWidth(buffer)), Int32(CVPixelBufferGetHeight(buffer)), stride)
        }) else { return lose(time: time, reason: "features unavailable frame") }
        guard result.status == 1 else {
            return lose(time: time, reason: "features rejection=\(result.rejectionCode) matches=\(result.matches) inliers=\(result.inliers)")
        }
        let points: [CGPoint] = withUnsafeBytes(of: &result.corners) { raw in
            let values = raw.bindMemory(to: Double.self)
            return (0..<4).map { CGPoint(x: values[$0 * 2], y: values[$0 * 2 + 1]) }
        }
        guard let quad = try? BoardQuad(points: points, allowOutside: true, preserveOrder: true) else {
            return lose(time: time, reason: "geometry native corners")
        }
        if let old = previous.quad {
            let displacement = zip(old.points, quad.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            if displacement / max(0.001, time - previous.time) > 0.01 { movingUntil = time + 1 }
        }
        if previous.state == .lost { registrationRecoveries += 1; movingUntil = time + 1 }
        lastRejection = nil
        lastRecoveryDiagnostic = "inliers=\(result.inliers)/\(result.matches) median=\(result.medianError) coverage=\(result.coverage)"
        let update = BoardTrackingUpdate(quad: quad, state: .tracking, confidence: Float(result.confidence), time: time)
        latest = update; return update
    }

    private func lose(time: Double, reason: String) -> BoardTrackingUpdate {
        lastRejection = reason
        let update = BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: time)
        latest = update; return update
    }
    private func withBGRA<T>(_ buffer: CVPixelBuffer, _ body: (UnsafePointer<UInt8>, Int) -> T) -> T? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return body(base.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(buffer))
    }
    private func setAnalysisSize(width: Int, height: Int) {
        let scale = min(1, Double(maximumAnalysisEdge) / Double(max(width, height)))
        lastAnalysisSize = CGSize(width: (Double(width) * scale).rounded(), height: (Double(height) * scale).rounded())
    }
    /// Foreground people are excluded once at calibration. No video is retained.
    private static func personMask(buffer: CVPixelBuffer) -> [UInt8]? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer,
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask), stride = CVPixelBufferGetBytesPerRow(mask)
        guard mw > 0, mh > 0 else { return nil }
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (y * mh / height) * stride
            for x in 0..<width { result[y * width + x] = bytes[row + x * mw / width] > 32 ? 255 : 0 }
        }
        return result
    }

    static func rectify(image: CIImage, quad: BoardQuad, context: CIContext) -> CGImage? {
        guard quad.isFullyVisible else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        func vector(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }
        let output = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
            "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft)])
        guard output.extent.width >= 1, output.extent.height >= 1,
              output.extent.width.isFinite, output.extent.height.isFinite else { return nil }
        return context.createCGImage(output, from: output.extent.integral)
    }
}
