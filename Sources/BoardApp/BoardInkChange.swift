import CoreGraphics
import Foundation

/// Bounded local motion sensing, not handwriting recognition. The compatibility
/// name and grayscale return type remain for saved-image/rendering integration;
/// every returned image is now UNIFORM, so a person or old text can never punch
/// spatial holes into an AI overlay. No differences accumulate across frames.
struct BoardInkChangeDetector {
    struct Target { let id: UUID; let revision: Int; let rect: CGRect }
    private struct Reference {
        let revision: Int
        let rect: CGRect
        var pixels: [UInt8]
        var time: TimeInterval
        var lastMotion: TimeInterval?
    }
    private var references: [UUID: Reference] = [:]
    private let width = 128, height = 96
    private let hold: TimeInterval = 1
    private let restore: TimeInterval = 2
    private let maximumTransparency: UInt8 = 170

    mutating func reset() { references.removeAll() }
    /// Camera/calibration changes establish a fresh temporal baseline. There is
    /// no physical-ink mask to retain: the whole AI layer starts intact.
    mutating func reanchor() { reset() }

    /// Ordinary gray images used solely as whole-overlay alpha controls:
    /// 0 = full AI layer, 170 = about one third of its manually selected opacity.
    /// `timestamp` is injectable for deterministic tests; production uses monotonic
    /// uptime. The caller samples at most twice per second, never continuous video.
    mutating func consume(_ image: CGImage, targets: [Target],
                          timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [UUID: CGImage] {
        guard timestamp.isFinite else { return [:] }
        let active = Set(targets.map(\.id))
        references = references.filter { active.contains($0.key) }
        var masks: [UUID: CGImage] = [:], seen = Set<UUID>()
        for target in targets where seen.insert(target.id).inserted {
            guard let pixels = sample(image, rect: target.rect) else {
                references.removeValue(forKey: target.id)
                continue
            }
            guard var reference = references[target.id],
                  reference.revision == target.revision, reference.rect == target.rect,
                  timestamp >= reference.time, timestamp - reference.time <= 2 else {
                // First frame, new overlay/region, clock discontinuity or a camera
                // gap cannot distinguish an intervention from old static content.
                references[target.id] = Reference(revision: target.revision, rect: target.rect,
                    pixels: pixels, time: timestamp, lastMotion: nil)
                masks[target.id] = uniformMask(0)
                continue
            }
            if timestamp > reference.time {
                // Compare only consecutive verified board frames, not a frozen
                // creation image. Newly settled ink/persons become ordinary context.
                if Self.changedFraction(reference.pixels, pixels, width: width, height: height) >= 0.004 {
                    reference.lastMotion = timestamp
                }
                reference.pixels = pixels
                reference.time = timestamp
            }
            var strength = 0.0
            if let motion = reference.lastMotion {
                let progress = min(1, max(0, (timestamp - motion - hold) / restore))
                // Smoothstep keeps restoration continuous, without thresholds that
                // would make the complete diagram repeatedly blink on and off.
                strength = 1 - progress * progress * (3 - 2 * progress)
                if progress == 1 { reference.lastMotion = nil }
            }
            references[target.id] = reference
            masks[target.id] = uniformMask(UInt8((Double(maximumTransparency) * strength).rounded()))
        }
        return masks
    }

    private static func changedFraction(_ previous: [UInt8], _ current: [UInt8], width: Int, height: Int) -> Double {
        let count = width * height
        guard previous.count == count, current.count == count, width > 0, height > 0 else { return 0 }
        let previousPaper = percentile(previous, fraction: 0.9)
        let currentPaper = percentile(current, fraction: 0.9)
        var darkPrevious: [UInt8] = [], darkCurrent: [UInt8] = []
        // Paper plus already dark structure remove global camera exposure changes.
        // A local correspondence tolerates one-pixel registration noise; this is
        // intentionally a motion threshold, not a claim to isolate marker strokes.
        for y in 0..<height { for x in 0..<width {
            let value = previous[y * width + x]
            guard Double(value) < previousPaper - 32 else { continue }
            var low = UInt8.max
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < width, yy >= 0, yy < height { low = min(low, current[yy * width + xx]) }
            } }
            darkPrevious.append(value); darkCurrent.append(low)
        } }
        var gain = 1.0
        if darkPrevious.count >= 24 {
            let previousDark = percentile(darkPrevious, fraction: 0.5), currentDark = percentile(darkCurrent, fraction: 0.5)
            if previousPaper - previousDark > 32, currentPaper - currentDark > 20 {
                gain = min(1.8, max(0.55, (currentPaper - currentDark) / (previousPaper - previousDark)))
            }
        }
        let offset = currentPaper - gain * previousPaper
        var changed = 0
        for y in 0..<height { for x in 0..<width {
            let value = (Double(current[y * width + x]) - offset) / gain
            var error = Double.greatestFiniteMagnitude
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < width, yy >= 0, yy < height {
                    error = min(error, abs(value - Double(previous[yy * width + xx])))
                }
            } }
            if error > 24 { changed += 1 }
        } }
        return Double(changed) / Double(count)
    }

    private static func percentile(_ pixels: [UInt8], fraction: Double) -> Double {
        guard !pixels.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let rank = max(1, Int(ceil(Double(pixels.count) * fraction)))
        var sum = 0
        for i in histogram.indices { sum += histogram[i]; if sum >= rank { return Double(i) } }
        return 255
    }

    private func sample(_ image: CGImage, rect: CGRect) -> [UInt8]? {
        guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.minX >= 0, rect.minY >= 0, rect.width > 0, rect.height > 0,
              rect.maxX <= 1.0000001, rect.maxY <= 1.0000001 else { return nil }
        let left = max(0, Int(floor(rect.minX * Double(image.width) + 1e-7)))
        let top = max(0, Int(floor(rect.minY * Double(image.height) + 1e-7)))
        let right = min(image.width, Int(ceil(rect.maxX * Double(image.width) - 1e-7)))
        let bottom = min(image.height, Int(ceil(rect.maxY * Double(image.height) - 1e-7)))
        guard right > left, bottom > top,
              let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return nil }
        var result = [UInt8](repeating: 0, count: width * height)
        let rendered = result.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? result : nil
    }

    private func uniformMask(_ value: UInt8) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(repeating: value, count: width * height) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
