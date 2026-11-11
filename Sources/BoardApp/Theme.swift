// Palette adapted from Desk; see LICENSE.
import SwiftUI
import AppKit

enum BoardTheme {
    // Resolve at drawing time, including in Canvas and native hosting windows.
    // Never snapshot NSApp.effectiveAppearance into a static SwiftUI color.
    static let ink = adaptive("ink", light: (0.18, 0.195, 0.22), dark: (0.90, 0.915, 0.94))
    static let secondary = adaptive("secondary", light: (0.37, 0.395, 0.43), dark: (0.65, 0.685, 0.735))
    static let orange = adaptive("orange", light: (0.74, 0.215, 0.075), dark: (1, 0.54, 0.36))
    static let paper = adaptive("paper", light: (0.951, 0.942, 0.921), dark: (0.12, 0.135, 0.16))
    static let paperShade = adaptive("paper-shade", light: (0.914, 0.906, 0.886), dark: (0.15, 0.165, 0.19))
    static let surface = adaptive("surface", light: (0.978, 0.970, 0.953), dark: (0.18, 0.195, 0.22))
    static let nativeField = native("field", light: (0.918, 0.909, 0.889), dark: (0.085, 0.10, 0.12))
    static let field = Color(nsColor: nativeField)
    static let line = Color(nsColor: native("line", light: (0.23, 0.255, 0.29), dark: (0.75, 0.79, 0.85), lightAlpha: 0.14, darkAlpha: 0.18))

    private typealias RGB = (CGFloat, CGFloat, CGFloat)
    private static func adaptive(_ name: String, light: RGB, dark: RGB) -> Color {
        Color(nsColor: native(name, light: light, dark: dark))
    }
    private static func native(_ name: String, light: RGB, dark: RGB, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: NSColor.Name("Board.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}
