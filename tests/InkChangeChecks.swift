import CoreGraphics
import Foundation

@main
struct InkChangeChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; checks += 1
        }
        func image(_ bytes: [UInt8], width: Int = 128, height: Int = 96) -> CGImage {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        func strength(_ mask: CGImage?) -> Int {
            guard let mask, let data = mask.dataProvider?.data else { fatalError("Expected ordinary grayscale opacity mask") }
            let bytes = Array(data as Data)
            expect(mask.width == 128 && mask.height == 96 && mask.bitsPerPixel == 8 && !mask.isMask,
                   "Keep ordinary128x96gray renderer ABI")
            expect(bytes.count == 128 * 96 && bytes.allSatisfy { $0 == bytes[0] },
                   "Every single mask pixel must match: no head-, ink-, or old-text-shaped holes")
            expect(bytes[0] <= 170, "Even during activity the whole overlay must remain partly visible")
            return Int(bytes[0])
        }
        func paint(_ bytes: inout [UInt8], x: Range<Int>, y: Range<Int>, value: UInt8, width: Int = 128) {
            for row in y { for column in x { bytes[row * width + column] = value } }
        }
        let id = UUID(), unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let target = BoardInkChangeDetector.Target(id: id, revision: 1, rect: unit)
        var base = [UInt8](repeating: 230, count: 128 * 96)
        paint(&base, x: 20..<23, y: 15..<72, value: 20)
        paint(&base, x: 80..<91, y: 60..<71, value: 110)
        let baseline = image(base)
        var detector = BoardInkChangeDetector()
        expect(strength(detector.consume(baseline, targets: [target], timestamp: 0)[id]) == 0, "Initial old text must keep AI intact")
        for time in [0.5, 1, 1.5, 2] {
            expect(strength(detector.consume(baseline, targets: [target], timestamp: time)[id]) == 0, "Static old text never fades")
        }
        for (gain, offset) in [(1.0, 35.0), (1.0, -35.0), (0.78, 18.0), (1.15, -10.0)] {
            var exposure = BoardInkChangeDetector()
            _ = exposure.consume(baseline, targets: [target], timestamp: 0)
            let changed = image(base.map { UInt8(min(255, max(0, (Double($0) * gain + offset).rounded()))) })
            expect(strength(exposure.consume(changed, targets: [target], timestamp: 0.5)[id]) == 0,
                   "Global camera brightness/contrast change must not trigger motion fading")
        }
        var shifted = [UInt8](repeating: 230, count: base.count)
        for y in 1..<96 { for x in 1..<128 { shifted[y * 128 + x] = base[(y - 1) * 128 + x - 1] } }
        var jitter = BoardInkChangeDetector()
        _ = jitter.consume(baseline, targets: [target], timestamp: 0)
        expect(strength(jitter.consume(image(shifted), targets: [target], timestamp: 0.5)[id]) == 0,
               "One-pixel registration jitter must not be mistaken for new writing")
        expect(strength(jitter.consume(baseline, targets: [target], timestamp: 1)[id]) == 0,
               "Returning one-pixel jitter must also stay intact")
        let noisy = base.enumerated().map { i, value in UInt8(max(0, min(255, Int(value) + (i % 13) - 6))) }
        expect(strength(jitter.consume(image(noisy), targets: [target], timestamp: 1.5)[id]) == 0,
               "Low camera noise must not trigger activity")

        var ink = base
        paint(&ink, x: 50..<53, y: 8..<36, value: 10)
        let inkImage = image(ink)
        expect(strength(detector.consume(inkImage, targets: [target], timestamp: 2.5)[id]) == 170,
               "New ink/motion lowers whole-overlay opacity promptly")
        var restoring: [Int] = []
        for time in [3.0, 3.5, 4.0, 4.5, 5.0, 5.5] {
            restoring.append(strength(detector.consume(inkImage, targets: [target], timestamp: time)[id]))
        }
        expect(restoring[0] == 170 && restoring[1] == 170, "Brief hold bridges gaps in a writing gesture")
        expect(restoring[2] < 170 && restoring[2] > restoring[3] && restoring[3] > restoring[4] && restoring[4] > 0,
               "Whole overlay returns gradually, rather than blinking")
        expect(restoring[5] == 0, "Settled new writing becomes context: no permanent holes or permanent fade")
        expect(strength(detector.consume(inkImage, targets: [target], timestamp: 6)[id]) == 0,
               "Unchanged new writing must not be rediscovered on every frame")

        var person = base
        paint(&person, x: 0..<70, y: 24..<96, value: 65)
        let personImage = image(person)
        var head = BoardInkChangeDetector()
        expect(strength(head.consume(personImage, targets: [target], timestamp: 0)[id]) == 0,
               "A person already in front when AI starts must not carve a person-shaped hole")
        expect(strength(head.consume(personImage, targets: [target], timestamp: 0.5)[id]) == 0,
               "A stationary foreground person keeps the full diagram intact")
        expect(strength(head.consume(baseline, targets: [target], timestamp: 1)[id]) == 170,
               "Departing person triggers only temporary uniform fading")
        for time in [1.5, 2, 2.5, 3, 3.5, 4] { _ = head.consume(baseline, targets: [target], timestamp: time) }
        expect(strength(head.consume(baseline, targets: [target], timestamp: 4.5)[id]) == 0,
               "After departure, the old head silhouette cannot survive")
        expect(strength(head.consume(personImage, targets: [target], timestamp: 5)[id]) == 170,
               "A large new occlusion must keep a complete faint diagram, not erase part of it")
        for time in [5.5, 6, 6.5, 7, 7.5, 8] { _ = head.consume(personImage, targets: [target], timestamp: time) }
        expect(strength(head.consume(personImage, targets: [target], timestamp: 8.5)[id]) == 0,
               "A person who stops moving cannot hold the AI layer faded indefinitely")

        var repeatedMotion = BoardInkChangeDetector()
        _ = repeatedMotion.consume(baseline, targets: [target], timestamp: 0)
        for (i, frame) in [personImage, baseline, personImage, baseline].enumerated() {
            expect(strength(repeatedMotion.consume(frame, targets: [target], timestamp: Double(i + 1) * 0.5)[id]) == 170,
                   "Continued movement extends the short activity hold")
        }
        repeatedMotion.reanchor()
        expect(strength(repeatedMotion.consume(personImage, targets: [target], timestamp: 2.5)[id]) == 0,
               "Recalibration clears transient activity and starts intact")
        _ = repeatedMotion.consume(baseline, targets: [target], timestamp: 3)
        let revised = BoardInkChangeDetector.Target(id: id, revision: 2, rect: unit)
        expect(strength(repeatedMotion.consume(baseline, targets: [revised], timestamp: 3.5)[id]) == 0,
               "Content refresh establishes a new full-opacity baseline")
        _ = repeatedMotion.consume(personImage, targets: [revised], timestamp: 4)
        repeatedMotion.reset()
        expect(strength(repeatedMotion.consume(personImage, targets: [revised], timestamp: 4.5)[id]) == 0,
               "Explicit reset clears activity")
        _ = repeatedMotion.consume(baseline, targets: [revised], timestamp: 5)
        expect(strength(repeatedMotion.consume(personImage, targets: [revised], timestamp: 8)[id]) == 0,
               "A camera gap cannot be interpreted as new writing")
        expect(strength(repeatedMotion.consume(baseline, targets: [revised], timestamp: 2)[id]) == 0,
               "A backward test clock resets safely")
        expect(repeatedMotion.consume(baseline, targets: [revised], timestamp: .nan).isEmpty,
               "Nonfinite time cannot poison activity state")

        var duplicates = BoardInkChangeDetector()
        _ = duplicates.consume(baseline, targets: [target], timestamp: 0)
        expect(strength(duplicates.consume(personImage, targets: [target, target], timestamp: 0.5)[id]) == 170,
               "Duplicate targets cannot count one frame twice or cancel activity")
        expect(strength(duplicates.consume(baseline, targets: [target], timestamp: 0.5)[id]) == 170,
               "Duplicate timestamp does not consume a second frame")
        let moved = BoardInkChangeDetector.Target(id: id, revision: 1, rect: CGRect(x: 0.1, y: 0, width: 0.8, height: 1))
        expect(strength(duplicates.consume(personImage, targets: [moved], timestamp: 1)[id]) == 0,
               "Region relocation establishes a fresh intact baseline")
        expect(duplicates.consume(baseline, targets: [], timestamp: 1.5).isEmpty, "Removed regions disappear")
        expect(strength(duplicates.consume(personImage, targets: [target], timestamp: 2)[id]) == 0,
               "Removed then readded region has no stale activity")
        for rect in [CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
                     CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0, width: -0.2, height: 0.5),
                     CGRect(x: 0.8, y: 0, width: 0.5, height: 0.5), .zero] {
            expect(duplicates.consume(baseline, targets: [.init(id: id, revision: 1, rect: rect)], timestamp: 2.5).isEmpty,
                   "Invalid/nonfinite target must be rejected without indexing/cropping")
        }

        let rightID = UUID()
        let leftTarget = BoardInkChangeDetector.Target(id: id, revision: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let rightTarget = BoardInkChangeDetector.Target(id: rightID, revision: 1, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let largeBase = [UInt8](repeating: 230, count: 256 * 96)
        var largeInk = largeBase
        paint(&largeInk, x: 45..<50, y: 20..<60, value: 30, width: 256)
        var local = BoardInkChangeDetector()
        _ = local.consume(image(largeBase, width: 256, height: 96), targets: [leftTarget, rightTarget], timestamp: 0)
        let localMasks = local.consume(image(largeInk, width: 256, height: 96), targets: [leftTarget, rightTarget], timestamp: 0.5)
        expect(strength(localMasks[id]) == 170 && strength(localMasks[rightID]) == 0,
               "Only the region with interaction fades; other overlays stay fully visible")

        func rgb(_ stroke: Bool) -> CGImage {
            var bytes = [UInt8](repeating: 230, count: 128 * 96 * 4)
            for y in 0..<96 { for x in 0..<128 {
                let i = (y * 128 + x) * 4; bytes[i + 3] = 255
                if stroke && (40..<44).contains(x) && (12..<45).contains(y) { bytes[i] = 220; bytes[i + 1] = 25; bytes[i + 2] = 25 }
            } }
            return CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        var red = BoardInkChangeDetector()
        _ = red.consume(rgb(false), targets: [target], timestamp: 0)
        expect(strength(red.consume(rgb(true), targets: [target], timestamp: 0.5)[id]) == 170,
               "Colored physical marker changes also produce temporary uniform fading")
        print("PASS: \(checks) in-memory uniform-opacity, temporal motion, head/old-text regression, exposure, jitter and reset checks")
    }
}
