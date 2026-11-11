import AppKit
import CoreImage
import CoreVideo
import Foundation

@main struct TrackingChecks {
    static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--real-wrapper-image"), CommandLine.arguments.count > index + 1 {
            try realWrapperChecks(path: CommandLine.arguments[index + 1]); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--real-board-image"), CommandLine.arguments.count > index + 1 {
            try realBoardChecks(path: CommandLine.arguments[index + 1]); return
        }
        if CommandLine.arguments.contains("--pan-diagnostic") { try panDiagnostic(); return }
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? condition()) == true else { fatalError(message) }; checks += 1
        }
        let seed = try BoardQuad(points: [CGPoint(x: 0.15, y: 0.2), CGPoint(x: 0.85, y: 0.2), CGPoint(x: 0.85, y: 0.8), CGPoint(x: 0.15, y: 0.8)])
        expect(try BoardQuad(points: [seed.bottomRight, seed.topLeft, seed.bottomLeft, seed.topRight]) == seed, "Click order")
        expect(abs(seed.area - 0.42) < 0.00001, "Polygon area")
        expect(BoardQuad.clamp(CGPoint(x: -1, y: 2)) == CGPoint(x: 0, y: 1), "UI corner clamp")
        expect((try? BoardQuad(points: [.zero, .zero, CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])) == nil, "Repeated corners")
        expect((try? BoardQuad(points: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0, y: 1)])) == nil, "Concave quad")
        expect((try? BoardQuad(points: [CGPoint(x: -0.001, y: 0)] + Array(seed.points.dropFirst()))) == nil, "Off-image corners must fail")
        expect((try? BoardQuad(points: [CGPoint(x: CGFloat.nan, y: 0)] + Array(seed.points.dropFirst()))) == nil, "Nonfinite geometry")
        expect(try JSONDecoder().decode(BoardQuad.self, from: JSONEncoder().encode(seed)) == seed, "Quad JSON round trip")
        let context = CIContext(options: [.cacheIntermediates: false])
        let texture = makeTexture(), initial = try makeFrame(quad: seed, texture: makeTexture(), context: context)
        guard let corrected = BoardTracker.rectify(image: CIImage(cvPixelBuffer: initial), quad: seed, context: context) else { fatalError("rectification") }
        let bitmap = NSBitmapImageRep(cgImage: corrected)
        func color(_ x: Double, _ y: Double) -> NSColor {
            bitmap.colorAt(x: Int(Double(corrected.width) * x), y: Int(Double(corrected.height) * y))!.usingColorSpace(.deviceRGB)!
        }
        let red = color(0.04, 0.06), green = color(0.96, 0.06), blue = color(0.04, 0.94), yellow = color(0.96, 0.94)
        expect(red.redComponent > 0.7 && red.blueComponent < 0.2, "Rectified top-left red")
        expect(green.greenComponent > 0.6 && green.redComponent < 0.3, "Rectified top-right green")
        expect(blue.blueComponent > 0.7 && blue.redComponent < 0.2, "Rectified bottom-left blue")
        expect(yellow.redComponent > 0.7 && yellow.greenComponent > 0.7 && yellow.blueComponent < 0.2, "Rectified bottom-right yellow")
        expect(corrected.width > 800 && corrected.height > 350, "Source-scale correction")
        let skew = try BoardQuad(points: [CGPoint(x: 0.22, y: 0.18), CGPoint(x: 0.82, y: 0.23), CGPoint(x: 0.9, y: 0.78), CGPoint(x: 0.12, y: 0.83)])
        let skewFrame = try makeFrame(quad: skew, texture: texture, context: context)
        let skewCorrected = BoardTracker.rectify(image: CIImage(cvPixelBuffer: skewFrame), quad: skew, context: context)!
        let skewBitmap = NSBitmapImageRep(cgImage: skewCorrected)
        let skewRed = skewBitmap.colorAt(x: Int(Double(skewCorrected.width) * 0.04), y: Int(Double(skewCorrected.height) * 0.06))!.usingColorSpace(.deviceRGB)!
        expect(skewRed.redComponent > 0.7 && skewRed.blueComponent < 0.2, "Skewed perspective correction must preserve corner orientation")
        let tracker = BoardTracker(), start = ProcessInfo.processInfo.systemUptime
        try tracker.start(buffer: initial, quad: seed, time: 0)
        let seedDuration = ProcessInfo.processInfo.systemUptime - start
        expect(tracker.latest?.state == .tracking, "Native feature seed")
        expect(tracker.maximumAnalysisEdge == 960 && max(tracker.lastAnalysisSize.width, tracker.lastAnalysisSize.height) <= 960, "Bounded native analysis resolution")
        let count = tracker.analysisCount
        expect(tracker.process(buffer: initial, time: 0, force: true)?.state == .tracking && tracker.analysisCount == count, "Duplicate capture timestamp")
        expect(tracker.process(buffer: initial, time: 0.03) == nil && tracker.analysisCount == count, "Rate-limited frame")
        expect(tracker.process(buffer: initial, time: 20, force: true)?.state == .tracking, "Calibration clicking pause")
        var durations: [Double] = [], largestError: CGFloat = 0
        for step in 1...10 {
            let t = Double(step)
            let target = try BoardQuad(points: [CGPoint(x: 0.15 + t * 0.003, y: 0.2 + t * 0.001), CGPoint(x: 0.85 + t * 0.002, y: 0.2 + t * 0.002),
                CGPoint(x: 0.85 + t * 0.003, y: 0.8 - t * 0.001), CGPoint(x: 0.15 + t * 0.002, y: 0.8 - t * 0.002)])
            let frame = try makeFrame(quad: target, texture: texture, context: context), began = ProcessInfo.processInfo.systemUptime
            guard let result = tracker.process(buffer: frame, time: 20 + t * 0.15), result.state == .tracking, let found = result.quad else { fatalError("Synthetic perspective frame \(step) lost") }
            durations.append(ProcessInfo.processInfo.systemUptime - began)
            let error = zip(target.points, found.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
            largestError = max(largestError, error)
            expect(error < 0.035, "Tracking error exceeds 3.5% normalized coordinates")
        }
        let covered = try makeFrame(quad: seed, texture: texture, context: context, occluded: true)
        let loss = tracker.process(buffer: covered, time: 21.7, force: true)
        expect(loss?.state == .lost && loss?.quad == nil, "Occlusion must withdraw quad")
        expect(tracker.canRecover && tracker.process(buffer: initial, time: 22, force: true)?.state == .tracking, "Same-board texture must recover after temporary occlusion")
        tracker.reset()
        expect(tracker.latest == nil && tracker.process(buffer: initial, time: 23, force: true) == nil, "Reset withdraws calibration")
        try tracker.start(buffer: initial, quad: seed, time: 30)
        _ = tracker.process(buffer: initial, time: 30.2, force: true)
        expect(tracker.process(buffer: initial, time: 33, force: true)?.time == 33, "After a gap only freshly validated frame may be used")
        try tracker.start(buffer: initial, quad: seed, time: 40)
        let resized = try makeFrame(quad: seed, texture: texture, context: context, width: 640, height: 480)
        expect(tracker.process(buffer: resized, time: 40.2, force: true)?.state == .lost, "Changed dimensions invalidate seed")
        let written = try makeFrame(quad: seed, texture: makeTexture(coloredCorners: false), context: context)
        try tracker.start(buffer: written, quad: seed, time: 50)
        let partialWriting = try makeFrame(quad: seed, texture: makeTexture(coloredCorners: false, changedCenter: true), context: context)
        expect(tracker.process(buffer: partialWriting, time: 50.1, force: true)?.state == .tracking, "Partial writing changes retain distributed original detail")
        let erased = try makeFrame(quad: seed, texture: makeTexture(writing: false, coloredCorners: false), context: context)
        expect(tracker.process(buffer: erased, time: 50.2, force: true)?.state == .lost && tracker.latest?.quad == nil, "Erasing all distinctive writing must withdraw unverified geometry")
        expect(tracker.canRecover && tracker.process(buffer: written, time: 50.5, force: true)?.state == .tracking, "Original detail returning must recover without a new reference")
        let emptyTracker = BoardTracker()
        let plain = try makeFrame(quad: seed, texture: makeTexture(writing: false, coloredCorners: false), context: context)
        do {
            try emptyTracker.start(buffer: plain, quad: seed, time: 60)
            fatalError("An empty frame without distributed distinctive features must reject calibration")
        } catch BoardTrackingError.insufficientDetail { checks += 1 }
        expect(!emptyTracker.canRecover && emptyTracker.latest == nil, "Failed blank calibration cannot authorize capture or recovery")
        let newWriting = try makeFrame(quad: seed, texture: makeTexture(coloredCorners: false), context: context)
        expect(emptyTracker.process(buffer: newWriting, time: 60.2, force: true) == nil, "New writing after failed calibration needs explicit calibration")
        try emptyTracker.start(buffer: newWriting, quad: seed, time: 60.3)
        expect(emptyTracker.latest?.state == .tracking, "Explicit calibration accepts the newly written board")
        try tracker.start(buffer: initial, quad: seed, time: 70)
        _ = tracker.process(buffer: initial, time: 70.2, force: true)
        _ = tracker.process(buffer: initial, time: 71.5, force: true)
        let steadyCount = tracker.analysisCount
        expect(tracker.process(buffer: initial, time: 71.56) == nil && tracker.analysisCount == steadyCount, "Steady board rate must be bounded at 8Hz")
        expect(tracker.process(buffer: initial, time: 71.64)?.state == .tracking, "Steady board updates after eighth second")
        let translated = try BoardQuad(points: seed.points.map { CGPoint(x: $0.x + 0.02, y: $0.y) })
        let moved = try makeFrame(quad: translated, texture: texture, context: context)
        expect(tracker.process(buffer: moved, time: 72.51)?.state == .tracking, "Motion must be recognized at next scheduled analysis")
        expect(tracker.process(buffer: moved, time: 72.59)?.state == .tracking, "Motion promotes tracking to at least 15Hz")
        let sorted = durations.sorted()
        checks += try panDiagnostic(requireSuccess: true)
        print("PASS: \(checks) geometry, native features, occlusion, content-change, pan and perspective checks")
        print(String(format: "Instrumented synthetic: seed %.1f ms; %d updates median %.1f ms, max %.1f ms; max corner error %.4f. No live camera tested.", seedDuration * 1000, durations.count, sorted[sorted.count / 2] * 1000, sorted.last! * 1000, largestError))
    }
    static func realWrapperChecks(path: String) throws {
        guard let loaded = NSImage(contentsOfFile: path),
              let source = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Real wrapper fixture unavailable") }
        let context = CIContext(options: [.cacheIntermediates: false])
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, source.width, source.height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess, let buffer = output else {
            throw BoardTrackingError.unavailableFrame
        }
        context.render(CIImage(cgImage: source), to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height), colorSpace: CGColorSpaceCreateDeviceRGB())
        let quad = try BoardQuad(points: [CGPoint(x: 0.10, y: 0.10), CGPoint(x: 0.98, y: 0.13),
            CGPoint(x: 0.98, y: 0.96), CGPoint(x: 0.06, y: 0.93)])
        let tracker = BoardTracker(), began = ProcessInfo.processInfo.systemUptime
        try tracker.start(buffer: buffer, quad: quad, time: 0)
        let seedMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
        guard let update = tracker.process(buffer: buffer, time: 0.2, force: true), update.state == .tracking,
              let found = update.quad else { fatalError("Real wrapper identity failed: \(tracker.lastRejection ?? "no reason")") }
        let error = zip(found.points, quad.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
        precondition(error < 0.005 && found.isFullyVisible && tracker.canRecover, "Real Vision person mask must retain board detail and ordered geometry")
        precondition(BoardTracker.rectify(image: CIImage(cvPixelBuffer: buffer), quad: found, context: context) != nil,
                     "Verified real frame must support exact-frame rectification")
        print("REAL WRAPPER PASS: Vision person exclusion + BGRA bridge + exact-frame identity + full-resolution rectification. seedMS=\(seedMilliseconds) cornerError=\(error) \(tracker.lastRecoveryDiagnostic ?? "")")
    }

    static func realBoardChecks(path: String) throws {
        let loaded = NSImage(contentsOfFile: path)!
        var proposed = CGRect(origin: .zero, size: loaded.size)
        let screenshot = loaded.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
        // This interior crop excludes the stale dashed outline, the face and app controls.
        guard let texture = screenshot.cropping(to: CGRect(x: 300, y: 130, width: 850, height: 460)) else { fatalError("fixture crop") }
        let context = CIContext(options: [.cacheIntermediates: false]), tracker = BoardTracker()
        let seed = try BoardQuad(points: [CGPoint(x: 0.04, y: 0.08), CGPoint(x: 0.90, y: 0.09), CGPoint(x: 0.93, y: 0.92), CGPoint(x: 0.02, y: 0.90)])
        let first = try makeFrame(quad: seed, texture: texture, context: context, whiteWall: true)
        try tracker.start(buffer: first, quad: seed, time: 0)
        _ = tracker.process(buffer: first, time: 20, force: true)
        var worst: CGFloat = 0, durations: [Double] = [], lost = 0, recovered = false, partial = false
        for frame in 1...75 {
            let progress = min(1, Double(frame) / 36), dx = 0.12 * progress
            let target = try BoardQuad(points: seed.points.enumerated().map { index, p in
                CGPoint(x: p.x + dx, y: p.y + (index == 1 ? 0.015 * progress : 0))
            }, allowOutside: true)
            let buffer = try makeFrame(quad: target, texture: texture, context: context, occluded: frame >= 38 && frame <= 42,
                                       blur: frame < 36 ? 1 : 0, whiteWall: true, foreground: frame > 12)
            let began = ProcessInfo.processInfo.systemUptime
            if let update = tracker.process(buffer: buffer, time: 20 + Double(frame) / 30) {
                durations.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                if update.state == .lost { lost += 1; precondition(update.quad == nil && tracker.canRecover) }
                else if let found = update.quad {
                    if lost > 0 { recovered = true }
                    let error = zip(target.points, found.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
                    worst = max(worst, error)
                    if !found.isFullyVisible { partial = true; precondition(BoardTracker.rectify(image: CIImage(cvPixelBuffer: buffer), quad: found, context: context) == nil) }
                }
            }
        }
        print("REAL interior crop: worst=\(worst) lostUpdates=\(lost) recovered=\(recovered) partial=\(partial) detail=\(tracker.lastRecoveryDiagnostic ?? "none") reason=\(tracker.lastRejection ?? "none")")
        let sorted = durations.sorted()
        print("REAL diagnostic milliseconds median=\(sorted[sorted.count / 2]) max=\(sorted.last!)")
        precondition(worst < 0.045 && partial && lost > 0 && recovered, "Actual-board pan/occlusion/partial-frame recovery regression")
        for frame in 76...105 {
            let progress = max(0, 1 - Double(frame - 75) / 30)
            let target = try BoardQuad(points: seed.points.enumerated().map { index, p in
                CGPoint(x: p.x + 0.12 * progress, y: p.y + (index == 1 ? 0.015 * progress : 0))
            }, allowOutside: true)
            let buffer = try makeFrame(quad: target, texture: texture, context: context, whiteWall: true, foreground: true)
            _ = tracker.process(buffer: buffer, time: 20 + Double(frame) / 30, force: frame == 105)
        }
        print("RETURN state=\(tracker.latest?.state.rawValue ?? "nil") visible=\(tracker.latest?.quad?.isFullyVisible ?? false) quad=\(String(describing: tracker.latest?.quad)) reason=\(tracker.lastRejection ?? "none")")
        precondition(tracker.latest?.state == .tracking && tracker.latest?.quad?.isFullyVisible == true, "Returning board must permit fresh complete capture")
        try tracker.start(buffer: first, quad: seed, time: 30)
        let different = try makeFrame(quad: seed, texture: makeTexture(), context: context, whiteWall: true)
        for frame in 1...20 {
            let result = tracker.process(buffer: different, time: 30 + Double(frame) / 15, force: frame == 20)
            if result?.state == .tracking { print("WRONG TARGET accepted at frame \(frame): \(tracker.lastRecoveryDiagnostic ?? "native")") }
            precondition(result?.state != .tracking, "Unrelated board must not be accepted as recovery")
        }
        precondition(tracker.canRecover && tracker.latest?.quad == nil, "Unknown target stays unavailable with original anchors intact")
        _ = tracker.process(buffer: first, time: 32, force: true)
        precondition(tracker.latest?.state == .tracking, "Original board must recover after unrelated target leaves")
        tracker.reset()
        precondition(!tracker.canRecover, "Explicit reset must withdraw all anchors")
        print("REAL PASS: original content anchored; partial-to-full return, occlusion recovery, wrong-target rejection, reset")
    }

    @discardableResult static func panDiagnostic(requireSuccess: Bool = false) throws -> Int {
        let context = CIContext(options: [.cacheIntermediates: false])
        var passed = 0
        for speed in [0.1, 0.3, 0.6] {
            for blur in [0.0, 2.0, 4.0] {
                let seed = try BoardQuad(points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.6, y: 0.8), CGPoint(x: 0.2, y: 0.8)])
                let texture = makeTexture(), tracker = BoardTracker()
                let first = try makeFrame(quad: seed, texture: texture, context: context)
                try tracker.start(buffer: first, quad: seed, time: 0)
                var worst: CGFloat = 0, lost = -1, updates = 0
                var recoveryMilliseconds: [Double] = []
                let lastFrame = 90 + Int(ceil(0.2 / speed * 30))
                for frame in 1...lastFrame {
                    let displacement = min(0.2, max(0, Double(frame - 90) / 30) * speed)
                    let target = try BoardQuad(points: seed.points.enumerated().map { index, p in
                        CGPoint(x: p.x + displacement, y: p.y + (index == 1 ? displacement * 0.1 : 0))
                    })
                    let buffer = frame <= 90 ? first : try makeFrame(quad: target, texture: texture, context: context, blur: blur)
                    let oldRecoveries = tracker.registrationRecoveries, began = ProcessInfo.processInfo.systemUptime
                    if let result = tracker.process(buffer: buffer, time: Double(frame) / 30) {
                        if tracker.registrationRecoveries > oldRecoveries { recoveryMilliseconds.append((ProcessInfo.processInfo.systemUptime - began) * 1000) }
                        if result.state == .lost { lost = frame; break }
                        if let found = result.quad {
                            updates += 1
                            worst = max(worst, zip(target.points, found.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!)
                        }
                    }
                }
                print("PAN speed=\(speed) blur=\(blur) lostFrame=\(lost) updates=\(updates) worst=\(worst) recoveries=\(tracker.registrationRecoveries) recoveryMS=\(recoveryMilliseconds) reason=\(tracker.lastRejection ?? "none")")
                if requireSuccess { precondition(lost == -1 && worst < 0.035, "Stationary-to-pan regression") }
                if lost == -1 && worst < 0.035 { passed += 1 }
            }
        }
        let faintSeed = try BoardQuad(points: [CGPoint(x: 0.06, y: 0.08), CGPoint(x: 0.9, y: 0.08), CGPoint(x: 0.9, y: 0.94), CGPoint(x: 0.06, y: 0.94)])
        let faintTexture = makeTexture(coloredCorners: false, lowContrast: true)
        let faintFrame = try makeFrame(quad: faintSeed, texture: faintTexture, context: context, whiteWall: true, glare: true)
        let faintTracker = BoardTracker()
        do {
            try faintTracker.start(buffer: faintFrame, quad: faintSeed, time: 0)
            var lost = -1, error: CGFloat = 0
            for frame in 1...120 {
                let dx = min(0.05, max(0, Double(frame - 90) / 30) * 0.1)
                let target = try BoardQuad(points: faintSeed.points.map { CGPoint(x: $0.x + dx, y: $0.y) })
                let buffer = frame <= 90 ? faintFrame : try makeFrame(quad: target, texture: faintTexture, context: context, blur: 1, whiteWall: true, glare: true)
                if let result = faintTracker.process(buffer: buffer, time: Double(frame) / 30) {
                    if result.state == .lost { lost = frame; break }
                    if let found = result.quad { error = max(error, zip(target.points, found.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!) }
                }
            }
            print("FAINT lostFrame=\(lost) worst=\(error) recoveries=\(faintTracker.registrationRecoveries) reason=\(faintTracker.lastRejection ?? "none")")
            if requireSuccess { precondition(lost == -1 && error < 0.035, "Thin low-contrast frame with glare regression") }
            if lost == -1 && error < 0.035 { passed += 1 }
        } catch { if requireSuccess { throw error }; print("FAINT seedFailure=\(error)") }
        return passed
    }
    static func makeTexture(writing: Bool = true, coloredCorners: Bool = true, lowContrast: Bool = false, changedCenter: Bool = false) -> CGImage {
        let width = 640, height = 420
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor((lowContrast ? NSColor(white: 0.8, alpha: 1) : NSColor.black).cgColor); ctx.setLineWidth(lowContrast ? 2 : 10)
        ctx.stroke(CGRect(x: 5, y: 5, width: width - 10, height: height - 10))
        if writing {
            for index in 0..<90 {
                let x = 75 + (index * 73) % 490, y = 65 + (index * 43) % 280
                ctx.setFillColor((lowContrast ? NSColor(srgbRed: 1, green: 0.73, blue: 0.73, alpha: 1) : NSColor(srgbRed: CGFloat(index % 3) * 0.1, green: CGFloat(index % 7) * 0.05, blue: 0.2, alpha: 1)).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 8 + index % 35, height: 4 + index % 9))
            }
        }
        if changedCenter {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 235, y: 155, width: 170, height: 105))
            ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(3)
            for index in 0..<4 {
                ctx.move(to: CGPoint(x: 250, y: 170 + index * 20))
                ctx.addLine(to: CGPoint(x: 385 - index * 12, y: 180 + index * 20))
                ctx.strokePath()
            }
        }
        if coloredCorners {
            for (color, x, y) in [(NSColor.red, 10, height - 65), (.green, width - 65, height - 65), (.blue, 10, 10), (.yellow, width - 65, 10)] {
                ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: x, y: y, width: 55, height: 55))
            }
        }
        return ctx.makeImage()!
    }
    static func makeFrame(quad: BoardQuad, texture: CGImage, context: CIContext, occluded: Bool = false,
                          width: Int = 1280, height: Int = 720, blur: Double = 0, whiteWall: Bool = false, glare: Bool = false, foreground: Bool = false) throws -> CVPixelBuffer {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let background = CIImage(color: whiteWall ? CIColor(red: 0.95, green: 0.95, blue: 0.95) : CIColor(red: 0.18, green: 0.23, blue: 0.29)).cropped(to: extent)
        func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * CGFloat(width), y: (1 - p.y) * CGFloat(height)) }
        let warped = CIImage(cgImage: texture).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": vector(quad.topLeft), "inputTopRight": vector(quad.topRight),
            "inputBottomRight": vector(quad.bottomRight), "inputBottomLeft": vector(quad.bottomLeft)])
        var image = occluded ? background : warped.composited(over: background)
        if blur > 0 { image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur]).cropped(to: extent) }
        if glare {
            image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.65))
                .cropped(to: CGRect(x: Double(width) * 0.04, y: Double(height) * 0.4, width: Double(width) * 0.2, height: Double(height) * 0.5)).composited(over: image)
        }
        if foreground {
            image = CIImage(color: CIColor(red: 0.25, green: 0.18, blue: 0.14))
                .cropped(to: CGRect(x: 0, y: 0, width: Double(width) * 0.28, height: Double(height) * 0.4)).composited(over: image)
        }
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { throw BoardTrackingError.unavailableFrame }
        context.render(image, to: output, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
