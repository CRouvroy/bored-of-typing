// Controls adapted from Desk; see LICENSE.
import SwiftUI

/// Plain action rows inside the floating controls, matching Desk's quiet rail.
struct BoardDockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? BoardTheme.paperShade : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
